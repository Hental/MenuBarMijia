import type {
  AssistantSuggestion,
  DeviceIntent,
  EnvironmentReading,
  HomeScene,
  IntentOperation,
  SmartDevice,
} from "../models.js";
import { deviceAcceptsControlWrites, deviceCanTogglePower, isDeviceActiveOn } from "../models.js";
import { timeBucketLabel } from "./context.js";
import { IntentReply } from "./intent.js";

// MARK: - Full-Channel Habit Memory & Top-4 Engine (#113)

/** One learned "in this time bucket + day type, this device gets this operation" counter. */
export interface HabitEntry {
  bucket: string;
  targetId: string;
  operationKey: string;
  count: number;
  /** Absent for entries recorded before ADR-0009; matches any day type. */
  dayType?: HabitDayType;
  /** Recency metadata for the decay score; the compared pattern stays the operation key. */
  lastRecordedAtMs?: number;
}

/** Weekday vs weekend context signal (WWDC18-211), coarsened to two buckets (ADR-0009). */
export type HabitDayType = "weekday" | "weekend";

/** One learned transition: after `afterKey` (targetId|operationKey), this operation often follows. */
export interface HabitSequenceEntry {
  afterKey: string;
  targetId: string;
  operationKey: string;
  count: number;
  lastRecordedAtMs?: number;
}

/** The most recent learned action, so the next record can form a transition. */
export interface HabitLastAction {
  targetId: string;
  operationKey: string;
  recordedAtMs: number;
}

export function habitDayType(now: Date): HabitDayType {
  const day = now.getDay();
  return day === 0 || day === 6 ? "weekend" : "weekday";
}

/** Recency half-life in days for the decay score (ADR-0009, own calibration). */
export const HABIT_DECAY_HALF_LIFE_DAYS = 14;
/** A transition is only learned when the previous action happened within this window. */
export const HABIT_SEQUENCE_WINDOW_MS = 30 * 60 * 1000;
/** The next-action boost only applies while the last action is still fresh. */
export const HABIT_SEQUENCE_BOOST_WINDOW_MS = 60 * 60 * 1000;
/** Score bonus per learned transition count when the last action matches (ADR-0009). */
export const HABIT_SEQUENCE_BOOST_WEIGHT = 2;
export const MAX_HABIT_SEQUENCES = 40;

export interface HabitEntryChange {
  readonly bucket: string;
  readonly targetId: string;
  readonly operationKey: string;
  /** The day type the entry carried *after* the call; part of the undo lookup key (ADR-0009). */
  readonly dayType: HabitDayType | null;
  /** `null` means the entry was inserted by the call and should be removed on undo. */
  readonly previousCount: number | null;
  /** The day type the entry carried before the call (upgrading a legacy entry records it here). */
  readonly previousDayType: HabitDayType | null;
  /** The recency metadata the entry carried before the call, so undo restores the decayed weight (Codex #116 re-review). */
  readonly previousLastRecordedAtMs: number | null;
}

/** What one `record` call changed, so undoing the action can take the habit back (#34). */
export interface HabitRecordingReceipt {
  readonly entries: readonly HabitEntryChange[];
  readonly sequences?: readonly HabitSequenceChange[];
  readonly previousLastAction?: HabitLastAction | null;
  readonly recordedLastAction?: HabitLastAction | null;
}

export function partitionHabitReceipt(
  receipt: HabitRecordingReceipt,
  failedDeviceIds: ReadonlySet<string>,
): { succeeded: HabitRecordingReceipt | null; remaining: HabitRecordingReceipt | null } {
  if (failedDeviceIds.size === 0) {
    return { succeeded: receipt, remaining: null };
  }
  const succeededEntries = receipt.entries.filter((entry) => !failedDeviceIds.has(entry.targetId));
  const remainingEntries = receipt.entries.filter((entry) => failedDeviceIds.has(entry.targetId));
  const succeededSequences = (receipt.sequences ?? []).filter((seq) => !failedDeviceIds.has(seq.targetId));
  const remainingSequences = (receipt.sequences ?? []).filter((seq) => failedDeviceIds.has(seq.targetId));

  const lastRemainingEntry = remainingEntries[remainingEntries.length - 1];
  const fallbackLastAction: HabitLastAction | null | undefined = lastRemainingEntry
    ? receipt.recordedLastAction
      ? {
          targetId: lastRemainingEntry.targetId,
          operationKey: lastRemainingEntry.operationKey,
          recordedAtMs: receipt.recordedLastAction.recordedAtMs,
        }
      : undefined
    : receipt.previousLastAction;

  const succeeded: HabitRecordingReceipt | null =
    succeededEntries.length === 0 && succeededSequences.length === 0
      ? null
      : {
          entries: succeededEntries,
          sequences: succeededSequences,
          previousLastAction: fallbackLastAction,
          recordedLastAction: receipt.recordedLastAction,
        };

  const remaining: HabitRecordingReceipt | null =
    remainingEntries.length === 0 && remainingSequences.length === 0
      ? null
      : {
          entries: remainingEntries,
          sequences: remainingSequences,
          previousLastAction: receipt.previousLastAction,
          recordedLastAction: fallbackLastAction ?? receipt.recordedLastAction,
        };

  return { succeeded, remaining };
}

