import type {
  AssistantSuggestion,
  DeviceIntent,
  EnvironmentReading,
  HomeScene,
  SmartDevice,
} from "../models.js";
import { deviceAcceptsControlWrites, isDeviceActiveOn } from "../models.js";
import { deviceHeadInstruction, proactiveHeadInstruction } from "./actionPolicy.js";
import type { AssistantContext } from "./context.js";
import { buildEnvironmentSummary, buildTimeSummary, EMPTY_ASSISTANT_CONTEXT } from "./context.js";
import { isAirPurifierDevice } from "./deviceCategory.js";
import type {
  CommandMention,
  HabitEntry,
  HabitLastAction,
  HabitSequenceEntry,
  HabitSharing,
} from "./habits.js";
import { shareHabitSentence } from "./habits.js";
import { IntentValidator } from "./intent.js";
import {
  cleanPromptField,
  PROMPT_DATA_NOTICE,
  PROMPT_NAME_LIMIT,
  PROMPT_STATE_LIMIT,
  sanitizePromptText,
} from "./promptText.js";

/** Builds the ambient context macOS sends: time, indoor readings, running devices, habits. */
export function buildAssistantContext(options: {
  readonly now: Date;
  readonly readings: readonly EnvironmentReading[];
  readonly devices: readonly SmartDevice[];
  readonly scenes: readonly HomeScene[];
  readonly sharing: HabitSharing;
  readonly memory: {
    readonly entries: readonly HabitEntry[];
    readonly sequences?: readonly HabitSequenceEntry[];
    readonly lastAction?: HabitLastAction | null;
  };
  readonly phrases: readonly { readonly phrase: string; readonly intents: readonly DeviceIntent[] }[];
  readonly mention: CommandMention;
}): AssistantContext {
  const active = options.devices
    .filter((device) => device.isOnline && isDeviceActiveOn(device))
    .map((device) => `${device.name}(${catalogStateSummary(device)})`);
  const habitSummary = shareHabitSentence({
    sharing: options.sharing,
    memory: options.memory,
    phrases: options.phrases,
    devices: options.devices,
    scenes: options.scenes,
    mention: options.mention,
    now: options.now,
  });
  return {
    timeSummary: cleanPromptField(buildTimeSummary(options.now)),
    environmentSummary: cleanPromptField(buildEnvironmentSummary(options.readings)),
    activeDevicesSummary: cleanPromptField(active.length > 0 ? active.join("、") : "全屋设备均关闭"),
    habitSummary: cleanPromptField(habitSummary),
  };
}

/** Category used in the model catalog; sensors are not assistant-controllable. */
export function assistantDeviceCategory(device: SmartDevice): string | null {
  if (device.model.includes(".derh.") && device.kind.kind === "fan") return "dehumidifier";
  if (device.model.includes(".diffuser.") && device.kind.kind === "plug") return "diffuser";
  switch (device.kind.kind) {
    case "light":
      return "light";
    case "climate":
      if (
        device.model.includes("heater") ||
        device.model.includes("blanket") ||
        ["电暖", "暖气", "取暖", "暖风"].some((hint) => device.name.includes(hint))
      ) {
        return "heater";
      }
      return "climate";
    case "plug":
    case "vacuum":
    case "camera":
      return device.kind.kind;
    case "fan":
      // Same classification the local parser and the macOS catalog use (#98).
      return isAirPurifierDevice(device) ? "airPurifier" : "fan";
    case "fridge":
    case "sensor":
      return null;
  }
}

