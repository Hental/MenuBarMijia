use serde_json::Value;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum AcceptFailure {
    SignatureMissing,
    Malformed,
    SignatureInvalid,
    KeyIdMismatch,
    ReleaseVersionMismatch,
    NotNewer,
    BelowMinimum { current: String, minimum: String },
    UnexpectedPackage,
    HashMismatch { expected: String, actual: String },
}

pub(crate) struct VerifiedUpdate {
    version_text: String,
    package_name: String,
}

pub(crate) struct ReleasePair {
    pub(crate) version: String,
    pub(crate) installer_url: reqwest::Url,
    pub(crate) manifest_url: reqwest::Url,
    pub(crate) signature_url: reqwest::Url,
}

pub(crate) fn accept_failure_message(failure: AcceptFailure) -> String {
    match failure {
        AcceptFailure::SignatureMissing => {
            "更新包缺少 Ed25519 数字签名（.update.json.ed25519.sig），已中止安装".to_string()
        }
        AcceptFailure::HashMismatch { expected, actual } => format!(
            "安装包 SHA-256 校验失败（期望 {}…，实际 {}…），已中止安装",
            &expected[..expected.len().min(12)],
            &actual[..actual.len().min(12)]
        ),
        AcceptFailure::BelowMinimum { current, minimum } => format!(
            "当前版本 {current} 低于此更新要求的最低版本 {minimum}，已中止安装"
        ),
        AcceptFailure::SignatureInvalid
        | AcceptFailure::Malformed
        | AcceptFailure::KeyIdMismatch
        | AcceptFailure::ReleaseVersionMismatch
        | AcceptFailure::NotNewer
        | AcceptFailure::UnexpectedPackage => {
            "更新包 Ed25519 数字签名校验失败：签名与发布清单不匹配，已中止安装".to_string()
        }
    }
}

pub(crate) fn accept_update_manifest(
    manifest: &[u8],
    signature_text: &str,
    public_key_base64: &str,
    release_version: &str,
    running_version: &str,
    package_name: &str,
    package_bytes: &[u8],
) -> Result<VerifiedUpdate, AcceptFailure> {
    let signature = signature_text.trim();
    if signature.is_empty() {
        return Err(AcceptFailure::SignatureMissing);
    }
    if manifest.len() > 4096 || signature.len() > 256 {
        return Err(AcceptFailure::Malformed);
    }
    if super::verify_ed25519_signature(signature, public_key_base64, manifest).is_err() {
        return Err(AcceptFailure::SignatureInvalid);
    }
    let parsed = parse_manifest(manifest).ok_or(AcceptFailure::Malformed)?;
    if parsed.key_id != public_key_base64 {
        return Err(AcceptFailure::KeyIdMismatch);
    }
    if parsed.version_text != release_version {
        return Err(AcceptFailure::ReleaseVersionMismatch);
    }
    let Some(ordering) = compare_versions(running_version, &parsed.version_text) else {
        return Err(AcceptFailure::NotNewer);
    };
    if ordering != std::cmp::Ordering::Less {
        return Err(AcceptFailure::NotNewer);
    }
    let floor = compare_versions(running_version, &parsed.min_from).ok_or(AcceptFailure::Malformed)?;
    if floor == std::cmp::Ordering::Less {
        return Err(AcceptFailure::BelowMinimum {
            current: running_version.to_string(),
            minimum: parsed.min_from,
        });
    }
    let Some(entry) = parsed.files.iter().find(|file| file.name == package_name) else {
        return Err(AcceptFailure::UnexpectedPackage);
    };
    let actual = super::compute_sha256_hex(package_bytes);
    if actual != entry.sha256 {
        return Err(AcceptFailure::HashMismatch {
            expected: entry.sha256.clone(),
            actual,
        });
    }
    Ok(VerifiedUpdate {
        version_text: parsed.version_text,
        package_name: package_name.to_string(),
    })
}