export interface HabitSequenceChange {
  readonly afterKey: string;
  readonly targetId: string;
  readonly operationKey: string;
  /** `null` means the transition was inserted by the call and should be removed on undo. */
  readonly previousCount: number | null;
  /** The recency metadata the transition carried before the call. */
  readonly previousLastRecordedAtMs?: number | null;
  /** True when capacity trimming removed the just-inserted transition; undo must not resurrect it. */
  insertedButTrimmed?: boolean;
}

export const MAX_HABIT_ENTRIES = 60;

/** Encodes an operation into the stable habit key; `null` for relative steps (never learned). */
export function encodeHabitOperation(op: IntentOperation): string | null {
  switch (op.kind) {
    case "power": return op.isOn ? "power:on" : "power:off";
    case "lightEffect": return `effect:${op.effect}`;
    case "brightness": return `brightness:${op.percent}`;
    case "colorTemperature": return `ct:${op.kelvin}`;
    case "hvacMode": return `hvac:${op.mode}`;
    case "targetTemperature": return `temp:${Math.round(op.celsius)}`;
    case "activateScene": return "scene:activate";
    case "fanSpeed": return `fan:${op.speed}`;
    case "oscillation": return op.enabled ? "swing:on" : "swing:off";
    case "brightnessStep":
    case "temperatureStep": return null;
  }
}

export function decodeHabitOperation(key: string): IntentOperation | null {
  const sep = key.indexOf(":");
  if (sep < 0) return null;
  const head = key.slice(0, sep);
  const value = key.slice(sep + 1);
  switch (head) {
    case "power": return value === "on" ? { kind: "power", isOn: true } : value === "off" ? { kind: "power", isOn: false } : null;
    case "effect": return value ? { kind: "lightEffect", effect: value } : null;
    case "brightness": return Number.isFinite(Number(value)) ? { kind: "brightness", percent: Number(value) } : null;
    case "ct": return Number.isFinite(Number(value)) ? { kind: "colorTemperature", kelvin: Number(value) } : null;
    case "hvac": return value ? { kind: "hvacMode", mode: value } : null;
    case "temp": return Number.isFinite(Number(value)) ? { kind: "targetTemperature", celsius: Number(value) } : null;
    case "scene": return value === "activate" ? { kind: "activateScene" } : null;
    case "fan": return value ? { kind: "fanSpeed", speed: value } : null;
    case "swing": return value === "on" ? { kind: "oscillation", enabled: true } : value === "off" ? { kind: "oscillation", enabled: false } : null;
    default: return null;
  }
}

