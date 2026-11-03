import type {
  AssistantSuggestion,
  DeviceIntent,
  HomeScene,
  IntentOperation,
  SmartDevice,
} from "../models.js";
import { deviceCategory } from "./deviceCategory.js";
import { IntentReply, IntentValidator } from "./intent.js";
import { PROMPT_NAME_LIMIT, sanitizePromptText } from "./promptText.js";

export function deviceHeadInstruction(alias: string): string {
  return `What action should be taken on device ${alias} for this command? Choose none if unrelated.`;
}

export function proactiveHeadInstruction(alias: string): string {
  return `What proactive adjustment for device ${alias}? Select none if current state is already ideal.`;
}

// MARK: - When AI actions may run by themselves (#21)

function readProbability(raw: unknown): number | null {
  let value: number | null = null;
  if (typeof raw === "number") {
    value = raw;
  } else if (typeof raw === "string" && raw.trim() !== "") {
    const text = raw.trim();
    value = text.endsWith("%") ? Number(text.slice(0, -1).trim()) / 100 : Number(text);
  }
  if (value === null || !Number.isFinite(value)) return null;
  if (value > 1) value /= 100;
  return Math.min(Math.max(value, 0), 1);
}

export interface ChosenAction {
  readonly intent: DeviceIntent;
  readonly confidence: number | null;
  readonly primaryChoice: boolean;
}

export interface ModelDecisionPayload {
  readonly actions: readonly ChosenAction[];
}

export interface ModelDecision {
  readonly intents: readonly DeviceIntent[];
  readonly suggestions: readonly AssistantSuggestion[];
}


type ConfirmationHazard =
  | { readonly kind: "anyChangeExceptOff" }
  | { readonly kind: "anyPower" }
  | { readonly kind: "powerOn" }
  | { readonly kind: "powerOnOrHotter"; readonly setpoint: number };

function confirmationHazard(dev: SmartDevice): ConfirmationHazard | null {
  // `deviceCategory` treats any 暖 in the name as a heater. A water heater whose model
  // is not a heater still follows the hotter-only rule (#167).
  if (
    dev.kind.kind === "climate" &&
    dev.name.includes("热水器") &&
    !dev.model.includes("heater") &&
    !dev.model.includes("blanket")
  ) {
    return { kind: "powerOnOrHotter", setpoint: dev.kind.targetTemperature };
  }
  switch (deviceCategory(dev)) {
    case "heater":
      return { kind: "anyChangeExceptOff" };
    case "plug":
    case "camera":
      return { kind: "anyPower" };
    case "vacuum":
      return { kind: "powerOn" };
    case "climate":
      if (dev.kind.kind !== "climate" || !dev.name.includes("热水器")) return null;
      return { kind: "powerOnOrHotter", setpoint: dev.kind.targetTemperature };
    default:
      return null;
  }
}

function confirmationHazardMatches(hazard: ConfirmationHazard, operation: IntentOperation): boolean {
  switch (hazard.kind) {
    case "anyChangeExceptOff":
      if (operation.kind === "power") return operation.isOn;
      if (operation.kind === "hvacMode") return operation.mode !== "off";
      return true;
    case "anyPower":
      return operation.kind === "power";
    case "powerOn":
      return operation.kind === "power" && operation.isOn;
    case "powerOnOrHotter":
      if (operation.kind === "power") return operation.isOn;
      if (operation.kind === "hvacMode") return operation.mode !== "off";
      if (operation.kind === "targetTemperature") return operation.celsius > hazard.setpoint;
      return false;
  }
}

function confidenceBadge(confidences: readonly (number | null)[]): number | null {
  if (confidences.some((value) => value === null)) return null;
  const present = confidences.filter((value): value is number => value !== null);
  if (present.length === 0) return null;
  return Math.min(...present);
}

function decisionSuggestions(
  waiting: readonly ChosenAction[],
  wide: boolean,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
): AssistantSuggestion[] {
  if (waiting.length === 0) return [];
  if (wide) {
    return ModelActionPolicy.chips(
      waiting.map((action) => action.intent),
      confidenceBadge(waiting.map((action) => action.confidence)),
      "confirm",
      devices,
      scenes,
      true,
    );
  }
  const suggestions: AssistantSuggestion[] = [];
  const primary = waiting.filter((action) => action.primaryChoice);
  if (primary.length > 0) {
    suggestions.push(
      ...ModelActionPolicy.chips(
        primary.map((action) => action.intent),
        confidenceBadge(primary.map((action) => action.confidence)),
        "confirm:primary",
        devices,
        scenes,
        true,
      ),
    );
  }
  const order: string[] = [];
  const byTarget = new Map<string, ChosenAction[]>();
  for (const action of waiting) {
    if (action.primaryChoice) continue;
    if (!byTarget.has(action.intent.targetId)) order.push(action.intent.targetId);
    byTarget.set(action.intent.targetId, [...(byTarget.get(action.intent.targetId) ?? []), action]);
  }
  for (const targetId of order) {
    const group = byTarget.get(targetId) ?? [];
    suggestions.push(
      ...ModelActionPolicy.chips(
        group.map((action) => action.intent),
        confidenceBadge(group.map((action) => action.confidence)),
        "confirm",
        devices,
        scenes,
      ),
    );
  }
  return suggestions;
}

/**
 * The plain-language "不确定时先问我" preference (#180). Only the confidence gate changes; hazard
 * rules still ask. Defaults preserve the shipped behaviour on both platforms.
 */