pub(crate) fn release_pair(
    name: &str,
    download_url: &str,
    manifest_url: &str,
) -> Result<ReleasePair, String> {
    let installer_url = super::validated_release_asset_url(download_url)?;
    let manifest = super::validated_release_asset_url(manifest_url)?;
    let (installer_version, installer_file) = release_file(&installer_url)
        .ok_or_else(|| "更新包地址里的版本或文件名无效".to_string())?;
    let (manifest_version, manifest_file) = release_file(&manifest)
        .ok_or_else(|| "更新清单地址里的版本或文件名无效".to_string())?;
    if installer_version != manifest_version {
        return Err("安装包与更新清单的版本不一致".to_string());
    }
    let exe = format!("MenuBarMijia-{installer_version}-windows-x64-setup.exe");
    let msi = format!("MenuBarMijia-{installer_version}-windows-x64.msi");
    if name != installer_file || (installer_file != exe && installer_file != msi) {
        return Err("更新包文件名与版本不匹配".to_string());
    }
    let expected_manifest = format!("MenuBarMijia-{manifest_version}.update.json");
    if manifest_file != expected_manifest {
        return Err("更新清单文件名与版本不匹配".to_string());
    }
    let mut signature_url = manifest.clone();
    signature_url.set_path(&format!("{}{}", manifest.path(), ".ed25519.sig"));
    super::validated_release_asset_url(signature_url.as_str())?;
    Ok(ReleasePair {
        version: installer_version,
        installer_url,
        manifest_url: manifest,
        signature_url,
    })
}

struct ManifestFile {
    name: String,
    sha256: String,
}

struct ParsedManifest {
    version_text: String,
    min_from: String,
    key_id: String,
    files: Vec<ManifestFile>,
}

fn parse_manifest(bytes: &[u8]) -> Option<ParsedManifest> {
    let value: Value = serde_json::from_slice(bytes).ok()?;
    let object = value.as_object()?;
    if object.len() != 4
        || !object.contains_key("version")
        || !object.contains_key("min_from")
        || !object.contains_key("key_id")
        || !object.contains_key("files")
    {
        return None;
    }
    let version = object.get("version")?.as_str()?;
    let min_from = object.get("min_from")?.as_str()?;
    let key_id = object.get("key_id")?.as_str()?;
    if !is_release_version(version) || !is_release_version(min_from) {
        return None;
    }
    let signed_vs_floor = compare_versions(min_from, version)?;
    if signed_vs_floor == std::cmp::Ordering::Greater {
        return None;
    }
    let raw_files = object.get("files")?.as_array()?;
    if raw_files.len() != 3 {
        return None;
    }
    let expected = [
        ("macos", format!("MenuBarMijia-{version}.dmg")),
        ("windows", format!("MenuBarMijia-{version}-windows-x64-setup.exe")),
        ("windows", format!("MenuBarMijia-{version}-windows-x64.msi")),
    ];
    let mut files = Vec::with_capacity(3);
    for (raw, (platform, name)) in raw_files.iter().zip(expected) {
        let file = raw.as_object()?;
        if file.len() != 3
            || file.get("platform")?.as_str()? != platform
            || file.get("file")?.as_str()? != name
            || !is_lowercase_sha256(file.get("sha256")?.as_str()?)
        {
            return None;
        }
        files.push(ManifestFile {
            name,
            sha256: file.get("sha256")?.as_str()?.to_string(),
        });
    }
    Some(ParsedManifest {
        version_text: version.to_string(),
        min_from: min_from.to_string(),
        key_id: key_id.to_string(),
        files,
    })
}

