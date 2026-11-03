import type { MiDeviceRecord } from "./client.js";
import type { HttpTransport } from "./session.js";

export interface MiotValueListItem {
  readonly value: number;
  readonly description: string;
}

export interface MiotProperty {
  readonly iid: number;
  readonly type: string;
  readonly format: string;
  readonly access: readonly string[];
  readonly valueRange?: readonly number[];
  readonly valueList?: readonly MiotValueListItem[];
  readonly unit?: string;
  readonly comment?: string;
}

export interface MiotAction {
  readonly iid: number;
  readonly type: string;
  readonly in?: readonly number[];
}

export interface MiotService {
  readonly iid: number;
  readonly type: string;
  readonly properties: readonly MiotProperty[];
  readonly actions: readonly MiotAction[];
}

export interface MiotDeviceSpec {
  readonly type: string;
  readonly services: readonly MiotService[];
}

export function miotShortName(urn: string): string {
  const parts = urn.split(":");
  return parts[3] ?? urn;
}

export function makeMiotAddress(did: string, siid: number): string {
  return `miot:${did}:${siid}`;
}

export function parseMiotAddress(entityId: string): { did: string; siid: number } | null {
  if (!entityId.startsWith("miot:")) return null;
  const rest = entityId.slice("miot:".length);
  const sep = rest.lastIndexOf(":");
  if (sep <= 0) return null;
  const did = rest.slice(0, sep);
  const siid = Number(rest.slice(sep + 1));
  if (!Number.isInteger(siid)) return null;
  return { did, siid };
}

export function hvacModeFromDescription(desc: string): string | null {
  switch (desc.trim().toLowerCase()) {
    case "cool":
    case "cooling":
    case "cold":
      return "cool";
    case "heat":
    case "heating":
    case "warm":
      return "heat";
    case "dry":
    case "dehumidify":
    case "dehumidification":
    case "dehumidifier":
      return "dry";
    case "fan":
    case "fan only":
    case "fan-only":
    case "fan_only":
    case "wind":
    case "ventilate":
      return "fan_only";
    case "auto":
    case "automatic":
    case "smart":
      return "auto";
    default:
      return null;
  }
}

export function parseMiotDeviceSpec(raw: unknown): MiotDeviceSpec | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const type = typeof obj["type"] === "string" ? obj["type"] : "";
  const rawServices = Array.isArray(obj["services"]) ? obj["services"] : null;
  if (!type || !rawServices) return null;

  const services: MiotService[] = [];
  for (const s of rawServices) {
    if (!s || typeof s !== "object") continue;
    const sObj = s as Record<string, unknown>;
    const sIid = typeof sObj["iid"] === "number" ? Math.trunc(sObj["iid"]) : NaN;
    const sType = typeof sObj["type"] === "string" ? sObj["type"] : "";
    if (!Number.isInteger(sIid) || !sType) continue;

    const rawProps = Array.isArray(sObj["properties"]) ? sObj["properties"] : [];
    const properties: MiotProperty[] = [];
    for (const p of rawProps) {
      if (!p || typeof p !== "object") continue;
      const pObj = p as Record<string, unknown>;
      const pIid = typeof pObj["iid"] === "number" ? Math.trunc(pObj["iid"]) : NaN;
      const pType = typeof pObj["type"] === "string" ? pObj["type"] : "";
      if (!Number.isInteger(pIid) || !pType) continue;
      const format = typeof pObj["format"] === "string" ? pObj["format"] : "string";
      const access = Array.isArray(pObj["access"])
        ? pObj["access"].filter((a): a is string => typeof a === "string")
        : [];
      const rawRange = pObj["value-range"] ?? pObj["valueRange"];
      const valueRange = Array.isArray(rawRange)
        ? rawRange.map((v) => Number(v)).filter((v) => Number.isFinite(v))
        : undefined;
      const rawList = pObj["value-list"] ?? pObj["valueList"];
      const valueList: MiotValueListItem[] | undefined = Array.isArray(rawList)
        ? rawList
            .filter((item): item is Record<string, unknown> => Boolean(item && typeof item === "object"))
            .map((item) => ({
              value: Math.trunc(Number(item["value"] ?? 0)),
              description: typeof item["description"] === "string" ? item["description"] : "",
            }))
        : undefined;

      const unit = typeof pObj["unit"] === "string" ? pObj["unit"] : undefined;
      const comment = typeof pObj["comment"] === "string" ? pObj["comment"] : undefined;

      properties.push({
        iid: pIid,
        type: pType,
        format,
        access,
        ...(valueRange ? { valueRange } : {}),
        ...(valueList ? { valueList } : {}),
        ...(unit !== undefined ? { unit } : {}),
        ...(comment !== undefined ? { comment } : {}),
      });
    }

    const rawActions = Array.isArray(sObj["actions"]) ? sObj["actions"] : [];
    const actions: MiotAction[] = [];
    for (const a of rawActions) {
      if (!a || typeof a !== "object") continue;
      const aObj = a as Record<string, unknown>;
      const aIid = typeof aObj["iid"] === "number" ? Math.trunc(aObj["iid"]) : NaN;
      const aType = typeof aObj["type"] === "string" ? aObj["type"] : "";
      const rawIn = Array.isArray(aObj["in"])
        ? aObj["in"].map((v) => Math.trunc(Number(v))).filter((v) => Number.isInteger(v))
        : undefined;
      if (Number.isInteger(aIid) && aType) {
        actions.push({
          iid: aIid,
          type: aType,
          ...(rawIn && rawIn.length > 0 ? { in: rawIn } : {}),
        });
      }
    }

    services.push({
      iid: sIid,
      type: sType,
      properties,
      actions,
    });
  }

  return { type, services };
}