/** Whether the intent's target is online and not already in the wanted state; mirrors macOS `isActionable`. */
export function habitActionable(
  intent: DeviceIntent,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
): boolean {
  const op = intent.operation;
  if (op.kind === "activateScene") return scenes.some((s) => s.id === intent.targetId);
  const dev = devices.find((d) => d.id === intent.targetId && d.isOnline);
  if (!dev || !deviceAcceptsControlWrites(dev)) return false;
  const k = dev.kind;
  switch (op.kind) {
    case "power":
      return deviceCanTogglePower(dev) && isDeviceActiveOn(dev) !== op.isOn;
    case "lightEffect":
      return k.kind === "light" && (!k.isOn || (k.currentEffect ?? "").toLowerCase() !== op.effect.toLowerCase());
    case "brightness":
      return k.kind === "light" && k.brightnessWritable !== false && (!k.isOn || Math.abs((k.brightnessPercent ?? 0) - op.percent) >= 10);
    case "colorTemperature":
      return k.kind === "light" && k.colorWritable !== false && k.colorTempKelvin !== op.kelvin;
    case "hvacMode":
      return k.kind === "climate" && k.availableModes.length > 0 && (!k.isOn || k.hvacMode !== op.mode);
    case "targetTemperature":
      return k.kind === "climate" && k.temperatureWritable !== false && (!k.isOn || Math.abs(k.targetTemperature - op.celsius) >= 0.5);
    case "fanSpeed":
      if (k.kind === "fan") return k.availablePresetModes.length > 0 && (!k.isOn || k.presetMode !== op.speed);
      if (k.kind === "climate") return k.availableFanModes.length > 0 && k.fanMode !== op.speed;
      return false;
    case "oscillation":
      return k.kind === "fan" && k.swingWritable !== false && k.isOscillating !== null && (!k.isOn || k.isOscillating !== op.enabled);
    default:
      return false;
  }
}

/** Devices whose `power` op is a real toggle the assistant can apply (#113). */
function isPowerToggleable(device: SmartDevice): boolean {
  const k = device.kind.kind;
  return (
    deviceCanTogglePower(device) &&
    (k === "light" || k === "climate" || k === "fan" || k === "plug" || k === "camera")
  );
}

export function habitSuggestionTitle(
  intent: DeviceIntent,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
): string | null {
  if (intent.operation.kind === "activateScene") {
    const scene = scenes.find((s) => s.id === intent.targetId);
    return scene ? scene.name : null;
  }
  if (!devices.some((d) => d.id === intent.targetId)) return null;
  return IntentReply.describe([intent], devices, scenes).replace(/^已/, "");
}

/**
 * Zero-delay Top-4 proactive engine (#113), mirroring macOS `UserHabitMemory.topSuggestions`:
 * learned habits first, then deterministic padding — starred-favorite toggles,
 * environment-driven climate trim, the 全屋关灯 builtin, and running-device power-off.
 * Pinned by `Tests/Fixtures/habit_golden.json` on both ends.
 */
export class UserHabitMemory {
  entries: HabitEntry[] = [];
  sequences: HabitSequenceEntry[] = [];
  lastAction: HabitLastAction | null = null;

  constructor(
    entries: readonly HabitEntry[] = [],
    sequences: readonly HabitSequenceEntry[] = [],
    lastAction: HabitLastAction | null = null,
  ) {
    // JSON round-trips can turn the legacy "no day type" into null; normalize to undefined.
    this.entries = entries.map((e) => ({ ...e, dayType: e.dayType ?? undefined }));
    this.sequences = [...sequences];
    this.lastAction = lastAction ? { ...lastAction } : null;
  }

