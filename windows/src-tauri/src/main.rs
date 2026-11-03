#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod home_assistant;
mod placement;
mod update_manifest;
use home_assistant::{ha_execute, ha_snapshot};
use placement::{
    drag_settle_finished, key_state_is_down, move_is_user_driven, move_suppression_deadline, place,
    primary_button_virtual_key, resized_top, taskbar_edge, PanelAnchor, PanelPlacement,
    PlacementInput, Rect, DRAG_SETTLE_MS,
};

#[cfg(test)]
static ORIGIN_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use ring::digest::{digest, SHA256};
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{LazyLock, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::{
    menu::{Menu, MenuBuilder},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewWindow, WindowEvent,
};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

static LAST_FOCUS_LOSS_MS: AtomicU64 = AtomicU64::new(0);
static PIN_POPOVER: AtomicBool = AtomicBool::new(false);

#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;

/// Keeps spawned helper processes (go2rtc, ffmpeg) from flashing a console window.
#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

struct TrayAndHotkeyState {
    active_shortcut: Option<Shortcut>,
    shortcut_label: Option<String>,
    update_version: Option<String>,
}

static TRAY_AND_HOTKEY_STATE: LazyLock<RwLock<TrayAndHotkeyState>> = LazyLock::new(|| {
    RwLock::new(TrayAndHotkeyState {
        active_shortcut: None,
        shortcut_label: Some("Alt+M".to_string()),
        update_version: None,
    })
});

fn is_standalone_function_key(code: Code) -> bool {
    matches!(
        code,
        Code::F1
            | Code::F2
            | Code::F3
            | Code::F4
            | Code::F5
            | Code::F6
            | Code::F7
            | Code::F8
            | Code::F9
            | Code::F10
            | Code::F11
            | Code::F12
            | Code::F13
            | Code::F14
            | Code::F15
            | Code::F16
            | Code::F17
            | Code::F18
            | Code::F19
            | Code::F20
    )
}

/// Validates and parses a global shortcut string (#43).
/// Requires at least one modifier (`Ctrl`/`Alt`/`Shift`/`Super`) or a standalone `F1`–`F20` key.
fn parse_global_shortcut(raw: &str) -> Result<(Shortcut, String), String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("快捷键不能为空".to_string());
    }
    let shortcut = Shortcut::from_str(trimmed)
        .map_err(|_| format!("快捷键格式无效：{trimmed}"))?;
    if shortcut.mods.is_empty() && !is_standalone_function_key(shortcut.key) {
        return Err("快捷键需要包含 Ctrl / Alt / Shift / Win 修饰键，或使用 F1–F20".to_string());
    }
    Ok((shortcut, trimmed.to_string()))
}

/// Configured origins retain the protocol and port, so permission for one service
/// cannot authorize another service on the same host (#29).
static EXTRA_ALLOWED_ORIGINS: LazyLock<RwLock<HashSet<String>>> =
    LazyLock::new(|| RwLock::new(HashSet::new()));

const BUILT_IN_HOST_SUFFIXES: &[&str] = &[
    "account.xiaomi.com",
    "api.io.mi.com",
    "miot-spec.org",
    // Public release metadata for the update check (#39); no credentials are sent.
    "api.github.com",
];

/// Windows release page opened from the tray/update row (#39).
const RELEASE_PAGE_URL: &str = "https://github.com/jryang1997/MenuBarMijia/releases/latest";

fn normalize_host(raw: &str) -> String {
    raw.trim()
        .trim_end_matches('.')
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_ascii_lowercase()
}

fn url_origin(url: &reqwest::Url) -> Option<String> {
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    let host = normalize_host(url.host_str()?);
    if host.is_empty() {
        return None;
    }
    let authority = if host.contains(':') {
        format!("[{host}]")
    } else {
        host
    };
    Some(format!(
        "{}://{}:{}", url.scheme(), authority, url.port_or_known_default()?
    ))
}

fn normalize_extra_origin(raw: &str) -> Option<String> {
    let url = reqwest::Url::parse(raw.trim()).ok()?;
    if url.path() != "/" || url.query().is_some() || url.fragment().is_some() {
        return None;
    }
    url_origin(&url)
}

fn check_url_allowed(url: &reqwest::Url, extra: &HashSet<String>) -> Result<(), String> {
    let origin = url_origin(url)
        .ok_or_else(|| "native_http 地址必须是无用户凭据的 http/https 地址".to_string())?;
    let host = normalize_host(url.host_str().unwrap_or_default());
    let built_in_host = BUILT_IN_HOST_SUFFIXES
        .iter()
        .any(|suffix| host == *suffix || host.ends_with(&format!(".{suffix}")));
    let allowed = if built_in_host {
        url.scheme() == "https" && url.port_or_known_default() == Some(443)
    } else {
        extra.contains(&origin)
    };
    if allowed {
        Ok(())
    } else {
        Err(format!("native_http 拒绝访问未授权来源：{origin}"))
    }
}

fn redirect_allowed(original_origin: &str, next: &reqwest::Url, extra: &HashSet<String>) -> bool {
    url_origin(next).as_deref() == Some(original_origin) && check_url_allowed(next, extra).is_ok()
}

fn allowed_origins_snapshot() -> Result<HashSet<String>, String> {
    EXTRA_ALLOWED_ORIGINS
        .read()
        .map(|origins| origins.clone())
        .map_err(|_| "origin allowlist unavailable".to_string())
}

const CREDENTIAL_SERVICE: &str = "com.jryang.menubarmijia";
const CREDENTIAL_NAMES: &[&str] = &["mi_session", "ha_token", "assistant_api_key"];

/// Fixed credential names only: this must not become a generic key/value store (#28).
fn allowed_credential_name(name: &str) -> Result<&str, String> {
    if CREDENTIAL_NAMES.contains(&name) {
        return Ok(name);
    }
    if let Some(suffix) = name.strip_prefix("assistant_api_key_") {
        if !suffix.is_empty()
            && suffix.len() <= 48
            && suffix
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            return Ok(name);
        }
    }
    Err(format!("不允许的凭据名称：{name}"))
}

fn credential_entry(name: &str) -> Result<keyring::Entry, String> {
    let name = allowed_credential_name(name)?;
    keyring::Entry::new(CREDENTIAL_SERVICE, name)
        .map_err(|error| format!("无法打开 Windows 凭据管理器：{error}"))
}

fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn tray_labels_for_shortcut(shortcut_label: Option<&str>) -> (String, String) {
    match shortcut_label.map(str::trim).filter(|s| !s.is_empty()) {
        Some(label) => (
            format!("打开/隐藏控制中心 ({label})"),
            format!("MenuBarMijia · 菜单栏米家 ({label})"),
        ),
        None => (
            "打开/隐藏控制中心".to_string(),
            "MenuBarMijia · 菜单栏米家".to_string(),
        ),
    }
}

/// Rebuilds the tray menu, adding the "有新版本" entry only when a release is known (#39)
/// and showing the active global shortcut when enabled (#43).
fn build_tray_menu(
    app: &AppHandle,
    shortcut_label: Option<&str>,
    update_version: Option<&str>,
) -> tauri::Result<Menu<tauri::Wry>> {
    let (toggle_text, _) = tray_labels_for_shortcut(shortcut_label);
    let mut builder = MenuBuilder::new(app).text("toggle", toggle_text);
    if let Some(version) = update_version {
        builder = builder.text("update", format!("有新版本 v{version}，点击查看"));
    }
    builder.text("quit", "退出 MenuBarMijia").build()
}

fn refresh_tray_chrome(app: &AppHandle, shortcut_label: Option<&str>, update_version: Option<&str>) {
    let Some(tray) = app.tray_by_id("main-tray") else {
        return;
    };
    let (_, tooltip) = tray_labels_for_shortcut(shortcut_label);
    let _ = tray.set_tooltip(Some(tooltip));
    if let Ok(menu) = build_tray_menu(app, shortcut_label, update_version) {
        let _ = tray.set_menu(Some(menu));
    }
}

/// The only external URL the frontend may open: a MenuBarMijia release page on GitHub.
fn validated_release_url(raw: &str) -> Result<String, String> {
    let url = reqwest::Url::parse(raw).map_err(|_| "更新页面地址无效".to_string())?;
    if url.scheme() != "https" {
        return Err("更新页面只允许 https 地址".to_string());
    }
    let host = url
        .host_str()
        .map(normalize_host)
        .unwrap_or_default();
    if host != "github.com" {
        return Err(format!("拒绝打开非 GitHub 地址：{host}"));
    }
    if !url.path().starts_with("/jryang1997/MenuBarMijia/releases") {
        return Err("拒绝打开非 MenuBarMijia 发布页".to_string());
    }
    Ok(url.to_string())
}

#[cfg(windows)]
#[link(name = "shell32")]
extern "system" {
    fn ShellExecuteW(
        hwnd: *mut core::ffi::c_void,
        operation: *const u16,
        file: *const u16,
        parameters: *const u16,
        directory: *const u16,
        show_cmd: i32,
    ) -> isize;
}

#[cfg(windows)]
fn open_url_in_browser(url: &str) {
    use std::os::windows::ffi::OsStrExt;

    let wide = |value: &str| -> Vec<u16> {
        std::ffi::OsStr::new(value)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    };
    let operation = wide("open");
    let file = wide(url);
    // ShellExecuteW returns a value > 32 on success; a failure has no useful recovery here.
    unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            operation.as_ptr(),
            file.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            1,
        );
    }
}

#[cfg(not(windows))]
fn open_url_in_browser(_url: &str) {}

#[tauri::command]
fn open_release_page(url: String) -> Result<(), String> {
    let target = validated_release_url(&url)?;
    open_url_in_browser(&target);
    Ok(())
}

/// Offline Ed25519 public key (32-byte raw, base64) shared with `UpdateChecker.updateSigningPublicKeyBase64` (ADR-0005).
const UPDATE_SIGNING_PUBLIC_KEY_BASE64: &str = "rLwWXuP0sOZvgd/KusLTTmBXN9DAZ9EzPBNhFSn9yUo=";

/// Optional second key trusted during a rotation; empty when unused.
/// See `docs/security/update-signing-key-rotation.md`.
const UPDATE_SIGNING_OVERLAP_PUBLIC_KEY_BASE64: &str = "";

/// Every key a release manifest may be signed with; `key_id` selects one.
fn update_signing_public_keys() -> Vec<&'static str> {
    [
        UPDATE_SIGNING_PUBLIC_KEY_BASE64,
        UPDATE_SIGNING_OVERLAP_PUBLIC_KEY_BASE64,
    ]
    .into_iter()
    .filter(|key| !key.is_empty())
    .collect()
}

const STAGED_INSTALLER_PREFIX: &str = "MenuBarMijia-update-";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct InstallerAssetPayload {
    name: String,
    download_url: String,
    #[allow(dead_code)]
    #[serde(default)]
    size_bytes: u64,
    manifest_url: String,
}

pub(crate) fn validated_release_asset_url(raw: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(raw.trim()).map_err(|_| "更新包下载地址无效".to_string())?;
    if url.scheme() != "https"
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("更新包地址必须是无附加参数的 https://github.com 地址".to_string());
    }
    let host = url.host_str().map(normalize_host).unwrap_or_default();
    if host != "github.com" {
        return Err(format!("拒绝从非 GitHub 地址下载更新包：{host}"));
    }
    if !url
        .path()
        .starts_with("/jryang1997/MenuBarMijia/releases/download/")
    {
        return Err("拒绝下载非 MenuBarMijia 官方发布附件".to_string());
    }
    Ok(url)
}

fn release_asset_redirect_allowed(next: &reqwest::Url) -> bool {
    if next.scheme() != "https"
        || next.port_or_known_default() != Some(443)
        || !next.username().is_empty()
        || next.password().is_some()
    {
        return false;
    }
    let host = next.host_str().map(normalize_host).unwrap_or_default();
    host == "github.com"
        || host == "githubusercontent.com"
        || host.ends_with(".githubusercontent.com")
}

fn parse_sha256_hex(raw: &str) -> Option<String> {
    let token = raw.split_whitespace().next()?;
    let candidate = token
        .strip_prefix("sha256:")
        .or_else(|| token.strip_prefix("SHA256:"))
        .unwrap_or(token)
        .to_ascii_lowercase();
    if candidate.len() == 64 && candidate.chars().all(|c| c.is_ascii_hexdigit()) {
        Some(candidate)
    } else {
        None
    }
}

fn sanitize_installer_filename(raw: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty()
        || trimmed.contains('/')
        || trimmed.contains('\\')
        || trimmed.contains(':')
        || trimmed.contains("..")
        || trimmed.chars().any(|c| c.is_control())
    {
        return Err("更新安装包文件名无效".to_string());
    }
    let lower = trimmed.to_ascii_lowercase();
    if !lower.ends_with(".exe") && !lower.ends_with(".msi") {
        return Err("仅支持 .exe 或 .msi 安装包".to_string());
    }
    Ok(trimmed.to_string())
}