export function parseMiotInstanceIndex(raw: unknown): Record<string, string> {
  if (!raw || typeof raw !== "object") return {};
  const instances = (raw as Record<string, unknown>)["instances"];
  if (!Array.isArray(instances)) return {};

  const bestVersion = new Map<string, { version: number; type: string }>();
  for (const item of instances) {
    if (!item || typeof item !== "object") continue;
    const rec = item as Record<string, unknown>;
    const model = typeof rec["model"] === "string" ? rec["model"] : "";
    const type = typeof rec["type"] === "string" ? rec["type"] : "";
    const version = typeof rec["version"] === "number" ? rec["version"] : 0;
    if (!model || !type) continue;
    const prev = bestVersion.get(model);
    if (!prev || version > prev.version) {
      bestVersion.set(model, { version, type });
    }
  }

  const out: Record<string, string> = {};
  for (const [model, info] of bestVersion.entries()) {
    out[model] = info.type;
  }
  return out;
}

export function inferFallbackSpec(record: Pick<MiDeviceRecord, "model" | "name">): MiotDeviceSpec {
  const m = record.model.toLowerCase();
  const n = record.name.toLowerCase();

  // A guessed (siid, piid) can hit the wrong attribute. Unverified fallbacks stay
  // read-only until a released model spec replaces them (#154). Fridge fallback
  // writes stay with #152 so this change does not redo that migration.
  if (m.includes("light") || m.includes("lamp") || m.includes("bulb") || n.includes("灯")) {
    return {
      type: "urn:miot-spec-v2:device:light:0000A001:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:light:00007802:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read"] },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:brightness:0000000D:fallback:1",
              format: "uint8",
              access: ["read"],
              valueRange: [1, 100, 1],
            },
            {
              iid: 3,
              type: "urn:miot-spec-v2:property:color-temperature:0000000F:fallback:1",
              format: "uint32",
              access: ["read"],
              valueRange: [2700, 6500, 100],
            },
          ],
          actions: [],
        },
      ],
    };
  }

  if (
    m.includes("aircondition") ||
    m.includes("acpartner") ||
    m.includes("heater") ||
    n.includes("空调") ||
    n.includes("取暖") ||
    n.includes("地暖")
  ) {
    return {
      type: "urn:miot-spec-v2:device:air-conditioner:0000A004:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:air-conditioner:0000780F:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read"] },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:mode:00000008:fallback:1",
              format: "uint8",
              access: ["read"],
              valueList: [
                { value: 2, description: "Cool" },
                { value: 5, description: "Heat" },
                { value: 3, description: "Dry" },
                { value: 4, description: "Fan" },
                { value: 1, description: "Auto" },
              ],
            },
            {
              iid: 4,
              type: "urn:miot-spec-v2:property:target-temperature:00000021:fallback:1",
              format: "float",
              access: ["read"],
              valueRange: [16, 30, 0.5],
            },
          ],
          actions: [],
        },
      ],
    };
  }

  if (m.includes(".fan.") || m.endsWith(".fan") || n.includes("风扇") || n.includes("循环扇")) {
    return {
      type: "urn:miot-spec-v2:device:fan:0000A005:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:fan:00007808:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read"] },
            {
              iid: 2,
              type: "urn:miot-spec-v2:property:fan-level:00000016:fallback:1",
              format: "uint8",
              access: ["read"],
              valueList: [
                { value: 1, description: "Level 1" },
                { value: 2, description: "Level 2" },
                { value: 3, description: "Level 3" },
                { value: 4, description: "Level 4" },
              ],
            },
            {
              iid: 3,
              type: "urn:miot-spec-v2:property:horizontal-swing:00000017:fallback:1",
              format: "bool",
              access: ["read"],
            },
          ],
          actions: [],
        },
      ],
    };
  }

  if (
    m.includes("airp") ||
    m.includes("airpurifier") ||
    m.includes("airfresh") ||
    m.includes("humidifier") ||
    n.includes("净化器") ||
    n.includes("空净") ||
    n.includes("新风") ||
    n.includes("加湿")
  ) {
    return {
      type: "urn:miot-spec-v2:device:air-purifier:0000A007:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:air-purifier:00007811:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read"] },
            {
              iid: 4,
              type: "urn:miot-spec-v2:property:mode:00000008:fallback:1",
              format: "uint8",
              access: ["read"],
              valueList: [
                { value: 0, description: "Auto" },
                { value: 1, description: "Sleep" },
                { value: 2, description: "Favorite" },
              ],
            },
          ],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:environment:0000780A:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:relative-humidity:0000000C:fallback:1", format: "uint8", access: ["read"], valueRange: [0, 100, 1] },
            { iid: 4, type: "urn:miot-spec-v2:property:pm2.5-density:00000034:fallback:1", format: "uint16", access: ["read"], valueRange: [0, 1000, 1] },
            { iid: 7, type: "urn:miot-spec-v2:property:temperature:00000020:fallback:1", format: "float", access: ["read"], valueRange: [-30, 100, 1] },
          ],
          actions: [],
        },
        {
          iid: 4,
          type: "urn:miot-spec-v2:service:filter:0000780B:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:filter-life-level:0000001E:fallback:1", format: "uint8", access: ["read"], valueRange: [0, 100, 1] },
          ],
          actions: [],
        },
      ],
    };
  }

  if (m.includes("vacuum") || n.includes("扫地") || n.includes("扫拖")) {
    return {
      type: "urn:miot-spec-v2:device:vacuum:0000A006:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:vacuum:00007810:fallback:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:status:00000007:fallback:1",
              format: "uint8",
              access: ["read"],
              valueList: [
                { value: 1, description: "Idle" },
                { value: 2, description: "Sweeping" },
                { value: 3, description: "Charging" },
                { value: 4, description: "Paused" },
                { value: 5, description: "Go Charging" },
              ],
            },
          ],
          actions: [],
        },
      ],
    };
  }

  if (
    m.includes("camera") ||
    m.includes("cateye") ||
    m.includes("doorbell") ||
    n.includes("摄像") ||
    n.includes("监控") ||
    n.includes("猫眼")
  ) {
    return {
      type: "urn:miot-spec-v2:device:camera:0000A01C:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:camera-control:0000782F:fallback:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:on:00000006:fallback:1",
              format: "bool",
              access: ["read"],
            },
            {
              iid: 3,
              type: "urn:miot-spec-v2:property:night-shot:00000057:fallback:1",
              format: "uint8",
              access: ["read"],
              valueList: [
                { value: 0, description: "Off" },
                { value: 1, description: "On" },
                { value: 2, description: "Auto" },
              ],
            },
          ],
          actions: [],
        },
      ],
    };
  }

  if (
    m.includes("sensor_ht") ||
    m.includes("temphum") ||
    m.includes("weather") ||
    n.includes("温湿度") ||
    n.includes("温度计")
  ) {
    return {
      type: "urn:miot-spec-v2:device:temperature-humidity-sensor:0000A00A:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:temperature-humidity-sensor:00007814:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:temperature:00000020:fallback:1", format: "float", access: ["read"] },
            { iid: 2, type: "urn:miot-spec-v2:property:relative-humidity:0000000C:fallback:1", format: "uint8", access: ["read"] },
          ],
          actions: [],
        },
      ],
    };
  }

  if (m.includes(".kettle.") || m.includes(".waterdispenser.") || n.includes("水壶") || n.includes("饮水")) {
    return {
      type: "urn:miot-spec-v2:device:kettle:0000A009:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:kettle:00007813:fallback:1",
          properties: [
            {
              iid: 1,
              type: "urn:miot-spec-v2:property:status:00000007:fallback:1",
              format: "uint8",
              access: ["read"],
              valueList: [
                { value: 1, description: "Idle" },
                { value: 2, description: "Heating" },
                { value: 3, description: "Keep Warm" },
              ],
            },
            { iid: 2, type: "urn:miot-spec-v2:property:temperature:00000020:fallback:1", format: "float", access: ["read"] },
          ],
          actions: [],
        },
      ],
    };
  }

  if (m.includes("sensor_motion") || n.includes("人体")) {
    return {
      type: "urn:miot-spec-v2:device:motion-sensor:0000A014:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:motion-sensor:00007825:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:motion-state:0000007D:fallback:1", format: "bool", access: ["read"] },
          ],
          actions: [],
        },
      ],
    };
  }

  if (m.includes(".lock.") || n.includes("门锁")) {
    return {
      type: "urn:miot-spec-v2:device:lock:0000A038:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:lock:00007855:fallback:1",
          properties: [],
          actions: [],
        },
      ],
    };
  }

  // A guessed (siid, piid) can hit the wrong attribute, so this fallback is read-only
  // until a verified model-specific spec replaces it (#148).
  if (m.includes(".fridge.") || n.includes("冰箱")) {
    return {
      type: "urn:miot-spec-v2:device:fridge:0000A00F:fallback:1",
      services: [
        {
          iid: 2,
          type: "urn:miot-spec-v2:service:fridge:00007819:fallback:1",
          properties: [],
          actions: [],
        },
        {
          iid: 3,
          type: "urn:miot-spec-v2:service:fridge-chamber:0000781A:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:temperature:00000020:fallback:1", format: "int8", access: ["read"], valueRange: [-30, 100, 1] },
            { iid: 2, type: "urn:miot-spec-v2:property:target-temperature:00000021:fallback:1", format: "int8", access: ["read"], valueRange: [2, 8, 1] },
          ],
          actions: [],
        },
        {
          iid: 4,
          type: "urn:miot-spec-v2:service:fridge-chamber:0000781A:fallback:1",
          properties: [
            { iid: 1, type: "urn:miot-spec-v2:property:temperature:00000020:fallback:1", format: "int8", access: ["read"], valueRange: [-50, 100, 1] },
            { iid: 2, type: "urn:miot-spec-v2:property:target-temperature:00000021:fallback:1", format: "int8", access: ["read"], valueRange: [-24, -15, 1] },
          ],
          actions: [],
        },
      ],
    };
  }

  return {
    type: "urn:miot-spec-v2:device:outlet:0000A002:fallback:1",
    services: [
      {
        iid: 2,
        type: "urn:miot-spec-v2:service:switch:0000780C:fallback:1",
        properties: [
          { iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read"] },
        ],
        actions: [],
      },
    ],
  };
}

