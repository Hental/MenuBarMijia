import { MiCloudCrypto } from "../miCloudCrypto.js";
import {
  asIdString,
  MiCloudError,
  miApiBaseURL,
  parseJsonObject,
  type HttpTransport,
  type MiSession,
} from "./session.js";
import type { MiotDeviceSpec } from "./spec.js";

export interface MiDeviceRecord {
  readonly did: string;
  readonly name: string;
  readonly model: string;
  readonly isOnline: boolean;
  readonly specType: string | null;
  /** Split key of a multi-key panel (did like `<parent>.s2`): MIoT calls go to the parent did, switch service `splitSiid`. */
  readonly splitParentDid?: string | null;
  readonly splitSiid?: number | null;
}

/** The did MIoT property and action calls address. */
export function miotDid(record: MiDeviceRecord): string {
  return record.splitParentDid ?? record.did;
}

/** Narrows a panel spec to the switch service a split key controls. */
export function specForRecord(record: MiDeviceRecord, spec: MiotDeviceSpec): MiotDeviceSpec {
  if (!record.splitParentDid || record.splitSiid == null) return spec;
  return { ...spec, services: spec.services.filter((s) => s.iid === record.splitSiid) };
}

export interface MiRoom {
  readonly id: string;
  readonly name: string;
  readonly dids: readonly string[];
  readonly homeId?: string;
  readonly homeName?: string;
  readonly isSharedHome?: boolean;
}

export interface MiotPropKey {
  readonly did: string;
  readonly siid: number;
  readonly piid: number;
}

export function propKeyString(k: MiotPropKey): string {
  return `${k.did}.${k.siid}.${k.piid}`;
}

export interface MiotPropWrite {
  readonly did: string;
  readonly siid: number;
  readonly piid: number;
  readonly value: unknown;
}

export interface MiotActionCall {
  readonly did: string;
  readonly siid: number;
  readonly aiid: number;
  readonly inputs: readonly unknown[];
}

export class MiCloudClient {
  private readonly session: MiSession;
  private readonly transport: HttpTransport;
  private readonly userAgent: string;

  constructor(session: MiSession, transport: HttpTransport) {
    this.session = session;
    this.transport = transport;
    this.userAgent = "abcdefghijklmnoqrs-ABCDEABCDEABC APP/com.xiaomi.mihome APPV/10.5.201";
  }

  async request(api: string, data: unknown): Promise<unknown> {
    const cleanPath = "/" + api.replace(/^\/+|\/+$/g, "");
    const url = `${miApiBaseURL(this.session.region)}${cleanPath}`;
    const nonce = MiCloudCrypto.makeNonce();
    const signed = MiCloudCrypto.signedNonce(this.session.ssecurity, nonce);
    const dataStr = MiCloudCrypto.compactJSONString(data);
    const fields = MiCloudCrypto.encryptParams(cleanPath, dataStr, this.session.ssecurity, nonce);

    const resp = await this.transport({
      url,
      method: "POST",
      headers: {
        "User-Agent": this.userAgent,
        "x-xiaomi-protocal-flag-cli": "PROTOCAL-HTTP2",
        "MIOT-ENCRYPT-ALGORITHM": "ENCRYPT-RC4",
        "Accept-Encoding": "identity",
        "Content-Type": "application/x-www-form-urlencoded",
        Cookie: [
          `userId=${this.session.userId}`,
          `serviceToken=${this.session.serviceToken}`,
          `yetAnotherServiceToken=${this.session.serviceToken}`,
          "locale=zh_CN",
          "timezone=GMT+08:00",
          "is_daylight=0",
          "dst_offset=0",
          "channel=MI_APP_STORE",
        ].join("; "),
      },
      body: MiCloudCrypto.formURLEncode(fields),
    });

    return MiCloudClient.decodeResponse(resp.body, resp.status, signed);
  }

