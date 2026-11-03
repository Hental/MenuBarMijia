import {
  deviceEnvironmentReading,
  environmentReadingPriority,
  type DeviceKind,
  type EnvironmentReading,
  type RoomCategory,
  type SmartDevice,
  type SynthesizedHome,
} from "../models.js";
import {
  miotDid,
  propKeyString,
  specForRecord,
  type MiDeviceRecord,
  type MiRoom,
  type MiotPropKey,
} from "./client.js";
import {
  hvacModeFromDescription,
  inferFallbackSpec,
  makeMiotAddress,
  miotShortName,
  type MiotDeviceSpec,
  type MiotProperty,
  type MiotService,
} from "./spec.js";

export function exposesWrite(access: readonly string[] | undefined): boolean {
  return Boolean(access?.includes("write"));
}

export function readOnlyFlags(flags: Record<string, boolean>): Record<string, false> {
  const out: Record<string, false> = {};
  for (const [key, writable] of Object.entries(flags)) {
    if (!writable) out[key] = false;
  }
  return out;
}

export function miotBool(val: unknown): boolean | null {
  if (typeof val === "boolean") return val;
  if (typeof val === "number") return val !== 0;
  return null;
}

export function hasScaleToken(comment: string, token: string): boolean {
  let idx = comment.indexOf(token);
  while (idx !== -1) {
    const prev = idx > 0 ? comment[idx - 1]! : "";
    if (!((prev >= "0" && prev <= "9") || prev === ".")) {
      return true;
    }
    idx = comment.indexOf(token, idx + token.length);
  }
  return false;
}

/** Explicit power metadata wins over magnitude, range-step, and misleading watt labels (#129). */
export function powerScale(prop: MiotProperty): number | null {
  const unit = (prop.unit ?? "").toLowerCase().replaceAll(" ", "");
  const comment = (prop.comment ?? "").toLowerCase().replaceAll(",", ".").replaceAll(" ", "");
  const scales: readonly (readonly [string, number])[] = [["0.001", 0.001], ["0.01", 0.01], ["0.1", 0.1]];
  for (const [token, scale] of scales) {
    const pattern = new RegExp("(?<![0-9.])" + token.replaceAll(".", "\\.") + "(?:watt|w)(?![a-z])");
    if (pattern.test(comment) || unit === token + "w" || unit === token + "watt") return scale;
  }
  switch (unit) {
    case "": case "none": case "w": case "watt": return 1;
    case "kw": case "kilowatt": return 1000;
    case "mw": case "milliwatt": return 0.001;
    default: return null;
  }
}

/**
 * Scale factor that converts a MIoT `power-consumption` reading into kWh (#62).
 * Returns `null` when an integer property has neither a recognized `unit` nor an explicit
 * scale in `comment` (e.g. "0.01kwh"), so ambiguous raw integers are never guessed.
 */
export function energyScale(prop: MiotProperty): number | null {
  const unit = (prop.unit ?? "")
    .trim()
    .toLowerCase()
    .replaceAll(",", ".")
    .replaceAll(" ", "");
  const comment = (prop.comment ?? "")
    .toLowerCase()
    .replaceAll(",", ".")
    .replaceAll(" ", "");
  if (unit === "wh" || unit === "watt-hour" || unit === "0.001kwh" || hasScaleToken(comment, "0.001kwh")) {
    return 0.001;
  }
  if (unit === "0.01kwh" || hasScaleToken(comment, "0.01kwh")) {
    return 0.01;
  }
  if (unit === "kwh" || unit === "kilowatt-hour" || unit === "1kwh" || hasScaleToken(comment, "1kwh")) {
    return 1.0;
  }
  if (prop.format === "float" && (unit === "" || unit === "none")) {
    return 1.0;
  }
  return null;
}

/** Descriptions that claim a door security state. Offline devices must not keep one of these. */
export const AFFIRMATIVE_LOCK_STATUS = new Set([
  "已上锁",
  "已开锁",
  "门虚掩",
  "门未关",
  "门锁卡住",
  "正在上锁",
  "正在开锁",
  "守护中",
]);

/**
 * Map a MIoT `door-state` value-list description to a lock status.
 * Child-lock / anti-lock entries and unrecognized text return null so the card stays unknown (#149).
 */
export function interpretLockStatus(description: string): string | null {
  const lower = description.toLowerCase();
  if (
    lower.includes("child") ||
    lower.includes("童锁") ||
    lower.includes("反锁") ||
    lower.includes("anti-lock") ||
    lower.includes("antilock")
  ) {
    return null;
  }
  if (
    lower.includes("unlock") ||
    lower.includes("已开锁") ||
    lower.includes("未上锁") ||
    lower.includes("not locked") ||
    lower.includes("未锁")
  ) {
    return "已开锁";
  }
  if (
    (lower.includes("ajar") || lower.includes("虚掩")) &&
    !lower.includes("解除") &&
    !lower.includes("clear") &&
    !lower.includes("release")
  ) {
    return "门虚掩";
  }
  if (lower.includes("not closed") || lower.includes("not close") || lower.includes("未关") || lower.includes("没关")) {
    return "门未关";
  }
  if (lower.includes("jam") || lower.includes("卡住")) {
    return "门锁卡住";
  }
  if (lower.includes("locked") || lower.includes("已上锁") || lower.includes("已锁")) {
    return "已上锁";
  }
  return null;
}

