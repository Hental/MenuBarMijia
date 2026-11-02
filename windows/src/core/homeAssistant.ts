import { sha256 } from "./miCloudCrypto.js";
import {
  deviceEnvironmentReading,
  environmentReadingPriority,
  type DeviceCommand,
  type DeviceKind,
  type SmartDevice,
  type SynthesizedHome,
} from "./models.js";

type Row = Record<string, unknown>;
interface HAState {
  entityId: string;
  state: string;
  attributes: Row;
}
interface HASnapshot {
  areas: Row[];
  devices: Row[];
  entities: Row[];
  states: HAState[];
}
export interface HaServiceCall {
  domain: string;
  service: string;
  entity_id: string;
  data: Row;
}
export type HAInvoke = <T>(
  command: string,
  args: Record<string, unknown>,
) => Promise<T>;

function object(value: unknown): Row {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("Invalid Home Assistant object");
  return Object.fromEntries(Object.entries(value));
}
function rows(value: unknown): Row[] {
  if (!Array.isArray(value)) throw new Error("Invalid Home Assistant list");
  return value.map(object);
}
function text(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}
function number(value: unknown): number | null {
  if (typeof value !== "number" && typeof value !== "string") return null;
  if (value === "") return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
}
function strings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}
function decode(value: unknown): HASnapshot {
  const raw = object(value);
  return {
    areas: rows(raw.areas),
    devices: rows(raw.devices),
    entities: rows(raw.entities),
    states: rows(raw.states).map((state) => {
      if (
        typeof state.entity_id !== "string" ||
        typeof state.state !== "string"
      )
        throw new Error("Invalid Home Assistant state");
      return {
        entityId: state.entity_id,
        state: state.state,
        attributes: object(state.attributes),
      };
    }),
  };
}


function requiredText(value: unknown): string {
  if (typeof value !== "string") throw new Error("Invalid cached text");
  return value;
}
function requiredNumber(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) throw new Error("Invalid cached number");
  return value;
}
function requiredBoolean(value: unknown): boolean {
  if (typeof value !== "boolean") throw new Error("Invalid cached boolean");
  return value;
}
function nullableText(value: unknown): string | null {
  return value === null ? null : requiredText(value);
}
function nullableNumber(value: unknown): number | null {
  return value === null ? null : requiredNumber(value);
}
function nullableBoolean(value: unknown): boolean | null {
  return value === null ? null : requiredBoolean(value);
}
function requiredStrings(value: unknown): string[] {
  if (!Array.isArray(value)) throw new Error("Invalid cached string list");
  return value.map(requiredText);
}
function cachedKind(value: unknown): DeviceKind {
  const k = object(value);
  switch (k.kind) {
    case "light": return { kind: "light", entityId: requiredText(k.entityId), isOn: requiredBoolean(k.isOn), brightnessPercent: nullableNumber(k.brightnessPercent), colorTempKelvin: nullableNumber(k.colorTempKelvin), minKelvin: requiredNumber(k.minKelvin), maxKelvin: requiredNumber(k.maxKelvin), currentEffect: nullableText(k.currentEffect), availableEffects: requiredStrings(k.availableEffects) };
    case "climate": return { kind: "climate", entityId: requiredText(k.entityId), isOn: requiredBoolean(k.isOn), hvacMode: requiredText(k.hvacMode), availableModes: requiredStrings(k.availableModes), targetTemperature: requiredNumber(k.targetTemperature), currentTemperature: nullableNumber(k.currentTemperature), minTemp: requiredNumber(k.minTemp), maxTemp: requiredNumber(k.maxTemp), step: requiredNumber(k.step), fanMode: nullableText(k.fanMode), availableFanModes: requiredStrings(k.availableFanModes) };
    case "fan": return { kind: "fan", entityId: requiredText(k.entityId), isOn: requiredBoolean(k.isOn), percentage: nullableNumber(k.percentage), presetMode: nullableText(k.presetMode), availablePresetModes: requiredStrings(k.availablePresetModes), isOscillating: nullableBoolean(k.isOscillating), pm25Density: nullableNumber(k.pm25Density ?? null), airQuality: nullableText(k.airQuality ?? null), temperature: nullableNumber(k.temperature ?? null), humidity: nullableNumber(k.humidity ?? null), filterLifePercent: nullableNumber(k.filterLifePercent ?? null) };
    case "plug": return { kind: "plug", switchEntityId: requiredText(k.switchEntityId), isOn: requiredBoolean(k.isOn), powerWatts: nullableNumber(k.powerWatts), energyKwh: nullableNumber(k.energyKwh ?? null), childLockEntityId: nullableText(k.childLockEntityId), isChildLocked: requiredBoolean(k.isChildLocked) };
    case "vacuum": return { kind: "vacuum", entityId: requiredText(k.entityId), status: requiredText(k.status), battery: nullableNumber(k.battery), modeEntityId: nullableText(k.modeEntityId), currentMode: nullableText(k.currentMode), availableModes: requiredStrings(k.availableModes) };
    case "camera": return { kind: "camera", entityId: requiredText(k.entityId), isOn: requiredBoolean(k.isOn), nightShot: nullableText(k.nightShot), availableNightShots: requiredStrings(k.availableNightShots), motionDetectionEntityId: nullableText(k.motionDetectionEntityId), isMotionDetectionOn: nullableBoolean(k.isMotionDetectionOn), streamEntityId: nullableText(k.streamEntityId), snapshotPath: null };
    case "sensor": return { kind: "sensor", temperature: nullableNumber(k.temperature), humidity: nullableNumber(k.humidity), battery: nullableNumber(k.battery) };
    default: throw new Error("Invalid cached device kind");
  }
}

