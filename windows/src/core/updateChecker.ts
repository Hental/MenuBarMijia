/**
 * Minimal GitHub release update check (#39).
 *
 * The panel asks at most once per local calendar day, remembers the last attempt in
 * `localStorage`, and never runs when the user turned "自动检查更新" off. The network
 * call is injected (`requestLatest`) so the rules are testable without a WebView or
 * GitHub. In production the UI passes the existing `native_http` transport; the Rust
 * allowlist includes `api.github.com` (#29).
 */

export const UPDATE_RELEASES_URL =
  "https://api.github.com/repos/jryang1997/MenuBarMijia/releases/latest";
export const UPDATE_RELEASES_PAGE = "https://github.com/jryang1997/MenuBarMijia/releases/latest";
export const UPDATE_STORAGE_KEY = "menumijia.windows.update.v1";
/** Offline Ed25519 public key (ADR-0005), shared with `UpdateChecker.updateSigningPublicKeyBase64` on macOS. */
export const UPDATE_SIGNING_PUBLIC_KEY_BASE64 = "rLwWXuP0sOZvgd/KusLTTmBXN9DAZ9EzPBNhFSn9yUo=";

export interface WindowsInstallerAsset {
  /** Asset file name, e.g. `MenuBarMijia-1.1.4-windows-x64-setup.exe`. */
  readonly name: string;
  /** Constructed download URL under https://github.com/jryang1997/MenuBarMijia/releases/download/... */
  readonly downloadUrl: string;
  /** Byte size reported by GitHub (0 when unknown). */
  readonly sizeBytes: number;
  /** Release manifest URL. The signature is this URL with `.ed25519.sig` appended. */
  readonly manifestUrl: string;
}

export interface GitHubRelease {
  /** Version without the leading `v`, e.g. `1.0.7`. */
  readonly version: string;
  /** Original release tag, e.g. `v1.0.7`. */
  readonly tag: string;
  /** GitHub release page, always an https://github.com/ URL. */
  readonly htmlURL: string;
  /** Optional release notes markdown (`body`). */
  readonly notes?: string;
  /** Optional verified Windows installer asset (`.exe` preferred over `.msi`). */
  readonly installerAsset?: WindowsInstallerAsset;
}

export interface UpdateState {
  readonly lastCheckedAtMs: number | null;
  readonly release: GitHubRelease | null;
}

/** Strips an optional `v`/`V` and validates the dotted numeric version shape. */
export function normalizeVersionTag(raw: string): string | null {
  const trimmed = raw.trim().replace(/^v/i, "");
  if (!/^\d+(?:\.\d+)*(?:[-+][0-9A-Za-z.-]+)?$/.test(trimmed)) return null;
  return trimmed;
}

function versionParts(raw: string): number[] {
  const core = (normalizeVersionTag(raw) ?? "0").split(/[-+]/, 1)[0] ?? "0";
  return core.split(".").map((part) => {
    const value = Number.parseInt(part, 10);
    return Number.isFinite(value) ? value : 0;
  });
}

/** Numeric dotted comparison: `1.0.6 < 1.0.10`; pre-release suffixes are ignored. */
export function compareVersions(a: string, b: string): number {
  const left = versionParts(a);
  const right = versionParts(b);
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const delta = (left[index] ?? 0) - (right[index] ?? 0);
    if (delta !== 0) return delta > 0 ? 1 : -1;
  }
  return 0;
}

export function isNewerVersion(latest: string, current: string): boolean {
  return compareVersions(latest, current) > 0;
}

/** Local calendar day key (`2026-10-27`), so "today" follows the user's clock. */
export function updateCheckDayKey(nowMs: number): string {
  const date = new Date(nowMs);
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${date.getFullYear()}-${month}-${day}`;
}

export function shouldCheckForUpdate(nowMs: number, lastCheckedAtMs: number | null): boolean {
  if (lastCheckedAtMs === null) return true;
  return updateCheckDayKey(nowMs) !== updateCheckDayKey(lastCheckedAtMs);
}

const RELEASE_DOWNLOAD_URL_PATTERN =
  /^https:\/\/github\.com\/jryang1997\/MenuBarMijia\/releases\/download\/[^\s]+$/i;

function releaseDownloadURL(version: string, fileName: string): string {
  return `https://github.com/jryang1997/MenuBarMijia/releases/download/v${version}/${fileName}`;
}