  static decodeResponse(body: string, statusCode: number, signedNonce: string): unknown {
    if (statusCode === 401 || statusCode === 403) {
      throw new MiCloudError("sessionExpired", "米家登录已过期，请重新扫码");
    }
    const plain = parseJsonObject(body);
    if (plain) {
      return MiCloudClient.unwrapResult(plain);
    }
    if (statusCode !== 200) {
      throw new MiCloudError("http", `米家云服务 HTTP ${statusCode}`, statusCode);
    }
    let decryptedText: string;
    try {
      decryptedText = MiCloudCrypto.decryptResponse(body, signedNonce);
    } catch {
      throw new MiCloudError("badResponse", "米家云响应无法解密");
    }
    const json = parseJsonObject(decryptedText);
    if (!json) {
      throw new MiCloudError("badResponse", "米家云解密后非 JSON");
    }
    return MiCloudClient.unwrapResult(json);
  }

  static unwrapResult(json: Record<string, unknown>): unknown {
    const code = typeof json["code"] === "number" ? Math.trunc(json["code"]) : 0;
    const message =
      typeof json["message"] === "string"
        ? json["message"]
        : typeof json["desc"] === "string"
          ? json["desc"]
          : "";
    if (code === 0) return json["result"] ?? null;
    const lower = message.toLowerCase();
    if (
      code === 2 ||
      code === 3 ||
      lower.includes("auth err") ||
      lower.includes("servicetoken_expired") ||
      lower.includes("token expired") ||
      lower.includes("invalid signature")
    ) {
      throw new MiCloudError("sessionExpired", "米家登录已过期，请重新扫码", code);
    }
    throw new MiCloudError("api", `米家云指令失败 (${code})：${message}`, code);
  }

  static parseDeviceList(result: unknown): MiDeviceRecord[] {
    if (!result || typeof result !== "object") return [];
    const list = (result as Record<string, unknown>)["list"];
    if (!Array.isArray(list)) return [];
    const out: MiDeviceRecord[] = [];
    for (const item of list) {
      if (!item || typeof item !== "object") continue;
      const rec = item as Record<string, unknown>;
      const did = asIdString(rec["did"]);
      const model = typeof rec["model"] === "string" ? rec["model"] : null;
      if (!did || !model) continue;
      const extra = rec["extra"] && typeof rec["extra"] === "object" ? (rec["extra"] as Record<string, unknown>) : {};
      const split = extra["split"] && typeof extra["split"] === "object" ? (extra["split"] as Record<string, unknown>) : null;
      const splitParentDid = split ? asIdString(split["parentId"]) : null;
      const splitSiid = split && typeof split["moduleId"] === "number" ? Math.trunc(split["moduleId"]) : null;
      out.push({
        did,
        name: typeof rec["name"] === "string" ? rec["name"] : model,
        model,
        isOnline: typeof rec["isOnline"] === "boolean" ? rec["isOnline"] : true,
        specType: typeof rec["spec_type"] === "string" ? rec["spec_type"] : null,
        ...(splitParentDid && splitSiid !== null ? { splitParentDid, splitSiid } : {}),
      });
    }
    return out;
  }

  /** Homes another account shared with this one arrive under `share_home_list`, not `homelist` (#134). */
  static parseRooms(result: unknown): MiRoom[] {
    if (!result || typeof result !== "object") return [];
    const obj = result as Record<string, unknown>;
    const rooms: MiRoom[] = [];
    const seenHomes = new Set<string>();
    const appendHomes = (homes: readonly unknown[], shared: boolean) => {
      for (const home of homes) {
        if (!home || typeof home !== "object") continue;
        const h = home as Record<string, unknown>;
        const homeId = asIdString(h["id"]) ?? "";
        if (homeId) {
          if (seenHomes.has(homeId)) continue;
          seenHomes.add(homeId);
        }
        const homeName = typeof h["name"] === "string" ? h["name"] : "";
        const sharedFlag = shared ? { isSharedHome: true as const } : {};
        const roomlist = h["roomlist"];
        if (Array.isArray(roomlist)) {
          for (const rm of roomlist) {
            if (!rm || typeof rm !== "object") continue;
            const r = rm as Record<string, unknown>;
            const id = asIdString(r["id"]);
            if (!id) continue;
            const rawDids = Array.isArray(r["dids"]) ? r["dids"] : [];
            const dids = rawDids.map(asIdString).filter((d): d is string => d !== null);
            rooms.push({
              id,
              name: typeof r["name"] === "string" ? r["name"] : "",
              dids,
              homeId,
              homeName,
              ...sharedFlag,
            });
          }
        }
        const homeDids = Array.isArray(h["dids"])
          ? h["dids"].map(asIdString).filter((d): d is string => d !== null)
          : [];
        if (homeId && homeDids.length > 0) {
          rooms.push({ id: `home_${homeId}`, name: "", dids: homeDids, homeId, homeName, ...sharedFlag });
        }
      }
    };
    appendHomes(Array.isArray(obj["homelist"]) ? obj["homelist"] : [], false);
    appendHomes(Array.isArray(obj["share_home_list"]) ? obj["share_home_list"] : [], true);
    return rooms;
  }