pub(crate) fn compute_sha256_hex(bytes: &[u8]) -> String {
    let sum = digest(&SHA256, bytes);
    let mut out = String::with_capacity(64);
    for byte in sum.as_ref() {
        use std::fmt::Write;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

/// Decodes standard RFC 4648 base64 (ignoring surrounding whitespace).
fn decode_base64_strict(raw: &str) -> Option<Vec<u8>> {
    let cleaned: Vec<u8> = raw
        .bytes()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    if cleaned.is_empty() || cleaned.len() % 4 != 0 {
        return None;
    }
    fn val(b: u8) -> Option<u8> {
        match b {
            b'A'..=b'Z' => Some(b - b'A'),
            b'a'..=b'z' => Some(b - b'a' + 26),
            b'0'..=b'9' => Some(b - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity((cleaned.len() / 4) * 3);
    for (idx, chunk) in cleaned.chunks_exact(4).enumerate() {
        let is_last = idx + 1 == cleaned.len() / 4;
        let a = val(chunk[0])?;
        let b = val(chunk[1])?;
        match (chunk[2], chunk[3]) {
            (b'=', b'=') if is_last => {
                if (b & 0x0f) != 0 {
                    return None;
                }
                out.push((a << 2) | (b >> 4));
            }
            (c_byte, b'=') if is_last => {
                let c = val(c_byte)?;
                if (c & 0x03) != 0 {
                    return None;
                }
                out.push((a << 2) | (b >> 4));
                out.push((b << 4) | (c >> 2));
            }
            (b'=', _) | (_, b'=') => return None,
            (c_byte, d_byte) => {
                let c = val(c_byte)?;
                let d = val(d_byte)?;
                out.push((a << 2) | (b >> 4));
                out.push((b << 4) | (c >> 2));
                out.push((c << 6) | d);
            }
        }
    }
    Some(out)
}

/// Verifies a detached Ed25519 signature over `data` against `public_key_base64` (ADR-0005).
pub(crate) fn verify_ed25519_signature(
    signature_base64: &str,
    public_key_base64: &str,
    data: &[u8],
) -> Result<(), String> {
    let trimmed_sig = signature_base64.trim();
    if trimmed_sig.is_empty() {
        return Err("更新包缺少 Ed25519 数字签名（.ed25519.sig），已中止安装".to_string());
    }
    let key_bytes = decode_base64_strict(public_key_base64)
        .filter(|bytes| bytes.len() == 32)
        .ok_or_else(|| "内置 Ed25519 更新公钥无效".to_string())?;
    let sig_bytes = decode_base64_strict(trimmed_sig)
        .filter(|bytes| bytes.len() == 64)
        .ok_or_else(|| "更新包 Ed25519 数字签名格式无效，已中止安装".to_string())?;
    let public_key = UnparsedPublicKey::new(&ED25519, key_bytes);
    public_key
        .verify(data, &sig_bytes)
        .map_err(|_| "更新包 Ed25519 数字签名校验失败：签名与安装包内容不匹配，已中止安装".to_string())
}

fn sweep_stale_update_installers() {
    let Ok(entries) = std::fs::read_dir(std::env::temp_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if name
            .to_str()
            .is_some_and(|s| s.starts_with(STAGED_INSTALLER_PREFIX))
        {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

fn elevated_launch_powershell_command(is_msi: bool) -> &'static str {
    if is_msi {
        "Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $env:MIJIA_INSTALLER_PATH) -Verb RunAs -ErrorAction Stop"
    } else {
        "Start-Process -FilePath $env:MIJIA_INSTALLER_PATH -Verb RunAs -ErrorAction Stop"
    }
}

fn launch_installer(installer_path: &std::path::Path) -> Result<(), String> {
    let is_msi = installer_path
        .extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| ext.eq_ignore_ascii_case("msi"));
    let mut cmd = if is_msi {
        let mut c = std::process::Command::new("msiexec");
        c.arg("/i").arg(installer_path);
        c
    } else {
        std::process::Command::new(installer_path)
    };
    match cmd.spawn() {
        Ok(mut child) => {
            std::thread::sleep(Duration::from_millis(250));
            if let Ok(Some(status)) = child.try_wait() {
                if !status.success() {
                    return Err(format!("安装程序未能正常启动（退出码 {:?}）", status.code()));
                }
            }
            Ok(())
        }
        Err(err) if err.raw_os_error() == Some(740) => {
            // ERROR_ELEVATION_REQUIRED (740): invoke ShellExecute with -Verb RunAs so UAC prompts
            // and wait for Start-Process to finish spawning the elevated installer (or fail if declined).
            let status = std::process::Command::new("powershell")
                .args([
                    "-NoProfile",
                    "-NonInteractive",
                    "-WindowStyle",
                    "Hidden",
                    "-Command",
                    elevated_launch_powershell_command(is_msi),
                ])
                .env("MIJIA_INSTALLER_PATH", installer_path)
                .status()
                .map_err(|e| format!("启动安装程序失败：{e}"))?;
            if !status.success() {
                return Err(format!(
                    "启动安装程序失败（未获管理员授权或启动被取消，退出码 {:?}）",
                    status.code()
                ));
            }
            Ok(())
        }
        Err(err) => Err(format!("启动安装程序失败：{err}")),
    }
}

#[tauri::command]
async fn install_update(app: AppHandle, asset: InstallerAssetPayload) -> Result<(), String> {
    let pair = update_manifest::release_pair(&asset.name, &asset.download_url, &asset.manifest_url)?;
    let running_version = app.package_info().version.to_string();

    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 5 {
                return attempt.stop();
            }
            if release_asset_redirect_allowed(attempt.url()) {
                attempt.follow()
            } else {
                attempt.stop()
            }
        }))
        .timeout(Duration::from_secs(120))
        .user_agent("MenuBarMijia-Windows")
        .build()
        .map_err(|err| format!("无法初始化下载客户端：{err}"))?;

    let manifest_resp = client
        .get(pair.manifest_url.clone())
        .send()
        .await
        .map_err(|err| format!("下载更新清单失败：{err}"))?;
    if !manifest_resp.status().is_success() {
        return Err(format!(
            "下载更新清单失败（HTTP {}）",
            manifest_resp.status().as_u16()
        ));
    }
    let manifest_bytes = manifest_resp
        .bytes()
        .await
        .map_err(|err| format!("读取更新清单失败：{err}"))?;

    let sig_resp = client
        .get(pair.signature_url.clone())
        .send()
        .await
        .map_err(|err| format!("下载 Ed25519 更新签名失败：{err}"))?;
    if sig_resp.status().as_u16() == 404 {
        return Err("更新包缺少 Ed25519 数字签名（.update.json.ed25519.sig），已中止安装".to_string());
    }
    if !sig_resp.status().is_success() {
        return Err(format!(
            "下载 Ed25519 更新签名失败（HTTP {}）",
            sig_resp.status().as_u16()
        ));
    }
    let sig_text = sig_resp
        .text()
        .await
        .map_err(|err| format!("读取 Ed25519 更新签名失败：{err}"))?;

    let response = client
        .get(pair.installer_url.clone())
        .send()
        .await
        .map_err(|err| format!("下载更新安装包失败：{err}"))?;
    if !response.status().is_success() {
        return Err(format!("下载更新安装包失败（HTTP {}）", response.status().as_u16()));
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|err| format!("读取更新安装包数据失败：{err}"))?;

    let trusted_public_keys = update_signing_public_keys();
    update_manifest::accept_update_manifest(
        &manifest_bytes,
        &sig_text,
        &trusted_public_keys,
        &pair.version,
        &running_version,
        &asset.name,
        &bytes,
    )
    .map_err(update_manifest::accept_failure_message)?;

    sweep_stale_update_installers();
    let installer_path = std::env::temp_dir().join(format!(
        "{STAGED_INSTALLER_PREFIX}{}-{}",
        std::process::id(),
        asset.name
    ));
    std::fs::write(&installer_path, &bytes)
        .map_err(|err| format!("写入临时安装程序失败：{err}"))?;

    if let Err(err) = launch_installer(&installer_path) {
        let _ = std::fs::remove_file(&installer_path);
        return Err(err);
    }

    let app_for_exit = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(150));
        app_for_exit.exit(0);
    });
    Ok(())
}

#[tauri::command]
fn set_update_available(app: AppHandle, version: Option<String>) -> Result<(), String> {
    let shortcut_label = {
        let mut guard = TRAY_AND_HOTKEY_STATE
            .write()
            .map_err(|_| "托盘状态不可用".to_string())?;
        guard.update_version = version.clone();
        guard.shortcut_label.clone()
    };
    let tray = app
        .tray_by_id("main-tray")
        .ok_or_else(|| "托盘尚未就绪".to_string())?;
    let menu = build_tray_menu(&app, shortcut_label.as_deref(), version.as_deref())
        .map_err(|error| error.to_string())?;
    tray.set_menu(Some(menu)).map_err(|error| error.to_string())
}

/// Applies the user's global shortcut preference (#43), adhering to Coding Standard #3:
/// disabling immediately unregisters the system-wide hotkey; enabling or changing unregisters
/// any previous hotkey before registering the new one and surfaces conflicts as `Err`.
#[tauri::command]
fn set_global_shortcut(app: AppHandle, enabled: bool, shortcut: String) -> Result<(), String> {
    let (old_shortcut, update_version) = {
        let guard = TRAY_AND_HOTKEY_STATE
            .read()
            .map_err(|_| "快捷键状态不可用".to_string())?;
        (guard.active_shortcut, guard.update_version.clone())
    };

    if !enabled {
        if let Some(old) = old_shortcut {
            let _ = app.global_shortcut().unregister(old);
        }
        if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
            guard.active_shortcut = None;
            guard.shortcut_label = None;
        }
        refresh_tray_chrome(&app, None, update_version.as_deref());
        return Ok(());
    }

    let (parsed, label) = parse_global_shortcut(&shortcut)?;
    if old_shortcut == Some(parsed) && app.global_shortcut().is_registered(parsed) {
        if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
            guard.shortcut_label = Some(label.clone());
        }
        refresh_tray_chrome(&app, Some(&label), update_version.as_deref());
        return Ok(());
    }

    if let Some(old) = old_shortcut {
        let _ = app.global_shortcut().unregister(old);
    }

    if let Err(err) = app.global_shortcut().register(parsed) {
        if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
            guard.active_shortcut = None;
            guard.shortcut_label = None;
        }
        refresh_tray_chrome(&app, None, update_version.as_deref());
        return Err(format!("这个组合已被其他应用占用或无法注册（{err}），换一个再试。"));
    }

    if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
        guard.active_shortcut = Some(parsed);
        guard.shortcut_label = Some(label.clone());
    }
    refresh_tray_chrome(&app, Some(&label), update_version.as_deref());
    Ok(())
}

#[derive(Serialize)]
struct NativeHttpResponse {
    status: u16,
    headers: HashMap<String, String>,
    body: String,
}

#[tauri::command]
async fn native_http(
    url: String,
    method: Option<String>,
    headers: Option<HashMap<String, String>>,
    body: Option<String>,
    follow_redirects: Option<bool>,
    timeout_ms: Option<u64>,
) -> Result<NativeHttpResponse, String> {
    let allowed_origins = allowed_origins_snapshot()?;
    let parsed_url = reqwest::Url::parse(&url).map_err(|e| format!("native_http 地址无效：{e}"))?;
    check_url_allowed(&parsed_url, &allowed_origins)?;

    let follow = follow_redirects.unwrap_or(true);
    let policy = if follow {
        let redirect_origins = allowed_origins.clone();
        let original_origin = url_origin(&parsed_url).expect("validated request origin");
        reqwest::redirect::Policy::custom(move |attempt| {
            if attempt.previous().len() >= 5 {
                return attempt.stop();
            }
            // Even another configured origin must not receive this request's headers or body.
            if redirect_allowed(&original_origin, attempt.url(), &redirect_origins) {
                attempt.follow()
            } else {
                attempt.stop()
            }
        })
    } else {
        reqwest::redirect::Policy::none()
    };

    let client = reqwest::Client::builder()
        .redirect(policy)
        .timeout(Duration::from_millis(timeout_ms.unwrap_or(15_000)))
        .build()
        .map_err(|e| e.to_string())?;

    let verb = method.unwrap_or_else(|| "GET".to_string()).to_uppercase();
    let mut req = match verb.as_str() {
        "GET" => client.get(&url),
        "POST" => client.post(&url),
        "PUT" => client.put(&url),
        "PATCH" => client.patch(&url),
        "DELETE" => client.delete(&url),
        other => return Err(format!("native_http 不支持的方法：{other}")),
    };

    if let Some(hdrs) = headers {
        let mut map = HeaderMap::new();
        for (k, v) in hdrs {
            // Request framing is owned by reqwest; letting the frontend set these
            // could smuggle a second request past the URL allowlist.
            if matches!(
                k.to_ascii_lowercase().as_str(),
                "host" | "content-length" | "transfer-encoding" | "connection" | "upgrade"
            ) {
                continue;
            }
            if let (Ok(name), Ok(val)) = (HeaderName::from_str(&k), HeaderValue::from_str(&v)) {
                map.insert(name, val);
            }
        }
        req = req.headers(map);
    }

    if let Some(b) = body {
        req = req.body(b);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    // A stopped redirect comes back as a 3xx here; surfacing it as an error is
    // clearer than handing the frontend a response from a host it may not use.
    if follow && resp.status().is_redirection() && status != 304 {
        return Err("native_http 拒绝跨来源或未授权重定向".to_string());
    }

    let mut out_headers: HashMap<String, String> = HashMap::new();
    for (name, val) in resp.headers().iter() {
        if let Ok(v_str) = val.to_str() {
            let key = name.as_str().to_lowercase();
            out_headers
                .entry(key)
                .and_modify(|existing| {
                    existing.push_str("; ");
                    existing.push_str(v_str);
                })
                .or_insert_with(|| v_str.to_string());
        }
    }

    let text = resp.text().await.map_err(|e| e.to_string())?;
    Ok(NativeHttpResponse {
        status,
        headers: out_headers,
        body: text,
    })
}

#[tauri::command]
fn set_allowed_origins(_origins: Vec<String>) -> Result<(), String> {
    Err("前端不能自行授权网络来源".into())
}

fn origin_from_endpoint(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    };
    let url = reqwest::Url::parse(&with_scheme).ok()?;
    url_origin(&url)
}