  record(
    intents: readonly DeviceIntent[],
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    now: Date = new Date(),
  ): HabitRecordingReceipt | null {
    if (intents.length === 0) return null;
    const bucket = timeBucketLabel(now.getHours());
    const dayType = habitDayType(now);
    const nowMs = now.getTime();
    const changes: HabitEntryChange[] = [];

    // Encode once: the normalized pattern keys drive entries, sequences, and lastAction.
    const encoded = intents
      .map((intent) => ({ targetId: intent.targetId, operationKey: encodeHabitOperation(intent.operation) }))
      .filter((item): item is { targetId: string; operationKey: string } => item.operationKey !== null);
    if (encoded.length === 0) return null;

    for (const intent of encoded) {
      // Exact (bucket, dayType) match first; a legacy dayType-less entry is upgraded in place.
      let idx = this.entries.findIndex(
        (e) =>
          e.bucket === bucket && e.dayType === dayType
            && e.targetId === intent.targetId && e.operationKey === intent.operationKey,
      );
      let previousDayType: HabitDayType | null = dayType;
      if (idx < 0) {
        idx = this.entries.findIndex(
          (e) =>
            e.bucket === bucket && e.dayType === undefined
              && e.targetId === intent.targetId && e.operationKey === intent.operationKey,
        );
        previousDayType = idx >= 0 ? null : dayType;
      }
      if (idx >= 0) {
        changes.push({
          bucket,
          targetId: intent.targetId,
          operationKey: intent.operationKey,
          dayType,
          previousCount: this.entries[idx]!.count,
          previousDayType: this.entries[idx]!.dayType ?? null,
          previousLastRecordedAtMs: this.entries[idx]!.lastRecordedAtMs ?? null,
        });
        this.entries[idx]!.count += 1;
        this.entries[idx]!.dayType = dayType;
        this.entries[idx]!.lastRecordedAtMs = nowMs;
      } else {
        changes.push({
          bucket,
          targetId: intent.targetId,
          operationKey: intent.operationKey,
          dayType,
          previousCount: null,
          previousDayType: null,
          previousLastRecordedAtMs: null,
        });
        this.entries.push({
          bucket,
          targetId: intent.targetId,
          operationKey: intent.operationKey,
          count: 1,
          dayType,
          lastRecordedAtMs: nowMs,
        });
      }
    }

    this.entries.sort((a, b) => b.count - a.count);
    if (this.entries.length > MAX_HABIT_ENTRIES) this.entries.length = MAX_HABIT_ENTRIES;

    // One-step transition learning: within the window, everything after the last action
    // is a candidate "what the user does next" pattern (ADR-0009).
    const sequenceChanges: HabitSequenceChange[] = [];
    if (this.lastAction && nowMs - this.lastAction.recordedAtMs <= HABIT_SEQUENCE_WINDOW_MS) {
      const afterKey = `${this.lastAction.targetId}|${this.lastAction.operationKey}`;
      for (const intent of encoded) {
        if (intent.targetId === this.lastAction.targetId && intent.operationKey === this.lastAction.operationKey) continue;
        const idx = this.sequences.findIndex(
          (s) => s.afterKey === afterKey && s.targetId === intent.targetId && s.operationKey === intent.operationKey,
        );
        if (idx >= 0) {
          sequenceChanges.push({
            afterKey,
            targetId: intent.targetId,
            operationKey: intent.operationKey,
            previousCount: this.sequences[idx]!.count,
            previousLastRecordedAtMs: this.sequences[idx]!.lastRecordedAtMs ?? null,
          });
          this.sequences[idx]!.count += 1;
          this.sequences[idx]!.lastRecordedAtMs = nowMs;
        } else {
          sequenceChanges.push({
            afterKey,
            targetId: intent.targetId,
            operationKey: intent.operationKey,
            previousCount: null,
            previousLastRecordedAtMs: null,
          });
          this.sequences.push({
            afterKey,
            targetId: intent.targetId,
            operationKey: intent.operationKey,
            count: 1,
            lastRecordedAtMs: nowMs,
          });
        }
      }
      this.sequences.sort((a, b) => b.count - a.count);
      if (this.sequences.length > MAX_HABIT_SEQUENCES) this.sequences.length = MAX_HABIT_SEQUENCES;
      // A just-inserted transition that trimming already dropped never existed for the user;
      // undo must not resurrect it (Codex #116 re-review).
      for (const change of sequenceChanges) {
        if (change.previousCount === null) {
          change.insertedButTrimmed = !this.sequences.some(
            (s) => s.afterKey === change.afterKey && s.targetId === change.targetId && s.operationKey === change.operationKey,
          );
        }
      }
    }

    const previousLastAction = this.lastAction ? { ...this.lastAction } : null;
    const last = encoded[encoded.length - 1];
    const recordedLastAction = last
      ? { targetId: last.targetId, operationKey: last.operationKey, recordedAtMs: nowMs }
      : null;
    if (recordedLastAction) this.lastAction = { ...recordedLastAction };

    if (changes.length === 0 && sequenceChanges.length === 0) return null;
    return { entries: changes, sequences: sequenceChanges, previousLastAction, recordedLastAction };
  }

