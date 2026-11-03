import type { EnvironmentReading } from "../models.js";

// MARK: - Ambient Context & Jev SystemOne Request (#38)

/**
 * Ambient context sent with Jev `/v1/systemone` requests. Field names and empty-value
 * semantics match macOS `AssistantContext` (Sources/MijiaCore/UserHabitMemory.swift),
 * so both ends send the same `state` keys for the same home (#38).
 */
export interface AssistantContext {
  readonly timeSummary: string;
  readonly environmentSummary: string;
  readonly activeDevicesSummary: string;
  readonly habitSummary: string;
}

export const EMPTY_ASSISTANT_CONTEXT: AssistantContext = {
  timeSummary: "",
  environmentSummary: "",
  activeDevicesSummary: "",
  habitSummary: "",
};

/** Time-of-day buckets, identical to macOS `UserHabitMemory.TimeBucket`. */
export function timeBucketLabel(hour: number): string {
  if (hour >= 6 && hour < 11) return "清晨";
  if (hour >= 11 && hour < 14) return "午间";
  if (hour >= 14 && hour < 18) return "下午";
  if (hour >= 18 && hour < 23) return "夜晚";
  return "深夜";
}

/** `下午 15:07`, matching HomeStore.buildAssistantContext on macOS. */
export function buildTimeSummary(now: Date): string {
  const hours = String(now.getHours()).padStart(2, "0");
  const minutes = String(now.getMinutes()).padStart(2, "0");
  return `${timeBucketLabel(now.getHours())} ${hours}:${minutes}`;
}

/** `客厅 25.5°C 52%，卧室 23.0°C`, matching the macOS environment summary. */
export function buildEnvironmentSummary(readings: readonly EnvironmentReading[]): string {
  return readings
    .map((reading) => {
      let text = reading.roomName;
      if (reading.temperature !== null) text += ` ${reading.temperature.toFixed(1)}°C`;
      if (reading.humidity !== null) text += ` ${Math.round(reading.humidity)}%`;
      return text;
    })
    .join("，");
}