fn requested_service_origins(assistant_url: &str, ha_url: &str) -> Result<HashSet<String>, String> {
    let mut origins = HashSet::new();
    for raw in [assistant_url, ha_url] {
        if raw.trim().is_empty() {
            continue;
        }
        let origin = origin_from_endpoint(raw)
            .ok_or_else(|| format!("invalid configured endpoint: {raw}"))?;
        origins.insert(origin);
    }
    Ok(origins)
}

fn read_origin_store(path: &std::path::Path) -> HashSet<String> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashSet::new();
    };
    let Ok(values) = serde_json::from_str::<Vec<String>>(&text) else {
        return HashSet::new();
    };
    values
        .into_iter()
        .filter_map(|value| normalize_extra_origin(&value))
        .collect()
}

fn write_origin_store(path: &std::path::Path, origins: &HashSet<String>) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("无法保存已授权来源：{error}"))?;
    }
    let mut values: Vec<&String> = origins.iter().collect();
    values.sort();
    let body = serde_json::to_string(&values).map_err(|error| error.to_string())?;
    std::fs::write(path, body).map_err(|error| format!("无法保存已授权来源：{error}"))
}

/// `%APPDATA%\MenuBarMijia`, the folder for the Windows-only state files.
#[cfg(not(test))]
fn app_state_dir() -> Option<std::path::PathBuf> {
    let base = std::env::var_os("APPDATA")?;
    Some(std::path::PathBuf::from(base).join("MenuBarMijia"))
}

#[cfg(test)]
fn authorization_store_path() -> Option<std::path::PathBuf> {
    None
}

#[cfg(not(test))]
fn authorization_store_path() -> Option<std::path::PathBuf> {
    Some(app_state_dir()?.join("authorized-http-origins.json"))
}

fn store_authorized(origins: &HashSet<String>) -> Result<(), String> {
    if let Some(path) = authorization_store_path() {
        write_origin_store(&path, origins)?;
    }
    let mut guard = EXTRA_ALLOWED_ORIGINS
        .write()
        .map_err(|_| "origin allowlist unavailable".to_string())?;
    *guard = origins.clone();
    Ok(())
}

fn decide_service_origins(
    current: &HashSet<String>,
    assistant_url: &str,
    ha_url: &str,
    confirm: impl Fn(&str) -> bool,
) -> Result<HashSet<String>, String> {
    let requested = requested_service_origins(assistant_url, ha_url)?;
    let mut novel: Vec<String> = requested.difference(current).cloned().collect();
    novel.sort();
    for origin in &novel {
        if !confirm(origin) {
            return Err(format!("未授权的网络来源：{origin}"));
        }
    }
    Ok(requested)
}

fn authorize_service_endpoints(
    assistant_url: &str,
    ha_url: &str,
    confirm: impl Fn(&str) -> bool,
) -> Result<(), String> {
    let current = allowed_origins_snapshot()?;
    let next = decide_service_origins(&current, assistant_url, ha_url, confirm)?;
    store_authorized(&next)
}

#[cfg(test)]
fn user_confirms_origin(_origin: &str) -> bool {
    false
}

#[cfg(all(windows, not(test)))]
fn user_confirms_origin(origin: &str) -> bool {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;
    let text = format!(
        "允许 MenuBarMijia 连接这个地址吗？\n\n{origin}\n\n只有你在设置里填写的 Home Assistant 或 AI 服务地址才应该出现在这里。"
    );
    let text_wide: Vec<u16> = OsStr::new(&text).encode_wide().chain(std::iter::once(0)).collect();
    let title_wide: Vec<u16> = OsStr::new("MenuBarMijia").encode_wide().chain(std::iter::once(0)).collect();
    #[link(name = "user32")]
    extern "system" {
        fn MessageBoxW(
            hwnd: *mut std::ffi::c_void,
            text: *const u16,
            caption: *const u16,
            utype: u32,
        ) -> i32;
    }
    const MB_YESNO: u32 = 0x0000_0004;
    const MB_ICONWARNING: u32 = 0x0000_0030;
    const MB_DEFBUTTON2: u32 = 0x0000_0100;
    const IDYES: i32 = 6;
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            text_wide.as_ptr(),
            title_wide.as_ptr(),
            MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2,
        ) == IDYES
    }
}

#[cfg(all(not(windows), not(test)))]
fn user_confirms_origin(_origin: &str) -> bool {
    false
}

#[tauri::command]
fn set_service_endpoints(assistant_url: String, ha_url: String) -> Result<(), String> {
    authorize_service_endpoints(&assistant_url, &ha_url, user_confirms_origin)
}

#[tauri::command]
fn secure_store_get(name: String) -> Result<Option<String>, String> {
    let entry = credential_entry(&name)?;
    match entry.get_password() {
        Ok(value) => Ok(Some(value)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(format!("读取 Windows 凭据失败：{error}")),
    }
}

#[tauri::command]
fn secure_store_set(name: String, value: String) -> Result<(), String> {
    if value.is_empty() {
        return secure_store_delete(name);
    }
    let entry = credential_entry(&name)?;
    entry
        .set_password(&value)
        .map_err(|error| format!("写入 Windows 凭据失败：{error}"))
}

#[tauri::command]
fn secure_store_delete(name: String) -> Result<(), String> {
    let entry = credential_entry(&name)?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(format!("删除 Windows 凭据失败：{error}")),
    }
}

#[tauri::command]
fn hide_panel(app: AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.hide();
    }
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    shutdown_camera_daemons();
    app.exit(0);
}

#[tauri::command]
fn set_pin_popover(pin: bool) {
    PIN_POPOVER.store(pin, Ordering::SeqCst);
}

/// The persisted placement the settings sheet shows and every open honours (#204).
#[tauri::command]
fn panel_placement() -> PanelPlacement {
    current_panel_placement()
}

#[tauri::command]
fn set_panel_placement(app: AppHandle, anchor: PanelAnchor) -> Result<(), String> {
    let saved = store_panel_placement(PanelPlacement { anchor });
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) {
            position_popover(&window, None);
        }
    }
    saved
}

/// The panel has no title bar, so a press on the header hands over to the OS move loop (#204).
#[tauri::command]
fn start_panel_drag(app: AppHandle, window: WebviewWindow) {
    // A header press is user movement from here on: stop ignoring `Moved` events even if the panel was
    // placed moments ago, and let the settle watcher end the session once the pointer rests.
    USER_DRAG_ACTIVE.store(true, Ordering::SeqCst);
    USER_MOVES_SEEN.store(false, Ordering::SeqCst);
    PROGRAMMATIC_MOVE_UNTIL_MS.store(0, Ordering::SeqCst);
    schedule_drag_settle(app);
    let _ = window.start_dragging();
}

static GROK_SIDE_LEFT: AtomicBool = AtomicBool::new(false);

fn panel_sidecar_on_left(room_left: f64, room_right: f64, scale: f64) -> bool {
    if room_right >= (232.0 + 20.0) * scale {
        false
    } else if room_left >= (232.0 + 12.0) * scale {
        true
    } else {
        room_left > room_right
    }
}

/// Panel placement preference (auto or a fixed work-area corner). It lives beside the window rather
/// than in the webview's local storage because a drag has to save it from the window event loop (#204).
static PANEL_PLACEMENT: LazyLock<RwLock<PanelPlacement>> =
    LazyLock::new(|| RwLock::new(PanelPlacement::default()));

/// Until this timestamp, `Moved` events come from our own placement calls, not from a drag.
static PROGRAMMATIC_MOVE_UNTIL_MS: AtomicU64 = AtomicU64::new(0);
/// Set from a header press until the drag settles; while it is set, placement calls must not swallow
/// the movement the user is producing (#204 review).
static USER_DRAG_ACTIVE: AtomicBool = AtomicBool::new(false);
/// Whether the current drag session actually moved the window, so a plain click never snaps it.
static USER_MOVES_SEEN: AtomicBool = AtomicBool::new(false);
/// Last user-driven move; the drag is over once the window stops moving for a moment.
static MOVE_SNAP_DEADLINE_MS: AtomicU64 = AtomicU64::new(0);
static MOVE_SNAP_SCHEDULED: AtomicBool = AtomicBool::new(false);

fn current_panel_placement() -> PanelPlacement {
    PANEL_PLACEMENT.read().map(|guard| *guard).unwrap_or_default()
}

fn remember_panel_placement(placement: PanelPlacement) {
    if let Ok(mut guard) = PANEL_PLACEMENT.write() {
        *guard = placement;
    }
}

fn store_panel_placement(placement: PanelPlacement) -> Result<(), String> {
    remember_panel_placement(placement);
    match panel_placement_path() {
        Some(path) => write_panel_placement(&path, placement),
        None => Ok(()),
    }
}

fn read_panel_placement(path: &std::path::Path) -> PanelPlacement {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn write_panel_placement(path: &std::path::Path, placement: PanelPlacement) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| format!("无法保存面板位置：{error}"))?;
    }
    let body = serde_json::to_string(&placement).map_err(|error| error.to_string())?;
    std::fs::write(path, body).map_err(|error| format!("无法保存面板位置：{error}"))
}

#[cfg(test)]
fn panel_placement_path() -> Option<std::path::PathBuf> {
    None
}

#[cfg(not(test))]
fn panel_placement_path() -> Option<std::path::PathBuf> {
    Some(app_state_dir()?.join("panel-placement.json"))
}

fn load_panel_placement() {
    if let Some(path) = panel_placement_path() {
        remember_panel_placement(read_panel_placement(&path));
    }
}

/// Full monitor bounds plus the work area that excludes docked taskbars. A runtime that cannot report
/// a work area falls back to the full bounds, which behaves like a taskbar-free monitor.
fn monitor_rects(monitor: &Monitor) -> (Rect, Rect) {
    let position = monitor.position();
    let size = monitor.size();
    let full = Rect::new(position.x, position.y, size.width as i32, size.height as i32);
    let area = monitor.work_area();
    let work = Rect::new(
        area.position.x,
        area.position.y,
        area.size.width as i32,
        area.size.height as i32,
    );
    if work.width <= 0 || work.height <= 0 {
        (full, full)
    } else {
        (full, work)
    }
}

/// Left inset of the main card column inside the panel; the sidecar widens the window to its left.
fn main_column_inset(window_width: i32, scale: f64) -> i32 {
    if GROK_SIDE_LEFT.load(Ordering::SeqCst) {
        (window_width - (472.0 * scale).round() as i32 - (8.0 * scale).round() as i32).max(0)
    } else {
        0
    }
}

/// Keep the main card column fixed while reserving space for the side-mounted assistant.
#[tauri::command]
fn set_panel_height(
    app: AppHandle,
    height: f64,
    expanded: bool,
    side_left: bool,
    grok_enabled: Option<bool>,
) -> bool {
    let Some(window) = app.get_webview_window("main") else { return side_left };
    let monitor = window.current_monitor().ok().flatten().or_else(|| window.primary_monitor().ok().flatten());
    let scale = monitor.as_ref().map(|m| m.scale_factor()).unwrap_or(1.0);
    let (full, work) = monitor
        .as_ref()
        .map(monitor_rects)
        .unwrap_or((Rect::new(0, 0, 1920, 1080), Rect::new(0, 0, 1920, 1080)));
    let margin = (12.0 * scale).round() as i32;
    // The work area already excludes the taskbar, whichever edge it is docked to (#204).
    let max_h = (work.height as f64 / scale - 24.0).max(480.0);
    let target_h = if height <= 0.0 { max_h } else { height.min(max_h) };
    let old_pos = window.outer_position().unwrap_or(PhysicalPosition::new(0, 0));
    let old_size = window.outer_size().unwrap_or(PhysicalSize::new(480, 520));
    let main_width = 472.0 * scale;
    let main_x = old_pos.x as f64 + if side_left { (old_size.width as f64 - main_width - 8.0 * scale).max(0.0) } else { 0.0 };
    let left = work.x as f64 + margin as f64;
    let right = work.right() as f64 - margin as f64;
    let room_right = right - main_x - main_width;
    let room_left = main_x - left;
    let enabled = grok_enabled.unwrap_or(true);
    let on_left = if enabled { panel_sidecar_on_left(room_left, room_right, scale) } else { false };
    let rail_width: f64 = if !enabled { 0.0 } else if expanded { 232.0 } else { 84.0 };
    let target_w = (472.0 + if enabled { rail_width + 20.0 } else { 8.0 }).min((right - left) / scale);
    let desired_x = main_x - if on_left { (rail_width + 12.0) * scale } else { 0.0 };
    let x = desired_x.clamp(left, (right - target_w * scale).max(left));
    let new_h = (target_h * scale).round() as i32;
    let corner = current_panel_placement().anchor.corner(taskbar_edge(full, work));
    let y = resized_top(work, margin, old_pos.y, old_size.height as i32, new_h, corner);
    suppress_move_snaps();
    let _ = window.set_size(tauri::LogicalSize::new(target_w, target_h));
    let _ = window.set_position(PhysicalPosition::new(x.round() as i32, y));
    GROK_SIDE_LEFT.store(on_left, Ordering::SeqCst);
    on_left
}

