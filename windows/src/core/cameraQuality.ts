/**
 * Xiaomi camera stream quality (#97, macOS parity with XiaomiCameraStreamQuality).
 *
 * go2rtc's `xiaomi://` source accepts `subtype=auto|sd|hd|3`. `sd` is about 480p,
 * `hd` is its usual quality 2, and several 4K models only expose the top stream on
 * numeric subtype 3. Stored values are semantic, so a future go2rtc mapping change
 * does not alter saved preferences.
 */

export type CameraStreamQuality = "auto" | "sd" | "hd" | "max";

export const CAMERA_STREAM_QUALITIES: readonly CameraStreamQuality[] = ["auto", "sd", "hd", "max"];

/** Matches the macOS storage default (#193): go2rtc's usual quality, not the 4K subtype. */
export const DEFAULT_CAMERA_STREAM_QUALITY: CameraStreamQuality = "hd";

/** go2rtc query value for a stored quality. `auto` lets the camera pick. */
export function cameraStreamSubtype(quality: CameraStreamQuality): string {
  switch (quality) {
    case "auto":
      return "auto";
    case "sd":
      return "sd";
    case "hd":
      return "hd";
    case "max":
      return "3";
  }
}

/** Unknown or corrupt persisted values fall back to the default instead of failing startup. */
export function normalizeCameraStreamQuality(raw: unknown): CameraStreamQuality {
  return typeof raw === "string" && (CAMERA_STREAM_QUALITIES as readonly string[]).includes(raw)
    ? (raw as CameraStreamQuality)
    : DEFAULT_CAMERA_STREAM_QUALITY;
}

/** Drops unknown ids/values from the persisted per-camera map. */
export function normalizeCameraStreamQualityMap(raw: unknown): Record<string, CameraStreamQuality> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const map: Record<string, CameraStreamQuality> = {};
  for (const [deviceId, value] of Object.entries(raw as Record<string, unknown>)) {
    if (deviceId.trim() === "" || typeof value !== "string") continue;
    if (!(CAMERA_STREAM_QUALITIES as readonly string[]).includes(value)) continue;
    map[deviceId] = value as CameraStreamQuality;
  }
  return map;
}