export class MiotSpecResolver {
  private readonly specByModel = new Map<string, MiotDeviceSpec>();
  private readonly specByType = new Map<string, MiotDeviceSpec>();
  private typeIndex: Record<string, string> | null = null;
  private indexPromise: Promise<Record<string, string>> | null = null;

  constructor(
    private readonly transport: HttpTransport,
    initialModelSpecs?: Readonly<Record<string, MiotDeviceSpec>>,
    initialModelTypes?: Readonly<Record<string, string>>,
  ) {
    if (initialModelSpecs) {
      for (const [m, s] of Object.entries(initialModelSpecs)) {
        this.specByModel.set(m, s);
      }
    }
    if (initialModelTypes && Object.keys(initialModelTypes).length > 0) {
      this.typeIndex = { ...initialModelTypes };
    }
  }

  exportCachedSpecs(): Record<string, MiotDeviceSpec> {
    const out: Record<string, MiotDeviceSpec> = {};
    for (const [k, v] of this.specByModel.entries()) {
      out[k] = v;
    }
    return out;
  }

  exportKnownModelTypes(models: readonly string[]): Record<string, string> {
    if (!this.typeIndex) return {};
    const out: Record<string, string> = {};
    for (const m of models) {
      const t = this.typeIndex[m];
      if (t) out[m] = t;
    }
    return out;
  }