  /** Undoes the exact changes from one `record` call, leaving earlier habits untouched (#34). */
  unrecord(receipt: HabitRecordingReceipt): void {
    for (const change of [...receipt.entries].reverse()) {
      const idx = this.entries.findIndex(
        (e) =>
          e.bucket === change.bucket && e.dayType === (change.dayType ?? undefined)
            && e.targetId === change.targetId && e.operationKey === change.operationKey,
      );
      if (idx < 0) continue;
      if (change.previousCount !== null) {
        this.entries[idx]!.count = change.previousCount;
        this.entries[idx]!.dayType = change.previousDayType ?? undefined;
        this.entries[idx]!.lastRecordedAtMs = change.previousLastRecordedAtMs ?? undefined;
      } else {
        this.entries.splice(idx, 1);
      }
    }
    this.entries.sort((a, b) => b.count - a.count);

    for (const change of [...(receipt.sequences ?? [])].reverse()) {
      const idx = this.sequences.findIndex(
        (s) => s.afterKey === change.afterKey && s.targetId === change.targetId && s.operationKey === change.operationKey,
      );
      if (idx >= 0) {
        if (change.previousCount !== null) {
          this.sequences[idx]!.count = change.previousCount;
          this.sequences[idx]!.lastRecordedAtMs = change.previousLastRecordedAtMs ?? undefined;
        } else {
          this.sequences.splice(idx, 1);
        }
      } else if (change.insertedButTrimmed !== true) {
        // A capacity-trimmed pre-existing transition still comes back on undo; a transition
        // that was trimmed on insertion never existed for the user (Codex #116 re-review).
        this.sequences.push({
          afterKey: change.afterKey,
          targetId: change.targetId,
          operationKey: change.operationKey,
          count: change.previousCount ?? 1,
          lastRecordedAtMs: change.previousLastRecordedAtMs ?? undefined,
        });
      }
    }
    this.sequences.sort((a, b) => b.count - a.count);

    if (receipt.previousLastAction !== undefined) {
      const canRestoreLastAction =
        receipt.recordedLastAction === undefined ||
        (this.lastAction !== null &&
          receipt.recordedLastAction !== null &&
          this.lastAction.targetId === receipt.recordedLastAction.targetId &&
          this.lastAction.operationKey === receipt.recordedLastAction.operationKey &&
          this.lastAction.recordedAtMs === receipt.recordedLastAction.recordedAtMs);
      if (canRestoreLastAction) {
        this.lastAction = receipt.previousLastAction ? { ...receipt.previousLastAction } : null;
      }
    }
  }