#[tauri::command]
async fn start_xiaomi_camera_bridge(
    did: String,
    model: String,
    local_ip: String,
    client_public: String,
    client_private: String,
    device_public: String,
    sign: String,
    vendor: String,
    uid: Option<String>,
) -> Result<String, String> {
    let _bridge_order = CAMERA_BRIDGE_LOCK.lock().await;
    let cam_ip: std::net::Ipv4Addr = local_ip
        .trim()
        .parse()
        .map_err(|_| format!("无效的局域网摄像机 IP：{local_ip}"))?;
    if !cam_ip.is_private() && !cam_ip.is_loopback() {
        return Err("仅允许局域网私有 IP 地址直连摄像机".to_string());
    }

    ensure_go2rtc_running().await?;
    let session = current_go2rtc_session()?;

    let clean_did: String = did
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    let raw_name = format!("cam_raw_{clean_did}");
    let h264_name = format!("cam_h264_{clean_did}");
    let mjpeg_name = format!("cam_mjpeg_{clean_did}");

    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(6))
        .build()
        .map_err(|e| e.to_string())?;

    // A camera keeps exactly one P2P session, and the relay thread dies with its old port.
    // Dropping the previous bridge first is what makes the second open work.
    stop_bridge(&http, Some(&session), &clean_did, &[&raw_name, &h264_name, &mjpeg_name]).await;

    let relay_port = camera_relay_port(&clean_did, cam_ip)?;

    let mut query = format!(
        "client_public={}&client_private={}&device_public={}&sign={}&vendor={}&transport=udp&subtype=sd&audio=0&model={}",
        urlencoding_simple(&client_public),
        urlencoding_simple(&client_private),
        urlencoding_simple(&device_public),
        urlencoding_simple(&sign),
        urlencoding_simple(&vendor),
        urlencoding_simple(&model)
    );
    if let Some(u) = uid.as_deref().filter(|s| !s.is_empty()) {
        query.push_str(&format!("&uid={}", urlencoding_simple(u)));
    }
    let xiaomi_url = format!("xiaomi://127.0.0.1:{relay_port}?{query}");

    put_stream(&http, &session, &raw_name, &xiaomi_url)
        .await
        .map_err(|e| format!("注册摄像机原始流失败：{e}"))?;
    // Two transcode targets: WebRTC plays H.264 with real-time pacing (it drops late frames
    // instead of buffering), while MJPEG is the fallback that paints on the first frame.
    put_stream(&http, &session, &h264_name, &format!("ffmpeg:{raw_name}#video=h264"))
        .await
        .map_err(|e| format!("注册摄像机 H.264 转码流失败：{e}"))?;
    put_stream(&http, &session, &mjpeg_name, &format!("ffmpeg:{raw_name}#video=mjpeg"))
        .await
        .map_err(|e| format!("注册摄像机 MJPEG 转码流失败：{e}"))?;

    Ok(format!("{h264_name}|{mjpeg_name}"))
}

#[tauri::command]
async fn bridge_hls_camera_stream(did: String, hls_url: String) -> Result<String, String> {
    let _bridge_order = CAMERA_BRIDGE_LOCK.lock().await;
    let parsed = reqwest::Url::parse(hls_url.trim())
        .map_err(|_| "无效的 HLS 流地址".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("HLS 流地址必须使用 http 或 https 协议".to_string());
    }
    ensure_go2rtc_running().await?;
    let session = current_go2rtc_session()?;
    let clean_did: String = did
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    let mjpeg_name = format!("cam_mjpeg_{clean_did}");
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(6))
        .build()
        .map_err(|e| e.to_string())?;
    let _ = authed(
        http.delete(api_url(
            &session,
            &format!("/api/streams?src={}", urlencoding_simple(&mjpeg_name)),
        )),
        &session,
    )
    .send()
    .await;
    let path_lower = parsed.path().to_ascii_lowercase();
    let stream_src = if path_lower.contains("/api/camera_proxy")
        || path_lower.ends_with(".mjpeg")
        || path_lower.ends_with(".mjpg")
        || path_lower.ends_with("/stream.mjpeg")
    {
        parsed.as_str().to_string()
    } else {
        format!("ffmpeg:{}#video=mjpeg", parsed.as_str())
    };
    put_stream(&http, &session, &mjpeg_name, &stream_src)
        .await
        .map_err(|e| format!("注册 HLS 转码流失败：{e}"))?;
    Ok(mjpeg_name)
}

#[tauri::command]
async fn stop_xiaomi_camera_bridge(did: String) -> Result<(), String> {
    let _bridge_order = CAMERA_BRIDGE_LOCK.lock().await;
    let clean_did: String = did
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(3))
        .build()
        .map_err(|e| e.to_string())?;
    let raw_name = format!("cam_raw_{clean_did}");
    let h264_name = format!("cam_h264_{clean_did}");
    let mjpeg_name = format!("cam_mjpeg_{clean_did}");
    let session = current_go2rtc_session().ok();
    stop_bridge(
        &http,
        session.as_ref(),
        &clean_did,
        &[&raw_name, &h264_name, &mjpeg_name],
    )
    .await;
    Ok(())
}

async fn put_stream(
    http: &reqwest::Client,
    session: &Go2RtcSession,
    name: &str,
    src: &str,
) -> Result<(), String> {
    let url = api_url(
        session,
        &format!(
            "/api/streams?name={}&src={}",
            urlencoding_simple(name),
            urlencoding_simple(src)
        ),
    );
    let resp = authed(http.put(&url), session)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if let Some(path) = go2rtc_config_path() {
        restrict_secret_file(&path);
    }
    if resp.status().is_success() {
        Ok(())
    } else {
        Err(format!("HTTP {}", resp.status()))
    }
}

async fn stop_bridge(
    http: &reqwest::Client,
    session: Option<&Go2RtcSession>,
    clean_did: &str,
    names: &[&str],
) {
    if let Some(session) = session {
        for name in names {
            let url = api_url(
                session,
                &format!("/api/streams?src={}", urlencoding_simple(name)),
            );
            let _ = authed(http.delete(&url), session).send().await;
        }
        if let Some(path) = go2rtc_config_path() {
            restrict_secret_file(&path);
        }
    }
    let no_active_relays = if let Ok(mut relays) = CAMERA_RELAYS.lock() {
        if let Some(relay) = relays.remove(clean_did) {
            relay.stop.store(true, Ordering::SeqCst);
        }
        relays.is_empty()
    } else {
        false
    };
    if no_active_relays {
        scrub_persisted_streams_from_config();
    }
}

struct CameraRelay {
    port: u16,
    stop: std::sync::Arc<AtomicBool>,
}

static CAMERA_RELAYS: LazyLock<std::sync::Mutex<HashMap<String, CameraRelay>>> =
    LazyLock::new(|| std::sync::Mutex::new(HashMap::new()));

/// Tracks the go2rtc child process spawned by this application instance so we never
/// terminate user-started `go2rtc.exe` processes by image name (#97).
static GO2RTC_PROCESS: LazyLock<std::sync::Mutex<Option<std::process::Child>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));
static GO2RTC_SESSION: LazyLock<std::sync::Mutex<Option<Go2RtcOwnerRecord>>> =
    LazyLock::new(|| std::sync::Mutex::new(None));

/// Serializes bridge start/stop end to end: two overlapping starts for the same
/// camera otherwise interleave their stop_bridge/register sequences and the
/// newer bridge ends up deleted by the stale one (#97).
static CAMERA_BRIDGE_LOCK: LazyLock<tauri::async_runtime::Mutex<()>> =
    LazyLock::new(|| tauri::async_runtime::Mutex::new(()));

fn scrub_persisted_streams_from_config() {
    let Some(cfg_path) = go2rtc_config_path() else {
        return;
    };
    let Ok(existing) = std::fs::read_to_string(&cfg_path) else {
        return;
    };
    if !existing.contains("streams:") {
        return;
    }
    let cleaned = format!("{}\n", base_go2rtc_config(&existing));
    let _ = write_secret_file(&cfg_path, &cleaned);
}

fn shutdown_camera_daemons() {
    if let Ok(mut relays) = CAMERA_RELAYS.lock() {
        for (_, relay) in relays.drain() {
            relay.stop.store(true, Ordering::SeqCst);
        }
    }
    if let Ok(mut guard) = GO2RTC_PROCESS.lock() {
        if let Some(mut child) = guard.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
    if let Ok(mut guard) = GO2RTC_SESSION.lock() {
        *guard = None;
    }
    scrub_persisted_streams_from_config();
}

/// The app-owned part of go2rtc.yaml, without the `streams:` section go2rtc appends.
fn base_go2rtc_config(yaml: &str) -> String {
    let mut kept = Vec::new();
    let mut in_streams = false;
    for line in yaml.split('\n') {
        let trimmed_cr = line.trim_end_matches('\r');
        let is_top_level = trimmed_cr
            .chars()
            .next()
            .is_some_and(|c| !c.is_whitespace());
        if is_top_level {
            in_streams = trimmed_cr.starts_with("streams:");
        }
        if !in_streams {
            kept.push(trimmed_cr);
        }
    }
    kept.join("\n").trim().to_string()
}

#[derive(Clone)]
struct Go2RtcSession {
    api_listen: String,
    rtsp_listen: String,
    username: String,
    password: String,
    nonce: String,
}

struct Go2RtcOwnerRecord {
    pid: u32,
    session: Go2RtcSession,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Go2RtcAction {
    ReuseOwned,
    RestartOwned,
    SpawnFresh,
}

#[derive(Clone, Copy)]
struct Go2RtcOwnershipProbe {
    pid_alive: bool,
    authenticated: bool,
    nonce_matches: bool,
    config_changed: bool,
}

const FORBIDDEN_GO2RTC_PORTS: [u16; 3] = [1984, 8554, 8555];

fn decide_go2rtc_action(probe: Go2RtcOwnershipProbe) -> Go2RtcAction {
    let owned = probe.pid_alive && probe.authenticated && probe.nonce_matches;
    if !owned {
        Go2RtcAction::SpawnFresh
    } else if probe.config_changed {
        Go2RtcAction::RestartOwned
    } else {
        Go2RtcAction::ReuseOwned
    }
}

/// v1.9.15 skips Basic auth on loopback unless `local_auth` is true.
fn desired_go2rtc_config(session: &Go2RtcSession, ffmpeg_bin: &str) -> String {
    let ffmpeg = yaml_double_quoted(ffmpeg_bin);
    let api = sanitized_listen(&session.api_listen);
    let rtsp = sanitized_listen(&session.rtsp_listen);
    format!(
        "api:\n  listen: {api}\n  username: {user}\n  password: {password}\n  local_auth: true\nrtsp:\n  listen: {rtsp}\nwebrtc:\n  listen: \"\"\nlog:\n  level: info\n  ffmpeg: error\nffmpeg:\n  bin: {ffmpeg}\nexec:\n  allow_paths:\n    - {ffmpeg}\nmenubarmijia:\n  nonce: {nonce}\n",
        user = yaml_double_quoted(&session.username),
        password = yaml_double_quoted(&session.password),
        nonce = yaml_double_quoted(&session.nonce),
    )
}

/// Reuses a live relay so reopening the panel does not renegotiate P2P from scratch.
fn camera_relay_port(clean_did: &str, cam_ip: std::net::Ipv4Addr) -> Result<u16, String> {
    let mut relays = CAMERA_RELAYS.lock().map_err(|_| "中继表不可用".to_string())?;
    if let Some(existing) = relays.get(clean_did) {
        if !existing.stop.load(Ordering::SeqCst) {
            return Ok(existing.port);
        }
    }
    relays.remove(clean_did);
    let (port, stop) = spawn_cs2_udp_relay(cam_ip)?;
    relays.insert(clean_did.to_string(), CameraRelay { port, stop });
    Ok(port)
}

fn urlencoding_simple(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn resolve_ffmpeg_bin(bin_dir: &std::path::Path) -> String {
    for candidate in ["ffmpeg-silent.exe", "ffmpeg.exe"] {
        let p = bin_dir.join(candidate);
        if p.exists() {
            return p.to_string_lossy().replace('\\', "/");
        }
    }
    "ffmpeg".to_string()
}

async fn download_go2rtc_win64(
    bin_dir: &std::path::Path,
    exe_path: &std::path::Path,
) -> Result<(), String> {
    const DOWNLOAD_URL: &str =
        "https://github.com/AlexxIT/go2rtc/releases/download/v1.9.15/go2rtc_win64.zip";
    const EXPECTED_SHA256: &str =
        "5b448fc90f15c925406d8da0984301985e385050222c1c2bbdf0a76fe4b1e9cb";

    std::fs::create_dir_all(bin_dir).map_err(|e| format!("创建组件目录失败：{e}"))?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(45))
        .build()
        .map_err(|e| e.to_string())?;
    let resp = client.get(DOWNLOAD_URL).send().await.map_err(|e| {
        format!(
            "首次打开摄像机需自动下载流媒体组件 go2rtc，但网络连接失败（{e}）。请检查网络后重试，或手动放入 %LOCALAPPDATA%\\MenuBarMijia\\bin\\go2rtc.exe"
        )
    })?;
    if !resp.status().is_success() {
        return Err(format!(
            "下载流媒体组件 go2rtc 失败 (HTTP {})，请稍后点击重试",
            resp.status().as_u16()
        ));
    }
    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("读取 go2rtc 组件数据失败：{e}"))?;
    let actual_sha256 = compute_sha256_hex(&bytes);
    if actual_sha256 != EXPECTED_SHA256 {
        return Err("go2rtc 组件 SHA-256 校验未通过，已拒绝加载".to_string());
    }

    let staging_dir = bin_dir.join(format!("staging-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&staging_dir);
    std::fs::create_dir_all(&staging_dir).map_err(|e| format!("创建解压目录失败：{e}"))?;
    let zip_path = staging_dir.join("go2rtc_win64.zip");
    std::fs::write(&zip_path, &bytes).map_err(|e| format!("写入临时压缩包失败：{e}"))?;

    let status = std::process::Command::new("tar.exe")
        .args([
            "-xf",
            &zip_path.to_string_lossy(),
            "-C",
            &staging_dir.to_string_lossy(),
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .status()
        .map_err(|e| format!("解压 go2rtc.exe 失败：{e}"))?;
    let extracted = staging_dir.join("go2rtc.exe");
    if !status.success() || !extracted.exists() {
        let _ = std::fs::remove_dir_all(&staging_dir);
        return Err("解压流媒体组件 go2rtc.exe 失败".to_string());
    }
    let _ = std::fs::remove_file(exe_path);
    std::fs::rename(&extracted, exe_path).map_err(|e| format!("安装 go2rtc.exe 失败：{e}"))?;
    let _ = std::fs::remove_dir_all(&staging_dir);
    Ok(())
}

fn running_child_pid() -> Option<u32> {
    let mut guard = GO2RTC_PROCESS.lock().ok()?;
    let child = guard.as_mut()?;
    match child.try_wait() {
        Ok(None) => Some(child.id()),
        _ => {
            *guard = None;
            None
        }
    }
}

fn current_go2rtc_session() -> Result<Go2RtcSession, String> {
    let guard = GO2RTC_SESSION
        .lock()
        .map_err(|_| "流媒体会话不可用".to_string())?;
    guard
        .as_ref()
        .map(|record| record.session.clone())
        .ok_or_else(|| "本地流媒体服务未启动".to_string())
}

fn store_go2rtc_session(record: Go2RtcOwnerRecord) {
    if let Ok(mut guard) = GO2RTC_SESSION.lock() {
        *guard = Some(record);
    }
}

fn bin_directory() -> Result<std::path::PathBuf, String> {
    let local = std::env::var("LOCALAPPDATA").map_err(|_| "无法读取 LOCALAPPDATA 目录".to_string())?;
    Ok(std::path::PathBuf::from(local).join("MenuBarMijia").join("bin"))
}

fn go2rtc_config_path() -> Option<std::path::PathBuf> {
    bin_directory().ok().map(|dir| dir.join("go2rtc.yaml"))
}

fn go2rtc_owner_path() -> Option<std::path::PathBuf> {
    bin_directory().ok().map(|dir| dir.join("go2rtc.owner"))
}

fn write_secret_file(path: &std::path::Path, contents: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("创建组件目录失败：{e}"))?;
    }
    std::fs::write(path, contents).map_err(|e| format!("写入 go2rtc 配置失败：{e}"))?;
    restrict_secret_file(path);
    Ok(())
}

fn restrict_secret_file(path: &std::path::Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(windows)]
    {
        let Ok(user) = std::env::var("USERNAME") else {
            return;
        };
        if user.is_empty()
            || user
                .bytes()
                .any(|byte| matches!(byte, b'"' | b'&' | b'|' | b'\n' | b'\r' | b'%'))
        {
            return;
        }
        let mut cmd = std::process::Command::new("icacls");
        cmd.arg(path)
            .arg("/inheritance:r")
            .arg("/grant:r")
            .arg(format!("{user}:(F)"))
            .creation_flags(CREATE_NO_WINDOW);
        let _ = cmd.status();
    }
}

fn api_url(session: &Go2RtcSession, path_and_query: &str) -> String {
    format!("http://{}{path_and_query}", session.api_listen)
}

fn authed(builder: reqwest::RequestBuilder, session: &Go2RtcSession) -> reqwest::RequestBuilder {
    builder.basic_auth(&session.username, Some(&session.password))
}

fn basic_authorization_value(username: &str, password: &str) -> String {
    format!(
        "Basic {}",
        base64_encode(format!("{username}:{password}").as_bytes())
    )
}

fn base64_encode(data: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut index = 0;
    while index + 3 <= data.len() {
        let value = ((data[index] as u32) << 16)
            | ((data[index + 1] as u32) << 8)
            | (data[index + 2] as u32);
        out.push(TABLE[((value >> 18) & 63) as usize] as char);
        out.push(TABLE[((value >> 12) & 63) as usize] as char);
        out.push(TABLE[((value >> 6) & 63) as usize] as char);
        out.push(TABLE[(value & 63) as usize] as char);
        index += 3;
    }
    if index < data.len() {
        let remain = data.len() - index;
        let mut value = (data[index] as u32) << 16;
        if remain == 2 {
            value |= (data[index + 1] as u32) << 8;
        }
        out.push(TABLE[((value >> 18) & 63) as usize] as char);
        out.push(TABLE[((value >> 12) & 63) as usize] as char);
        if remain == 2 {
            out.push(TABLE[((value >> 6) & 63) as usize] as char);
            out.push('=');
        } else {
            out.push('=');
            out.push('=');
        }
    }
    out
}

fn yaml_double_quoted(value: &str) -> String {
    let mut out = String::from("\"");
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' | '\r' => {}
            _ => out.push(ch),
        }
    }
    out.push('"');
    out
}