export function formatTemperatureValue(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

/**
 * One-line state summary inside the catalog, mirroring macOS `IntentCatalog.stateSummary`.
 * Kept byte-for-byte compatible in shape (Chinese words and separators) so a prompt built
 * on either platform means the same thing to the model.
 */
export function catalogStateSummary(device: SmartDevice): string {
  if (!device.isOnline) return "离线";
  const kind = device.kind;
  switch (kind.kind) {
    case "light": {
      const effects = kind.availableEffects.length > 0 ? ` 可用模式:${kind.availableEffects.join("/")}` : "";
      if (!kind.isOn) return `关${effects}`;
      let text = "开";
      if (kind.brightnessPercent !== null) text += ` 亮度${kind.brightnessPercent}%`;
      if (kind.currentEffect) text += ` 当前:${kind.currentEffect}`;
      return text + effects;
    }
    case "climate": {
      const modes = kind.availableModes.join("/");
      const range = `${formatTemperatureValue(kind.minTemp)}-${formatTemperatureValue(kind.maxTemp)}°C`;
      const current = kind.isOn && kind.hvacMode !== "off"
        ? `${kind.hvacMode} ${formatTemperatureValue(kind.targetTemperature)}°C`
        : "关";
      const fan = kind.availableFanModes.length > 0 ? ` 可选风速:${kind.availableFanModes.join("/")}` : "";
      return `${current} 可用模式:${modes} 温度范围:${range}${fan}`;
    }
    case "fan": {
      let text = kind.isOn ? "开" : "关";
      if (kind.isOn && kind.presetMode) text += ` 风速:${kind.presetMode}`;
      if (kind.availablePresetModes.length > 0) text += ` 可选风速:${kind.availablePresetModes.join("/")}`;
      if (kind.isOscillating !== null) text += ` 摇头:${kind.isOscillating ? "开" : "关"}`;
      return text;
    }
    case "plug":
      return kind.isOn ? "开" : "关";
    case "vacuum":
      // macOS VacuumSpec.isCleaning treats both "cleaning" and "on" as 清扫中 (#38).
      return kind.status === "cleaning" || kind.status === "on" ? "清扫中" : "待机";
    case "camera":
      return kind.isOn ? "开" : "关";
    case "fridge":
    case "sensor":
      return "";
  }
}

export interface IntentCatalog {
  readonly text: string;
  readonly aliasDevices: ReadonlyArray<{ readonly alias: string; readonly device: SmartDevice }>;
  readonly criteriaByAlias: Readonly<Record<string, string>>;
  readonly aliasToIds: ReadonlyMap<string, readonly string[]>;
}

/**
 * Short aliases for controllable devices (d1…dN, never truncated) plus scene aliases and
 * the room/all-light/whole-home shortcuts macOS offers the model (#33 / #38).
 */
export function buildIntentCatalog(
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[]
): IntentCatalog {
  const aliasDevices: Array<{ alias: string; device: SmartDevice }> = [];
  const aliasToIds = new Map<string, string[]>();
  const criteriaByAlias: Record<string, string> = {};
  const allLightIds: string[] = [];
  const allDeviceIds: string[] = [];
  const roomLights = new Map<string, string[]>();
  const aliasById = new Map<string, string>();
  const deviceRows: Array<Record<string, unknown>> = [];

  for (const device of devices) {
    const category = assistantDeviceCategory(device);
    if (category === null || !deviceAcceptsControlWrites(device)) continue;
    const alias = `d${aliasDevices.length + 1}`;
    const state = sanitizePromptText(catalogStateSummary(device), PROMPT_STATE_LIMIT);
    aliasDevices.push({ alias, device });
    aliasToIds.set(alias, [device.id]);
    aliasById.set(device.id, alias);
    if (!aliasToIds.has(device.id)) aliasToIds.set(device.id, [device.id]);
    allDeviceIds.push(device.id);
    if (category === "light" && device.roomName) {
      allLightIds.push(device.id);
      const ids = roomLights.get(device.roomName) ?? [];
      ids.push(device.id);
      roomLights.set(device.roomName, ids);
    } else if (category === "light") {
      allLightIds.push(device.id);
    }
    criteriaByAlias[alias] = `${category}; ${state}`;
    const row: Record<string, unknown> = {
      id: alias,
      name: sanitizePromptText(device.name, PROMPT_NAME_LIMIT),
      room: sanitizePromptText(device.roomName, PROMPT_NAME_LIMIT),
      category,
      state,
    };
    if (device.isSharedHome === true) row["shared"] = true;
    deviceRows.push(row);
  }

  let groupIndex = 0;
  const groupRows: Array<{ id: string; room: string; members: string[] }> = [];
  for (const [room, ids] of roomLights) {
    if (ids.length < 2) continue;
    groupIndex += 1;
    const alias = `room_lights:${groupIndex}`;
    aliasToIds.set(alias, ids);
    criteriaByAlias[alias] = `灯组 ${ids.length}盏`;
    groupRows.push({
      id: alias,
      room: sanitizePromptText(room, PROMPT_NAME_LIMIT),
      members: ids.map((id) => aliasById.get(id) ?? id),
    });
  }
  if (allLightIds.length >= 2) {
    aliasToIds.set("all_lights", allLightIds);
    criteriaByAlias["all_lights"] = `全屋所有灯具 (${allLightIds.length}盏)`;
  }
  if (allDeviceIds.length >= 2) {
    aliasToIds.set("all_devices", allDeviceIds);
    criteriaByAlias["all_devices"] = `全屋所有可控设备 (${allDeviceIds.length}台)`;
  }

  const sceneRows = scenes.map((scene, index) => {
    const alias = `s${index + 1}`;
    aliasToIds.set(alias, [scene.id]);
    if (!aliasToIds.has(scene.id)) aliasToIds.set(scene.id, [scene.id]);
    criteriaByAlias[alias] = "场景";
    return { id: alias, name: sanitizePromptText(scene.name, PROMPT_NAME_LIMIT) };
  });

  const text = `${PROMPT_DATA_NOTICE}\n${JSON.stringify({ devices: deviceRows, groups: groupRows, scenes: sceneRows })}`;
  return { text, aliasDevices, criteriaByAlias, aliasToIds };
}

/** Operations offered to the model, matching macOS `opCriteria` (#38). */
export function systemOneOpCriteria(): Record<string, string> {
  return {
    power_on: "打开设备电源",
    power_off: "关闭设备电源",
    effect_night: "切换月光/夜灯模式 (Night)",
    effect_day: "切换日光模式 (Day)",
    bri_20: "调暗灯光 (亮度 20%)",
    bri_50: "中等亮度 (亮度 50%)",
    bri_100: "调亮/最亮灯光 (亮度 100%)",
    bri_down_20: "相对调暗一点 (-20%)",
    bri_up_20: "相对调亮一点 (+20%)",
    ct_2700: "暖光/黄光 (色温 2700K)",
    ct_4000: "自然光 (色温 4000K)",
    ct_6500: "白光/冷光 (色温 6500K)",
    hvac_cool: "空调制冷模式",
    hvac_heat: "空调制热模式",
    hvac_dry: "空调除湿模式",
    hvac_fan: "空调送风模式",
    hvac_auto: "空调自动模式",
    temp: "仅调节空调温度",
    temp_up_2: "空调温度相对调高 2°C",
    temp_down_2: "空调温度相对调低 2°C",
    fan_low: "风速调为低档/一档",
    fan_medium: "风速调为中档/二档",
    fan_high: "风速调为高档/三档",
    fan_auto: "风速调为自动档",
    osc_on: "开启风扇摇头/摆风",
    osc_off: "停止风扇摇头/摆风",
    scene: "执行智能场景",
  };
}

export function systemOneTempCriteria(): Record<string, string> {
  const criteria: Record<string, string> = { none: "不指定具体温度" };
  for (let celsius = 18; celsius <= 28; celsius += 1) {
    criteria[String(celsius)] = `${celsius}°C`;
  }
  return criteria;
}

/** Per-device decision head choices, mirroring macOS `deviceSpecificCriteria` (#38). */
export function deviceSpecificCriteria(device: SmartDevice): Record<string, string> {
  const criteria: Record<string, string> = {
    none: "保持不变，不操作此设备",
    power_on: "打开此设备",
    power_off: "关闭此设备",
  };
  const kind = device.kind;
  switch (kind.kind) {
    case "light": {
      if (kind.availableEffects.some((effect) => effect.toLowerCase() === "day")) {
        criteria["effect_day"] = "切换为日光模式（专注照明）";
      }
      if (kind.availableEffects.some((effect) => effect.toLowerCase() === "night")) {
        criteria["effect_night"] = "切换为月光/夜灯模式（柔和助眠）";
      }
      criteria["bri_20"] = "调暗灯光 (20%)";
      criteria["bri_100"] = "调亮灯光 (100%)";
      if (kind.isOn) {
        criteria["bri_down_20"] = "再暗一点 (-20%)";
        criteria["bri_up_20"] = "再亮一点 (+20%)";
      }
      break;
    }
    case "climate": {
      if (kind.availableModes.includes("cool")) {
        criteria["cool_24"] = "开启制冷 24°C（快速降温）";
        criteria["cool_25"] = "开启制冷 25°C";
        criteria["cool_26"] = "开启制冷 26°C（舒适恒温）";
      }
      if (kind.availableModes.includes("heat")) {
        criteria["heat_22"] = "开启制热 22°C";
        criteria["heat_24"] = "开启制热 24°C";
      }
      if (kind.availableModes.includes("dry")) {
        criteria["hvac_dry"] = "开启除湿模式";
      }
      if (kind.isOn) {
        criteria["temp_up_2"] = "温度相对调高 2°C";
        criteria["temp_down_2"] = "温度相对调低 2°C";
      }
      break;
    }
    case "fan": {
      if (kind.availablePresetModes.length > 0) {
        criteria["fan_low"] = "风速调为低档";
        criteria["fan_medium"] = "风速调为中档";
        criteria["fan_high"] = "风速调为高档";
      }
      criteria["osc_on"] = "开启摇头";
      criteria["osc_off"] = "停止摇头";
      break;
    }
    case "plug":
    case "vacuum":
    case "camera":
    case "sensor":
      break;
  }
  return criteria;
}

export interface SystemOneRequest {
  readonly body: {
    readonly model: string;
    readonly state: Record<string, unknown>;
    readonly questions: Record<string, unknown>;
  };
  readonly catalog: IntentCatalog;
}

/**
 * Builds the Jev `/v1/systemone` body with the same keys and per-device heads as macOS
 * `ModelIntentResolver.makeSystemOneRequest` (#38). Shared fixture:
 * Tests/Fixtures/ai_request_golden.json.
 */
export function buildSystemOneRequestBody(options: {
  readonly model: string;
  readonly utterance: string;
  readonly devices: readonly SmartDevice[];
  readonly scenes: readonly HomeScene[];
  readonly context?: AssistantContext;
}): SystemOneRequest {
  const catalog = buildIntentCatalog(options.devices, options.scenes);
  const context = options.context ?? EMPTY_ASSISTANT_CONTEXT;

  const targetCriteria: Record<string, string> = { ...catalog.criteriaByAlias, none: "无匹配设备或场景" };
  const questions: Record<string, unknown> = {
    target: {
      type: "choice",
      instructions: "Select the primary target device, room light group, or scene id for the command",
      criteria: targetCriteria,
    },
    op: {
      type: "choice",
      instructions: "Select the primary operation to perform on the target",
      criteria: systemOneOpCriteria(),
    },
    temp: {
      type: "choice",
      instructions: "If the command sets an air-conditioner temperature, select the degree in Celsius; otherwise none",
      criteria: systemOneTempCriteria(),
    },
  };

  for (const { alias, device } of catalog.aliasDevices) {
    questions[`dev_${alias}`] = {
      type: "choice",
      instructions: deviceHeadInstruction(alias),
      criteria: deviceSpecificCriteria(device),
    };
  }

  const state: Record<string, unknown> = {
    catalog: catalog.text,
    command: options.utterance,
  };
  const time = cleanPromptField(context.timeSummary);
  const environment = cleanPromptField(context.environmentSummary);
  const activeDevices = cleanPromptField(context.activeDevicesSummary);
  const habits = cleanPromptField(context.habitSummary);
  if (time) state["time"] = time;
  if (environment) state["environment"] = environment;
  if (activeDevices) state["active_devices"] = activeDevices;
  if (habits) state["user_habits"] = habits;

  return {
    body: { model: options.model, state, questions },
    catalog,
  };
}

/** Proactive per-device decision heads; mirrors macOS `makeProactiveSystemOneRequest` (#113). */
export function buildProactiveSystemOneRequestBody(options: {
  readonly model: string;
  readonly devices: readonly SmartDevice[];
  readonly context: AssistantContext;
  readonly catalog: IntentCatalog;
}): SystemOneRequest {
  const questions: Record<string, unknown> = {};
  for (const { alias, device } of options.catalog.aliasDevices) {
    questions[`dev_${alias}`] = {
      type: "choice",
      instructions: proactiveHeadInstruction(alias),
      criteria: deviceSpecificCriteria(device),
    };
  }

  const state: Record<string, unknown> = {
    catalog: options.catalog.text,
    time: cleanPromptField(options.context.timeSummary),
    environment: cleanPromptField(options.context.environmentSummary),
    active_devices: cleanPromptField(options.context.activeDevicesSummary),
    user_habits: cleanPromptField(options.context.habitSummary),
  };

  return {
    body: { model: options.model, state, questions },
    catalog: options.catalog,
  };
}

/** Proactive chat prompt; mirrors macOS `makeProactiveChatRequest` (#113). */
export function buildProactiveChatRequestBody(
  model: string,
  context: AssistantContext,
  catalog: IntentCatalog,
): Record<string, unknown> {
  const system = [
    "你是智能家居主动建议引擎。根据当前时间、室内温湿度、开启中的设备与用户习惯，推荐最多 3 个最值得立即执行的设备调整建议，只输出 JSON，不要解释。",
    catalog.text,
    'schema: {"suggestions":[{"device":"id","op":"power|brightness|color_temp|effect|hvac_mode|temperature|fan_speed|oscillation|scene","value":...,"confidence":85}]}',
    "规则：confidence 为 20-99 的整数置信度；如果当前环境已处于理想状态无需操作，输出 {\"suggestions\":[]}。只能使用上面列出的 id。",
  ].join("\n");
  const userState = `时间：${cleanPromptField(context.timeSummary)}\n环境：${cleanPromptField(context.environmentSummary)}\n开启中：${cleanPromptField(context.activeDevicesSummary)}\n习惯：${cleanPromptField(context.habitSummary)}`;
  return {
    model: model.trim(),
    messages: [
      { role: "system", content: system },
      { role: "user", content: userState },
    ],
    temperature: 0,
    max_tokens: 600,
    stream: false,
  };
}
