import type {
  DeviceCommand,
  DeviceIntent,
  HomeScene,
  IntentOperation,
  IntentPlan,
  SmartDevice,
} from "../models.js";
import { deviceAcceptsControlWrites, isDeviceActiveOn } from "../models.js";
import { deviceCategory, isAssistantControllable, type IntentCategory } from "./deviceCategory.js";

const CONSUMED_MARKER = "\u001f";

// MARK: - Spoken Delay & Undo Phrases

export interface ParsedDelay {
  readonly seconds: number;
  readonly remainder: string;
}

const CN_DIGITS: Readonly<Record<string, number>> = {
  一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5, 六: 6, 七: 7, 八: 8, 九: 9, 十: 10,
  十五: 15, 二十: 20, 三十: 30, 四十五: 45,
};

function parseCnOrArabicNumber(s: string): number | null {
  const n = Number(s);
  if (Number.isFinite(n) && n > 0) return n;
  return CN_DIGITS[s] ?? null;
}

const EN_CANCEL_PHRASES = [
  "cancel timer", "cancel timers", "cancel all timers",
  "clear timer", "clear timers", "clear all timers",
  "stop timer", "stop timers", "stop all timers",
];

function buildDelay(val: number | null, unitMultiplier: number, remainder: string): ParsedDelay | null {
  const rem = remainder.trim();
  if (val === null || !Number.isFinite(val) || val <= 0 || !rem) return null;
  const seconds = Math.round(val * unitMultiplier);
  if (seconds <= 0 || seconds > 86400) return null;
  return { seconds, remainder: rem };
}

function englishUnitMultiplier(unitRaw: string): number {
  const u = unitRaw.toLowerCase();
  return u.startsWith("h") ? 3600 : u.startsWith("m") ? 60 : 1;
}

function chineseUnitMultiplier(unitRaw: string): number {
  return unitRaw.startsWith("小") || unitRaw.startsWith("钟") ? 3600 : unitRaw.startsWith("分") ? 60 : 1;
}