  async resolveForDevices(devices: readonly MiDeviceRecord[]): Promise<Record<string, MiotDeviceSpec>> {
    const needsIndex = devices.some(
      (d) => !this.specByModel.has(d.model) && (!d.specType || d.specType.trim() === ""),
    );
    if (needsIndex) {
      await this.loadTypeIndex().catch(() => ({}));
    }

    await Promise.all(
      devices.map(async (dev) => {
        await this.resolve(dev);
      }),
    );

    return this.exportCachedSpecs();
  }

  async resolve(device: MiDeviceRecord): Promise<MiotDeviceSpec> {
    const existing = this.specByModel.get(device.model);
    if (existing) return existing;

    let urn = device.specType && device.specType.trim() !== "" ? device.specType.trim() : null;
    if (!urn) {
      const idx = await this.loadTypeIndex().catch(() => ({} as Record<string, string>));
      urn = idx[device.model] ?? null;
    }

    if (urn) {
      const fetched = await this.fetchInstance(urn);
      if (fetched) {
        this.specByModel.set(device.model, fetched);
        return fetched;
      }
    }

    const fallback = inferFallbackSpec(device);
    this.specByModel.set(device.model, fallback);
    return fallback;
  }

  private async loadTypeIndex(): Promise<Record<string, string>> {
    if (this.typeIndex && Object.keys(this.typeIndex).length > 100) {
      return this.typeIndex;
    }
    if (this.indexPromise) {
      return this.indexPromise;
    }
    this.indexPromise = (async () => {
      try {
        const resp = await this.transport({
          url: "https://miot-spec.org/miot-spec-v2/instances?status=released",
          method: "GET",
          timeoutMs: 45000,
        });
        if (resp.status === 200) {
          const parsed = parseMiotInstanceIndex(JSON.parse(resp.body));
          this.typeIndex = { ...(this.typeIndex ?? {}), ...parsed };
          return this.typeIndex;
        }
      } catch {
        // network fallback
      }
      return this.typeIndex ?? {};
    })();
    return this.indexPromise;
  }

  private async fetchInstance(urn: string): Promise<MiotDeviceSpec | null> {
    const cached = this.specByType.get(urn);
    if (cached) return cached;
    try {
      const resp = await this.transport({
        url: `https://miot-spec.org/miot-spec-v2/instance?type=${encodeURIComponent(urn)}`,
        method: "GET",
        timeoutMs: 15000,
      });
      if (resp.status !== 200) return null;
      const spec = parseMiotDeviceSpec(JSON.parse(resp.body));
      if (spec && spec.services.length > 0) {
        this.specByType.set(urn, spec);
        return spec;
      }
    } catch {
      // ignore instance fetch failure
    }
    return null;
  }
}
