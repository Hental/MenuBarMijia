

export interface HttpRequest {
  readonly url: string;
  readonly method?: "GET" | "POST";
  readonly headers?: Readonly<Record<string, string>>;
  readonly body?: string;
  readonly followRedirects?: boolean;
  readonly timeoutMs?: number;
}

export interface HttpResponse {
  readonly status: number;
  readonly headers: Readonly<Record<string, string>>;
  readonly body: string;
}

export type HttpTransport = (req: HttpRequest) => Promise<HttpResponse>;

export interface QRLoginTicket {
  readonly qrImageURL: string;
  readonly loginURL: string;
  readonly longPollURL: string;
  readonly timeout: number;
}

export interface MiSession {
  readonly userId: string;
  readonly cUserId: string;
  readonly ssecurity: string;
  readonly serviceToken: string;
  readonly passToken: string;
  readonly region: string;
}

export function maskedMiUserId(userId: string): string {
  if (userId.length <= 4) return "*".repeat(userId.length);
  return `${userId.slice(0, 2)}****${userId.slice(-2)}`;
}

export interface MiCloudRegionOption {
  /** Xiaomi cloud region code, used as the API subdomain (`<code>.api.io.mi.com`). */
  readonly code: string;
  /** Label shown in the region dropdown. */
  readonly label: string;
}

/**
 * Xiaomi cloud regions offered by both apps (#37). Order and membership are shared with
 * macOS: Tests/Fixtures/region_golden.json is the single source of truth and both ends'
 * tests assert against it (macOS `MiCloudRegion.allCases`, Windows `MI_CLOUD_REGIONS`).
 */
export const MI_CLOUD_REGIONS: ReadonlyArray<MiCloudRegionOption> = [
  { code: "cn", label: "中国大陆 (cn)" },
  { code: "de", label: "欧洲 (de)" },
  { code: "i2", label: "印度 (i2)" },
  { code: "ru", label: "俄罗斯 (ru)" },
  { code: "sg", label: "新加坡 / 国际 (sg)" },
  { code: "us", label: "美区 (us)" },
];

/** Falls back to China Mainland for unknown/missing values coming from older settings. */
export function normalizeMiCloudRegion(raw: unknown): string {
  if (typeof raw !== "string") return "cn";
  const code = raw.trim().toLowerCase();
  return MI_CLOUD_REGIONS.some((region) => region.code === code) ? code : "cn";
}

export function miCloudRegionLabel(code: string): string {
  const normalized = normalizeMiCloudRegion(code);
  return MI_CLOUD_REGIONS.find((region) => region.code === normalized)?.label ?? normalized;
}

export function miApiBaseURL(region = "cn"): string {
  const r = region.trim().toLowerCase();
  return r === "" || r === "cn" ? "https://api.io.mi.com/app" : `https://${r}.api.io.mi.com/app`;
}

export class MiCloudError extends Error {
  readonly kind: "notLoggedIn" | "sessionExpired" | "http" | "api" | "badResponse";
  readonly code?: number;

  constructor(
    kind: "notLoggedIn" | "sessionExpired" | "http" | "api" | "badResponse",
    message: string,
    code?: number
  ) {
    super(message);
    this.kind = kind;
    this.code = code;
  }
}

export function stripStartPrefix(raw: string): string {
  const trimmed = raw.trim();
  const marker = "&&&START&&&";
  const idx = trimmed.indexOf(marker);
  return idx >= 0 ? trimmed.slice(idx + marker.length).trim() : trimmed;
}

export function parseJsonObject(raw: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = JSON.parse(stripStartPrefix(raw));
    if (parsed !== null && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
    return null;
  } catch {
    return null;
  }
}

export function asIdString(v: unknown): string | null {
  if (typeof v === "string" && v.length > 0) return v;
  if (typeof v === "number" && Number.isFinite(v)) return String(Math.trunc(v));
  return null;
}