export const DelayPhrase = {
  isCancel(utterance: string): boolean {
    const lower = utterance.toLowerCase().trim();
    if (EN_CANCEL_PHRASES.some((p) => lower.includes(p))) return true;
    const clean = utterance.replace(/[，。！？、\s]/g, "");
    return clean === "取消定时" || clean === "取消倒计时" || clean === "取消所有定时" || clean === "清除定时";
  },

  extract(utterance: string): ParsedDelay | null {
    const trimmed = utterance.trim();
    const enLead = /^(?:in|after)\s+(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b[,\s]*(.+)$/i.exec(trimmed);
    if (enLead) {
      return buildDelay(Number(enLead[1]), englishUnitMultiplier(enLead[2] ?? ""), enLead[3] ?? "");
    }
    const enTrail = /^(.+?)[,\s]+(?:in|after)\s+(\d+(?:\.\d+)?)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\s*$/i.exec(trimmed);
    if (enTrail) {
      return buildDelay(Number(enTrail[2]), englishUnitMultiplier(enTrail[3] ?? ""), enTrail[1] ?? "");
    }
    if (/^半小时(?:以)?后(.+)$/.test(trimmed)) {
      const m = /^半小时(?:以)?后(.+)$/.exec(trimmed);
      return buildDelay(1800, 1, m?.[1] ?? "");
    }
    const regex = /^(?:过|等)?([0-9]+|[一二两三四五六七八九十]+)\s*(秒钟?|分钟?|小时|钟头)(?:以)?后?[，,\s]*(.+)$/;
    const front = regex.exec(trimmed);
    if (front) {
      return buildDelay(parseCnOrArabicNumber(front[1] ?? ""), chineseUnitMultiplier(front[2] ?? ""), front[3] ?? "");
    }
    const backRegex = /^(.+?)[，,\s]*(?:过|等)?([0-9]+|[一二两三四五六七八九十]+)\s*(秒钟?|分钟?|小时|钟头)(?:以)?后$/;
    const back = backRegex.exec(trimmed);
    if (back) {
      return buildDelay(parseCnOrArabicNumber(back[2] ?? ""), chineseUnitMultiplier(back[3] ?? ""), back[1] ?? "");
    }
    return null;
  },

  formatDelay(seconds: number): string {
    if (seconds % 3600 === 0) return `${seconds / 3600} 小时`;
    if (seconds % 60 === 0) return `${seconds / 60} 分钟`;
    return `${seconds} 秒`;
  },
};

const EN_UNDO_SET = new Set(["undo", "revert", "undo that", "revert that", "cancel that"]);

export const UndoPhrase = {
  isUndo(utterance: string): boolean {
    const lower = utterance.toLowerCase().replace(/^[，。！？,.!?\s]+|[，。！？,.!?\s]+$/g, "");
    if (EN_UNDO_SET.has(lower)) return true;
    const clean = utterance.replace(/[，。！？、\s]/g, "");
    return ["撤销", "撤回", "刚才那个撤销", "撤销刚才的操作", "恢复刚才的状态"].includes(clean);
  },
};

// MARK: - Intent Validation & Normalization

export const IntentValidator = {
  normalize(op: IntentOperation, device: SmartDevice): IntentOperation | null {
    const k = device.kind;
    switch (op.kind) {
      case "power": {
        if (k.kind === "plug") {
          if (k.powerWritable === false) return null;
          if (k.switchEntityId.startsWith("button.") && !op.isOn) {
            return null;
          }
          return op;
        }
        if (k.kind === "light" || k.kind === "climate" || k.kind === "fan" || k.kind === "camera") {
          return k.powerWritable === false ? null : op;
        }
        if (k.kind === "vacuum") return k.actionsWritable === false ? null : op;
        return null;
      }
      case "brightness": {
        if (k.kind !== "light" || k.brightnessWritable === false) return null;
        return { kind: "brightness", percent: Math.max(1, Math.min(100, Math.round(op.percent))) };
      }
      case "brightnessStep": {
        if (k.kind !== "light" || k.brightnessWritable === false) return null;
        const base = k.isOn ? (k.brightnessPercent ?? 50) : 0;
        return { kind: "brightness", percent: Math.max(1, Math.min(100, Math.round(base + op.delta))) };
      }
      case "colorTemperature": {
        if (k.kind !== "light" || k.colorWritable === false) return null;
        return {
          kind: "colorTemperature",
          kelvin: Math.max(k.minKelvin, Math.min(k.maxKelvin, Math.round(op.kelvin))),
        };
      }
      case "lightEffect": {
        if (k.kind !== "light") return null;
        const matched = k.availableEffects.find((e) => e.toLowerCase() === op.effect.toLowerCase());
        return matched ? { kind: "lightEffect", effect: matched } : null;
      }
      case "hvacMode": {
        if (k.kind === "climate") {
          if (k.availableModes.length === 0) return null;
          const matched = k.availableModes.find((m) => m.toLowerCase() === op.mode.toLowerCase());
          return matched ? { kind: "hvacMode", mode: matched } : null;
        }
        // 「自动模式」 parses as hvacMode(auto); on a fan that means its Auto preset (#98).
        if (k.kind === "fan" && op.mode.toLowerCase() === "auto") {
          const m = k.availablePresetModes.find((p) => /auto|自动|smart|natural/i.test(p));
          return m ? { kind: "fanSpeed", speed: m } : null;
        }
        return null;
      }
      case "targetTemperature": {
        if (k.kind !== "climate" || k.temperatureWritable === false) return null;
        const clamped = Math.max(k.minTemp, Math.min(k.maxTemp, op.celsius));
        return { kind: "targetTemperature", celsius: clamped };
      }
      case "temperatureStep": {
        if (k.kind !== "climate" || k.temperatureWritable === false) return null;
        const next = Math.max(k.minTemp, Math.min(k.maxTemp, k.targetTemperature + op.delta));
        return { kind: "targetTemperature", celsius: next };
      }
      case "fanSpeed": {
        const list =
          k.kind === "fan"
            ? k.availablePresetModes
            : k.kind === "climate"
              ? k.availableFanModes
              : null;
        if (!list || list.length === 0) return null;
        const exact = list.find((m) => m.toLowerCase() === op.speed.toLowerCase());
        if (exact) return { kind: "fanSpeed", speed: exact };
        const s = op.speed.toLowerCase();
        if (s === "auto" || s === "自动") {
          const autoMatch = list.find((m) => /auto|自动|smart|natural/i.test(m));
          return autoMatch ? { kind: "fanSpeed", speed: autoMatch } : null;
        }
        if (s === "sleep" || s === "睡眠" || s === "silent" || s === "静音") {
          const sleepMatch = list.find((m) => /sleep|睡眠|silent|静音/i.test(m));
          return sleepMatch ? { kind: "fanSpeed", speed: sleepMatch } : null;
        }
        if (s === "favorite" || s === "favourite" || s === "最爱" || s === "manual" || s === "手动") {
          const favMatch = list.find((m) => /favorite|favourite|最爱|manual|手动/i.test(m));
          return favMatch ? { kind: "fanSpeed", speed: favMatch } : null;
        }
        const ranked = list.filter((m) => !/auto|自动|sleep|睡眠|silent|静音|favorite|favourite|最爱/i.test(m));
        const pool = ranked.length > 0 ? ranked : list;
        if (s === "low" || s === "低" || s === "1") {
          const first = pool[0];
          return first ? { kind: "fanSpeed", speed: first } : null;
        }
        if (s === "medium" || s === "中" || s === "2") {
          const mid = pool[Math.floor((pool.length - 1) / 2)];
          return mid ? { kind: "fanSpeed", speed: mid } : null;
        }
        if (s === "high" || s === "高" || s === "3") {
          const last = pool[pool.length - 1];
          return last ? { kind: "fanSpeed", speed: last } : null;
        }
        return null;
      }
      case "oscillation": {
        if (k.kind !== "fan" || k.swingWritable === false || k.isOscillating === null) return null;
        return op;
      }
      case "activateScene":
        return null;
      default: {
        const _exhaustive: never = op;
        return _exhaustive;
      }
    }
  },

  sanitize(
    raw: readonly DeviceIntent[],
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): DeviceIntent[] {
    const devMap = new Map(devices.map((d) => [d.id, d]));
    const sceneSet = new Set(scenes.map((s) => s.id));
    const out: DeviceIntent[] = [];
    for (const intent of raw) {
      if (intent.operation.kind === "activateScene") {
        if (sceneSet.has(intent.targetId)) out.push(intent);
        continue;
      }
      const dev = devMap.get(intent.targetId);
      if (!dev) continue;
      const norm = this.normalize(intent.operation, dev);
      if (norm) {
        out.push({ targetId: dev.id, operation: norm });
      }
    }
    return out;
  },

  commandsForIntent(intent: DeviceIntent, device: SmartDevice): DeviceCommand[] {
    const k = device.kind;
    const op = intent.operation;
    switch (op.kind) {
      case "power": {
        if (k.kind === "light")
          return k.powerWritable === false ? [] : [{ kind: "setLightPower", entityId: k.entityId, isOn: op.isOn }];
        if (k.kind === "climate")
          return k.powerWritable === false
            ? []
            : [{ kind: "setClimatePower", entityId: k.entityId, isOn: op.isOn, resumeMode: "cool" }];
        if (k.kind === "fan")
          return k.powerWritable === false ? [] : [{ kind: "setFanPower", entityId: k.entityId, isOn: op.isOn }];
        if (k.kind === "plug") {
          if (k.powerWritable === false) return [];
          if (k.switchEntityId.startsWith("button.")) {
            return op.isOn ? [{ kind: "setSwitch", entityId: k.switchEntityId, isOn: true }] : [];
          }
          return [{ kind: "setSwitch", entityId: k.switchEntityId, isOn: op.isOn }];
        }
        if (k.kind === "camera")
          return k.powerWritable === false ? [] : [{ kind: "setSwitch", entityId: k.entityId, isOn: op.isOn }];
        if (k.kind === "vacuum")
          return k.actionsWritable === false
            ? []
            : [{ kind: "vacuumAction", entityId: k.entityId, action: op.isOn ? "start" : "returnToBase" }];
        return [];
      }
      case "brightness":
        return k.kind === "light" && k.brightnessWritable !== false
          ? [{ kind: "setLightBrightness", entityId: k.entityId, percent: op.percent }]
          : [];
      case "colorTemperature":
        return k.kind === "light" && k.colorWritable !== false
          ? [{ kind: "setLightColorTemp", entityId: k.entityId, kelvin: op.kelvin }]
          : [];
      case "lightEffect":
        return k.kind === "light" ? [{ kind: "setLightEffect", entityId: k.entityId, effect: op.effect }] : [];
      case "hvacMode":
        return k.kind === "climate" && k.availableModes.length > 0
          ? [{ kind: "setClimateMode", entityId: k.entityId, hvacMode: op.mode }]
          : [];
      case "targetTemperature":
        return k.kind === "climate" && k.temperatureWritable !== false
          ? [{ kind: "setClimateTemperature", entityId: k.entityId, temperature: op.celsius }]
          : [];
      case "fanSpeed":
        if (k.kind === "fan" && k.availablePresetModes.length > 0)
          return [{ kind: "setFanPresetMode", entityId: k.entityId, presetMode: op.speed }];
        if (k.kind === "climate" && k.availableFanModes.length > 0)
          return [{ kind: "setClimateFanMode", entityId: k.entityId, fanMode: op.speed }];
        return [];
      case "oscillation":
        return k.kind === "fan" && k.swingWritable !== false
          ? [{ kind: "setFanOscillating", entityId: k.entityId, oscillating: op.enabled }]
          : [];
      case "brightnessStep":
      case "temperatureStep":
      case "activateScene":
        return [];
      default: {
        const _exhaustive: never = op;
        return _exhaustive;
      }
    }
  },
};

export const IntentReply = {
  fanSpeedLabel(speed: string): string {
    const m = /^level\s*([0-9]+)$/i.exec(speed.trim());
    if (m?.[1]) return `${m[1]} 档`;
    const map: Record<string, string> = {
      low: "低档",
      medium: "中档",
      high: "高档",
      auto: "自动",
      sleep: "睡眠",
      silent: "静音",
      favorite: "最爱",
      favourite: "最爱",
      manual: "手动",
    };
    return map[speed.toLowerCase()] ?? speed;
  },

  describe(
    intents: readonly DeviceIntent[],
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): string {
    if (intents.length === 0) return "未找到可执行的设备操作";
    const devMap = new Map(devices.map((d) => [d.id, d.name]));
    const sceneMap = new Map(scenes.map((s) => [s.id, s.name]));

    const firstOp = intents[0]?.operation;
    if (
      firstOp &&
      intents.every((i) => JSON.stringify(i.operation) === JSON.stringify(firstOp))
    ) {
      const names = intents
        .map((i) => devMap.get(i.targetId) ?? sceneMap.get(i.targetId) ?? i.targetId)
        .join("、");
      return this.describeOp(firstOp, names);
    }

    const parts = intents.map((i) => {
      const name = devMap.get(i.targetId) ?? sceneMap.get(i.targetId) ?? i.targetId;
      return this.describeOp(i.operation, name).replace(/^已/, "");
    });
    return `已${parts.join("，")}`;
  },

  describeOp(op: IntentOperation, targetNames: string): string {
    switch (op.kind) {
      case "power":
        return `已${op.isOn ? "打开" : "关闭"}${targetNames}`;
      case "brightness":
        return `已${targetNames}亮度调至 ${op.percent}%`;
      case "colorTemperature":
        return `已${targetNames}色温调至 ${op.kelvin}K`;
      case "lightEffect": {
        const label =
          op.effect.toLowerCase() === "night"
            ? "月光模式"
            : op.effect.toLowerCase() === "day"
              ? "日光模式"
              : op.effect;
        return `已${targetNames}切换为${label}`;
      }
      case "hvacMode": {
        const map: Record<string, string> = {
          cool: "制冷",
          heat: "制热",
          dry: "除湿",
          fan_only: "送风",
          auto: "自动",
          off: "关闭",
        };
        return `已${targetNames}设为${map[op.mode] ?? op.mode}模式`;
      }
      case "targetTemperature":
        return `已${targetNames}设为 ${op.celsius}°C`;
      case "fanSpeed":
        return `已${targetNames}风速调为 ${this.fanSpeedLabel(op.speed)}`;
      case "oscillation":
        return `已${targetNames}${op.enabled ? "开启摇头" : "停止摇头"}`;
      case "activateScene":
        return `已执行${targetNames}`;
      case "brightnessStep":
      case "temperatureStep":
        return `已调节${targetNames}`;
      default: {
        const _exhaustive: never = op;
        return _exhaustive;
      }
    }
  },
};

// MARK: - 0ms Local Intent Parser


function isRelativeOp(op: IntentOperation): boolean {
  return op.kind === "brightnessStep" || op.kind === "temperatureStep";
}

function impliedCategories(ops: readonly IntentOperation[]): Set<IntentCategory> | null {
  for (const op of ops) {
    switch (op.kind) {
      case "brightness":
      case "brightnessStep":
      case "colorTemperature":
      case "lightEffect":
        return new Set(["light"]);
      case "hvacMode":
      case "targetTemperature":
      case "temperatureStep":
        return new Set(["climate", "heater"]);
      case "fanSpeed":
        return new Set(["fan", "airPurifier", "climate"]);
      case "oscillation":
        return new Set(["fan"]);
      case "power":
      case "activateScene":
        continue;
    }
  }
  return null;
}

function dispatchRank(op: IntentOperation): number {
  switch (op.kind) {
    case "power": return 0;
    case "hvacMode": return 1;
    case "targetTemperature":
    case "temperatureStep": return 2;
    case "lightEffect": return 3;
    case "brightness":
    case "brightnessStep": return 4;
    case "colorTemperature": return 5;
    case "activateScene": return 6;
    case "fanSpeed": return 7;
    case "oscillation": return 8;
  }
}

function reconcileOps(ops: readonly IntentOperation[]): IntentOperation[] | null {
  if (ops.length === 0) return null;
  const byRank = new Map<number, IntentOperation>();
  for (const op of ops) {
    const rank = dispatchRank(op);
    const existing = byRank.get(rank);
    if (existing && JSON.stringify(existing) !== JSON.stringify(op)) return null;
    byRank.set(rank, op);
  }
  const p = byRank.get(0);
  if (p?.kind === "power" && !p.isOn && byRank.size > 1) return null;
  if (p?.kind === "power" && p.isOn && (byRank.has(1) || byRank.has(3) || byRank.has(4) || byRank.has(5))) {
    byRank.delete(0);
  }
  return Array.from(byRank.keys())
    .sort((a, b) => a - b)
    .map((k) => byRank.get(k)!);
}

function buildPlanFromCandidates(
  candidates: readonly SmartDevice[],
  mustAcceptIds: ReadonlySet<string>,
  ops: readonly IntentOperation[],
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[]
): IntentPlan | null {
  const intents: DeviceIntent[] = [];
  for (const dev of candidates) {
    const normOps = ops
      .map((o) => IntentValidator.normalize(o, dev))
      .filter((o): o is IntentOperation => o !== null);
    if (normOps.length !== ops.length) {
      if (mustAcceptIds.has(dev.id)) return null;
      continue;
    }
    for (const no of normOps) {
      intents.push({ targetId: dev.id, operation: no });
    }
  }
  if (intents.length === 0) return null;
  return {
    intents,
    reply: IntentReply.describe(intents, devices, scenes),
    source: "local",
    suggestions: [],
  };
}

const EN_ROOM_ALIASES: Readonly<Record<string, readonly string[]>> = {
  "master bedroom": ["主卧", "卧室", "master bedroom", "master"],
  "second bedroom": ["次卧", "小卧室", "second bedroom", "guest"],
  "guest room": ["次卧", "小卧室", "guest room"],
  "living room": ["客厅", "living room", "living"],
  "dining room": ["餐厅", "dining room", "dining"],
  "study room": ["书房", "study"],
  study: ["书房", "study"],
  bedroom: ["卧室", "主卧", "bedroom"],
  kitchen: ["厨房", "kitchen"],
  balcony: ["阳台", "balcony"],
  bathroom: ["卫生间", "浴室", "bathroom", "bath"],
  entryway: ["玄关", "entryway", "entry"],
};

const EN_SCOPE_WORDS = [
  "whole home", "entire home", "whole house", "everywhere", "everything", "all", "every",
];

const EN_CATEGORY_WORDS: ReadonlyArray<readonly [string, IntentCategory]> = [
  ["air conditioner", "climate"], ["air conditioning", "climate"],
  ["ceiling lights", "light"], ["ceiling light", "light"],
  ["bedside lamp", "light"], ["desk lamp", "light"], ["table lamp", "light"],
  ["screen bar", "light"], ["light strip", "light"],
  ["robot vacuum", "vacuum"], ["smart plug", "plug"], ["space heater", "heater"],
  ["standing fan", "fan"], ["air purifiers", "airPurifier"], ["air purifier", "airPurifier"],
  ["purifiers", "airPurifier"], ["purifier", "airPurifier"],
  ["fresh air", "airPurifier"], ["humidifiers", "airPurifier"], ["humidifier", "airPurifier"],
  ["lights", "light"], ["light", "light"], ["lamps", "light"], ["lamp", "light"],
  ["climate", "climate"], ["ac", "climate"],
  ["heater", "heater"], ["dehumidifier", "dehumidifier"], ["diffuser", "diffuser"],
  ["fans", "fan"], ["fan", "fan"],
  ["plugs", "plug"], ["plug", "plug"], ["socket", "plug"], ["outlet", "plug"],
  ["vacuum", "vacuum"],
  ["television", "tv"], ["tv", "tv"],
  ["cameras", "camera"], ["camera", "camera"],
];

const EN_FILLERS = [
  "please", "can", "could", "would", "you", "help", "me",
  "the", "my", "a", "an", "in", "at", "to", "by", "for", "into", "of",
  "set", "change", "switch", "adjust", "make", "it", "bit", "little",
  "mode", "room", "temperature", "temp", "brightness", "level", "speed",
].sort((a, b) => b.length - a.length);

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function consumeEnglishPhrase(phrase: string, state: { rest: string }): boolean {
  if (!phrase) return false;
  const escaped = escapeRegex(phrase);
  const isAscii = /^[\x00-\x7f]+$/.test(phrase);
  const pattern = isAscii ? `(?<![a-z0-9])${escaped}(?![a-z0-9])` : escaped;
  const regex = new RegExp(pattern, "g");
  if (!regex.test(state.rest)) return false;
  state.rest = state.rest.replace(new RegExp(pattern, "g"), ` ${CONSUMED_MARKER} `);
  return true;
}

function extractEnglishNumericOps(state: { rest: string }): IntentOperation[] {
  const ops: IntentOperation[] = [];
  const stepRegex = /(?<![a-z])(increase|raise|up|decrease|lower|down)(?:\s+by)?\s+(\d{1,2})\s*(?:degrees?|deg|℃|°c|°)(?![a-z])/g;
  let stepMatched = false;
  for (const m of state.rest.matchAll(stepRegex)) {
    const dir = m[1] ?? "";
    const amount = Number(m[2]);
    if (Number.isFinite(amount)) {
      const sign = dir === "increase" || dir === "raise" || dir === "up" ? 1 : -1;
      ops.push({ kind: "temperatureStep", delta: sign * amount });
      stepMatched = true;
    }
  }
  if (stepMatched) {
    state.rest = state.rest.replace(stepRegex, ` ${CONSUMED_MARKER} `);
  }

  const trailingStepRegex = /(?<![a-z0-9])(\d{1,2})\s*(?:degrees?|deg|℃|°c|°)\s+(warmer|hotter|higher|cooler|colder|lower)(?![a-z])/g;
  let trailingStepMatched = false;
  for (const m of state.rest.matchAll(trailingStepRegex)) {
    const amount = Number(m[1]);
    const dir = m[2] ?? "";
    if (Number.isFinite(amount)) {
      const sign = dir === "warmer" || dir === "hotter" || dir === "higher" ? 1 : -1;
      ops.push({ kind: "temperatureStep", delta: sign * amount });
      trailingStepMatched = true;
    }
  }
  if (trailingStepMatched) {
    state.rest = state.rest.replace(trailingStepRegex, ` ${CONSUMED_MARKER} `);
  }

  const numericPatterns: ReadonlyArray<readonly [RegExp, (val: number) => IntentOperation]> = [
    [/(?<![a-z0-9])(\d{4})\s*k(?![a-z0-9])/g, (v) => ({ kind: "colorTemperature", kelvin: Math.round(v) })],
    [/(?<![a-z0-9])(\d{1,3})\s*(?:%|percent)(?![a-z0-9])/g, (v) => ({ kind: "brightness", percent: Math.round(v) })],
    [/(?<![a-z0-9])(\d{1,2}(?:\.\d)?)\s*(?:degrees?\s*celsius|degrees?|deg|℃|°c|°)(?![a-z0-9])/g, (v) => ({ kind: "targetTemperature", celsius: v })],
  ];
  for (const [regex, make] of numericPatterns) {
    let matched = false;
    for (const m of state.rest.matchAll(regex)) {
      const val = Number(m[1]);
      if (Number.isFinite(val)) {
        ops.push(make(val));
        matched = true;
      }
    }
    if (matched) {
      state.rest = state.rest.replace(regex, ` ${CONSUMED_MARKER} `);
    }
  }
  return ops;
}

export const LocalIntentParser = {
  parse(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): IntentPlan | null {
    const clean = utterance.replace(/[，。！？、\s]/g, "");
    if (!clean) return null;

    if (!/[\u4e00-\u9fff]/.test(utterance) && /[a-zA-Z]/.test(utterance)) {
      return this.parseEnglish(utterance, devices, scenes);
    }

    for (const scene of scenes) {
      if (clean === scene.name || clean === `执行${scene.name}` || clean === `打开${scene.name}` || clean === `开启${scene.name}`) {
        const intents: DeviceIntent[] = [{ targetId: scene.id, operation: { kind: "activateScene" } }];
        return {
          intents,
          reply: IntentReply.describe(intents, devices, scenes),
          source: "local",
          suggestions: [],
        };
      }
    }

    let ops: IntentOperation[] = [];
    if (clean.includes("月光模式") || clean.includes("夜灯模式") || clean.includes("月光")) {
      ops.push({ kind: "lightEffect", effect: "Night" });
    } else if (clean.includes("日光模式") || clean.includes("日光")) {
      ops.push({ kind: "lightEffect", effect: "Day" });
    }

    const ctMatch = /(\d{4})[kK]/.exec(clean);
    if (ctMatch?.[1]) {
      ops.push({ kind: "colorTemperature", kelvin: Number(ctMatch[1]) });
    } else if (clean.includes("暖光") || clean.includes("暖色") || clean.includes("黄光")) {
      ops.push({ kind: "colorTemperature", kelvin: 2700 });
    } else if (clean.includes("自然光")) {
      ops.push({ kind: "colorTemperature", kelvin: 4000 });
    } else if (clean.includes("白光") || clean.includes("冷光")) {
      ops.push({ kind: "colorTemperature", kelvin: 6500 });
    }

    if (clean.includes("再暗一点") || clean.includes("暗一点") || clean.includes("调暗一点")) {
      ops.push({ kind: "brightnessStep", delta: -20 });
    } else if (clean.includes("再亮一点") || clean.includes("亮一点") || clean.includes("调亮一点")) {
      ops.push({ kind: "brightnessStep", delta: 20 });
    } else {
      const briMatch = /(?:亮度)?(?:调到|设为)?([0-9]{1,3})%/.exec(clean);
      if (briMatch?.[1]) {
        ops.push({ kind: "brightness", percent: Number(briMatch[1]) });
      } else if (clean.includes("调暗")) {
        ops.push({ kind: "brightness", percent: 20 });
      } else if (clean.includes("调亮") || clean.includes("最亮")) {
        ops.push({ kind: "brightness", percent: 100 });
      }
    }

    if (clean.includes("调高两度") || clean.includes("升高两度")) {
      ops.push({ kind: "temperatureStep", delta: 2 });
    } else if (clean.includes("调低两度") || clean.includes("降低两度")) {
      ops.push({ kind: "temperatureStep", delta: -2 });
    } else if (clean.includes("温度高一点") || clean.includes("调高一点") || clean.includes("热一点")) {
      ops.push({ kind: "temperatureStep", delta: 1 });
    } else if (clean.includes("温度低一点") || clean.includes("调低一点") || clean.includes("凉快一点")) {
      ops.push({ kind: "temperatureStep", delta: -1 });
    } else {
      const tempMatch = /(?:调到|设为)?([1-3][0-9])(?:度|°C|℃)/i.exec(clean);
      if (tempMatch?.[1]) {
        ops.push({ kind: "targetTemperature", celsius: Number(tempMatch[1]) });
      }
    }

    if (clean.includes("制冷")) ops.push({ kind: "hvacMode", mode: "cool" });
    else if (clean.includes("制热")) ops.push({ kind: "hvacMode", mode: "heat" });
    else if (clean.includes("除湿") && !clean.includes("除湿机")) ops.push({ kind: "hvacMode", mode: "dry" });
    else if (clean.includes("送风")) ops.push({ kind: "hvacMode", mode: "fan_only" });

    if (clean.includes("停止摇头") || clean.includes("关闭摇头") || clean.includes("不摇头")) {
      ops.push({ kind: "oscillation", enabled: false });
    } else if (clean.includes("摇头") || clean.includes("摆风")) {
      ops.push({ kind: "oscillation", enabled: true });
    }

    if (clean.includes("高档") || clean.includes("三档") || clean.includes("风速调高") || clean.includes("最大风")) {
      ops.push({ kind: "fanSpeed", speed: "high" });
    } else if (clean.includes("中档") || clean.includes("二档")) {
      ops.push({ kind: "fanSpeed", speed: "medium" });
    } else if (clean.includes("低档") || clean.includes("一档") || clean.includes("风速调低") || clean.includes("最小风")) {
      ops.push({ kind: "fanSpeed", speed: "low" });
    } else if (clean.includes("自动模式")) {
      ops.push({ kind: "fanSpeed", speed: "auto" });
    } else if (clean.includes("自动风") || clean.includes("自动档")) {
      ops.push({ kind: "fanSpeed", speed: "auto" });
    } else if (clean.includes("睡眠模式") || clean.includes("睡眠档") || clean.includes("静音模式") || clean.includes("静音档")) {
      ops.push({ kind: "fanSpeed", speed: "sleep" });
    } else if (clean.includes("最爱模式") || clean.includes("最爱档") || clean.includes("最爱")) {
      ops.push({ kind: "fanSpeed", speed: "favorite" });
    }

    const hasOpen = clean.includes("打开") || clean.includes("开启") || clean.startsWith("开");
    const hasClose = clean.includes("关闭") || clean.includes("关掉") || clean.startsWith("关");
    if (hasOpen && hasClose) return null;
    if (ops.length === 0) {
      if (hasOpen) ops = [{ kind: "power", isOn: true }];
      else if (hasClose) ops = [{ kind: "power", isOn: false }];
      else if (/[a-zA-Z]/.test(utterance)) return this.parseEnglish(utterance, devices, scenes);
      else return null;
    }

    const explicitDevs = devices.filter((d) => clean.includes(d.name));
    const hasAllScope = clean.includes("所有") || clean.includes("全部") || clean.includes("全屋");
    const onlyActive = ops.every(isRelativeOp);

    let candidates: SmartDevice[] = [];
    if (explicitDevs.length > 0) {
      candidates = explicitDevs;
    } else {
      const roomNames = Array.from(new Set(devices.map((d) => d.roomName)));
      const matchedRooms = roomNames.filter(
        (r) => clean.includes(r) || (r === "主卧" && clean.includes("卧室"))
      );
      const implied = impliedCategories(ops);
      const wanted = new Set<IntentCategory>();
      if (clean.includes("灯")) wanted.add("light");
      if (clean.includes("空调")) wanted.add("climate");
      if (clean.includes("除湿机")) wanted.add("dehumidifier");
      if (clean.includes("香氛机")) wanted.add("diffuser");
      if (clean.includes("插座")) wanted.add("plug");
      if (clean.includes("净化器") || clean.includes("空净") || clean.includes("新风") || clean.includes("加湿")) wanted.add("airPurifier");
      else if (clean.includes("风扇")) wanted.add("fan");
      if (clean.includes("摄像") || clean.includes("监控")) wanted.add("camera");
      const effectiveWanted = wanted.size > 0 ? wanted : implied;

      candidates = devices.filter((d) => {
        const cat = deviceCategory(d);
        if (!d.isOnline || !isAssistantControllable(cat) || !deviceAcceptsControlWrites(d)) return false;
        if (onlyActive && !isDeviceActiveOn(d)) return false;
        if (matchedRooms.length > 0 && !matchedRooms.includes(d.roomName)) return false;
        if (effectiveWanted && !effectiveWanted.has(cat)) return false;
        return effectiveWanted !== null || hasAllScope || matchedRooms.length > 0;
      });

      if (!onlyActive && !hasAllScope && matchedRooms.length === 0 && candidates.length !== 1) {
        if (/[a-zA-Z]/.test(utterance)) return this.parseEnglish(utterance, devices, scenes);
        return null;
      }
    }

    const plan = buildPlanFromCandidates(
      candidates,
      new Set(explicitDevs.map((d) => d.id)),
      ops,
      devices,
      scenes
    );
    if (!plan && /[a-zA-Z]/.test(utterance)) {
      return this.parseEnglish(utterance, devices, scenes);
    }
    return plan;
  },

  parseEnglish(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): IntentPlan | null {
    const lower = utterance
      .toLowerCase()
      .replace(/[,!?;:'"“”‘’。，！？、]+/g, " ")
      .replace(/\s+/g, " ")
      .trim();
    if (!lower) return null;

    for (const scene of scenes) {
      if (!scene.name) continue;
      const sName = scene.name.toLowerCase();
      if (
        lower === `activate ${sName}` ||
        lower === `run ${sName}` ||
        lower === `start ${sName}` ||
        lower === `${sName} scene`
      ) {
        const intents: DeviceIntent[] = [{ targetId: scene.id, operation: { kind: "activateScene" } }];
        return {
          intents,
          reply: IntentReply.describe(intents, devices, scenes),
          source: "local",
          suggestions: [],
        };
      }
    }

    const state = { rest: ` ${lower} ` };
    const rawOps: IntentOperation[] = extractEnglishNumericOps(state);

    const explicitIds: string[] = [];
    const sortedDevices = [...devices].sort((a, b) => b.name.length - a.name.length);
    for (const dev of sortedDevices) {
      if (!dev.name) continue;
      if (consumeEnglishPhrase(dev.name.toLowerCase(), state)) {
        if (!explicitIds.includes(dev.id)) explicitIds.push(dev.id);
      }
    }

    const roomKeySet = new Set<string>(Object.keys(EN_ROOM_ALIASES));
    for (const d of devices) {
      if (d.roomName) roomKeySet.add(d.roomName.toLowerCase());
    }
    const allRoomKeys = Array.from(roomKeySet).sort((a, b) => b.length - a.length);
    const matchedRoomKeys: string[] = [];
    for (const roomKey of allRoomKeys) {
      if (consumeEnglishPhrase(roomKey, state)) {
        matchedRoomKeys.push(roomKey);
      }
    }

    let hasScope = false;
    for (const scopeWord of EN_SCOPE_WORDS) {
      if (consumeEnglishPhrase(scopeWord, state)) {
        hasScope = true;
      }
    }

    const oscPhrases: ReadonlyArray<readonly [string, boolean]> = [
      ["stop oscillating", false], ["stop oscillation", false], ["stop swing", false],
      ["oscillation off", false], ["swing off", false],
      ["start oscillating", true], ["oscillation on", true], ["swing on", true],
      ["oscillate", true], ["oscillation", true], ["swing", true],
    ];
    for (const [p, val] of oscPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "oscillation", enabled: val });
    }

    const fanPhrases: ReadonlyArray<readonly [string, string]> = [
      ["fan speed high", "high"], ["high fan speed", "high"], ["high speed", "high"], ["max speed", "high"],
      ["fan speed medium", "medium"], ["medium fan speed", "medium"], ["medium speed", "medium"],
      ["fan speed low", "low"], ["low fan speed", "low"], ["low speed", "low"], ["min speed", "low"],
      ["fan speed auto", "auto"], ["auto fan speed", "auto"], ["auto speed", "auto"],
      ["sleep mode", "sleep"], ["favorite mode", "favorite"],
    ];
    for (const [p, val] of fanPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "fanSpeed", speed: val });
    }

    const briStepPhrases: ReadonlyArray<readonly [string, number]> = [
      ["a bit darker", -20], ["a little darker", -20], ["a bit dimmer", -20], ["a little dimmer", -20],
      ["dimmer", -20], ["darker", -20],
      ["a bit brighter", 20], ["a little brighter", 20], ["brighter", 20],
    ];
    for (const [p, val] of briStepPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "brightnessStep", delta: val });
    }

    const tempStepPhrases: ReadonlyArray<readonly [string, number]> = [
      ["a bit warmer", 1], ["a little warmer", 1], ["warmer", 1], ["hotter", 1],
      ["a bit cooler", -1], ["a little cooler", -1], ["cooler", -1], ["colder", -1],
    ];
    for (const [p, val] of tempStepPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "temperatureStep", delta: val });
    }

    const effectPhrases: ReadonlyArray<readonly [string, string]> = [
      ["moonlight mode", "Night"], ["moonlight", "Night"],
      ["night light mode", "Night"], ["night light", "Night"], ["night mode", "Night"],
      ["daylight mode", "Day"], ["daylight", "Day"], ["day mode", "Day"],
    ];
    for (const [p, val] of effectPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "lightEffect", effect: val });
    }

    const briPhrases: ReadonlyArray<readonly [string, number]> = [
      ["minimum brightness", 10], ["dimmest", 10], ["dim", 20],
      ["maximum brightness", 100], ["max brightness", 100], ["full brightness", 100], ["brightest", 100],
    ];
    for (const [p, val] of briPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "brightness", percent: val });
    }

    const ctPhrases: ReadonlyArray<readonly [string, number]> = [
      ["warm light", 2700], ["warm white", 2700], ["yellow light", 2700],
      ["natural light", 4000], ["neutral white", 4000],
      ["white light", 6500], ["cool white", 6500], ["cold light", 6500],
    ];
    for (const [p, val] of ctPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "colorTemperature", kelvin: val });
    }

    const hvacPhrases: ReadonlyArray<readonly [string, string]> = [
      ["cooling mode", "cool"], ["cool mode", "cool"], ["cooling", "cool"], ["cool", "cool"],
      ["heating mode", "heat"], ["heat mode", "heat"], ["heating", "heat"], ["heat", "heat"],
      ["dry mode", "dry"], ["dehumidify", "dry"],
      ["fan only mode", "fan_only"], ["fan only", "fan_only"], ["fan mode", "fan_only"],
      ["auto mode", "auto"],
    ];
    for (const [p, val] of hvacPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "hvacMode", mode: val });
    }

    const powerPhrases: ReadonlyArray<readonly [string, boolean]> = [
      ["turn on", true], ["switch on", true], ["power on", true], ["enable", true], ["open", true],
      ["turn off", false], ["switch off", false], ["power off", false], ["shut off", false], ["disable", false], ["close", false],
      ["off", false], ["on", true],
    ];
    for (const [p, val] of powerPhrases) {
      if (consumeEnglishPhrase(p, state)) rawOps.push({ kind: "power", isOn: val });
    }

    const categories = new Set<IntentCategory>();
    for (const [phrase, cat] of EN_CATEGORY_WORDS) {
      if (consumeEnglishPhrase(phrase, state)) {
        categories.add(cat);
      }
    }

    for (const filler of EN_FILLERS) {
      consumeEnglishPhrase(filler, state);
    }

    if (state.rest.replaceAll(CONSUMED_MARKER, "").trim().length > 0) {
      return null;
    }

    const ops = reconcileOps(rawOps);
    if (!ops) return null;

    const roomDeviceIds = new Set<string>();
    for (const key of matchedRoomKeys) {
      const aliases = EN_ROOM_ALIASES[key] ?? [key];
      for (const dev of devices) {
        const rLower = dev.roomName.toLowerCase();
        if (aliases.some((a) => rLower === a.toLowerCase() || rLower.includes(a.toLowerCase()))) {
          roomDeviceIds.add(dev.id);
        }
      }
    }

    const isTurningOff = ops.length === 1 && ops[0]?.kind === "power" && !ops[0].isOn;
    const mustAcceptIds = new Set<string>(explicitIds);
    let candidates: SmartDevice[] = [];

    if (explicitIds.length > 0) {
      const devById = new Map(devices.map((d) => [d.id, d]));
      candidates = explicitIds.map((id) => devById.get(id)).filter((d): d is SmartDevice => d !== undefined);
    } else {
      const implied = impliedCategories(ops);
      const wanted = categories.size > 0 ? categories : implied;
      if (wanted === null && !isTurningOff) return null;
      if (!hasScope && matchedRoomKeys.length === 0 && wanted === null) return null;

      const onlyActive = ops.every(isRelativeOp);
      candidates = devices.filter((dev) => {
        const cat = deviceCategory(dev);
        if (!dev.isOnline || !isAssistantControllable(cat) || !deviceAcceptsControlWrites(dev)) return false;
        if (onlyActive && !isDeviceActiveOn(dev)) return false;
        if (matchedRoomKeys.length > 0 && !roomDeviceIds.has(dev.id)) return false;
        if (wanted && !wanted.has(cat)) return false;
        return true;
      });
      if (!onlyActive && !hasScope && matchedRoomKeys.length === 0 && candidates.length !== 1) {
        return null;
      }
    }

    return buildPlanFromCandidates(candidates, mustAcceptIds, ops, devices, scenes);
  },
};