  topSuggestions(options: {
    now?: Date;
    devices: readonly SmartDevice[];
    scenes: readonly HomeScene[];
    limit?: number;
    favoriteIds?: readonly string[];
    environmentReadings?: readonly EnvironmentReading[];
  }): AssistantSuggestion[] {
    const limit = options.limit ?? 4;
    const now = options.now ?? new Date();
    const devices = options.devices;
    const scenes = options.scenes;
    const bucket = timeBucketLabel(now.getHours());
    const todayDayType = habitDayType(now);
    const nowMs = now.getTime();

    // Phase 1: learned habits, most specific context first (WWDC18-211: more specific
    // patterns outrank general ones). Tier 0 matches the current day type, tier 1 is the
    // same bucket with another/legacy day type, and the rest of the memory is the last
    // fallback. Within a tier, recency-decayed frequency plus the next-action boost rank.
    const decayFactor = (entry: HabitEntry): number => {
      if (entry.lastRecordedAtMs === undefined) return 1;
      const days = Math.max(0, (nowMs - entry.lastRecordedAtMs) / 86_400_000);
      return Math.pow(0.5, days / HABIT_DECAY_HALF_LIFE_DAYS);
    };
    const sequenceBonus = (entry: HabitEntry): number => {
      if (!this.lastAction || nowMs - this.lastAction.recordedAtMs > HABIT_SEQUENCE_BOOST_WINDOW_MS) return 0;
      const afterKey = `${this.lastAction.targetId}|${this.lastAction.operationKey}`;
      const hit = this.sequences.find(
        (s) => s.afterKey === afterKey && s.targetId === entry.targetId && s.operationKey === entry.operationKey,
      );
      return hit ? hit.count * HABIT_SEQUENCE_BOOST_WEIGHT : 0;
    };
    const candidates = this.entries
      .filter((e) => e.bucket === bucket)
      .map((entry) => ({
        entry,
        tier: entry.dayType === undefined || entry.dayType === todayDayType ? 0 : 1,
        score: entry.count * decayFactor(entry) + sequenceBonus(entry),
      }));
    for (const entry of this.entries.filter((e) => e.bucket !== bucket)) {
      candidates.push({ entry, tier: 2, score: entry.count * decayFactor(entry) + sequenceBonus(entry) });
    }
    candidates.sort((a, b) => (a.tier !== b.tier ? a.tier - b.tier : b.score - a.score));

    const results: AssistantSuggestion[] = [];
    const seenTargets = new Set<string>();
    const append = (id: string, title: string, intents: readonly DeviceIntent[]): void => {
      if (results.length >= limit) return;
      results.push({ id, title, confidencePercent: null, intents: [...intents] });
    };

    // Phase 1: learned habits for the current context.
    for (const candidate of candidates) {
      const entry = candidate.entry;
      if (seenTargets.has(entry.targetId)) continue;
      const op = decodeHabitOperation(entry.operationKey);
      if (!op) continue;
      const intent: DeviceIntent = { targetId: entry.targetId, operation: op };
      if (!habitActionable(intent, devices, scenes)) continue;
      const title = habitSuggestionTitle(intent, devices, scenes);
      if (title === null) continue;
      seenTargets.add(entry.targetId);
      append(`habit:${entry.bucket}:${entry.targetId}:${entry.operationKey}`, title, [intent]);
      if (results.length >= limit) break;
    }
    if (results.length >= limit) return results;

    const temperatures = (options.environmentReadings ?? [])
      .map((r) => r.temperature)
      .filter((t): t is number => t !== null);
    const hottest = temperatures.length > 0 ? Math.max(...temperatures) : null;
    const coldest = temperatures.length > 0 ? Math.min(...temperatures) : null;

    // Phase 2: starred favorites toggle toward the opposite state. Only devices the
    // assistant can actually power — a fridge or speaker power op is a dead chip (#113).
    for (const id of options.favoriteIds ?? []) {
      if (results.length >= limit) break;
      if (seenTargets.has(id)) continue;
      const dev = devices.find((d) => d.id === id && d.isOnline);
      if (!dev || !isPowerToggleable(dev)) continue;
      const intent: DeviceIntent = { targetId: id, operation: { kind: "power", isOn: !isDeviceActiveOn(dev) } };
      if (!habitActionable(intent, devices, scenes)) continue;
      const title = habitSuggestionTitle(intent, devices, scenes);
      if (title === null) continue;
      seenTargets.add(id);
      append(`fav:${id}:${isDeviceActiveOn(dev) ? "off" : "on"}`, title, [intent]);
    }
    if (results.length >= limit) return results;

    // Phase 3: hot rooms want cooling, cold rooms want heating — one trim on the first
    // running climate that is not already at the target.
    const padClimate = (temperature: number): void => {
      if (results.length >= limit) return;
      for (const dev of devices) {
        const k = dev.kind;
        if (!dev.isOnline || k.kind !== "climate" || !k.isOn || k.hvacMode === "off") continue;
        const intent: DeviceIntent = { targetId: dev.id, operation: { kind: "targetTemperature", celsius: temperature } };
        if (seenTargets.has(dev.id) || !habitActionable(intent, devices, scenes)) continue;
        const title = habitSuggestionTitle(intent, devices, scenes);
        if (title === null) continue;
        seenTargets.add(dev.id);
        append(`env:${dev.id}:temp:${Math.round(temperature)}`, title, [intent]);
        return;
      }
    };
    if (hottest !== null && hottest >= 28) padClimate(26);
    if (coldest !== null && coldest <= 16) padClimate(22);
    if (results.length >= limit) return results;

    // Phase 4: 全屋关灯 builtin once two or more online lights are burning.
    const builtinLightIds = new Set<string>();
    const backfillTargets = new Set<string>();
    const lightsOn = devices.filter(
      (d) => d.isOnline && isDeviceActiveOn(d) && d.kind.kind === "light",
    );
    if (lightsOn.length >= 2 && lightsOn.some((d) => !seenTargets.has(d.id))) {
      append(
        "builtin:lightsOff",
        "全屋关灯",
        lightsOn.map((d) => ({ targetId: d.id, operation: { kind: "power" as const, isOn: false } })),
      );
      for (const d of lightsOn) {
        seenTargets.add(d.id);
        builtinLightIds.add(d.id);
      }
    }
    if (results.length >= limit) return results;

    // Phase 5: running devices the user probably wants off (excluding vacuums heading home
    // and speakers, whose power op is not a real toggle).
    for (const dev of devices) {
      if (results.length >= limit) break;
      if (!dev.isOnline || !isDeviceActiveOn(dev) || seenTargets.has(dev.id) || !isPowerToggleable(dev)) continue;
      const intent: DeviceIntent = { targetId: dev.id, operation: { kind: "power", isOn: false } };
      if (!habitActionable(intent, devices, scenes)) continue;
      const title = habitSuggestionTitle(intent, devices, scenes);
      if (title === null) continue;
      seenTargets.add(dev.id);
      append(`active:${dev.id}:off`, title, [intent]);
    }

    // Phase 6: last-resort backfill for the 全屋关灯 builtin — when nothing else can fill
    // the remaining slots, per-light power-off is still actionable and better than fewer
    // than `limit` candidates (#113).
    if (builtinLightIds.size > 1) {
      for (const dev of devices) {
        if (results.length >= limit) break;
        if (!builtinLightIds.has(dev.id) || backfillTargets.has(dev.id)) continue;
        const intent: DeviceIntent = { targetId: dev.id, operation: { kind: "power", isOn: false } };
        const title = habitSuggestionTitle(intent, devices, scenes);
        if (title === null) continue;
        backfillTargets.add(dev.id);
        append(`active:${dev.id}:off`, title, [intent]);
      }
    }

    // An all-off home still needs useful choices before it has learned any habits (#114).
    for (const dev of devices) {
      if (results.length >= limit) break;
      if (!dev.isOnline || seenTargets.has(dev.id) || !isPowerToggleable(dev)) continue;
      const intent: DeviceIntent = { targetId: dev.id, operation: { kind: "power", isOn: !isDeviceActiveOn(dev) } };
      const title = habitSuggestionTitle(intent, devices, scenes);
      if (!habitActionable(intent, devices, scenes) || title === null) continue;
      seenTargets.add(dev.id);
      append(`available:${dev.id}:${isDeviceActiveOn(dev) ? "off" : "on"}`, title, [intent]);
    }

    return results;
  }
}