  static parseLightGroupMembers(result: unknown): Map<string, string[]> {
    const groups = new Map<string, string[]>();
    if (!Array.isArray(result)) return groups;
    for (const item of result) {
      if (!item || typeof item !== "object") continue;
      const record = item as Record<string, unknown>;
      const groupDid = asIdString(record["group_did"]);
      if (!groupDid) continue;
      const raw = [record["member_ship"], record["membership"]].find(
        (value): value is Record<string, unknown> =>
          value !== null && typeof value === "object" && !Array.isArray(value),
      );
      if (!raw) continue;
      const members = groups.get(groupDid) ?? [];
      for (const memberDid of Object.keys(raw)) {
        if (memberDid.length > 0 && !members.includes(memberDid)) members.push(memberDid);
      }
      groups.set(groupDid, members);
    }
    return groups;
  }

  /**
   * `v2/home/device_list_page` also returns the split keys of multi-key Mesh panels, which
   * `home/device_list` omits even with `get_split_device`; fall back to the latter on failure.
   */
  async deviceList(): Promise<MiDeviceRecord[]> {
    try {
      return await this.deviceListPaged();
    } catch (err) {
      if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
      return this.legacyDeviceList();
    }
  }

  /**
   * Devices of homes shared with this account are missing from the unfiltered list; the cloud
   * returns them only when asked for by did, as Xiaomi's own `xiaomi_home` integration does (#134).
   */
  async devicesByDids(dids: string[]): Promise<MiDeviceRecord[]> {
    const records: MiDeviceRecord[] = [];
    for (let start = 0; start < dids.length; start += 150) {
      records.push(...(await this.deviceListPaged(dids.slice(start, start + 150))));
    }
    const seen = new Set<string>();
    return records.filter((r) => !seen.has(r.did) && (seen.add(r.did), true));
  }

  private async deviceListPaged(dids?: string[]): Promise<MiDeviceRecord[]> {
    const records: MiDeviceRecord[] = [];
    let startDid = "";
    for (let page = 0; page < 20; page++) {
      const data: Record<string, unknown> = { get_split_device: true, support_smart_home: true, limit: 200 };
      if (dids) data["dids"] = dids;
      if (startDid) data["start_did"] = startDid;
      const res = await this.request("v2/home/device_list_page", data);
      records.push(...MiCloudClient.parseDeviceList(res));
      const obj = res && typeof res === "object" ? (res as Record<string, unknown>) : {};
      const next = asIdString(obj["next_start_did"]) ?? "";
      if (obj["has_more"] !== true || !next || next === startDid) break;
      startDid = next;
    }
    const seen = new Set<string>();
    return records.filter((r) => !seen.has(r.did) && (seen.add(r.did), true));
  }

  private async legacyDeviceList(): Promise<MiDeviceRecord[]> {
    const res = await this.request("home/device_list", {
      getVirtualModel: true,
      getHuamiDevices: 1,
      get_split_device: false,
      support_smart_home: true,
    });
    return MiCloudClient.parseDeviceList(res);
  }

