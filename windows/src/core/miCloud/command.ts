import type { DeviceCommand } from "../models.js";
import type { MiotActionCall, MiotPropWrite } from "./client.js";
import {
  hvacModeFromDescription,
  miotShortName,
  parseMiotAddress,
  type MiotDeviceSpec,
  type MiotProperty,
  type MiotService,
} from "./spec.js";

export type MiotWrite =
  | { readonly kind: "setProps"; readonly writes: readonly MiotPropWrite[] }
  | { readonly kind: "action"; readonly call: MiotActionCall };

export const MiotCommandMapper = {
  map(command: DeviceCommand, spec: MiotDeviceSpec): MiotWrite {
    const addr = parseMiotAddress(command.entityId);
    if (!addr) throw new Error(`Invalid MIoT address: ${command.entityId}`);
    const service = spec.services.find((s) => s.iid === addr.siid);
    if (!service) throw new Error(`Service ${addr.siid} not found`);

    const findProp = (short: string, searchAll = false) => {
      const local = service.properties.find((p) => miotShortName(p.type) === short && p.access.includes("write"));
      if (local) return { service, prop: local };
      if (searchAll) {
        const others = [
          ...spec.services.filter((s) => miotShortName(s.type) === "fan-control"),
          ...spec.services.filter((s) => s.iid !== service.iid),
        ];
        for (const s of others) {
          const p = s.properties.find((pr) => miotShortName(pr.type) === short && pr.access.includes("write"));
          if (p) return { service: s, prop: p };
        }
      }
      throw new Error(`Unsupported property: ${short}`);
    };

    const findListProp = (short: string, description: string, searchAll = false) => {
      const services = [
        service,
        ...(searchAll
          ? [
              ...spec.services.filter((s) => miotShortName(s.type) === "fan-control"),
              ...spec.services.filter((s) => miotShortName(s.type) === "air-purifier-favorite"),
              ...spec.services.filter((s) => miotShortName(s.type) === "air-fresh-favorite"),
              ...spec.services.filter((s) => s.iid !== service.iid),
            ]
          : []),
      ];
      for (const s of services) {
        for (const p of s.properties) {
          if (miotShortName(p.type) === short && p.access.includes("write")) {
            const item = p.valueList?.find(
              (i) => i.description.toLowerCase() === description.toLowerCase()
            );
            if (item) return { service: s, prop: p, item };
          }
        }
      }
      return null;
    };

    const coerce = (prop: MiotProperty, val: number): number => {
      let n = val;
      if (prop.valueRange && prop.valueRange.length >= 2) {
        const lo = prop.valueRange[0] ?? n;
        const hi = prop.valueRange[1] ?? n;
        n = Math.min(hi, Math.max(lo, n));
      }
      if (prop.format.startsWith("int") || prop.format.startsWith("uint")) {
        return Math.round(n);
      }
      const step = prop.valueRange?.[2];
      if (step && step > 0) {
        const base = prop.valueRange?.[0] ?? 0;
        n = base + Math.round((n - base) / step) * step;
      }
      return n;
    };

    const powerOnPrefix = (): MiotPropWrite[] => {
      const onP = service.properties.find((p) => miotShortName(p.type) === "on" && p.access.includes("write"));
      return onP ? [{ did: addr.did, siid: service.iid, piid: onP.iid, value: true }] : [];
    };

    switch (command.kind) {
      case "setLightPower":
      case "setClimatePower":
      case "setFanPower": {
        const { prop } = findProp("on");
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: service.iid, piid: prop.iid, value: command.isOn }],
        };
      }
      case "setLightBrightness": {
        if (command.percent <= 0) {
          const { prop } = findProp("on");
          return {
            kind: "setProps",
            writes: [{ did: addr.did, siid: service.iid, piid: prop.iid, value: false }],
          };
        }
        const { prop } = findProp("brightness");
        const max = prop.valueRange?.[1] ?? 100;
        const raw = max > 0 && max !== 100 ? (command.percent / 100) * max : command.percent;
        return {
          kind: "setProps",
          writes: [
            ...powerOnPrefix(),
            { did: addr.did, siid: service.iid, piid: prop.iid, value: coerce(prop, raw) },
          ],
        };
      }
      case "setLightColorTemp": {
        const { prop } = findProp("color-temperature");
        return {
          kind: "setProps",
          writes: [
            ...powerOnPrefix(),
            { did: addr.did, siid: service.iid, piid: prop.iid, value: coerce(prop, command.kelvin) },
          ],
        };
      }
      case "setLightEffect": {
        const found = findListProp("mode", command.effect);
        if (!found) throw new Error(`Unsupported effect: ${command.effect}`);
        return {
          kind: "setProps",
          writes: [
            ...powerOnPrefix(),
            { did: addr.did, siid: found.service.iid, piid: found.prop.iid, value: found.item.value },
          ],
        };
      }
      case "setClimateMode": {
        const { prop: onProp } = findProp("on");
        if (command.hvacMode === "off") {
          return {
            kind: "setProps",
            writes: [{ did: addr.did, siid: service.iid, piid: onProp.iid, value: false }],
          };
        }
        const writes: MiotPropWrite[] = [
          { did: addr.did, siid: service.iid, piid: onProp.iid, value: true },
        ];
        const modeProp = service.properties.find(
          (p) => miotShortName(p.type) === "mode" && p.access.includes("write")
        );
        const item = modeProp?.valueList?.find(
          (i) => hvacModeFromDescription(i.description) === command.hvacMode
        );
        if (modeProp && item) {
          writes.push({ did: addr.did, siid: service.iid, piid: modeProp.iid, value: item.value });
        }
        return { kind: "setProps", writes };
      }
      case "setClimateTemperature": {
        const { prop } = findProp("target-temperature");
        return {
          kind: "setProps",
          writes: [
            { did: addr.did, siid: service.iid, piid: prop.iid, value: coerce(prop, command.temperature) },
          ],
        };
      }
      case "setClimateFanMode": {
        const found = findListProp("fan-level", command.fanMode, true);
        if (!found) throw new Error(`Unsupported fan mode: ${command.fanMode}`);
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: found.service.iid, piid: found.prop.iid, value: found.item.value }],
        };
      }
      case "setFanPercentage": {
        if (command.percent <= 0) {
          const { prop } = findProp("on");
          return {
            kind: "setProps",
            writes: [{ did: addr.did, siid: service.iid, piid: prop.iid, value: false }],
          };
        }
        let speedFound: { service: MiotService; prop: MiotProperty } | null = null;
        const directRange = service.properties.find(
          (p) => miotShortName(p.type) === "fan-level" && p.access.includes("write") && p.valueRange !== undefined
        );
        if (directRange) {
          speedFound = { service, prop: directRange };
        }
        if (!speedFound) {
          const favServices = [
            ...spec.services.filter((s) => miotShortName(s.type) === "air-purifier-favorite"),
            ...spec.services.filter((s) => miotShortName(s.type) === "air-fresh-favorite"),
            ...spec.services.filter((s) => miotShortName(s.type) === "motor-speed"),
            ...spec.services.filter((s) => miotShortName(s.type) === "custom-service"),
            ...spec.services.filter((s) => miotShortName(s.type) === "fan-control"),
          ];
          const candidates = ["fan-level", "favorite-fan-level", "favorite-level", "favorite-speed"];
          for (const name of candidates) {
            if (speedFound) break;
            for (const s of favServices) {
              const p = s.properties.find((pr) => miotShortName(pr.type) === name && pr.access.includes("write"));
              if (p) {
                speedFound = { service: s, prop: p };
                break;
              }
            }
          }
        }
        if (!speedFound) {
          const directList = service.properties.find(
            (p) => miotShortName(p.type) === "fan-level" && p.access.includes("write")
          );
          if (directList) speedFound = { service, prop: directList };
        }
        if (!speedFound) throw new Error("Unsupported property: fan-level");

        const clamped = Math.max(0, Math.min(100, command.percent));
        let writeVal: number;
        const range = speedFound.prop.valueRange;
        const list = speedFound.prop.valueList;
        if (range && range.length >= 2 && (range[1] ?? 0) > (range[0] ?? 0)) {
          const lo = range[0] ?? 0;
          const hi = range[1] ?? 100;
          const raw = lo > 1 ? lo + (clamped / 100) * (hi - lo) : hi !== 100 ? (clamped / 100) * hi : clamped;
          writeVal = coerce(speedFound.prop, raw);
        } else if (list && list.length > 0) {
          const vals = list.map((i) => i.value);
          const lo = Math.min(...vals);
          const hi = Math.max(...vals);
          const target = lo === 0 && hi > 0 ? (clamped / 100) * hi : hi > lo ? lo + (clamped / 100) * (hi - lo) : lo;
          let best = list[0]!;
          for (const item of list) {
            if (Math.abs(item.value - target) < Math.abs(best.value - target)) {
              best = item;
            }
          }
          writeVal = best.value;
        } else {
          writeVal = coerce(speedFound.prop, clamped);
        }

        const prefix = [...powerOnPrefix()];
        if (speedFound.service.iid !== service.iid) {
          const favMode = findListProp("mode", "Favorite");
          if (favMode) {
            prefix.push({ did: addr.did, siid: favMode.service.iid, piid: favMode.prop.iid, value: favMode.item.value });
          }
        }
        return {
          kind: "setProps",
          writes: [
            ...prefix,
            { did: addr.did, siid: speedFound.service.iid, piid: speedFound.prop.iid, value: writeVal },
          ],
        };
      }
      case "setFanPresetMode": {
        const found = findListProp("mode", command.presetMode) ?? findListProp("fan-level", command.presetMode, true);
        if (!found) throw new Error(`Unsupported preset: ${command.presetMode}`);
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: found.service.iid, piid: found.prop.iid, value: found.item.value }],
        };
      }
      case "setFanOscillating": {
        const { prop } = findProp("horizontal-swing");
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: service.iid, piid: prop.iid, value: command.oscillating }],
        };
      }
      case "setSwitch": {
        const sShort = miotShortName(service.type);
        const targetProp =
          service.properties.find(
            (p) => miotShortName(p.type) === "on" && p.access.includes("write")
          ) ??
          (sShort === "speaker"
            ? service.properties.find(
                (p) => miotShortName(p.type) === "mute" && p.access.includes("write")
              )
            : undefined) ??
          (sShort === "intelligent-speaker"
            ? service.properties.find(
                (p) => miotShortName(p.type) === "sleep-mode" && p.access.includes("write")
              )
            : undefined) ??
          service.properties.find(
            (p) => miotShortName(p.type) === "motion-detection" && p.access.includes("write")
          ) ??
          service.properties.find(
            (p) => miotShortName(p.type) === "physical-controls-locked" && p.access.includes("write")
          );
        if (targetProp) {
          return {
            kind: "setProps",
            writes: [{ did: addr.did, siid: service.iid, piid: targetProp.iid, value: command.isOn }],
          };
        }
        const candidates = command.isOn
          ? ["start-cook", "resume-cook"]
          : ["cancel-cooking", "pause"];
        for (const name of candidates) {
          for (const s of [service, ...spec.services.filter((sv) => sv.iid !== service.iid)]) {
            const act = s.actions.find(
              (a) => miotShortName(a.type) === name && (a.in?.length ?? 0) === 0
            );
            if (act) {
              return {
                kind: "action",
                call: { did: addr.did, siid: s.iid, aiid: act.iid, inputs: [] },
              };
            }
          }
        }
        throw new Error("Unsupported property: on");
      }
      case "setSelectOption": {
        const found = findListProp("mode", command.option) ?? findListProp("night-shot", command.option);
        if (!found) throw new Error(`Unsupported select option: ${command.option}`);
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: found.service.iid, piid: found.prop.iid, value: found.item.value }],
        };
      }
      case "setNumberValue": {
        const { prop } = findProp("target-temperature");
        return {
          kind: "setProps",
          writes: [{ did: addr.did, siid: service.iid, piid: prop.iid, value: coerce(prop, command.value) }],
        };
      }
      case "vacuumAction": {
        const candidates =
          command.action === "start"
            ? ["start-sweep", "start-clean", "start-sweep-mop", "start-mop"]
            : command.action === "pause"
              ? ["pause-sweeping", "pause", "stop-sweeping", "stop-clean"]
              : ["start-charge", "stop-and-gocharge", "return-to-charge", "go-charging"];
        for (const name of candidates) {
          for (const s of [service, ...spec.services.filter((sv) => sv.iid !== service.iid)]) {
            const act = s.actions.find((a) => miotShortName(a.type) === name);
            if (act) {
              return {
                kind: "action",
                call: { did: addr.did, siid: s.iid, aiid: act.iid, inputs: [] },
              };
            }
          }
        }
        throw new Error(`Unsupported vacuum action: ${command.action}`);
      }
      case "activateScene":
        throw new Error("Scenes are not Miot device properties");
      default: {
        const _exhaustive: never = command;
        return _exhaustive;
      }
    }
  },
};