export function parseCachedHAHome(value: unknown): { identity: string; home: SynthesizedHome } | null {
  try {
    const cache = object(value);
    const home = object(cache.home);
    return {
      identity: requiredText(cache.identity),
      home: {
        devices: rows(home.devices).map((d) => ({ id: requiredText(d.id), name: requiredText(d.name), roomId: requiredText(d.roomId), roomName: requiredText(d.roomName), model: requiredText(d.model), isOnline: requiredBoolean(d.isOnline), kind: cachedKind(d.kind) })),
        rooms: rows(home.rooms).map((r) => ({ id: requiredText(r.id), name: requiredText(r.name), deviceCount: requiredNumber(r.deviceCount) })),
        environmentReadings: rows(home.environmentReadings).map((r) => ({ id: requiredText(r.id), label: requiredText(r.label), roomName: requiredText(r.roomName), temperature: nullableNumber(r.temperature), humidity: nullableNumber(r.humidity), battery: nullableNumber(r.battery) })),
        scenes: rows(home.scenes).map((s) => ({ id: requiredText(s.id), name: requiredText(s.name), entityId: requiredText(s.entityId) })),
      },
    };
  } catch {
    return null;
  }
}

export function homeAssistantIdentity(baseURL: string, token: string): string | null {
  try {
    const url = new URL(baseURL.trim());
    if ((url.protocol !== "http:" && url.protocol !== "https:") || url.username || url.password || !url.hostname) return null;
    const digest = sha256(new TextEncoder().encode(token));
    return `${url.origin}|${Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
  } catch {
    return null;
  }
}

export function homeAssistantCommand(command: DeviceCommand, devices: readonly SmartDevice[]): DeviceCommand {
  if (command.kind !== "setClimatePower" || !command.isOn) return command;
  const device = devices.find((entry) => entry.kind.kind === "climate" && entry.kind.entityId === command.entityId);
  if (!device || device.kind.kind !== "climate") throw new Error("Home Assistant climate not found");
  const k = device.kind;
  const resumeMode = [k.hvacMode, command.resumeMode, ...k.availableModes].find(
    (mode) => mode !== "off" && mode !== "unknown" && mode !== "unavailable" && k.availableModes.includes(mode),
  );
  if (!resumeMode) throw new Error("Home Assistant climate has no supported resume mode");
  return { ...command, resumeMode };
}

function buildKind(
  entities: Row[],
  states: Map<string, HAState>,
  model: string,
): { kind: DeviceKind; online: boolean } | null {
  const find = (
    domain: string,
    predicate: (entity: Row) => boolean = () => true,
  ) => {
    const entity = entities.find(
      (entry) =>
        text(entry.entity_id).startsWith(`${domain}.`) && predicate(entry),
    );
    return entity ? states.get(text(entity.entity_id)) : undefined;
  };
  const sensor = (metric: string) =>
    find("sensor", (entry) => {
      const state = states.get(text(entry.entity_id));
      const entityId = text(entry.entity_id);
      if (metric === "air_quality") {
        return state?.attributes.device_class === "aqi" || state?.attributes.device_class === "air_quality" || entityId.includes("air_quality");
      }
      if (state?.attributes.device_class === metric) return true;
      if (metric === "power") {
        if (state?.attributes.device_class === "energy") return false;
        return entityId.includes("electric_power") || (entityId.includes("power") && !entityId.includes("power_consumption"));
      }
      if (metric === "energy") {
        if (state?.attributes.device_class === "power") return false;
        return entityId.includes("power_consumption") || entityId.includes("energy");
      }
      if (metric === "pm25") {
        return /pm2[._]?5|pm25/.test(entityId);
      }
      if (metric === "temperature") {
        return entityId.includes("temperature") && !entityId.includes("color_temperature");
      }
      return entityId.includes(metric);
    });
  const reading = (metric: string) => number(sensor(metric)?.state);
  const sensorText = (metric: string) => {
    const found = sensor(metric);
    return found && found.state !== "unknown" && found.state !== "unavailable" ? found.state : null;
  };
  const powerSwitch = find(
    "switch",
    (entry) =>
      !/motion|indicator|watermark|wdr|tracking|distortion/.test(
        text(entry.entity_id),
      ),
  );
  let state: HAState | undefined;
  let kind: DeviceKind;
  if ((state = find("climate"))) {
    const a = state.attributes;
    const modes = strings(a.hvac_modes);
    kind = {
      kind: "climate",
      entityId: state.entityId,
      isOn: state.state !== "off" && state.state !== "unknown" && state.state !== "unavailable",
      hvacMode: state.state,
      availableModes: modes.length > 0 ? modes : ["cool", "heat", "dry", "fan_only", "off"],
      targetTemperature: number(a.temperature) ?? number(a.target_temp_low) ?? number(a.current_temperature) ?? 26,
      currentTemperature: number(a.current_temperature),
      minTemp: number(a.min_temp) ?? 16,
      maxTemp: number(a.max_temp) ?? 30,
      step: number(a.target_temp_step) ?? 1,
      fanMode: typeof a.fan_mode === "string" ? a.fan_mode : null,
      availableFanModes: strings(a.fan_modes),
    };
  } else if (
    (state = find(
      "light",
      (entry) =>
        entry.entity_category !== "config" &&
        !text(entry.entity_id).endsWith("_indicator_light"),
    ))
  ) {
    const a = state.attributes,
      brightness = number(a.brightness);
    kind = {
      kind: "light",
      entityId: state.entityId,
      isOn: state.state === "on",
      brightnessPercent:
        brightness === null
          ? null
          : Math.max(1, Math.min(100, Math.round((brightness / 255) * 100))),
      colorTempKelvin: number(a.color_temp_kelvin),
      minKelvin: number(a.min_color_temp_kelvin) ?? 2700,
      maxKelvin: number(a.max_color_temp_kelvin) ?? 6500,
      currentEffect: typeof a.effect === "string" ? a.effect : null,
      availableEffects: strings(a.effect_list),
    };
  } else if ((state = find("fan"))) {
    const a = state.attributes;
    kind = {
      kind: "fan",
      entityId: state.entityId,
      isOn: state.state === "on",
      percentage: number(a.percentage),
      presetMode: typeof a.preset_mode === "string" ? a.preset_mode : null,
      availablePresetModes: strings(a.preset_modes),
      isOscillating: typeof a.oscillating === "boolean" ? a.oscillating : null,
      temperature: reading("temperature") ?? number(a.temperature),
      humidity: reading("humidity") ?? number(a.humidity),
      pm25Density: reading("pm25") ?? number(a.pm25),
      airQuality: sensorText("air_quality") ?? (typeof a.air_quality === "string" ? a.air_quality : null),
      filterLifePercent: reading("filter_life") ?? number(a.filter_life_remaining),
    };
  } else if ((state = find("vacuum"))) {
    const mode = find("select", (entry) =>
      text(entry.entity_id).includes("mode"),
    );
    kind = {
      kind: "vacuum",
      entityId: state.entityId,
      status: state.state,
      battery: reading("battery") ?? number(state.attributes.battery_level),
      modeEntityId: mode?.entityId ?? null,
      currentMode: mode && mode.state !== "unknown" && mode.state !== "unavailable" ? mode.state : null,
      availableModes: strings(mode?.attributes.options),
    };
  } else if ((state = find("camera") ?? (model.startsWith("chuangmi.camera") ? powerSwitch : undefined))) {
    const camera = find("camera");
    const power = powerSwitch;
    const motion = find("switch", (entry) =>
      text(entry.entity_id).includes("motion"),
    );
    const night = find("select", (entry) =>
      /night|ir_mode/.test(text(entry.entity_id)),
    );
    const powerId = power?.entityId ?? state.entityId;
    kind = {
      kind: "camera",
      entityId: night ? `${powerId}|${night.entityId}` : powerId,
      isOn: power ? power.state === "on" : state.state !== "off",
      nightShot: night && night.state !== "unknown" && night.state !== "unavailable" ? night.state : null,
      availableNightShots: strings(night?.attributes.options),
      motionDetectionEntityId: motion?.entityId ?? null,
      isMotionDetectionOn: motion ? motion.state === "on" : null,
      streamEntityId: camera?.entityId ?? null,
      snapshotPath:
        typeof camera?.attributes.entity_picture === "string"
          ? camera.attributes.entity_picture
          : typeof camera?.attributes.access_token === "string" && camera.entityId
            ? `/api/camera_proxy/${camera.entityId}?token=${camera.attributes.access_token}`
            : null,
    };
  } else if (
    (state = find(
      "switch",
      (entry) =>
        entry.entity_category !== "config" &&
        entry.entity_category !== "diagnostic" &&
        (states.get(text(entry.entity_id))?.attributes.device_class === "outlet" ||
          (!/(?:^|_)(?:physical_controls_locked|child_lock|indicator|mute|sleep_mode)(?:_|$)/.test(
            text(entry.entity_id).split(".")[1] ?? "",
          ) &&
            (model.includes("plug") || (!sensor("temperature") && !sensor("humidity"))))),
    ))
  ) {
    const lock = find("switch", (entry) =>
      /child_lock|physical_controls_locked/.test(text(entry.entity_id)),
    );
    kind = {
      kind: "plug",
      switchEntityId: state.entityId,
      isOn: state.state === "on",
      powerWatts: reading("power"),
      energyKwh: reading("energy"),
      childLockEntityId: lock?.entityId ?? null,
      isChildLocked: lock?.state === "on",
    };
  } else {
    const temperature = sensor("temperature"),
      humidity = sensor("humidity");
    state =
      [temperature, humidity].find(
        (entry) =>
          entry && entry.state !== "unknown" && entry.state !== "unavailable",
      ) ??
      temperature ??
      humidity;
    if (state) {
      kind = {
        kind: "sensor",
        temperature: reading("temperature"),
        humidity: reading("humidity"),
        battery: reading("battery"),
      };
    } else {
      const primaryButtons = entities.filter((entry) => {
        const entityId = text(entry.entity_id);
        if (!entityId.startsWith("button.") || entry.entity_category != null) return false;
        const devClass = states.get(entityId)?.attributes.device_class;
        if (devClass === "restart" || devClass === "update" || devClass === "identify") return false;
        const objectId = entityId.slice("button.".length);
        return !/(?:^|_)(?:reboot|restart|reset|identify|calibrate)(?:_|$)/.test(objectId);
      });
      const buttonEntity =
        primaryButtons.find((entry) => text(entry.entity_id).includes("wake_on_lan")) ??
        primaryButtons[0];
      const buttonState = buttonEntity ? states.get(text(buttonEntity.entity_id)) : undefined;
      if (!buttonState) return null;
      return {
        kind: {
          kind: "plug",
          switchEntityId: buttonState.entityId,
          isOn: false,
          powerWatts: null,
          energyKwh: null,
          childLockEntityId: null,
          isChildLocked: false,
        },
        online: buttonState.state !== "unavailable",
      };
    }
  }
  return {
    kind,
    online: state.state !== "unavailable" && state.state !== "unknown",
  };
}

export class HomeAssistantSynthesizer {
  static synthesize(raw: unknown): SynthesizedHome {
    const snapshot = decode(raw);
    const states = new Map(
      snapshot.states.map((state) => [state.entityId, state]),
    );
    const registry = new Map(
      snapshot.entities.map((entity) => [text(entity.entity_id), entity]),
    );
    const registered = new Set(
      snapshot.devices.map((device) => text(device.id)),
    );
    const active = snapshot.entities.filter(
      (entity) => entity.disabled_by == null && entity.hidden_by == null,
    );
    const groups = new Map<string, Row[]>();
    for (const entity of active) {
      const id = text(entity.device_id);
      if (id) groups.set(id, [...(groups.get(id) ?? []), entity]);
    }
    const devices: SmartDevice[] = [];
    const append = (
      id: string,
      name: string,
      areaId: string,
      model: string,
      entities: Row[],
    ) => {
      const built = buildKind(entities, states, model);
      if (!built) return;
      const rawRoomName = text(
        snapshot.areas.find((area) => area.area_id === areaId)?.name,
        "全屋",
      ).trim();
      const roomName =
        !rawRoomName || rawRoomName === "默认房间"
          ? "全屋"
          : rawRoomName;
      const roomIds: Record<string, string> = {
        客厅: "ke_ting",
        书房: "shu_fang",
        卧室: "wo_shi",
        主卧: "zhu_wo",
        次卧: "ci_wo",
        小卧室: "xiao_wo_shi",
        厨房: "chu_fang",
        阳台: "yang_tai",
      };
      let cleanName = name
        .trim()
        .replace(/^(?:直流变频循环扇|米家踢脚线电暖器|Yeelight LED 彩光灯带)\s*/, "")
        .replace(/(?:  灯|  电暖器|  风扇|  音箱|  电视|  开关 开关)$/, "")
        .trim();
      if (cleanName === "吸顶灯" && roomName !== "全屋")
        cleanName = `${roomName}吸顶灯`;
      devices.push({
        id,
        name: cleanName || name.trim(),
        roomId: areaId || roomIds[roomName] || "other",
        roomName,
        model,
        isOnline: built.online,
        kind: built.kind,
      });
    };
    const nonEmpty = (value: unknown, fallback = ""): string =>
      typeof value === "string" && value.trim().length > 0 ? value.trim() : fallback;
    for (const device of snapshot.devices) {
      const id = text(device.id),
        entities = groups.get(id) ?? [],
        model = text(device.model);
      if (
        device.disabled_by != null ||
        model === "hyperDLNA" ||
        model.startsWith("Apple TV") ||
        model.startsWith("lumi.gateway")
      )
        continue;
      append(
        id,
        nonEmpty(device.name_by_user, nonEmpty(device.name, "智能设备")),
        text(
          device.area_id,
          text(entities.find((entity) => entity.area_id)?.area_id),
        ),
        model,
        entities,
      );
    }
    for (const state of snapshot.states) {
      const entity = registry.get(state.entityId);
      if (
        entity &&
        (entity.disabled_by != null ||
          entity.hidden_by != null ||
          registered.has(text(entity.device_id)))
      )
        continue;
      append(
        state.entityId,
        nonEmpty(
          entity?.name,
          nonEmpty(entity?.original_name, nonEmpty(state.attributes.friendly_name, state.entityId)),
        ),
        text(entity?.area_id),
        "",
        [entity ?? { entity_id: state.entityId }],
      );
    }
    const scenes = snapshot.states
      .filter(
        (state) =>
          /^(scene|script)\./.test(state.entityId) &&
          state.state !== "unavailable" &&
          state.state !== "unknown",
      )
      .filter((state) => {
        const entity = registry.get(state.entityId);
        return (
          !entity ||
          (entity.disabled_by == null &&
            entity.hidden_by == null &&
            !snapshot.devices.some(
              (device) =>
                device.id === entity.device_id && device.disabled_by != null,
            ))
        );
      })
      .map((state) => {
        const entity = registry.get(state.entityId);
        return {
          id: state.entityId,
          entityId: state.entityId,
          name: nonEmpty(
            entity?.name,
            nonEmpty(entity?.original_name, nonEmpty(state.attributes.friendly_name, state.entityId)),
          ),
        };
      });
    const rooms = [...new Set(devices.map((device) => device.roomId))].map(
      (id) => ({
        id,
        name:
          devices.find((device) => device.roomId === id)?.roomName ?? "全屋",
        deviceCount: devices.filter((device) => device.roomId === id).length,
      }),
    );
    return {
      devices,
      rooms,
      scenes,
      environmentReadings: [...devices]
        .sort((a, b) => environmentReadingPriority(a.kind) - environmentReadingPriority(b.kind))
        .flatMap((device) => {
          const reading = deviceEnvironmentReading(device);
          return reading ? [reading] : [];
        }),
    };
  }
}

export function haServiceCall(command: DeviceCommand): HaServiceCall {
  const [powerEntityId = "", selectEntityId] = command.entityId.split("|");
  const entity_id =
    command.kind === "setSelectOption" && selectEntityId
      ? selectEntityId
      : powerEntityId;
  const domain = entity_id.split(".")[0] ?? "";
  const call = (service: string, data: Row = {}): HaServiceCall => ({
    domain,
    service,
    entity_id,
    data,
  });
  switch (command.kind) {
    case "setLightPower":
    case "setFanPower":
    case "setSwitch":
      if (domain === "button") return call("press");
      return call(command.isOn ? "turn_on" : "turn_off");
    case "setLightBrightness":
      return call("turn_on", { brightness_pct: command.percent });
    case "setLightColorTemp":
      return call("turn_on", { color_temp_kelvin: command.kelvin });
    case "setLightEffect":
      return call("turn_on", { effect: command.effect });
    case "setClimatePower":
      return call("set_hvac_mode", {
        hvac_mode: command.isOn ? command.resumeMode : "off",
      });
    case "setClimateMode":
      return call("set_hvac_mode", { hvac_mode: command.hvacMode });
    case "setClimateTemperature":
      return call("set_temperature", { temperature: command.temperature });
    case "setClimateFanMode":
      return call("set_fan_mode", { fan_mode: command.fanMode });
    case "setFanPercentage":
      return call("set_percentage", { percentage: command.percent });
    case "setFanPresetMode":
      return call("set_preset_mode", { preset_mode: command.presetMode });
    case "setFanOscillating":
      return call("oscillate", { oscillating: command.oscillating });
    case "setSelectOption":
      return call("select_option", { option: command.option });
    case "vacuumAction":
      return call(
        command.action === "returnToBase" ? "return_to_base" : command.action,
      );
    case "activateScene":
      return call("turn_on");
  }
}

export class HomeAssistantClient {
  constructor(
    private readonly baseURL: string,
    private readonly token: string,
    private readonly invoke: HAInvoke = async (command, args) => {
      if (!window.__TAURI_INTERNALS__?.invoke)
        throw new Error("Home Assistant requires the Windows app");
      return window.__TAURI_INTERNALS__.invoke(command, args);
    },
  ) {}
  async snapshot(): Promise<SynthesizedHome> {
    return HomeAssistantSynthesizer.synthesize(
      await this.invoke<unknown>("ha_snapshot", {
        baseUrl: this.baseURL,
        token: this.token,
      }),
    );
  }
  async execute(command: DeviceCommand): Promise<void> {
    await this.invoke("ha_execute", {
      baseUrl: this.baseURL,
      token: this.token,
      command: haServiceCall(command),
    });
  }
}