fn is_credential_token(value: &str) -> bool {
    (8..=128).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

fn is_acceptable_go2rtc_listen(value: &str) -> bool {
    let Some(port_text) = value.strip_prefix("127.0.0.1:") else {
        return false;
    };
    let Ok(port) = port_text.parse::<u16>() else {
        return false;
    };
    port > 0 && !FORBIDDEN_GO2RTC_PORTS.contains(&port) && value == format!("127.0.0.1:{port}")
}

fn sanitized_listen(value: &str) -> String {
    if is_acceptable_go2rtc_listen(value) {
        value.to_string()
    } else {
        "127.0.0.1:9".to_string()
    }
}

fn random_credential_token() -> Result<String, String> {
    let rng = SystemRandom::new();
    let mut bytes = [0u8; 16];
    rng.fill(&mut bytes)
        .map_err(|_| "无法生成流媒体凭据".to_string())?;
    let mut out = String::from("m");
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    Ok(out)
}

fn make_ephemeral_go2rtc_session() -> Result<Go2RtcSession, String> {
    let ports = reserve_loopback_ports(2)?;
    Ok(Go2RtcSession {
        api_listen: format!("127.0.0.1:{}", ports[0]),
        rtsp_listen: format!("127.0.0.1:{}", ports[1]),
        username: random_credential_token()?,
        password: random_credential_token()?,
        nonce: random_credential_token()?,
    })
}

fn reserve_loopback_ports(count: usize) -> Result<Vec<u16>, String> {
    let mut listeners = Vec::new();
    let mut ports = Vec::new();
    for _ in 0..64 {
        if ports.len() == count {
            break;
        }
        let Ok(listener) = std::net::TcpListener::bind("127.0.0.1:0") else {
            continue;
        };
        let port = listener.local_addr().map_err(|e| e.to_string())?.port();
        if FORBIDDEN_GO2RTC_PORTS.contains(&port) || ports.contains(&port) {
            drop(listener);
            continue;
        }
        ports.push(port);
        listeners.push(listener);
    }
    drop(listeners);
    if ports.len() != count {
        return Err("无法分配本地流媒体端口".to_string());
    }
    Ok(ports)
}

fn serialize_owner(record: &Go2RtcOwnerRecord) -> String {
    format!(
        "pid={}\nnonce={}\napi_listen={}\nrtsp_listen={}\nusername={}\npassword={}\n",
        record.pid,
        record.session.nonce,
        record.session.api_listen,
        record.session.rtsp_listen,
        record.session.username,
        record.session.password
    )
}

fn parse_owner(text: &str) -> Option<Go2RtcOwnerRecord> {
    let mut fields = std::collections::HashMap::<String, String>::new();
    for line in text.split('\n') {
        let line = line.trim_end_matches('\r');
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if !key.is_empty() && !value.is_empty() {
            fields.insert(key.to_string(), value.to_string());
        }
    }
    let pid = fields.get("pid")?.parse::<u32>().ok()?;
    let nonce = fields.get("nonce")?.clone();
    let api_listen = fields.get("api_listen")?.clone();
    let rtsp_listen = fields.get("rtsp_listen")?.clone();
    let username = fields.get("username")?.clone();
    let password = fields.get("password")?.clone();
    if !is_credential_token(&nonce)
        || !is_credential_token(&username)
        || !is_credential_token(&password)
        || !is_acceptable_go2rtc_listen(&api_listen)
        || !is_acceptable_go2rtc_listen(&rtsp_listen)
    {
        return None;
    }
    Some(Go2RtcOwnerRecord {
        pid,
        session: Go2RtcSession {
            api_listen,
            rtsp_listen,
            username,
            password,
            nonce,
        },
    })
}

fn read_owner() -> Option<Go2RtcOwnerRecord> {
    let path = go2rtc_owner_path()?;
    let text = std::fs::read_to_string(path).ok()?;
    parse_owner(&text)
}

fn process_is_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    #[cfg(windows)]
    {
        extern "system" {
            fn OpenProcess(access: u32, inherit: i32, pid: u32) -> *mut core::ffi::c_void;
            fn GetExitCodeProcess(handle: *mut core::ffi::c_void, code: *mut u32) -> i32;
            fn CloseHandle(handle: *mut core::ffi::c_void) -> i32;
        }
        const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
        const STILL_ACTIVE: u32 = 259;
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if handle.is_null() {
                return false;
            }
            let mut code = 0u32;
            let ok = GetExitCodeProcess(handle, &mut code);
            CloseHandle(handle);
            ok != 0 && code == STILL_ACTIVE
        }
    }
    #[cfg(not(windows))]
    {
        let _ = pid;
        false
    }
}

fn terminate_pid(pid: u32) {
    if pid == 0 {
        return;
    }
    #[cfg(windows)]
    {
        extern "system" {
            fn OpenProcess(access: u32, inherit: i32, pid: u32) -> *mut core::ffi::c_void;
            fn TerminateProcess(handle: *mut core::ffi::c_void, code: u32) -> i32;
            fn CloseHandle(handle: *mut core::ffi::c_void) -> i32;
        }
        const PROCESS_TERMINATE: u32 = 0x0001;
        unsafe {
            let handle = OpenProcess(PROCESS_TERMINATE, 0, pid);
            if !handle.is_null() {
                TerminateProcess(handle, 1);
                CloseHandle(handle);
            }
        }
    }
}

struct OwnedApiProbe {
    reachable: bool,
    authenticated: bool,
    nonce_matches: bool,
}

async fn probe_owned(http: &reqwest::Client, session: &Go2RtcSession) -> OwnedApiProbe {
    let missed = OwnedApiProbe {
        reachable: false,
        authenticated: false,
        nonce_matches: false,
    };
    let Ok(response) = authed(http.get(api_url(session, "/api")), session).send().await else {
        return missed;
    };
    if !response.status().is_success() {
        return OwnedApiProbe {
            reachable: true,
            authenticated: false,
            nonce_matches: false,
        };
    }
    let Ok(config) = authed(http.get(api_url(session, "/api/config")), session)
        .send()
        .await
    else {
        return missed;
    };
    if !config.status().is_success() {
        return missed;
    }
    let Ok(body) = config.text().await else {
        return missed;
    };
    let needle = format!("nonce: {}", yaml_double_quoted(&session.nonce));
    OwnedApiProbe {
        reachable: true,
        authenticated: true,
        nonce_matches: body.contains(&needle),
    }
}

fn existing_owned_record() -> Option<Go2RtcOwnerRecord> {
    if let Some(pid) = running_child_pid() {
        if let Ok(guard) = GO2RTC_SESSION.lock() {
            if let Some(record) = guard.as_ref() {
                return Some(Go2RtcOwnerRecord {
                    pid,
                    session: record.session.clone(),
                });
            }
        }
    }
    if let Ok(guard) = GO2RTC_SESSION.lock() {
        if let Some(record) = guard.as_ref() {
            if process_is_alive(record.pid) {
                return Some(Go2RtcOwnerRecord {
                    pid: record.pid,
                    session: record.session.clone(),
                });
            }
        }
    }
    let saved = read_owner()?;
    if process_is_alive(saved.pid) {
        Some(saved)
    } else {
        None
    }
}

async fn request_owned_exit(http: &reqwest::Client, session: &Go2RtcSession) {
    let _ = authed(http.post(api_url(session, "/api/exit?code=0")), session)
        .send()
        .await;
}