export interface ConfirmationPolicy {
  readonly askWhenUnsure: boolean;
  readonly threshold: number;
}

/** Mirrors MijiaCore.ModelActionPolicy: guesses below 80% and risky actions wait for a tap. */
export const ModelActionPolicy = {
  AUTO_RUN_THRESHOLD: 0.8,
  SUGGESTION_FLOOR: 0.2,
  maxAutoRunDevices: 3,

  /** probabilities[choice], else confidence, else 0 — a missing number means "not sure". */
  probabilityOf(answer: Record<string, unknown> | undefined, choice: string): number {
    if (!answer) return 0;
    const probs = answer["probabilities"];
    if (probs && typeof probs === "object") {
      const value = readProbability((probs as Record<string, unknown>)[choice]);
      if (value !== null) return value;
    }
    return readProbability(answer["confidence"]) ?? 0;
  },

  decide(
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    payload: ModelDecisionPayload,
    policy: Partial<ConfirmationPolicy> = {}
  ): ModelDecision {
    const askWhenUnsure = policy.askWhenUnsure ?? true;
    const threshold = policy.threshold ?? this.AUTO_RUN_THRESHOLD;
    const unsure = (confidence: number | null): boolean =>
      askWhenUnsure && confidence !== null && confidence < threshold;
    const deviceById = new Map(devices.map((device) => [device.id, device]));
    const seen = new Set<string>();
    const surviving: ChosenAction[] = [];
    for (const action of payload.actions) {
      for (const intent of IntentValidator.sanitize([action.intent], devices, scenes)) {
        const key = JSON.stringify(intent);
        if (seen.has(key)) continue;
        seen.add(key);
        surviving.push({ intent, confidence: action.confidence, primaryChoice: action.primaryChoice });
      }
    }
    const deviceIDs = new Set(surviving.filter((action) => deviceById.has(action.intent.targetId)).map((action) => action.intent.targetId));
    const wide = deviceIDs.size > this.maxAutoRunDevices;
    const judged = surviving.map((action) => {
      if (wide) return { action, confirms: true };
      const device = deviceById.get(action.intent.targetId);
      if (device) {
        const lowConfidence = unsure(action.confidence);
        const confirms =
          device.isSharedHome === true ||
          sanitizePromptText(device.name, PROMPT_NAME_LIMIT) !== device.name ||
          sanitizePromptText(device.roomName, PROMPT_NAME_LIMIT) !== device.roomName ||
          lowConfidence ||
          this.needsConfirmation(action.intent, devices);
        return { action, confirms };
      }
      const scene = scenes.find((item) => item.id === action.intent.targetId);
      if (scene) {
        const lowConfidence = unsure(action.confidence);
        return {
          action,
          confirms: sanitizePromptText(scene.name, PROMPT_NAME_LIMIT) !== scene.name || lowConfidence,
        };
      }
      return {
        action,
        confirms: unsure(action.confidence),
      };
    });
    const waiting = judged.filter((item) => item.confirms).map((item) => item.action);
    return {
      intents: judged.filter((item) => !item.confirms).map((item) => item.action.intent),
      suggestions: decisionSuggestions(waiting, wide, devices, scenes),
    };
  },

  /** A heater change other than off, any plug or camera power change, a vacuum start, or turning a 热水器 on or hotter needs a tap even when the model is sure. */
  needsConfirmation(intent: DeviceIntent, devices: readonly SmartDevice[]): boolean {
    const dev = devices.find((d) => d.id === intent.targetId);
    if (!dev) return false;
    const hazard = confirmationHazard(dev);
    return hazard !== null && confirmationHazardMatches(hazard, intent.operation);
  },

  partition(
    intents: readonly DeviceIntent[],
    devices: readonly SmartDevice[]
  ): { run: DeviceIntent[]; confirm: DeviceIntent[] } {
    const run: DeviceIntent[] = [];
    const confirm: DeviceIntent[] = [];
    for (const intent of intents) {
      (this.needsConfirmation(intent, devices) ? confirm : run).push(intent);
    }
    return { run, confirm };
  },

  /** One chip per device, or one chip for the whole group when `grouped`. */
  chips(
    intents: readonly DeviceIntent[],
    probability: number | null,
    idPrefix: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    grouped = false
  ): AssistantSuggestion[] {
    if (intents.length === 0) return [];
    const percent = probability !== null && probability > 0 ? Math.max(20, Math.min(99, Math.round(probability * 100))) : null;
    const title = (group: readonly DeviceIntent[]) => IntentReply.describe(group, devices, scenes).replace(/^已/, "");
    if (grouped) {
      return [{ id: idPrefix, title: title(intents), confidencePercent: percent, intents: [...intents] }];
    }
    const byTarget = new Map<string, DeviceIntent[]>();
    for (const intent of intents) {
      byTarget.set(intent.targetId, [...(byTarget.get(intent.targetId) ?? []), intent]);
    }
    return [...byTarget.entries()].map(([targetId, group]) => ({
      id: `${idPrefix}:${targetId}`,
      title: title(group),
      confidencePercent: percent,
      intents: group,
    }));
  },

  confirmationReply(ranReply: string | null): string {
    if (!ranReply) return "没把握直接执行，点下面的建议再执行";
    return `${ranReply}；下面的建议要点一下才执行`;
  },
};