fn is_release_version(text: &str) -> bool {
    let parts: Vec<&str> = text.split('.').collect();
    parts.len() == 3
        && parts
            .iter()
            .all(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
}

fn is_lowercase_sha256(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn version_parts(raw: &str) -> Option<Vec<u64>> {
    let trimmed = raw.trim();
    let without_v = trimmed
        .strip_prefix('v')
        .or_else(|| trimmed.strip_prefix('V'))
        .unwrap_or(trimmed);
    let core = without_v.split(['-', '+', ' ']).next().unwrap_or("");
    if core.is_empty() {
        return None;
    }
    let mut parts = Vec::new();
    for piece in core.split('.') {
        if piece.is_empty() {
            return None;
        }
        parts.push(piece.parse::<u64>().ok()?);
    }
    Some(parts)
}

fn compare_versions(left: &str, right: &str) -> Option<std::cmp::Ordering> {
    let left_parts = version_parts(left)?;
    let right_parts = version_parts(right)?;
    let length = left_parts.len().max(right_parts.len());
    for index in 0..length {
        let l = left_parts.get(index).copied().unwrap_or(0);
        let r = right_parts.get(index).copied().unwrap_or(0);
        if l != r {
            return Some(l.cmp(&r));
        }
    }
    Some(std::cmp::Ordering::Equal)
}

fn release_file(url: &reqwest::Url) -> Option<(String, String)> {
    let segments: Vec<&str> = url.path().split('/').filter(|part| !part.is_empty()).collect();
    if segments.len() != 6
        || segments[0] != "jryang1997"
        || segments[1] != "MenuBarMijia"
        || segments[2] != "releases"
        || segments[3] != "download"
    {
        return None;
    }
    let version = segments[4].strip_prefix('v')?;
    if !is_release_version(version) {
        return None;
    }
    Some((version.to_string(), segments[5].to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::rand::SystemRandom;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    struct SignedManifest {
        bytes: Vec<u8>,
        signature: String,
        public_key: String,
        package: Vec<u8>,
    }

    fn base64_encode(bytes: &[u8]) -> String {
        const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        let mut index = 0;
        while index + 3 <= bytes.len() {
            let value = ((bytes[index] as u32) << 16)
                | ((bytes[index + 1] as u32) << 8)
                | (bytes[index + 2] as u32);
            out.push(TABLE[((value >> 18) & 63) as usize] as char);
            out.push(TABLE[((value >> 12) & 63) as usize] as char);
            out.push(TABLE[((value >> 6) & 63) as usize] as char);
            out.push(TABLE[(value & 63) as usize] as char);
            index += 3;
        }
        let remaining = bytes.len() - index;
        if remaining == 1 {
            let value = (bytes[index] as u32) << 16;
            out.push(TABLE[((value >> 18) & 63) as usize] as char);
            out.push(TABLE[((value >> 12) & 63) as usize] as char);
            out.push('=');
            out.push('=');
        } else if remaining == 2 {
            let value = ((bytes[index] as u32) << 16) | ((bytes[index + 1] as u32) << 8);
            out.push(TABLE[((value >> 18) & 63) as usize] as char);
            out.push(TABLE[((value >> 12) & 63) as usize] as char);
            out.push(TABLE[((value >> 6) & 63) as usize] as char);
            out.push('=');
        }
        out
    }

    fn sign_manifest(version: &str, min_from: &str, key_id: Option<&str>, dmg_file: Option<&str>, package: &[u8]) -> SignedManifest {
        let rng = SystemRandom::new();
        let document = Ed25519KeyPair::generate_pkcs8(&rng).expect("ephemeral key");
        let key = Ed25519KeyPair::from_pkcs8(document.as_ref()).expect("ephemeral key");
        let public_key = base64_encode(key.public_key().as_ref());
        let owned_dmg = format!("MenuBarMijia-{version}.dmg");
        let dmg_name = dmg_file.unwrap_or(owned_dmg.as_str());
        let digest = super::super::compute_sha256_hex(package);
        let key_text = key_id.unwrap_or(public_key.as_str());
        let body = format!(
            "{{\"version\":\"{version}\",\"min_from\":\"{min_from}\",\"key_id\":\"{key_text}\",\"files\":[{{\"platform\":\"macos\",\"file\":\"{dmg_name}\",\"sha256\":\"{digest}\"}},{{\"platform\":\"windows\",\"file\":\"MenuBarMijia-{version}-windows-x64-setup.exe\",\"sha256\":\"{b}\"}},{{\"platform\":\"windows\",\"file\":\"MenuBarMijia-{version}-windows-x64.msi\",\"sha256\":\"{c}\"}}]}}\n",
            b = "b".repeat(64),
            c = "c".repeat(64),
        );
        let bytes = body.into_bytes();
        let signature = base64_encode(key.sign(&bytes).as_ref()) + "\n";
        SignedManifest {
            bytes,
            signature,
            public_key,
            package: package.to_vec(),
        }
    }

    fn accept<'a>(
        signed: &'a SignedManifest,
        release_version: &str,
        running_version: &str,
        package_name: &str,
        package_bytes: &'a [u8],
    ) -> Result<VerifiedUpdate, AcceptFailure> {
        accept_update_manifest(
            &signed.bytes,
            &signed.signature,
            &signed.public_key,
            release_version,
            running_version,
            package_name,
            package_bytes,
        )
    }

    #[test]
    fn rejects_a_manifest_signed_for_an_older_version() {
        let signed = sign_manifest("1.1.6", "1.0.0", None, None, b"dmg-1.1.6");
        let result = accept(&signed, "1.1.8", "1.1.5", "MenuBarMijia-1.1.6.dmg", &signed.package);
        assert_eq!(result.err(), Some(AcceptFailure::ReleaseVersionMismatch));
    }

    #[test]
    fn rejects_the_same_running_version() {
        let signed = sign_manifest("1.1.6", "1.0.0", None, None, b"dmg");
        let result = accept(&signed, "1.1.6", "1.1.6", "MenuBarMijia-1.1.6.dmg", &signed.package);
        assert_eq!(result.err(), Some(AcceptFailure::NotNewer));
    }

    #[test]
    fn rejects_version_text_changed_under_the_old_signature() {
        let signed = sign_manifest("1.1.6", "1.0.0", None, None, b"dmg");
        let mut text = String::from_utf8(signed.bytes.clone()).unwrap();
        let range = text.find("\"version\":\"1.1.6\"").unwrap();
        text.replace_range(range..range + "\"version\":\"1.1.6\"".len(), "\"version\":\"9.9.9\"");
        let result = accept_update_manifest(
            text.as_bytes(),
            &signed.signature,
            &signed.public_key,
            "9.9.9",
            "1.0.0",
            "MenuBarMijia-1.1.6.dmg",
            &signed.package,
        );
        assert_eq!(result.err(), Some(AcceptFailure::SignatureInvalid));
    }

    #[test]
    fn rejects_package_bytes_that_do_not_match() {
        let signed = sign_manifest("1.1.6", "1.0.0", None, None, b"dmg");
        let tampered = b"tampered";
        let result = accept(&signed, "1.1.6", "1.1.5", "MenuBarMijia-1.1.6.dmg", tampered);
        assert_eq!(
            result.err(),
            Some(AcceptFailure::HashMismatch {
                expected: super::super::compute_sha256_hex(&signed.package),
                actual: super::super::compute_sha256_hex(tampered),
            })
        );
    }

    #[test]
    fn rejects_a_key_id_that_differs_from_the_public_key() {
        let signed = sign_manifest("1.1.6", "1.0.0", Some("not-the-public-key"), None, b"dmg");
        let result = accept(&signed, "1.1.6", "1.1.5", "MenuBarMijia-1.1.6.dmg", &signed.package);
        assert_eq!(result.err(), Some(AcceptFailure::KeyIdMismatch));
    }

    #[test]
    fn rejects_a_running_version_below_the_minimum() {
        let signed = sign_manifest("1.1.6", "1.1.0", None, None, b"dmg");
        let result = accept(&signed, "1.1.6", "1.0.9", "MenuBarMijia-1.1.6.dmg", &signed.package);
        assert_eq!(
            result.err(),
            Some(AcceptFailure::BelowMinimum {
                current: "1.0.9".to_string(),
                minimum: "1.1.0".to_string(),
            })
        );
    }

    #[test]
    fn rejects_an_empty_signature() {
        let signed = sign_manifest("1.1.6", "1.0.0", None, None, b"dmg");
        let result = accept_update_manifest(
            &signed.bytes,
            "",
            &signed.public_key,
            "1.1.6",
            "1.1.5",
            "MenuBarMijia-1.1.6.dmg",
            &signed.package,
        );
        assert_eq!(result.err(), Some(AcceptFailure::SignatureMissing));
    }

    #[test]
    fn rejects_a_dmg_name_that_disagrees_with_the_version() {
        let signed = sign_manifest("1.1.6", "1.0.0", None, Some("MenuBarMijia-1.1.7.dmg"), b"dmg");
        let result = accept(&signed, "1.1.6", "1.1.5", "MenuBarMijia-1.1.6.dmg", &signed.package);
        assert_eq!(result.err(), Some(AcceptFailure::Malformed));
    }

    #[test]
    fn success_returns_the_signed_version_and_package_name() {
        let signed = sign_manifest("1.1.7", "1.0.0", None, None, b"dmg");
        let verified = accept(&signed, "1.1.7", "1.1.6", "MenuBarMijia-1.1.7.dmg", &signed.package).unwrap();
        assert_eq!(verified.version_text, "1.1.7");
        assert_eq!(verified.package_name, "MenuBarMijia-1.1.7.dmg");
    }

    #[test]
    fn one_zero_ten_is_newer_than_one_zero_nine() {
        let signed = sign_manifest("1.0.10", "1.0.0", None, None, b"dmg");
        let verified = accept(&signed, "1.0.10", "1.0.9", "MenuBarMijia-1.0.10.dmg", &signed.package).unwrap();
        assert_eq!(verified.version_text, "1.0.10");
    }

    #[test]
    fn release_pair_rejects_a_non_github_host() {
        let result = release_pair(
            "MenuBarMijia-1.2.0-windows-x64-setup.exe",
            "https://evil.example/jryang1997/MenuBarMijia/releases/download/v1.2.0/MenuBarMijia-1.2.0-windows-x64-setup.exe",
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.2.0/MenuBarMijia-1.2.0.update.json",
        );
        assert!(result.is_err());
    }

    #[test]
    fn release_pair_rejects_a_version_mismatch_between_installer_and_manifest() {
        let result = release_pair(
            "MenuBarMijia-1.2.0-windows-x64-setup.exe",
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.2.0/MenuBarMijia-1.2.0-windows-x64-setup.exe",
            "https://github.com/jryang1997/MenuBarMijia/releases/download/v1.2.1/MenuBarMijia-1.2.1.update.json",
        );
        assert!(result.is_err());
    }
}