export type HabitSharing = "off" | "on";

export type CommandMention =
  | { readonly kind: "none" }
  | { readonly kind: "utterance"; readonly text: string };

export function resolveHabitSharing(stored: unknown): { sharing: HabitSharing; persistOff: boolean } {
  if (stored === true) return { sharing: "on", persistOff: false };
  if (stored === false) return { sharing: "off", persistOff: false };
  return { sharing: "off", persistOff: true };
}

export function shareHabitSentence(input: {
  sharing: HabitSharing;
  memory: {
    readonly entries: readonly HabitEntry[];
    readonly sequences?: readonly HabitSequenceEntry[];
    readonly lastAction?: HabitLastAction | null;
  };
  phrases: readonly { readonly phrase: string; readonly intents: readonly DeviceIntent[] }[];
  devices: readonly SmartDevice[];
  scenes: readonly HomeScene[];
  mention: CommandMention;
  now: Date;
}): string {
  if (input.sharing !== "on") return "";
  if (input.mention.kind !== "utterance") return "";
  const utterance = input.mention.text.trim();
  if (!utterance) return "";
  const ids = mentionedHabitTargets(utterance, input.devices, input.scenes);
  if (ids.size === 0) return "";

  const bucket = timeBucketLabel(input.now.getHours());
  const parts: string[] = [];
  const bucketTitles: string[] = [];
  for (const entry of input.memory.entries) {
    if (entry.bucket !== bucket || !ids.has(entry.targetId)) continue;
    const operation = decodeHabitOperation(entry.operationKey);
    if (!operation) continue;
    const title = habitSuggestionTitle({ targetId: entry.targetId, operation }, input.devices, input.scenes);
    if (!title) continue;
    bucketTitles.push(`${title}(${entry.count}次)`);
    if (bucketTitles.length === 4) break;
  }
  if (bucketTitles.length > 0) parts.push(`${bucket}常做：${bucketTitles.join("、")}`);

  const phraseBits: string[] = [];
  for (const phrase of input.phrases) {
    const titles: string[] = [];
    let qualified = true;
    for (const intent of phrase.intents) {
      if (encodeHabitOperation(intent.operation) === null) continue;
      const title = habitSuggestionTitle(intent, input.devices, input.scenes);
      if (!ids.has(intent.targetId) || !title) {
        qualified = false;
        break;
      }
      titles.push(title);
    }
    if (!qualified || titles.length === 0) continue;
    phraseBits.push(`「${phrase.phrase}」→${titles.join("+")}`);
    if (phraseBits.length === 4) break;
  }
  if (phraseBits.length > 0) parts.push(`个人口头禅：${phraseBits.join("；")}`);

  const last = input.memory.lastAction;
  if (last && input.now.getTime() - last.recordedAtMs <= HABIT_SEQUENCE_BOOST_WINDOW_MS) {
    const afterKey = `${last.targetId}|${last.operationKey}`;
    const next = [...(input.memory.sequences ?? [])]
      .filter((item) => item.afterKey === afterKey)
      .sort((a, b) => b.count - a.count)[0];
    if (next && ids.has(last.targetId) && ids.has(next.targetId)) {
      const previousOperation = decodeHabitOperation(last.operationKey);
      const nextOperation = decodeHabitOperation(next.operationKey);
      if (previousOperation && nextOperation) {
        const previousTitle = habitSuggestionTitle(
          { targetId: last.targetId, operation: previousOperation },
          input.devices,
          input.scenes,
        );
        const nextTitle = habitSuggestionTitle(
          { targetId: next.targetId, operation: nextOperation },
          input.devices,
          input.scenes,
        );
        if (previousTitle && nextTitle) {
          parts.push(`刚做完${previousTitle}后常做：${nextTitle}(${next.count}次)`);
        }
      }
    }
  }
  return parts.join("。");
}