export const MiotSynthesizer = {
  synthesize(
    devices: readonly MiDeviceRecord[],
    rooms: readonly MiRoom[],
    specs: Readonly<Record<string, MiotDeviceSpec>>,
    values: ReadonlyMap<string, unknown>
  ): SynthesizedHome {
    const roomByDid = new Map<string, MiRoom>();
    for (const room of rooms) {
      for (const did of room.dids) {
        if (!roomByDid.has(did)) roomByDid.set(did, room);
      }
    }

    // A panel whose keys are listed as split devices is shown through those keys only.
    const splitParents = new Set(devices.map((d) => d.splitParentDid).filter((d): d is string => !!d));

    const smartDevices: SmartDevice[] = [];
    const readings: EnvironmentReading[] = [];

    for (const record of devices) {
      if (splitParents.has(record.did)) continue;
      // A real spec that yields no builder means the category is unsupported — drop the
      // device (macOS parity). The offline fallback spec applies only when no real spec
      // was fetched at all; re-falling back here would re-admit devices the guard rejected.
      const spec = specs[record.model] ?? inferFallbackSpec(record);
      const built = record.splitParentDid
        ? this.buildDeviceKind(miotDid(record), specForRecord(record, spec), values)
        : this.buildDeviceKind(record.did, spec, values);
      if (!built) continue;

      const room =
        roomByDid.get(record.did) ??
        (record.splitParentDid ? roomByDid.get(record.splitParentDid) : undefined);
      const roomName = room?.name.trim() || "全屋";
      const roomId = room ? `room_${room.id}` : "other";

      const kind =
        record.isOnline || built.kind !== "sensor" || !built.statusText || !AFFIRMATIVE_LOCK_STATUS.has(built.statusText)
          ? built
          : { ...built, statusText: "锁状态未知" };
      const smartDevice: SmartDevice = {
        id: record.did,
        name: record.name,
        roomId,
        roomName,
        model: record.model,
        isOnline: record.isOnline,
        kind,
        ...(room?.isSharedHome === true ? { isSharedHome: true } : {}),
      };
      smartDevices.push(smartDevice);

      const reading = deviceEnvironmentReading(smartDevice);
      if (reading) {
        readings.push(reading);
      }
    }

    const roomOrderByName = new Map<string, number>();
    rooms.forEach((r, idx) => {
      const name = r.name.trim() || "全屋";
      if (!roomOrderByName.has(name)) roomOrderByName.set(name, idx);
    });
    const firstSeenRoom = new Map<string, number>();
    for (const d of smartDevices) {
      if (!firstSeenRoom.has(d.roomName)) firstSeenRoom.set(d.roomName, firstSeenRoom.size);
    }
    const fallbackBase = roomOrderByName.size + 1;
    const roomOrder = (name: string): number =>
      roomOrderByName.get(name) ?? fallbackBase + (firstSeenRoom.get(name) ?? 999);
    const priorityById = new Map<string, number>(
      smartDevices.map((d) => [d.id, environmentReadingPriority(d.kind)])
    );
    readings.sort((a, b) => {
      const pa = priorityById.get(a.id) ?? 0;
      const pb = priorityById.get(b.id) ?? 0;
      if (pa !== pb) return pa - pb;
      const ra = roomOrder(a.roomName);
      const rb = roomOrder(b.roomName);
      if (ra !== rb) return ra - rb;
      return a.label < b.label ? -1 : a.label > b.label ? 1 : 0;
    });

    const roomCounts = new Map<string, { name: string; count: number }>();
    for (const dev of smartDevices) {
      const prev = roomCounts.get(dev.roomId);
      roomCounts.set(dev.roomId, {
        name: dev.roomName,
        count: (prev?.count ?? 0) + 1,
      });
    }
    const roomCategories: RoomCategory[] = Array.from(roomCounts.entries()).map(([id, info]) => ({
      id,
      name: info.name,
      deviceCount: info.count,
    }));

    return {
      devices: smartDevices,
      rooms: roomCategories,
      environmentReadings: readings,
      scenes: [],
    };
  },

  requiredProps(device: MiDeviceRecord, spec: MiotDeviceSpec): MiotPropKey[] {
    const touched: MiotPropKey[] = [];
    const seen = new Set<string>();
    const proxyValues = new Proxy(new Map<string, unknown>(), {
      get(target, prop) {
        if (prop === "get") {
          return (keyStr: string) => {
            if (!seen.has(keyStr)) {
              seen.add(keyStr);
              const parts = keyStr.split(".");
              const siid = Number(parts[parts.length - 2]);
              const piid = Number(parts[parts.length - 1]);
              const did = parts.slice(0, -2).join(".");
              touched.push({ did, siid, piid });
            }
            return target.get(keyStr);
          };
        }
        return Reflect.get(target, prop);
      },
    });
    this.buildDeviceKind(miotDid(device), specForRecord(device, spec), proxyValues);
    return touched;
  },

  buildDeviceKind(
    did: string,
    spec: MiotDeviceSpec,
    values: ReadonlyMap<string, unknown>
  ): DeviceKind | null {
    const priority = [
      "air-conditioner",
      "heater",
      "thermostat",
      "electric-blanket",
      "dehumidifier",
      "diffuser",
      "light",
      "fan",
      "air-purifier",
      "air-fresh",
      "humidifier",
      "video-doorbell",
      "vacuum",
      "fridge",
      "camera-control",
      "outlet",
      "switch",
      "kettle",
      "ble-kettle",
      "water-dispenser",
      "cooker",
      "air-fryer",
      "oven",
      "microwave-oven",
      "health-pot",
      "lock",
      "motion-sensor",
      "occupancy-sensor",
      "magnet-sensor",
      "submersion-sensor",
      "illumination-sensor",
      "air-monitor",
      "temperature-humidity-sensor",
    ];
    const devShort = miotShortName(spec.type);
    const preferredServices =
      devShort === "outlet"
        ? ["outlet", "switch"]
        : devShort === "camera" || devShort === "cateye" || devShort === "video-doorbell"
          ? ["camera-control", "video-doorbell"]
          : devShort === "kettle" || devShort === "ble-kettle"
            ? ["kettle", "ble-kettle", "water-dispenser"]
            : [devShort];
    let primaryService: MiotService | undefined = spec.services.find((s) => {
      const sShort = miotShortName(s.type);
      return preferredServices.includes(sShort) && priority.includes(sShort);
    });
    if (!primaryService) {
      for (const p of priority) {
        // A secondary `light` service must not claim devices whose own type is something
        // else (hood / airer / bath-heater / ceiling-fan / gateway), or those cards become
        // bare lamps that only toggle their lamp while the primary function stays hidden.
        if (p === "light" && devShort !== "light" && !devShort.includes("light") && !devShort.includes("lamp")) {
          continue;
        }
        const found = spec.services.find((s) => miotShortName(s.type) === p);
        if (found) {
          primaryService = found;
          break;
        }
      }
    }
    if (!primaryService && devShort.endsWith("sensor")) {
      primaryService = spec.services.find((s) => miotShortName(s.type) === "environment");
    }
    if (
      !primaryService &&
      // If the spec names a service of its own device type we simply do not support that
      // category yet — claiming the first writable `on` as a plug would fake a device
      // (hood/airer would show up as an outlet).
      !spec.services.some((s) => miotShortName(s.type) === devShort)
    ) {
      // Only genuine plug-like services may fall back to a plug card. macOS has no
      // generic-on fallback at all, so accepting e.g. a bath-heater's `ptc-bath-heater`
      // or `light` service here would fake a device the other platform drops (#98).
      primaryService = spec.services.find(
        (s) =>
          ["outlet", "switch"].includes(miotShortName(s.type)) &&
          s.properties.some((p) => miotShortName(p.type) === "on" && p.access.includes("write"))
      );
    }
    if (!primaryService) return null;

    const readProp = (s: MiotService, short: string, predicate?: (p: MiotProperty) => boolean) => {
      const prop = s.properties.find(
        (p) => miotShortName(p.type) === short && p.access.includes("read") && (!predicate || predicate(p))
      );
      if (!prop) return null;
      const val = values.get(propKeyString({ did, siid: s.iid, piid: prop.iid }));
      return { service: s, prop, val };
    };

    const readProps = (s: MiotService, short: string) =>
      s.properties
        .filter((p) => miotShortName(p.type) === short && p.access.includes("read"))
        .map((prop) => ({
          service: s,
          prop,
          val: values.get(propKeyString({ did, siid: s.iid, piid: prop.iid })),
        }));

    const readFirst = (services: readonly MiotService[], short: string, predicate?: (p: MiotProperty) => boolean) => {
      const seen = new Set<number>();
      for (const s of services) {
        if (seen.has(s.iid)) continue;
        seen.add(s.iid);
        const found = readProp(s, short, predicate);
        if (found) return found;
      }
      return null;
    };

    const sName = miotShortName(primaryService.type);
    if (sName === "light") {
      const on = readProp(primaryService, "on");
      const bri = readProp(primaryService, "brightness");
      const ct = readProp(primaryService, "color-temperature");
      const mode = readProp(primaryService, "mode");
      const modeVal = typeof mode?.val === "number" ? Math.trunc(mode.val) : null;
      const currentEffect =
        modeVal !== null
          ? (mode?.prop.valueList?.find((i) => i.value === modeVal)?.description ?? null)
          : null;
      const briNum = typeof bri?.val === "number" ? bri.val : null;
      const maxBri = bri?.prop.valueRange?.[1] ?? 100;
      const briPct =
        briNum !== null
          ? Math.max(0, Math.min(100, Math.round(maxBri > 0 && maxBri !== 100 ? (briNum / maxBri) * 100 : briNum)))
          : null;

      const isLightGroup = did.startsWith("group.");
      const onWritable = exposesWrite(on?.prop.access);
      return {
        kind: "light",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        brightnessPercent: briPct,
        colorTempKelvin: typeof ct?.val === "number" ? Math.round(ct.val) : null,
        minKelvin: Math.round(ct?.prop.valueRange?.[0] ?? 2700),
        maxKelvin: Math.round(ct?.prop.valueRange?.[1] ?? 6500),
        currentEffect: isLightGroup ? null : currentEffect,
        availableEffects:
          isLightGroup || !exposesWrite(mode?.prop.access)
            ? []
            : (mode?.prop.valueList?.map((i) => i.description) ?? []),
        ...readOnlyFlags({
          powerWritable: onWritable,
          brightnessWritable: bri ? exposesWrite(bri.prop.access) : true,
          colorWritable: ct ? exposesWrite(ct.prop.access) : true,
        }),
      };
    }

    if (sName === "air-conditioner" || sName === "heater" || sName === "thermostat" || sName === "electric-blanket") {
      const on = readProp(primaryService, "on");
      const mode = sName === "electric-blanket" ? null : readProp(primaryService, "mode");
      const target = readProp(primaryService, "target-temperature");
      const current = sName === "electric-blanket" ? null : readFirst(
        [
          primaryService,
          ...spec.services.filter((s) => miotShortName(s.type) === "environment"),
          ...spec.services.filter((s) => miotShortName(s.type) === "temperature-humidity-sensor"),
        ],
        "temperature"
      );
      const fanLevel = readFirst(
        [...spec.services.filter((s) => miotShortName(s.type) === "fan-control"), primaryService],
        "fan-level"
      );

      const isOn = miotBool(on?.val) ?? false;
      const onWritable = exposesWrite(on?.prop.access);
      const modeWritable = exposesWrite(mode?.prop.access);
      const haModes: string[] = [];
      for (const item of mode?.prop.valueList ?? []) {
        const mapped = hvacModeFromDescription(item.description);
        if (mapped && !haModes.includes(mapped)) haModes.push(mapped);
      }
      if (haModes.length === 0 && (modeWritable || (!mode && onWritable))) {
        haModes.push(sName === "air-conditioner" ? "cool" : "heat");
      }
      const modeVal = typeof mode?.val === "number" ? Math.trunc(mode.val) : null;
      const rawDesc = modeVal !== null ? mode?.prop.valueList?.find((i) => i.value === modeVal)?.description : null;
      const activeMode = (rawDesc ? hvacModeFromDescription(rawDesc) : null) ?? haModes[0] ?? (sName === "air-conditioner" ? "cool" : "heat");
      const fanVal = typeof fanLevel?.val === "number" ? Math.trunc(fanLevel.val) : null;
      const fanDesc =
        fanVal !== null ? (fanLevel?.prop.valueList?.find((i) => i.value === fanVal)?.description ?? null) : null;
      const exposeModes = modeWritable || (!mode && onWritable);

      return {
        kind: "climate",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn,
        hvacMode: isOn ? activeMode : "off",
        availableModes: exposeModes ? [...haModes, "off"] : [],
        targetTemperature: typeof target?.val === "number" ? target.val : 26,
        currentTemperature: typeof current?.val === "number" ? current.val : null,
        minTemp: target?.prop.valueRange?.[0] ?? 16,
        maxTemp: target?.prop.valueRange?.[1] ?? 30,
        step: target?.prop.valueRange?.[2] ?? 1,
        fanMode: fanDesc,
        availableFanModes: exposesWrite(fanLevel?.prop.access)
          ? (fanLevel?.prop.valueList?.map((i) => i.description) ?? [])
          : [],
        ...readOnlyFlags({
          powerWritable: onWritable,
          temperatureWritable: target ? exposesWrite(target.prop.access) : true,
        }),
      };
    }

    if (sName === "fan") {
      const on = readProp(primaryService, "on");
      const mode = readProp(primaryService, "mode");
      const levels = readProps(primaryService, "fan-level");
      const swing = readProp(primaryService, "horizontal-swing");
      const percentRef = levels.find((r) => r.prop.valueRange !== undefined);
      const presetRef =
        (mode?.prop.valueList?.length ?? 0) > 0
          ? mode
          : levels.find((r) => (r.prop.valueList?.length ?? 0) > 0);
      const pctNum = typeof percentRef?.val === "number" ? percentRef.val : null;
      const maxPct = percentRef?.prop.valueRange?.[1] ?? 100;
      const percentage =
        pctNum !== null
          ? Math.max(
              0,
              Math.min(100, Math.round(maxPct > 0 && maxPct !== 100 ? (pctNum / maxPct) * 100 : pctNum))
            )
          : null;
      const presetVal = typeof presetRef?.val === "number" ? Math.trunc(presetRef.val) : null;
      const presetDesc =
        presetVal !== null
          ? (presetRef?.prop.valueList?.find((i) => i.value === presetVal)?.description ?? null)
          : null;

      const onWritable = exposesWrite(on?.prop.access);
      return {
        kind: "fan",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        percentage,
        presetMode: presetDesc,
        availablePresetModes: exposesWrite(presetRef?.prop.access)
          ? (presetRef?.prop.valueList?.map((i) => i.description) ?? [])
          : [],
        isOscillating: miotBool(swing?.val),
        ...readOnlyFlags({
          powerWritable: onWritable,
          speedWritable: percentRef ? exposesWrite(percentRef.prop.access) : true,
          swingWritable: swing ? exposesWrite(swing.prop.access) : true,
        }),
      };
    }

    if (sName === "air-purifier" || sName === "air-fresh" || sName === "humidifier") {
      const on = readProp(primaryService, "on");
      const mode = readProp(primaryService, "mode");
      const levels = readProps(primaryService, "fan-level");
      const favServices = [
        ...spec.services.filter((s) => miotShortName(s.type) === "air-purifier-favorite"),
        ...spec.services.filter((s) => miotShortName(s.type) === "air-fresh-favorite"),
        ...spec.services.filter((s) => miotShortName(s.type) === "motor-speed"),
        ...spec.services.filter((s) => miotShortName(s.type) === "custom-service"),
        ...spec.services.filter((s) => miotShortName(s.type) === "fan-control"),
      ];
      const favSpeed =
        readFirst(favServices, "fan-level") ??
        readFirst(favServices, "favorite-fan-level") ??
        readFirst(favServices, "favorite-level") ??
        readFirst(favServices, "favorite-speed");
      const speedRef =
        favSpeed ??
        levels.find((r) => r.prop.valueRange !== undefined) ??
        levels.find((r) => (r.prop.valueList?.length ?? 0) > 0);
      const presetRef =
        (mode?.prop.valueList?.length ?? 0) > 0
          ? mode
          : levels.find((r) => (r.prop.valueList?.length ?? 0) > 0);

      let percentage: number | null = null;
      if (speedRef && typeof speedRef.val === "number") {
        const raw = speedRef.val;
        const range = speedRef.prop.valueRange;
        const list = speedRef.prop.valueList;
        let scaled = raw;
        if (range && range.length >= 2 && (range[1] ?? 0) > (range[0] ?? 0)) {
          const lo = range[0] ?? 0;
          const hi = range[1] ?? 100;
          scaled = lo > 1 ? ((raw - lo) / (hi - lo)) * 100 : hi !== 100 ? (raw / hi) * 100 : raw;
        } else if (list && list.length > 0) {
          const vals = list.map((i) => i.value);
          const lo = Math.min(...vals);
          const hi = Math.max(...vals);
          if (hi > lo) {
            scaled = lo > 1 ? ((raw - lo) / (hi - lo)) * 100 : (raw / hi) * 100;
          }
        }
        percentage = Math.max(0, Math.min(100, Math.round(scaled)));
      }

      const presetVal = typeof presetRef?.val === "number" ? Math.trunc(presetRef.val) : null;
      const presetDesc =
        presetVal !== null
          ? (presetRef?.prop.valueList?.find((i) => i.value === presetVal)?.description ?? null)
          : null;

      const envServices = [
        ...spec.services.filter((s) => miotShortName(s.type) === "environment"),
        ...spec.services.filter((s) => miotShortName(s.type) === "temperature-humidity-sensor"),
        primaryService,
      ];
      const pm25 = readFirst(envServices, "pm2.5-density");
      const aq = readFirst(envServices, "air-quality");
      const temp = readFirst(envServices, "temperature");
      const hum = readFirst(envServices, "relative-humidity");
      const filterServices = [
        ...spec.services.filter((s) => miotShortName(s.type) === "filter"),
        primaryService,
      ];
      const filterLife = readFirst(filterServices, "filter-life-level");

      const pm25Density = typeof pm25?.val === "number" ? Math.round(pm25.val) : null;
      const aqVal = typeof aq?.val === "number" ? Math.trunc(aq.val) : null;
      const airQuality =
        aqVal !== null
          ? (aq?.prop.valueList?.find((i) => i.value === aqVal)?.description ?? null)
          : null;
      const temperature = typeof temp?.val === "number" ? temp.val : null;
      const humidity = typeof hum?.val === "number" ? hum.val : null;
      const filterLifePercent = typeof filterLife?.val === "number" ? Math.round(filterLife.val) : null;

      const onWritable = exposesWrite(on?.prop.access);
      return {
        kind: "fan",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        percentage,
        presetMode: presetDesc,
        availablePresetModes: exposesWrite(presetRef?.prop.access)
          ? (presetRef?.prop.valueList?.map((i) => i.description) ?? [])
          : [],
        isOscillating: null,
        ...(pm25Density !== null ? { pm25Density } : {}),
        ...(airQuality !== null ? { airQuality } : {}),
        ...(temperature !== null ? { temperature } : {}),
        ...(humidity !== null ? { humidity } : {}),
        ...(filterLifePercent !== null ? { filterLifePercent } : {}),
        ...readOnlyFlags({
          powerWritable: onWritable,
          speedWritable: speedRef ? exposesWrite(speedRef.prop.access) : true,
        }),
      };
    }

    if (sName === "vacuum") {
      const status = readProp(primaryService, "status");
      const mode = readProp(primaryService, "mode");
      const battery = readFirst(
        [...spec.services.filter((s) => miotShortName(s.type) === "battery"), primaryService],
        "battery-level"
      );
      const statusVal = typeof status?.val === "number" ? Math.trunc(status.val) : null;
      const statusDesc =
        statusVal !== null
          ? (status?.prop.valueList?.find((i) => i.value === statusVal)?.description?.toLowerCase() ?? "")
          : "";
      let normalizedStatus = "idle";
      if (
        statusDesc.includes("go charging") ||
        statusDesc.includes("returning") ||
        statusDesc.includes("go home") ||
        statusDesc.includes("back to") ||
        statusDesc.includes("recharge")
      ) {
        normalizedStatus = "returning";
      } else if (statusDesc.includes("paus")) {
        normalizedStatus = "paused";
      } else if (
        statusDesc.includes("sweep") ||
        statusDesc.includes("clean") ||
        statusDesc.includes("mop") ||
        statusDesc.includes("working") ||
        statusDesc.includes("busy")
      ) {
        normalizedStatus = "cleaning";
      } else if (statusDesc.includes("charg") || statusDesc.includes("dock") || statusDesc.includes("full")) {
        normalizedStatus = "docked";
      }

      const modeVal = typeof mode?.val === "number" ? Math.trunc(mode.val) : null;
      const currentMode =
        modeVal !== null
          ? (mode?.prop.valueList?.find((i) => i.value === modeVal)?.description ?? null)
          : null;

      return {
        kind: "vacuum",
        entityId: makeMiotAddress(did, primaryService.iid),
        status: normalizedStatus,
        battery: typeof battery?.val === "number" ? Math.round(battery.val) : null,
        modeEntityId: mode ? makeMiotAddress(did, mode.service.iid) : null,
        currentMode,
        availableModes: mode?.prop.valueList?.map((i) => i.description) ?? [],
        ...readOnlyFlags({
          actionsWritable: spec.services.some((service) =>
            service.actions.some((action) =>
              ["start-sweep", "start-clean", "start-sweep-mop", "start-mop"].includes(miotShortName(action.type)),
            ),
          ),
        }),
      };
    }

    if (sName === "fridge") {
      const mode = readProp(primaryService, "mode");
      const chambers = spec.services.filter((s) => miotShortName(s.type) === "fridge-chamber");
      const fridgeChamber =
        chambers.find((s) => {
          const target = s.properties.find((p) => miotShortName(p.type) === "target-temperature");
          return (target?.valueRange?.[0] ?? 0) >= 0;
        }) ?? chambers[0];
      const freezerChamber =
        chambers.find((s) => {
          const target = s.properties.find((p) => miotShortName(p.type) === "target-temperature");
          return (target?.valueRange?.[0] ?? 0) < 0;
        }) ?? (chambers.length > 1 ? chambers[1] : undefined);

      const fridgeTemp = fridgeChamber ? readProp(fridgeChamber, "temperature") : null;
      const fridgeTarget = fridgeChamber ? readProp(fridgeChamber, "target-temperature") : null;
      const freezerTemp = freezerChamber ? readProp(freezerChamber, "temperature") : null;
      const freezerTarget = freezerChamber ? readProp(freezerChamber, "target-temperature") : null;

      const modeVal = typeof mode?.val === "number" ? Math.trunc(mode.val) : null;
      const currentMode =
        modeVal !== null
          ? (mode?.prop.valueList?.find((i) => i.value === modeVal)?.description ?? "None")
          : "None";
      const modeWritable = Boolean(mode?.prop.access.includes("write"));
      const fridgeTargetWritable = Boolean(fridgeTarget?.prop.access.includes("write"));
      const freezerTargetWritable = Boolean(freezerTarget?.prop.access.includes("write"));

      return {
        kind: "fridge",
        modeEntityId: modeWritable ? makeMiotAddress(did, primaryService.iid) : null,
        currentMode,
        availableModes: modeWritable ? (mode?.prop.valueList?.map((i) => i.description) ?? []) : [],
        fridgeCurrentTemp: typeof fridgeTemp?.val === "number" ? fridgeTemp.val : null,
        fridgeTargetTemp: typeof fridgeTarget?.val === "number" ? fridgeTarget.val : 4,
        fridgeTargetEntityId: fridgeTargetWritable && fridgeChamber ? makeMiotAddress(did, fridgeChamber.iid) : null,
        freezerCurrentTemp: typeof freezerTemp?.val === "number" ? freezerTemp.val : null,
        freezerTargetTemp: typeof freezerTarget?.val === "number" ? freezerTarget.val : -18,
        freezerTargetEntityId: freezerTargetWritable && freezerChamber ? makeMiotAddress(did, freezerChamber.iid) : null,
      };
    }

    if (sName === "camera-control" || sName === "video-doorbell") {
      const on = readProp(primaryService, "on");
      const nightShot = readProp(primaryService, "night-shot");
      const motionSvc = spec.services.find((s) => miotShortName(s.type) === "motion-detection");
      const motion = motionSvc ? readProp(motionSvc, "motion-detection") : null;
      const streamSvc = spec.services.find(
        (s) =>
          miotShortName(s.type) === "camera-stream-for-google-home" &&
          s.actions.some((a) => miotShortName(a.type) === "start-hls-stream")
      );
      const nightVal = typeof nightShot?.val === "number" ? Math.trunc(nightShot.val) : null;
      const currentNightShot =
        nightVal !== null
          ? (nightShot?.prop.valueList?.find((i) => i.value === nightVal)?.description ?? null)
          : null;

      const onWritable = exposesWrite(on?.prop.access);
      return {
        kind: "camera",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        nightShot: currentNightShot,
        availableNightShots: exposesWrite(nightShot?.prop.access)
          ? (nightShot?.prop.valueList?.map((i) => i.description) ?? [])
          : [],
        motionDetectionEntityId:
          motion && exposesWrite(motion.prop.access) ? makeMiotAddress(did, motion.service.iid) : null,
        isMotionDetectionOn: miotBool(motion?.val),
        streamEntityId: streamSvc ? makeMiotAddress(did, streamSvc.iid) : null,
        ...readOnlyFlags({ powerWritable: onWritable }),
      };
    }

    if (
      [
        "kettle",
        "ble-kettle",
        "water-dispenser",
        "cooker",
        "air-fryer",
        "oven",
        "microwave-oven",
        "health-pot",
      ].includes(sName) &&
      !primaryService.properties.some((p) => miotShortName(p.type) === "on" && p.access.includes("write"))
    ) {
      const status = readProp(primaryService, "status");
      const statusVal = typeof status?.val === "number" ? Math.trunc(status.val) : null;
      const statusDesc =
        statusVal !== null
          ? (status?.prop.valueList?.find((i) => i.value === statusVal)?.description ?? null)
          : null;
      const hasActionControl = primaryService.actions.some(
        (a) =>
          ["start-cook", "cancel-cooking", "pause"].includes(miotShortName(a.type)) &&
          (a.in?.length ?? 0) === 0
      );
      if (hasActionControl) {
        const desc = (statusDesc ?? "").toLowerCase();
        const isActive =
          desc.includes("running") ||
          desc.includes("cooking") ||
          desc.includes("heating") ||
          desc.includes("boiling") ||
          desc.includes("preheat") ||
          desc.includes("keep warm") ||
          desc.includes("warming") ||
          desc.includes("busy");
        return {
          kind: "plug",
          switchEntityId: makeMiotAddress(did, primaryService.iid),
          isOn: isActive,
          powerWatts: null,
          childLockEntityId: null,
          isChildLocked: false,
        };
      }
      const temp = readProp(primaryService, "temperature") ?? readProp(primaryService, "target-temperature");
      const leftTime = readProp(primaryService, "left-time");
      readProp(primaryService, "ble-keep-warm-time");
      const parts: string[] = [];
      if (statusDesc) {
        const lower = statusDesc.toLowerCase();
        if (lower.includes("idle") || lower.includes("standby") || lower.includes("off")) parts.push("待机");
        else if (lower.includes("warm") || lower.includes("insulation")) parts.push("保温中");
        else if (lower.includes("cook") || lower.includes("work") || lower.includes("busy") || lower.includes("boil") || lower.includes("heat")) parts.push("运行中");
        else if (lower.includes("preheat")) parts.push("预热中");
        else if (lower.includes("delay") || lower.includes("appoint") || lower.includes("reservation")) parts.push("预约中");
        else if (lower.includes("paus")) parts.push("已暂停");
        else parts.push(statusDesc);
      }
      if (typeof temp?.val === "number" && Number.isFinite(temp.val)) {
        parts.push(`${Math.round(temp.val)}°C`);
      }
      if (typeof leftTime?.val === "number" && leftTime.val > 0) {
        parts.push(`剩余 ${Math.round(leftTime.val)} 分`);
      }
      const fallback = ["kettle", "ble-kettle", "water-dispenser"].includes(sName) ? "保温监控" : "待机";
      return {
        kind: "sensor",
        temperature: null,
        humidity: null,
        battery: null,
        statusText: parts.length > 0 ? parts.join(" · ") : fallback,
      };
    }

    if (
      [
        "temperature-humidity-sensor",
        "environment",
        "lock",
        "motion-sensor",
        "occupancy-sensor",
        "magnet-sensor",
        "submersion-sensor",
        "illumination-sensor",
        "air-monitor",
      ].includes(sName)
    ) {
      const readingServices = [
        primaryService,
        ...spec.services.filter((s) => miotShortName(s.type) === "environment"),
        ...spec.services.filter((s) => miotShortName(s.type) === "temperature-humidity-sensor"),
      ];
      const temp = readFirst(readingServices, "temperature");
      const hum = readFirst(readingServices, "relative-humidity");
      const battery = readFirst(
        [...spec.services.filter((s) => miotShortName(s.type) === "battery"), primaryService],
        "battery-level"
      );
      let statusText: string | null = null;
      if (temp === null && hum === null) {
        if (sName === "lock") {
          const doorServices = [
            primaryService,
            ...spec.services.filter((s) => miotShortName(s.type) === "door"),
          ];
          const door = readFirst(doorServices, "door-state");
          const doorValue = typeof door?.val === "number" ? Math.trunc(door.val) : null;
          const description =
            doorValue !== null
              ? (door?.prop.valueList?.find((item) => item.value === doorValue)?.description ?? null)
              : null;
          statusText = (description && interpretLockStatus(description)) || "锁状态未知";
        } else if (sName === "motion-sensor" || sName === "occupancy-sensor") {
          const motion = readProp(primaryService, "motion-state") ?? readProp(primaryService, "occupancy-status");
          const lux = readFirst(
            [primaryService, ...spec.services.filter((s) => miotShortName(s.type) === "illumination-sensor")],
            "illumination"
          );
          const mBool = miotBool(motion?.val);
          const parts = [mBool === true ? "有人移动" : mBool === false ? "无人移动" : "移动监测"];
          if (typeof lux?.val === "number" && Number.isFinite(lux.val)) {
            parts.push(`${Math.round(lux.val)} lx`);
          }
          statusText = parts.join(" · ");
        } else if (sName === "magnet-sensor") {
          const contact = miotBool(readProp(primaryService, "contact-state")?.val);
          statusText = contact === true ? "已闭合" : contact === false ? "已打开" : "门窗监测";
        } else if (sName === "submersion-sensor") {
          const wet = miotBool(readProp(primaryService, "submersion-state")?.val);
          statusText = wet === true ? "浸水告警" : wet === false ? "正常" : "水浸监测";
        } else if (sName === "illumination-sensor") {
          const lux = readProp(primaryService, "illumination");
          statusText = typeof lux?.val === "number" && Number.isFinite(lux.val) ? `${Math.round(lux.val)} lx` : "光照监测";
        }
      }
      return {
        kind: "sensor",
        temperature: typeof temp?.val === "number" ? temp.val : null,
        humidity: typeof hum?.val === "number" ? hum.val : null,
        battery: typeof battery?.val === "number" ? Math.round(battery.val) : null,
        ...(statusText ? { statusText } : {}),
      };
    }

    if (sName === "dehumidifier") {
      const on = readProp(primaryService, "on");
      const mode = readProp(primaryService, "mode");
      const env = spec.services.filter((s) => miotShortName(s.type) === "environment");
      const temperature = readFirst(env, "temperature");
      const humidity = readFirst(env, "relative-humidity");
      const onWritable = exposesWrite(on?.prop.access);
      return {
        kind: "fan",
        entityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        percentage: null,
        presetMode: mode?.prop.valueList?.find((item) => item.value === mode.val)?.description ?? null,
        availablePresetModes: mode?.prop.access.includes("write") ? mode.prop.valueList?.map((item) => item.description) ?? [] : [],
        isOscillating: null,
        temperature: typeof temperature?.val === "number" ? temperature.val : null,
        humidity: typeof humidity?.val === "number" ? humidity.val : null,
        ...readOnlyFlags({ powerWritable: onWritable }),
      };
    }

    if (
      sName === "outlet" ||
      sName === "diffuser" ||
      sName === "switch" ||
      primaryService.properties.some((p) => miotShortName(p.type) === "on")
    ) {
      const on = readProp(primaryService, "on");
      const consumptionServices = [
        ...spec.services.filter((s) => miotShortName(s.type) === "power-consumption"),
        ...spec.services,
      ];
      const power = readFirst(consumptionServices, "electric-power");
      const powerScaleVal = power ? powerScale(power.prop) : null;
      const watts = typeof power?.val === "number" && power.val >= 0 && powerScaleVal !== null ? power.val * powerScaleVal : NaN;
      const energy = readFirst(consumptionServices, "power-consumption", (p) => energyScale(p) !== null);
      const energyScaleVal = energy ? energyScale(energy.prop) : null;
      const energyKwh =
        energy && typeof energy.val === "number" && Number.isFinite(energy.val) && energy.val >= 0 && energyScaleVal !== null
          ? Math.round(energy.val * energyScaleVal * 1000) / 1000
          : null;
      const lockSvc = spec.services.find((s) => miotShortName(s.type) === "physical-controls-locked");
      const lock = lockSvc ? readProp(lockSvc, "physical-controls-locked") : null;

      const onWritable = exposesWrite(on?.prop.access);
      return {
        kind: "plug",
        switchEntityId: makeMiotAddress(did, primaryService.iid),
        isOn: miotBool(on?.val) ?? false,
        powerWatts: Number.isFinite(watts) ? watts : null,
        ...(energyKwh !== null ? { energyKwh } : {}),
        childLockEntityId: lock ? makeMiotAddress(did, lock.service.iid) : null,
        isChildLocked: miotBool(lock?.val) ?? false,
        ...readOnlyFlags({ powerWritable: onWritable }),
      };
    }

    return null;
  },
};