async fn stop_owned_process(http: &reqwest::Client, record: &Go2RtcOwnerRecord) {
    request_owned_exit(http, &record.session).await;
    let child_pid = running_child_pid();
    if child_pid == Some(record.pid) {
        if let Ok(mut guard) = GO2RTC_PROCESS.lock() {
            if let Some(mut child) = guard.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
    for _ in 0..20 {
        if !process_is_alive(record.pid) {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    if process_is_alive(record.pid) {
        terminate_pid(record.pid);
    }
    if let Ok(mut guard) = GO2RTC_SESSION.lock() {
        *guard = None;
    }
}

async fn wait_for_owned_api(http: &reqwest::Client, session: &Go2RtcSession) -> bool {
    for _ in 0..25 {
        std::thread::sleep(Duration::from_millis(120));
        let probe = probe_owned(http, session).await;
        if probe.authenticated && probe.nonce_matches {
            return true;
        }
        if probe.reachable && !probe.authenticated {
            return false;
        }
        if probe.authenticated && !probe.nonce_matches {
            return false;
        }
    }
    false
}

async fn spawn_fresh_go2rtc(
    http: &reqwest::Client,
    bin_dir: &std::path::Path,
    ffmpeg_bin: &str,
) -> Result<(), String> {
    let exe_path = bin_dir.join("go2rtc.exe");
    if !exe_path.exists() {
        download_go2rtc_win64(bin_dir, &exe_path).await?;
    }
    let cfg_path = bin_dir.join("go2rtc.yaml");
    let owner_path = bin_dir.join("go2rtc.owner");
    for _ in 0..4 {
        let session = make_ephemeral_go2rtc_session()?;
        let desired = desired_go2rtc_config(&session, ffmpeg_bin);
        write_secret_file(&cfg_path, &desired)?;
        let mut command = std::process::Command::new(&exe_path);
        command.arg("-c").arg(&cfg_path).current_dir(bin_dir);
        #[cfg(windows)]
        {
            command.creation_flags(CREATE_NO_WINDOW);
        }
        let child = command.spawn().map_err(|e| format!("启动 go2rtc 失败：{e}"))?;
        let pid = child.id();
        if let Ok(mut guard) = GO2RTC_PROCESS.lock() {
            *guard = Some(child);
        }
        let record = Go2RtcOwnerRecord { pid, session: session.clone() };
        write_secret_file(&owner_path, &serialize_owner(&record))?;
        store_go2rtc_session(record);
        if wait_for_owned_api(http, &session).await {
            return Ok(());
        }
        if let Ok(mut guard) = GO2RTC_PROCESS.lock() {
            if let Some(mut child) = guard.take() {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
        if let Ok(mut guard) = GO2RTC_SESSION.lock() {
            *guard = None;
        }
    }
    Err("本地流媒体服务启动超时".to_string())
}

async fn ensure_go2rtc_running() -> Result<(), String> {
    let bin_dir = bin_directory()?;
    std::fs::create_dir_all(&bin_dir).map_err(|e| format!("创建组件目录失败：{e}"))?;
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_millis(800))
        .build()
        .map_err(|e| e.to_string())?;
    let ffmpeg_bin = resolve_ffmpeg_bin(&bin_dir);

    if let Some(record) = existing_owned_record() {
        let probe = probe_owned(&http, &record.session).await;
        let desired = desired_go2rtc_config(&record.session, &ffmpeg_bin);
        let existing = go2rtc_config_path()
            .and_then(|path| std::fs::read_to_string(path).ok())
            .unwrap_or_default();
        let changed = base_go2rtc_config(&existing) != base_go2rtc_config(&desired);
        let action = decide_go2rtc_action(Go2RtcOwnershipProbe {
            pid_alive: true,
            authenticated: probe.authenticated,
            nonce_matches: probe.nonce_matches,
            config_changed: changed,
        });
        match action {
            Go2RtcAction::ReuseOwned => {
                store_go2rtc_session(record);
                return Ok(());
            }
            Go2RtcAction::RestartOwned => {
                stop_owned_process(&http, &record).await;
            }
            Go2RtcAction::SpawnFresh => {
                if running_child_pid() == Some(record.pid) {
                    if let Ok(mut guard) = GO2RTC_PROCESS.lock() {
                        if let Some(mut child) = guard.take() {
                            let _ = child.kill();
                            let _ = child.wait();
                        }
                    }
                    if let Ok(mut guard) = GO2RTC_SESSION.lock() {
                        *guard = None;
                    }
                }
            }
        }
    }

    spawn_fresh_go2rtc(&http, &bin_dir, &ffmpeg_bin).await
}

#[derive(Serialize)]
struct Go2RtcEndpoint {
    origin: String,
    authorization: String,
}

#[tauri::command]
async fn go2rtc_endpoint() -> Result<Go2RtcEndpoint, String> {
    let _bridge_order = CAMERA_BRIDGE_LOCK.lock().await;
    ensure_go2rtc_running().await?;
    let session = current_go2rtc_session()?;
    let origin = format!("http://{}", session.api_listen);
    if !origin.starts_with("http://127.0.0.1:") || !is_acceptable_go2rtc_listen(&session.api_listen) {
        return Err("本地流媒体地址无效".to_string());
    }
    Ok(Go2RtcEndpoint {
        origin,
        authorization: basic_authorization_value(&session.username, &session.password),
    })
}

fn is_go2rtc_stream_name(src: &str) -> bool {
    !src.is_empty()
        && src.len() <= 128
        && src
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
}

fn go2rtc_jpeg_frame_url(session: &Go2RtcSession, src: &str) -> Result<String, String> {
    if !is_go2rtc_stream_name(src) {
        return Err("无效的摄像机流名称".to_string());
    }
    if !is_acceptable_go2rtc_listen(&session.api_listen) {
        return Err("本地流媒体地址无效".to_string());
    }
    Ok(api_url(
        session,
        &format!("/api/frame.jpeg?src={}", urlencoding_simple(src)),
    ))
}

#[tauri::command]
async fn go2rtc_jpeg_frame(src: String) -> Result<String, String> {
    let session = current_go2rtc_session()?;
    let url = go2rtc_jpeg_frame_url(&session, &src)?;
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(8))
        .build()
        .map_err(|e| e.to_string())?;
    let response = authed(http.get(&url), &session)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!(
            "读取摄像机画面失败 (HTTP {})",
            response.status()
        ));
    }
    let bytes = response.bytes().await.map_err(|e| e.to_string())?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err("摄像机画面过大".to_string());
    }
    Ok(base64_encode(&bytes))
}

fn spawn_cs2_udp_relay(
    cam_ip: std::net::Ipv4Addr,
) -> Result<(u16, std::sync::Arc<AtomicBool>), String> {
    use std::net::{SocketAddrV4, UdpSocket};
    use std::sync::Arc;

    // Discover the local IPv4 interface that routes to cam_ip
    let probe = UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
    probe
        .connect(SocketAddrV4::new(cam_ip, 32108))
        .map_err(|e| e.to_string())?;
    let local_ip = match probe.local_addr().map_err(|e| e.to_string())?.ip() {
        std::net::IpAddr::V4(v4) => v4,
        _ => std::net::Ipv4Addr::UNSPECIFIED,
    };
    drop(probe);

    let octets = cam_ip.octets();
    let broadcast_ip = std::net::Ipv4Addr::new(octets[0], octets[1], octets[2], 255);

    let local_relay = UdpSocket::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    let relay_port = local_relay.local_addr().map_err(|e| e.to_string())?.port();
    local_relay
        .set_read_timeout(Some(Duration::from_millis(25)))
        .map_err(|e| e.to_string())?;

    let lan_sock = UdpSocket::bind(SocketAddrV4::new(local_ip, 0)).map_err(|e| e.to_string())?;
    lan_sock.set_broadcast(true).map_err(|e| e.to_string())?;
    lan_sock
        .set_read_timeout(Some(Duration::from_millis(25)))
        .map_err(|e| e.to_string())?;

    let stop = Arc::new(AtomicBool::new(false));
    let stop_for_thread = Arc::clone(&stop);
    std::thread::spawn(move || {
        let mut go2rtc_addr: Option<std::net::SocketAddr> = None;
        let mut cam_dynamic_port: u16 = 32108;
        let mut buf = [0u8; 2048];

        while !stop_for_thread.load(Ordering::SeqCst) {
            if let Ok((n, src)) = local_relay.recv_from(&mut buf) {
                go2rtc_addr = Some(src);
                if n >= 2 && buf[0] == 0xf1 && buf[1] == 0x30 {
                    let _ = lan_sock.send_to(&buf[..n], SocketAddrV4::new(broadcast_ip, 32108));
                    let _ = lan_sock.send_to(&buf[..n], SocketAddrV4::new(cam_ip, 32108));
                } else {
                    let _ = lan_sock.send_to(&buf[..n], SocketAddrV4::new(cam_ip, cam_dynamic_port));
                }
            }

            while let Ok((n, src)) = lan_sock.recv_from(&mut buf) {
                if src.ip() == std::net::IpAddr::V4(cam_ip) {
                    cam_dynamic_port = src.port();
                    if let Some(client_addr) = go2rtc_addr {
                        let _ = local_relay.send_to(&buf[..n], client_addr);
                    }
                }
            }
        }
    });

    Ok((relay_port, stop))
}

/// Placement for a tray click (which passes the icon position) or the hotkey/menu paths.
fn position_popover(window: &WebviewWindow, anchor: Option<PhysicalPosition<f64>>) {
    let win_size = window.outer_size().unwrap_or(PhysicalSize::new(480, 520));
    let win_w = win_size.width as i32;
    let win_h = win_size.height as i32;

    // A tray click knows which display hosts the icon; the other paths follow the window's monitor.
    let monitor = anchor
        .and_then(|pos| window.monitor_from_point(pos.x, pos.y).ok().flatten())
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());

    let Some(monitor) = monitor else {
        if let Some(pos) = anchor {
            let x = (pos.x as i32 - win_w / 2).max(16);
            let y = (pos.y as i32 - win_h - 16).max(16);
            suppress_move_snaps();
            let _ = window.set_position(PhysicalPosition::new(x, y));
        }
        return;
    };

    let (full, work) = monitor_rects(&monitor);
    let scale = monitor.scale_factor();
    let (x, y) = place(&PlacementInput {
        monitor: full,
        work,
        window: (win_w, win_h),
        margin: (12.0 * scale).round() as i32,
        anchor: anchor.map(|pos| (pos.x.round() as i32, pos.y.round() as i32)),
        preference: current_panel_placement().anchor,
        main_inset: main_column_inset(win_w, scale),
        main_width: (472.0 * scale).round() as i32,
    });
    suppress_move_snaps();
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

/// Whether the primary mouse button is still held. A drag that pauses without emitting `Moved` events
/// is not finished, so the settle watcher must wait for the release (#204 review).
#[cfg(all(windows, not(test)))]
fn primary_button_down() -> bool {
    #[link(name = "user32")]
    extern "system" {
        fn GetAsyncKeyState(vkey: i32) -> i16;
        fn GetSystemMetrics(index: i32) -> i32;
    }
    // "Swap primary and secondary buttons" makes the header's logical-primary press arrive on the right
    // button, so ask which physical button is primary before sampling it.
    const SM_SWAPBUTTON: i32 = 23;
    let swapped = unsafe { GetSystemMetrics(SM_SWAPBUTTON) != 0 };
    key_state_is_down(unsafe { GetAsyncKeyState(primary_button_virtual_key(swapped)) })
}

#[cfg(any(not(windows), test))]
fn primary_button_down() -> bool {
    false
}

/// Ignore `Moved` events caused by our own placement calls; the window covers the IPC round trips.
/// A running drag keeps the window: arming here would swallow the movement the user is producing.
fn suppress_move_snaps() {
    let drag_active = USER_DRAG_ACTIVE.load(Ordering::SeqCst);
    if let Some(deadline) = move_suppression_deadline(drag_active, now_epoch_ms()) {
        PROGRAMMATIC_MOVE_UNTIL_MS.store(deadline, Ordering::SeqCst);
    }
}

/// Watches one native drag until the window is still **and** the pointer has been released, then ends
/// the session. Only a drag that actually moved the window snaps, so a plain header click changes
/// nothing.
fn schedule_drag_settle(app: AppHandle) {
    MOVE_SNAP_DEADLINE_MS.store(now_epoch_ms() + DRAG_SETTLE_MS, Ordering::SeqCst);
    if MOVE_SNAP_SCHEDULED.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        loop {
            let now = now_epoch_ms();
            let quiet_until = MOVE_SNAP_DEADLINE_MS.load(Ordering::SeqCst);
            // Only a released pointer finishes the drag; a pause while the button is still down is not
            // a drop, so keep the quiet window rolling instead of snapping an intermediate corner.
            let held = USER_DRAG_ACTIVE.load(Ordering::SeqCst) && primary_button_down();
            if drag_settle_finished(now, quiet_until, held) {
                break;
            }
            if now >= quiet_until {
                MOVE_SNAP_DEADLINE_MS.store(now + DRAG_SETTLE_MS, Ordering::SeqCst);
            }
            std::thread::sleep(Duration::from_millis(60));
        }
        let moved = USER_MOVES_SEEN.swap(false, Ordering::SeqCst);
        USER_DRAG_ACTIVE.store(false, Ordering::SeqCst);
        MOVE_SNAP_SCHEDULED.store(false, Ordering::SeqCst);
        if !moved {
            return;
        }
        if let Some(window) = app.get_webview_window("main") {
            snap_panel_to_work_area(&window);
        }
    });
}

/// A drag emits `Moved` on every mouse step; keep the session alive until the pointer is released.
fn note_user_move(app: &AppHandle) {
    let drag_active = USER_DRAG_ACTIVE.load(Ordering::SeqCst);
    let suppressed_until = PROGRAMMATIC_MOVE_UNTIL_MS.load(Ordering::SeqCst);
    if !move_is_user_driven(drag_active, now_epoch_ms(), suppressed_until) {
        return;
    }
    USER_MOVES_SEEN.store(true, Ordering::SeqCst);
    schedule_drag_settle(app.clone());
}