function mentionedHabitTargets(
  utterance: string,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
): Set<string> {
  const idsByText = new Map<string, Set<string>>();
  const absorb = (raw: string, ids: Iterable<string>) => {
    const folded = asciiCasefold(raw);
    if (folded.length < 2) return;
    let bucket = idsByText.get(folded);
    if (!bucket) {
      bucket = new Set();
      idsByText.set(folded, bucket);
    }
    for (const id of ids) bucket.add(id);
  };
  for (const device of devices) absorb(device.name, [device.id]);
  for (const scene of scenes) absorb(scene.name, [scene.id]);
  for (const device of devices) absorb(device.roomName, [device.id]);

  const baseIds = new Map<string, Set<string>>();
  for (const device of devices) {
    const base = roomStrippedBase(device.name, device.roomName);
    if (!base) continue;
    const folded = asciiCasefold(base);
    if (folded.length < 2) continue;
    let bucket = baseIds.get(folded);
    if (!bucket) {
      bucket = new Set();
      baseIds.set(folded, bucket);
    }
    bucket.add(device.id);
  }
  for (const [base, ids] of baseIds) {
    if (ids.size === 1) absorb(base, ids);
  }

  const needles = [...idsByText.entries()].map(([text, ids]) => ({ text, ids }));
  needles.sort((a, b) => {
    if (a.text.length !== b.text.length) return b.text.length - a.text.length;
    const count = Math.min(a.text.length, b.text.length);
    for (let index = 0; index < count; index++) {
      const delta = b.text.charCodeAt(index) - a.text.charCodeAt(index);
      if (delta !== 0) return delta;
    }
    return b.text.length - a.text.length;
  });

  const foldedUtterance = asciiCasefold(utterance);
  const accepted: Array<[number, number]> = [];
  const ids = new Set<string>();
  for (const needle of needles) {
    const hits: number[] = [];
    let from = 0;
    while (from <= foldedUtterance.length - needle.text.length) {
      const at = foldedUtterance.indexOf(needle.text, from);
      if (at < 0) break;
      const end = at + needle.text.length;
      const overlaps = accepted.some(([start, stop]) => at < stop && start < end);
      if (!overlaps && hasAsciiWordBoundary(foldedUtterance, needle.text, at)) hits.push(at);
      from = at + 1;
    }
    if (hits.length === 0) continue;
    for (const hit of hits) accepted.push([hit, hit + needle.text.length]);
    for (const id of needle.ids) ids.add(id);
  }
  return ids;
}

function roomStrippedBase(name: string, roomName: string): string | null {
  if (roomName.length < 1 || !name.startsWith(roomName)) return null;
  const base = name.slice(roomName.length);
  return base.length > 0 ? base : null;
}

function asciiCasefold(text: string): string {
  let out = "";
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    out += code >= 65 && code <= 90 ? String.fromCharCode(code + 32) : text[index]!;
  }
  return out;
}

/** English names match whole words only, so a room named "Den" does not match inside "garden". */
function hasAsciiWordBoundary(haystack: string, needle: string, start: number): boolean {
  const isWordUnit = (code: number) =>
    (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  const end = start + needle.length;
  const leftOk = !isWordUnit(needle.charCodeAt(0)) || start === 0 || !isWordUnit(haystack.charCodeAt(start - 1));
  const rightOk = !isWordUnit(needle.charCodeAt(needle.length - 1)) || end === haystack.length || !isWordUnit(haystack.charCodeAt(end));
  return leftOk && rightOk;
}