function assetSize(raw: unknown): number {
  return typeof raw === "number" && Number.isFinite(raw) && raw >= 0 ? Math.floor(raw) : 0;
}

function parseInstallerAssetRecord(raw: unknown): WindowsInstallerAsset | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const record = raw as Record<string, unknown>;
  const legacySignature = record["signatureUrl"] ?? record["signatureURL"];
  const manifestUrl = typeof record["manifestUrl"] === "string" ? record["manifestUrl"].trim() : "";
  if (typeof legacySignature === "string" && legacySignature.trim() !== "" && manifestUrl === "") return null;
  const name = typeof record["name"] === "string" ? record["name"].trim() : "";
  const downloadUrlRaw = record["downloadUrl"] ?? record["downloadURL"];
  const downloadUrl = typeof downloadUrlRaw === "string" ? downloadUrlRaw.trim() : "";
  if (!name || /[\\/:]|\.\./.test(name) || !/\.(?:exe|msi)$/i.test(name)) return null;
  if (!RELEASE_DOWNLOAD_URL_PATTERN.test(downloadUrl)) return null;
  if (!RELEASE_DOWNLOAD_URL_PATTERN.test(manifestUrl) || !manifestUrl.endsWith(".update.json")) return null;
  return { name, downloadUrl, sizeBytes: assetSize(record["sizeBytes"]), manifestUrl };
}

export function selectWindowsInstallerAsset(version: string, rawAssets: unknown): WindowsInstallerAsset | null {
  if (!/^\d+\.\d+\.\d+$/.test(version) || !Array.isArray(rawAssets)) return null;
  const names = new Set<string>();
  const sizeByName = new Map<string, number>();
  for (const item of rawAssets) {
    if (item === null || typeof item !== "object" || Array.isArray(item)) continue;
    const record = item as Record<string, unknown>;
    const name = typeof record["name"] === "string" ? record["name"].trim() : "";
    if (!name) continue;
    names.add(name);
    if (!sizeByName.has(name)) sizeByName.set(name, assetSize(record["size"]));
  }
  const manifestName = `MenuBarMijia-${version}.update.json`;
  if (!names.has(manifestName)) return null;
  const exeName = `MenuBarMijia-${version}-windows-x64-setup.exe`;
  const msiName = `MenuBarMijia-${version}-windows-x64.msi`;
  const chosen = names.has(exeName) ? exeName : names.has(msiName) ? msiName : null;
  if (!chosen) return null;
  return {
    name: chosen,
    downloadUrl: releaseDownloadURL(version, chosen),
    sizeBytes: sizeByName.get(chosen) ?? 0,
    manifestUrl: releaseDownloadURL(version, manifestName),
  };
}

/** Parses `GET /repos/.../releases/latest`; rejects drafts/odd payloads without a tag. */
export function parseLatestRelease(body: string): GitHubRelease | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return null;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const record = parsed as Record<string, unknown>;
  const tag = typeof record["tag_name"] === "string" ? record["tag_name"] : "";
  const version = normalizeVersionTag(tag);
  if (!version) return null;
  const rawURL = typeof record["html_url"] === "string" ? record["html_url"].trim() : "";
  const htmlURL = /^https:\/\/github\.com\/[^\s]+$/i.test(rawURL) ? rawURL : UPDATE_RELEASES_PAGE;
  const notes = typeof record["body"] === "string" ? record["body"].trim() : "";
  const installerAsset = selectWindowsInstallerAsset(version, record["assets"]);
  return {
    version,
    tag,
    htmlURL,
    ...(notes ? { notes } : {}),
    ...(installerAsset ? { installerAsset } : {}),
  };
}