  async homeRooms(): Promise<MiRoom[]> {
    try {
      const merged = await this.request("v2/homeroom/gethome_merged", {
        fg: true,
        fetch_share: true,
        fetch_share_dev: true,
        limit: 300,
        app_ver: 7,
        plat_form: 0,
      });
      return MiCloudClient.parseRooms(merged);
    } catch (err) {
      if (err instanceof MiCloudError && err.kind === "sessionExpired") throw err;
      const fallback = await this.request("v2/homeroom/gethome", {
        fg: true,
        fetch_share: true,
        fetch_share_dev: true,
        limit: 300,
        app_ver: 7,
      });
      return MiCloudClient.parseRooms(fallback);
    }
  }

  /** Maps each Xiaomi light group among `groupDids` to its member device dids, in first-seen order. */
  async lightGroupMembers(groupDids: readonly string[]): Promise<Map<string, string[]>> {
    const unique = [...new Set(groupDids)].filter((did) => did.startsWith("group."));
    const members = new Map<string, string[]>();
    for (let start = 0; start < unique.length; start += 100) {
      const result = await this.request("v2/groupv2/query_status", {
        group_did: unique.slice(start, start + 100),
      });
      for (const [groupDid, memberDids] of MiCloudClient.parseLightGroupMembers(result)) {
        const merged = members.get(groupDid) ?? [];
        for (const memberDid of memberDids) {
          if (!merged.includes(memberDid)) merged.push(memberDid);
        }
        members.set(groupDid, merged);
      }
    }
    return members;
  }

  async getProps(keys: readonly MiotPropKey[]): Promise<Map<string, unknown>> {
    const values = new Map<string, unknown>();
    const chunkSize = 100;
    for (let start = 0; start < keys.length; start += chunkSize) {
      const chunk = keys.slice(start, start + chunkSize);
      const params = chunk.map((k) => ({ did: k.did, siid: k.siid, piid: k.piid }));
      const result = await this.request("miotspec/prop/get", { params });
      if (Array.isArray(result)) {
        for (const item of result) {
          if (!item || typeof item !== "object") continue;
          const obj = item as Record<string, unknown>;
          const did = asIdString(obj["did"]);
          const siid = typeof obj["siid"] === "number" ? Math.trunc(obj["siid"]) : null;
          const piid = typeof obj["piid"] === "number" ? Math.trunc(obj["piid"]) : null;
          const code = typeof obj["code"] === "number" ? Math.trunc(obj["code"]) : 0;
          if (did && siid !== null && piid !== null && code === 0 && "value" in obj) {
            values.set(propKeyString({ did, siid, piid }), obj["value"]);
          }
        }
      }
    }
    return values;
  }

  async setProps(writes: readonly MiotPropWrite[]): Promise<void> {
    const params = writes.map((w) => ({
      did: w.did,
      siid: w.siid,
      piid: w.piid,
      value: w.value,
    }));
    const result = await this.request("miotspec/prop/set", { params });
    if (Array.isArray(result)) {
      for (const item of result) {
        if (item && typeof item === "object") {
          const code = typeof (item as Record<string, unknown>)["code"] === "number"
            ? Math.trunc((item as Record<string, unknown>)["code"] as number)
            : 0;
          if (code < 0) {
            throw new MiCloudError("api", "设备未响应或离线", code);
          }
        }
      }
    }
  }

  async action(call: MiotActionCall): Promise<void> {
    await this.callAction(call);
  }

  async callAction(call: MiotActionCall): Promise<unknown> {
    const result = await this.request("miotspec/action", {
      params: {
        did: call.did,
        siid: call.siid,
        aiid: call.aiid,
        in: call.inputs,
      },
    });
    if (result && typeof result === "object") {
      const code = typeof (result as Record<string, unknown>)["code"] === "number"
        ? Math.trunc((result as Record<string, unknown>)["code"] as number)
        : 0;
      if (code < 0) {
        throw new MiCloudError("api", "设备未响应或离线", code);
      }
    }
    return result;
  }
}

// MARK: - MIoT Spec & Synthesis