/// Drag-to-move lands on the nearest work-area corner, and that corner becomes the preference.
fn snap_panel_to_work_area(window: &WebviewWindow) {
    let Ok(position) = window.outer_position() else { return };
    let size = window.outer_size().unwrap_or(PhysicalSize::new(480, 520));
    let win_w = size.width as i32;
    let win_h = size.height as i32;
    let center = (position.x + win_w / 2, position.y + win_h / 2);
    let Some(monitor) = window
        .monitor_from_point(center.0 as f64, center.1 as f64)
        .ok()
        .flatten()
        .or_else(|| window.current_monitor().ok().flatten())
    else {
        return;
    };
    let (full, work) = monitor_rects(&monitor);
    let anchor = PanelAnchor::nearest(work, center);
    // A drop inside the current quadrant still snaps the window back to its corner; only a different
    // corner needs a write, so an unchanged preference never rewrites the file (#204 review).
    if anchor != current_panel_placement().anchor {
        let _ = store_panel_placement(PanelPlacement { anchor });
    }
    let scale = monitor.scale_factor();
    let (x, y) = place(&PlacementInput {
        monitor: full,
        work,
        window: (win_w, win_h),
        margin: (12.0 * scale).round() as i32,
        anchor: None,
        preference: anchor,
        main_inset: main_column_inset(win_w, scale),
        main_width: (472.0 * scale).round() as i32,
    });
    suppress_move_snaps();
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

fn toggle_main_window(app: &AppHandle, anchor: Option<PhysicalPosition<f64>>, from_tray_click: bool) {
    if let Some(window) = app.get_webview_window("main") {
        let is_visible = window.is_visible().unwrap_or(false);
        if is_visible {
            let _ = window.hide();
        } else {
            if from_tray_click {
                let elapsed = now_epoch_ms().saturating_sub(LAST_FOCUS_LOSS_MS.load(Ordering::SeqCst));
                if elapsed < 280 {
                    return;
                }
            }
            position_popover(&window, anchor);
            let _ = window.show();
            let _ = window.set_focus();
        }
    }
}

fn main() {
    let default_shortcut = Shortcut::new(Some(Modifiers::ALT), Code::KeyM);
    if let Ok(mut guard) = TRAY_AND_HOTKEY_STATE.write() {
        guard.active_shortcut = Some(default_shortcut);
        guard.shortcut_label = Some("Alt+M".to_string());
    }

    tauri::Builder::default()
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |app, shortcut, event| {
                    if event.state() != ShortcutState::Pressed {
                        return;
                    }
                    let matches = TRAY_AND_HOTKEY_STATE
                        .read()
                        .ok()
                        .and_then(|guard| guard.active_shortcut)
                        .is_some_and(|active| &active == shortcut);
                    if matches {
                        toggle_main_window(app, None, false);
                    }
                })
                .build(),
        )
        .invoke_handler(tauri::generate_handler![
            ha_snapshot,
            ha_execute,
            native_http,
            set_allowed_origins,
            set_service_endpoints,
            secure_store_get,
            secure_store_set,
            secure_store_delete,
            hide_panel,
            quit_app,
            set_panel_height,
            set_pin_popover,
            panel_placement,
            set_panel_placement,
            start_panel_drag,
            set_update_available,
            set_global_shortcut,
            open_release_page,
            install_update,
            start_xiaomi_camera_bridge,
            bridge_hls_camera_stream,
            stop_xiaomi_camera_bridge,
            go2rtc_endpoint,
            go2rtc_jpeg_frame
        ])
        .setup(move |app| {
            sweep_stale_update_installers();
            if let Some(path) = authorization_store_path() {
                if let Ok(mut guard) = EXTRA_ALLOWED_ORIGINS.write() {
                    *guard = read_origin_store(&path);
                }
            }
            let _ = app.global_shortcut().register(default_shortcut);
            load_panel_placement();
            if let Some(main_win) = app.get_webview_window("main") {
                position_popover(&main_win, None);
                let win_for_event = main_win.clone();
                let app_for_events = app.handle().clone();
                main_win.on_window_event(move |event| match event {
                    WindowEvent::Focused(false) => {
                        if !PIN_POPOVER.load(Ordering::SeqCst) {
                            LAST_FOCUS_LOSS_MS.store(now_epoch_ms(), Ordering::SeqCst);
                            let _ = win_for_event.hide();
                        }
                    }
                    // Drag-to-move: a header press hands over to the OS move loop, and the resulting
                    // moves snap to the nearest work-area corner once the drag settles (#204).
                    WindowEvent::Moved(_) => note_user_move(&app_for_events),
                    _ => {}
                });
            }

            let menu = build_tray_menu(app.handle(), Some("Alt+M"), None)?;

            let mut tray_builder = TrayIconBuilder::with_id("main-tray")
                .tooltip("MenuBarMijia · 菜单栏米家 (Alt+M)")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "toggle" => toggle_main_window(app, None, false),
                    "update" => {
                        if let Some(window) = app.get_webview_window("main") {
                            PIN_POPOVER.store(true, Ordering::SeqCst);
                            position_popover(&window, None);
                            let _ = window.show();
                            let _ = window.set_focus();
                            let _ = window.eval(
                                "window.dispatchEvent(new CustomEvent('menumijia:open-update'))",
                            );
                        } else if let Ok(url) = validated_release_url(RELEASE_PAGE_URL) {
                            open_url_in_browser(&url);
                        }
                    }
                    "quit" => {
                        shutdown_camera_daemons();
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        position,
                        ..
                    } = event
                    {
                        toggle_main_window(tray.app_handle(), Some(position), true);
                    }
                });

            if let Some(icon) = app.default_window_icon() {
                tray_builder = tray_builder.icon(icon.clone());
            }

            let _tray = tray_builder.build(app)?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running MenuBarMijia Windows application");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidecar_reserves_the_complete_expanded_footprint_at_each_scale() {
        for scale in [1.0, 1.25, 1.5, 2.0] {
            assert!(panel_sidecar_on_left(1178.0 * scale, 246.0 * scale, scale));
            assert!(!panel_sidecar_on_left(1178.0 * scale, 252.0 * scale, scale));
            assert!(panel_sidecar_on_left(244.0 * scale, 251.0 * scale, scale));
        }
    }



    fn extra(origins: &[&str]) -> HashSet<String> {
        origins
            .iter()
            .filter_map(|origin| normalize_extra_origin(origin))
            .collect()
    }

    fn allows(url: &str, origins: &[&str]) -> bool {
        let parsed = reqwest::Url::parse(url).expect("test URL");
        check_url_allowed(&parsed, &extra(origins)).is_ok()
    }

    #[test]
    fn native_http_invoke_rejects_an_unconfigured_host() {
        let app = tauri::test::mock_builder()
            .invoke_handler(tauri::generate_handler![native_http])
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("isolated IPC application");
        let window = tauri::WebviewWindowBuilder::new(&app, "main", Default::default())
            .build()
            .expect("isolated IPC window");
        let response = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "native_http".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: "http://tauri.localhost".parse().expect("local app origin"),
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "url": "https://not-configured.invalid/private",
                    "method": "POST",
                    "headers": {"Authorization": "Bearer isolated-test-value"},
                    "body": "private-data",
                    "timeoutMs": 100
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        let error = response.expect_err("unconfigured hosts must fail before networking");
        let message = error.as_str().expect("policy error returned to the frontend");
        assert!(message.contains("not-configured.invalid"), "unexpected IPC error: {message}");
        assert!(message.contains("拒绝访问未授权来源"), "request reached transport: {message}");
    }

    #[test]
    fn allows_only_xiaomi_api_and_configured_origins() {
        assert!(allows("https://api.io.mi.com/app/home/device_list", &[]));
        assert!(allows("https://de.api.io.mi.com/app/home/device_list", &[]));
        assert!(allows(
            "https://account.xiaomi.com/longPolling/loginUrl",
            &[]
        ));
        assert!(allows("https://lp.account.xiaomi.com/lp/s?d=x", &[]));
        assert!(allows("https://miot-spec.org/miot-spec-v2/instance", &[]));
        assert!(allows(
            "https://api.deepseek.com/v1/chat/completions",
            &["https://api.deepseek.com"]
        ));
        assert!(allows("http://192.168.1.8:8123/api/", &["http://192.168.1.8:8123"]));

        assert!(!allows("https://evil.example/steal", &[]));
        assert!(!allows("https://api.io.mi.com.evil.example/app", &[]));
        assert!(!allows(
            "https://api.deepseek.com.evil.example/v1",
            &["https://api.deepseek.com"]
        ));
        assert!(!allows("file:///C:/Windows/win.ini", &[]));
    }

    #[test]
    fn built_in_services_reject_plaintext_and_alternate_ports() {
        assert!(!allows("http://api.io.mi.com/app/private", &[]));
        assert!(!allows("https://api.io.mi.com:8443/app/private", &[]));
        assert!(!allows("http://account.xiaomi.com/pass/serviceLogin", &[]));
        assert!(!allows("http://api.io.mi.com/app/private", &["http://api.io.mi.com"]));
        assert!(!allows("https://api.io.mi.com:8443/app/private", &["https://api.io.mi.com:8443"]));
    }

    #[test]
    fn configured_origins_keep_scheme_and_effective_port() {
        assert!(allows("https://api.deepseek.com/v1", &["https://api.deepseek.com:443"]));
        assert!(!allows("http://api.deepseek.com/v1", &["https://api.deepseek.com"]));
        assert!(!allows("https://api.deepseek.com:8443/v1", &["https://api.deepseek.com"]));
        assert!(allows("http://localhost:11434/api", &["http://localhost:11434"]));
        assert!(!allows("http://localhost:8123/api", &["http://localhost:11434"]));
        assert!(allows("http://[::1]:11434/api", &["http://[::1]:11434"]));
        assert!(!allows("https://user@api.io.mi.com/app", &[]));
    }

    #[test]
    fn normalizes_configured_origins_and_rejects_non_origins() {
        assert_eq!(normalize_extra_origin(" HTTPS://API.DeepSeek.com.:443/ "), Some("https://api.deepseek.com:443".to_string()));
        assert_eq!(normalize_extra_origin("http://[::1]:11434"), Some("http://[::1]:11434".to_string()));
        for invalid in ["api.deepseek.com", "https://evil.example/path", "https://evil.example?key=value", "https://evil.example#fragment", "https://user@evil.example", "file:///tmp/config", ""] {
            assert_eq!(normalize_extra_origin(invalid), None, "{invalid}");
        }
    }

    #[test]
    fn redirects_cannot_change_origin_even_to_another_allowed_origin() {
        let origins = extra(&["https://configured.example", "http://configured.example", "https://configured.example:8443"]);
        let original = reqwest::Url::parse("https://configured.example/start").unwrap();
        let original_origin = url_origin(&original).unwrap();
        assert!(redirect_allowed(&original_origin, &reqwest::Url::parse("https://configured.example:443/next").unwrap(), &origins));
        for target in ["http://configured.example/next", "https://configured.example:8443/next", "https://api.io.mi.com/app"] {
            assert!(!redirect_allowed(&original_origin, &reqwest::Url::parse(target).unwrap(), &origins), "{target}");
        }
    }

    #[test]
    fn credential_names_are_limited_to_known_entries() {
        assert_eq!(
            allowed_credential_name("mi_session").ok(),
            Some("mi_session")
        );
        assert_eq!(allowed_credential_name("ha_token").ok(), Some("ha_token"));
        assert_eq!(
            allowed_credential_name("assistant_api_key").ok(),
            Some("assistant_api_key")
        );
        assert_eq!(
            allowed_credential_name("assistant_api_key_openrouter").ok(),
            Some("assistant_api_key_openrouter")
        );
        assert!(allowed_credential_name("arbitrary_key").is_err());
        assert!(allowed_credential_name("assistant_api_key_").is_err());
        assert!(allowed_credential_name("assistant_api_key_a/b").is_err());
    }

    #[test]
    fn allows_the_public_github_release_api_only() {
        assert!(allows(
            "https://api.github.com/repos/jryang1997/MenuBarMijia/releases/latest",
            &[]
        ));
        // The browser-facing host is opened through the OS, never proxied by native_http.
        assert!(!allows("https://github.com/jryang1997/MenuBarMijia/releases", &[]));
        assert!(!allows("https://api.github.com.evil.example/latest", &[]));
    }

    #[test]
    fn installer_asset_payload_matches_the_windows_frontend_contract() {
        let raw = include_str!("../../tests/fixtures/windows-installer-asset.json");
        let payload: InstallerAssetPayload =
            serde_json::from_str(raw).expect("the Windows frontend installer payload must deserialize");
        assert_eq!(payload.name, "MenuBarMijia-9.9.9-windows-x64-setup.exe");
        assert_eq!(
            payload.download_url,
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v9.9.9/MenuBarMijia-9.9.9-windows-x64-setup.exe"
        );
        assert_eq!(payload.size_bytes, 3_145_728);
        assert_eq!(
            payload.manifest_url,
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v9.9.9/MenuBarMijia-9.9.9.update.json"
        );
    }

    #[test]
    fn only_opens_menu_barmijia_release_pages() {
        assert!(validated_release_url(RELEASE_PAGE_URL).is_ok());
        assert!(validated_release_url(
            "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.0.7"
        )
        .is_ok());

        assert!(validated_release_url("http://github.com/jryang1997/MenuBarMijia/releases").is_err());
        assert!(validated_release_url("https://evil.example/jryang1997/MenuBarMijia/releases").is_err());
        assert!(validated_release_url("https://github.com/other/repo/releases").is_err());
        assert!(validated_release_url("https://github.com/jryang1997/MenuBarMijia").is_err());
        assert!(validated_release_url("javascript:alert(1)").is_err());
    }

    #[test]
    fn frontend_cannot_grant_an_arbitrary_origin_and_then_request_it() {
        let _guard = ORIGIN_TEST_LOCK.lock().unwrap();
        {
            let mut guard = EXTRA_ALLOWED_ORIGINS.write().expect("allowlist lock");
            guard.clear();
        }
        let app = tauri::test::mock_builder()
            .invoke_handler(tauri::generate_handler![native_http, set_allowed_origins, set_service_endpoints])
            .build(tauri::test::mock_context(tauri::test::noop_assets()))
            .expect("isolated IPC application");
        let window = tauri::WebviewWindowBuilder::new(&app, "main", Default::default())
            .build()
            .expect("isolated IPC window");
        let invoke_url: reqwest::Url = "http://tauri.localhost".parse().expect("local app origin");
        let _grant = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "set_allowed_origins".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: invoke_url.clone(),
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "origins": ["https://evil.example"]
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        let _service = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "set_service_endpoints".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: invoke_url.clone(),
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "assistantUrl": "https://evil.example",
                    "haUrl": ""
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        let response = tauri::test::get_ipc_response(
            &window,
            tauri::webview::InvokeRequest {
                cmd: "native_http".into(),
                callback: tauri::ipc::CallbackFn(0),
                error: tauri::ipc::CallbackFn(1),
                url: invoke_url,
                body: tauri::ipc::InvokeBody::Json(serde_json::json!({
                    "url": "https://evil.example/steal",
                    "method": "POST",
                    "headers": {"Authorization": "Bearer isolated-test-value"},
                    "body": "private-data",
                    "timeoutMs": 100
                })),
                headers: Default::default(),
                invoke_key: tauri::test::INVOKE_KEY.to_string(),
            },
        );
        EXTRA_ALLOWED_ORIGINS.write().expect("allowlist lock").clear();
        let error = response.expect_err("a frontend grant must not make native_http reach evil.example");
        let message = error.as_str().expect("policy error returned to the frontend");
        assert!(
            message.contains("拒绝访问未授权来源"),
            "frontend grant reached transport: {message}"
        );
        assert!(message.contains("evil.example"), "unexpected IPC error: {message}");
    }

    #[test]
    fn confirmation_authorizes_only_the_configured_service_origins() {
        let empty = HashSet::new();
        let granted = decide_service_origins(
            &empty,
            "HTTPS://API.DeepSeek.com:8443/v1",
            "http://[::1]:8123/api",
            |_| true,
        )
        .expect("confirmed endpoints authorize");
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://api.deepseek.com:8443/v1/chat/completions").unwrap(),
            &granted
        )
        .is_ok());
        assert!(check_url_allowed(
            &reqwest::Url::parse("http://[::1]:8123/api/states").unwrap(),
            &granted
        )
        .is_ok());
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://evil.example/steal").unwrap(),
            &granted
        )
        .is_err());
        assert!(check_url_allowed(
            &reqwest::Url::parse("http://api.deepseek.com:8443/v1").unwrap(),
            &granted
        )
        .is_err());

        let denied = decide_service_origins(&granted, "https://evil.example", "http://[::1]:8123/api", |_| false);
        assert!(denied.is_err());
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://evil.example/steal").unwrap(),
            &granted
        )
        .is_err());

        let shrunk = decide_service_origins(&granted, "", "http://[::1]:8123/api", |_| false)
            .expect("dropping an endpoint does not need a new grant");
        assert!(check_url_allowed(
            &reqwest::Url::parse("https://api.deepseek.com:8443/v1").unwrap(),
            &shrunk
        )
        .is_err());
        assert!(check_url_allowed(
            &reqwest::Url::parse("http://[::1]:8123/api/states").unwrap(),
            &shrunk
        )
        .is_ok());
    }

    #[test]
    fn authorized_origin_store_roundtrips_exact_origins() {
        let dir = std::env::temp_dir().join(format!("menubarmijia-origins-{}", std::process::id()));
        let path = dir.join("authorized-http-origins.json");
        let mut origins = HashSet::new();
        origins.insert("https://api.deepseek.com:8443".to_string());
        origins.insert("http://[::1]:8123".to_string());
        write_origin_store(&path, &origins).expect("write store");
        assert_eq!(read_origin_store(&path), origins);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn panel_placement_roundtrips_and_falls_back_to_auto() {
        let dir = std::env::temp_dir().join(format!("menubarmijia-placement-{}", std::process::id()));
        let path = dir.join("panel-placement.json");
        assert_eq!(read_panel_placement(&path).anchor, PanelAnchor::Auto);
        write_panel_placement(&path, PanelPlacement { anchor: PanelAnchor::TopRight }).expect("write placement");
        assert_eq!(read_panel_placement(&path).anchor, PanelAnchor::TopRight);
        std::fs::write(&path, "{not json").expect("corrupt placement");
        assert_eq!(read_panel_placement(&path).anchor, PanelAnchor::Auto);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn global_shortcut_parser_accepts_modified_keys_and_function_keys_only() {
        let (alt_m, label) = parse_global_shortcut("Alt+M").expect("Alt+M is valid");
        assert_eq!(label, "Alt+M");
        assert_eq!(alt_m, Shortcut::new(Some(Modifiers::ALT), Code::KeyM));

        let (ctrl_shift_k, _) = parse_global_shortcut("Ctrl+Shift+K").expect("Ctrl+Shift+K is valid");
        assert_eq!(
            ctrl_shift_k,
            Shortcut::new(Some(Modifiers::CONTROL | Modifiers::SHIFT), Code::KeyK)
        );

        let (f8, _) = parse_global_shortcut("F8").expect("standalone F8 is valid");
        assert_eq!(f8, Shortcut::new(None, Code::F8));

        let (ctrl_numpad1, _) = parse_global_shortcut("Ctrl+Numpad1").expect("Ctrl+Numpad1 is valid");
        assert_eq!(ctrl_numpad1, Shortcut::new(Some(Modifiers::CONTROL), Code::Numpad1));

        for invalid in ["", "   ", "M", "1", "Space", "Ctrl+", "NotAKey"] {
            assert!(
                parse_global_shortcut(invalid).is_err(),
                "expected {invalid:?} to be rejected"
            );
        }
    }

    #[test]
    fn tray_labels_include_shortcut_only_when_enabled() {
        assert_eq!(
            tray_labels_for_shortcut(Some("Ctrl+Alt+M")),
            (
                "打开/隐藏控制中心 (Ctrl+Alt+M)".to_string(),
                "MenuBarMijia · 菜单栏米家 (Ctrl+Alt+M)".to_string()
            )
        );
        assert_eq!(
            tray_labels_for_shortcut(None),
            (
                "打开/隐藏控制中心".to_string(),
                "MenuBarMijia · 菜单栏米家".to_string()
            )
        );
    }

    #[test]
    fn validates_release_asset_urls_filenames_and_sha256() {
        assert!(validated_release_asset_url(
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/MenuBarMijia-1.1.4-windows-x64-setup.exe"
        )
        .is_ok());
        assert!(validated_release_asset_url(
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/MenuBarMijia-1.1.4-windows-x64-setup.exe.sha256"
        )
        .is_ok());

        for bad in [
            "http://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/setup.exe",
            "https://evil.example/jryang1997/MenuBarMijia/releases/download/v1.1.4/setup.exe",
            "https://github.com/other/repo/releases/download/v1.1.4/setup.exe",
            "https://github.com/jryang1997/MenuBarMijia/releases/tag/v1.1.4",
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.1.4/setup.exe?foo=1",
        ] {
            assert!(validated_release_asset_url(bad).is_err(), "{bad}");
        }

        assert!(release_asset_redirect_allowed(
            &reqwest::Url::parse("https://objects.githubusercontent.com/github-production-release-asset/123").unwrap()
        ));
        assert!(!release_asset_redirect_allowed(
            &reqwest::Url::parse("https://evil.example/setup.exe").unwrap()
        ));
        assert!(!release_asset_redirect_allowed(
            &reqwest::Url::parse("http://objects.githubusercontent.com/setup.exe").unwrap()
        ));

        assert_eq!(
            sanitize_installer_filename("MenuBarMijia-1.1.4-windows-x64-setup.exe").ok(),
            Some("MenuBarMijia-1.1.4-windows-x64-setup.exe".to_string())
        );
        for bad_name in [
            "../setup.exe",
            "dir/setup.exe",
            "dir\\setup.exe",
            "C:setup.exe",
            "payload.bat",
            "",
        ] {
            assert!(sanitize_installer_filename(bad_name).is_err(), "{bad_name}");
        }

        let hex = compute_sha256_hex(b"verified-windows-installer");
        assert_eq!(parse_sha256_hex(&format!("sha256:{}", hex.to_uppercase())), Some(hex.clone()));
        assert_eq!(parse_sha256_hex(&format!("{hex}  MenuBarMijia-1.1.4-windows-x64-setup.exe\n")), Some(hex));
        assert_eq!(parse_sha256_hex("sha256:1234"), None);

        // Built-in Ed25519 public key decodes to 32 bytes (ADR-0005).
        assert_eq!(
            decode_base64_strict(UPDATE_SIGNING_PUBLIC_KEY_BASE64).map(|b| b.len()),
            Some(32)
        );
        assert_eq!(
            update_signing_public_keys().first().copied(),
            Some(UPDATE_SIGNING_PUBLIC_KEY_BASE64)
        );
        assert!(update_signing_public_keys().iter().all(|key| !key.is_empty()));
        // Cross-platform CryptoKit Ed25519 signature over `b"verified-windows-installer"`.
        let test_pub_b64 = "IVL40Zt5HSRFMkLhXy6rbLfP+ntqXtMAl5YOBpiB2xI=";
        let test_sig_b64 =
            "KtT4QT0xAahlehckpgTkX9/sMX/HypxQGInJ5/dR9Nl78X8bKzLcRNNLEzDGH6y+W3CRzkGiuf1qgIs6DCQDAQ==";
        assert!(verify_ed25519_signature(
            test_sig_b64,
            test_pub_b64,
            b"verified-windows-installer"
        )
        .is_ok());
        assert!(verify_ed25519_signature(
            test_sig_b64,
            test_pub_b64,
            b"tampered-windows-installer"
        )
        .is_err());
        assert!(verify_ed25519_signature(
            test_sig_b64,
            UPDATE_SIGNING_PUBLIC_KEY_BASE64,
            b"verified-windows-installer"
        )
        .is_err());
        assert!(verify_ed25519_signature("", UPDATE_SIGNING_PUBLIC_KEY_BASE64, b"payload").is_err());
        assert!(verify_ed25519_signature("not-base64!", UPDATE_SIGNING_PUBLIC_KEY_BASE64, b"payload").is_err());

        assert!(elevated_launch_powershell_command(false).contains("-Verb RunAs"));
        assert!(elevated_launch_powershell_command(false).contains("-ErrorAction Stop"));
        assert!(elevated_launch_powershell_command(true).contains("msiexec.exe"));
        assert!(elevated_launch_powershell_command(true).contains("-Verb RunAs"));
    }

    #[test]
    fn go2rtc_config_requires_local_auth_and_ignores_appended_streams() {
        let session = Go2RtcSession {
            api_listen: "127.0.0.1:43123".to_string(),
            rtsp_listen: "127.0.0.1:43124".to_string(),
            username: "muser0001".to_string(),
            password: "mpass0001".to_string(),
            nonce: "mnonce0001".to_string(),
        };
        let ffmpeg = "C:/Users/test/AppData/Local/MenuBarMijia/bin/ffmpeg-silent.exe";
        let written = desired_go2rtc_config(&session, ffmpeg);
        assert!(
            !written.contains("origin:"),
            "go2rtc config must not expose wildcard CORS to arbitrary web pages: {written}"
        );
        assert!(!written.contains('*'));
        assert!(!written.contains("1984"));
        assert!(!written.contains("8554"));
        assert!(written.contains("listen: 127.0.0.1:43123"));
        assert!(written.contains("listen: 127.0.0.1:43124"));
        assert!(written.contains("local_auth: true"));
        assert!(written.contains("username: \"muser0001\""));
        assert!(written.contains("password: \"mpass0001\""));
        assert!(written.contains("nonce: \"mnonce0001\""));
        assert!(written.contains("allow_paths:"));
        assert!(written.contains(&yaml_double_quoted(ffmpeg)));
        assert!(written.contains("webrtc:\n  listen: \"\""));
        assert_eq!(
            basic_authorization_value("muser", "mpass"),
            "Basic bXVzZXI6bXBhc3M="
        );
        assert!(parse_owner(
            "pid=1\napi_listen=127.0.0.1:1984\nrtsp_listen=127.0.0.1:43124\nusername=muser0001\npassword=mpass0001\nnonce=mnonce0001\n"
        )
        .is_none());

        let rewritten_by_go2rtc = format!(
            "{written}\nstreams:\n  cam_raw_1105610385:\n    - xiaomi://127.0.0.1:5000?client_private=secret\n"
        );
        assert_eq!(
            base_go2rtc_config(&rewritten_by_go2rtc),
            base_go2rtc_config(&written)
        );
        assert_ne!(
            base_go2rtc_config(&written.replace("43123", "43125")),
            base_go2rtc_config(&written)
        );
    }

    #[test]
    fn go2rtc_reuses_only_an_authenticated_owned_instance() {
        let owned = Go2RtcOwnershipProbe {
            pid_alive: true,
            authenticated: true,
            nonce_matches: true,
            config_changed: false,
        };
        assert_eq!(decide_go2rtc_action(owned), Go2RtcAction::ReuseOwned);
        assert_eq!(
            decide_go2rtc_action(Go2RtcOwnershipProbe {
                config_changed: true,
                ..owned
            }),
            Go2RtcAction::RestartOwned
        );
        assert_eq!(
            decide_go2rtc_action(Go2RtcOwnershipProbe {
                pid_alive: true,
                authenticated: false,
                nonce_matches: false,
                config_changed: true,
            }),
            Go2RtcAction::SpawnFresh
        );
        assert_eq!(
            decide_go2rtc_action(Go2RtcOwnershipProbe {
                pid_alive: true,
                authenticated: true,
                nonce_matches: false,
                config_changed: false,
            }),
            Go2RtcAction::SpawnFresh
        );
        assert_eq!(
            decide_go2rtc_action(Go2RtcOwnershipProbe {
                pid_alive: false,
                authenticated: true,
                nonce_matches: true,
                config_changed: false,
            }),
            Go2RtcAction::SpawnFresh
        );
        let session = Go2RtcSession {
            api_listen: "127.0.0.1:43123".to_string(),
            rtsp_listen: "127.0.0.1:43124".to_string(),
            username: "muser0001".to_string(),
            password: "mpass0001".to_string(),
            nonce: "mnonce0001".to_string(),
        };
        assert_eq!(
            go2rtc_jpeg_frame_url(&session, "cam_mjpeg_dev_cam").expect("frame url"),
            "http://127.0.0.1:43123/api/frame.jpeg?src=cam_mjpeg_dev_cam"
        );
        assert!(go2rtc_jpeg_frame_url(&session, "http://127.0.0.1:1984/api/config").is_err());
        assert!(go2rtc_jpeg_frame_url(&session, "../api/config").is_err());
        let stranger = Go2RtcSession {
            api_listen: "127.0.0.1:1984".to_string(),
            ..session
        };
        assert!(go2rtc_jpeg_frame_url(&stranger, "cam_mjpeg_dev_cam").is_err());

        let ports = reserve_loopback_ports(2).expect("loopback ports");
        assert_eq!(ports.len(), 2);
        assert_ne!(ports[0], ports[1]);
        for port in ports {
            assert!(!FORBIDDEN_GO2RTC_PORTS.contains(&port));
        }
    }
}