export function parseUpdateState(raw: string | null): UpdateState {
  if (!raw) return { lastCheckedAtMs: null, release: null };
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const lastCheckedAtMs =
      typeof parsed["lastCheckedAtMs"] === "number" && Number.isFinite(parsed["lastCheckedAtMs"])
        ? parsed["lastCheckedAtMs"]
        : null;
    const stored = parsed["release"];
    let release: GitHubRelease | null = null;
    if (stored !== null && typeof stored === "object" && !Array.isArray(stored)) {
      const record = stored as Record<string, unknown>;
      const version = typeof record["version"] === "string" ? normalizeVersionTag(record["version"]) : null;
      if (version) {
        const rawURL = typeof record["htmlURL"] === "string" ? record["htmlURL"].trim() : "";
        const notes = typeof record["notes"] === "string" ? record["notes"].trim() : "";
        const installerAsset = parseInstallerAssetRecord(record["installerAsset"]);
        release = {
          version,
          tag: typeof record["tag"] === "string" ? record["tag"] : `v${version}`,
          htmlURL: /^https:\/\/github\.com\/[^\s]+$/i.test(rawURL) ? rawURL : UPDATE_RELEASES_PAGE,
          ...(notes ? { notes } : {}),
          ...(installerAsset ? { installerAsset } : {}),
        };
      }
    }
    return { lastCheckedAtMs, release };
  } catch {
    return { lastCheckedAtMs: null, release: null };
  }
}

export function serializeUpdateState(state: UpdateState): string {
  return JSON.stringify({
    lastCheckedAtMs: state.lastCheckedAtMs,
    release: state.release
      ? {
          version: state.release.version,
          tag: state.release.tag,
          htmlURL: state.release.htmlURL,
          ...(state.release.notes ? { notes: state.release.notes } : {}),
          ...(state.release.installerAsset ? { installerAsset: state.release.installerAsset } : {}),
        }
      : null,
  });
}

export interface UpdateCheckResult {
  /** True when the network was actually contacted. */
  readonly requested: boolean;
  readonly release: GitHubRelease | null;
  /** True only for a successfully parsed release newer than the running version. */
  readonly updateAvailable: boolean;
  /** Attempt time to persist; `null` when the check was skipped. */
  readonly checkedAtMs: number | null;
  /** True when the request/parse failed (offline, rate limit, malformed JSON). */
  readonly failed: boolean;
}

export interface UpdateCheckOptions {
  readonly currentVersion: string;
  readonly enabled: boolean;
  readonly lastCheckedAtMs: number | null;
  readonly nowMs: number;
  /** Injected network call; resolves the HTTP status and body. */
  readonly requestLatest: () => Promise<{ readonly status: number; readonly body: string }>;
  /** Manual "立即检查" bypasses the once-a-day rule but never the off switch. */
  readonly force?: boolean;
}

export async function checkForUpdate(options: UpdateCheckOptions): Promise<UpdateCheckResult> {
  if (!options.enabled) {
    return { requested: false, release: null, updateAvailable: false, checkedAtMs: options.lastCheckedAtMs, failed: false };
  }
  if (!options.force && !shouldCheckForUpdate(options.nowMs, options.lastCheckedAtMs)) {
    return { requested: false, release: null, updateAvailable: false, checkedAtMs: options.lastCheckedAtMs, failed: false };
  }

  let release: GitHubRelease | null = null;
  let failed = false;
  try {
    const response = await options.requestLatest();
    if (response.status === 200) {
      release = parseLatestRelease(response.body);
      if (release === null) failed = true;
    } else {
      failed = true;
    }
  } catch {
    failed = true;
  }

  return {
    requested: true,
    release,
    updateAvailable: release !== null && isNewerVersion(release.version, options.currentVersion),
    checkedAtMs: options.nowMs,
    failed,
  };
}
