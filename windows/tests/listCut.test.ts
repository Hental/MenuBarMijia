import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { catalogEntry } from "../src/core/i18n.js";
import type { SmartDevice } from "../src/core/models.js";
import {
  KIND_CHIP,
  KIND_RANK,
  filterByListCut,
  foldGroupedLights,
  kindChips,
  memberGroupOwners,
  showsKindRow,
  type DeviceKindTag,
  type DeviceListCut,
} from "../src/ui/listCut.js";

function light(id: string, roomName: string, isOnline = true): SmartDevice {
  return {
    id,
    name: id,
    roomId: roomName,
    roomName,
    model: "m",
    isOnline,
    kind: {
      kind: "light",
      entityId: id,
      isOn: true,
      brightnessPercent: null,
      colorTempKelvin: null,
      minKelvin: 2700,
      maxKelvin: 6500,
      currentEffect: null,
      availableEffects: [],
    },
  };
}

function climate(id: string, name: string, roomName: string): SmartDevice {
  return {
    id,
    name,
    roomId: roomName,
    roomName,
    model: "m",
    isOnline: true,
    kind: {
      kind: "climate",
      entityId: id,
      isOn: true,
      hvacMode: "heat",
      availableModes: ["heat", "off"],
      targetTemperature: 22,
      currentTemperature: null,
      minTemp: 16,
      maxTemp: 30,
      step: 1,
      fanMode: null,
      availableFanModes: [],
    },
  };
}

function fan(id: string, name: string, roomName: string): SmartDevice {
  return {
    id,
    name,
    roomId: roomName,
    roomName,
    model: "m",
    isOnline: true,
    kind: {
      kind: "fan",
      entityId: id,
      isOn: true,
      percentage: 40,
      presetMode: null,
      availablePresetModes: [],
      isOscillating: false,
    },
  };
}

function sensor(id: string, roomName: string): SmartDevice {
  return {
    id,
    name: id,
    roomId: roomName,
    roomName,
    model: "m",
    isOnline: true,
    kind: { kind: "sensor", temperature: 22, humidity: 40, battery: 90 },
  };
}

const heater = climate("climate.heater", "电暖器", "客厅");
const purifier = fan("fan.purifier", "净化器", "书房");
const living = light("light.living", "客厅");
const study = light("light.study", "书房");
const offline = light("light.offline", "书房", false);

describe("device list cut", () => {
  it("keeps online lights from every room and drops the other kinds", () => {
    const cut: DeviceListCut = { kind: "deviceKind", tag: "light" };
    const shown = filterByListCut([purifier, study, heater, living, offline], cut, true);
    assert.deepEqual(shown.map((dev) => dev.id), ["light.study", "light.living"]);
  });

  it("keeps a heater on climate and a purifier on fan", () => {
    const devices = [purifier, heater, living];
    assert.deepEqual(
      filterByListCut(devices, { kind: "deviceKind", tag: "climate" }, true).map((dev) => dev.name),
      ["电暖器"],
    );
    assert.deepEqual(
      filterByListCut(devices, { kind: "deviceKind", tag: "fan" }, true).map((dev) => dev.name),
      ["净化器"],
    );
  });

  it("compares the room arm by room name", () => {
    const shown = filterByListCut(
      [living, study],
      { kind: "room", roomName: "客厅" },
      false,
    );
    assert.deepEqual(shown.map((dev) => dev.id), ["light.living"]);
  });

  it("orders chips by rank, and keeps a selected tag that has no device", () => {
    assert.deepEqual(
      kindChips([purifier, living, heater], { kind: "all" }, false),
      ["climate", "light", "fan"],
    );
    const selected: DeviceListCut = { kind: "deviceKind", tag: "plug" };
    assert.deepEqual(
      kindChips([sensor("sensor.living", "客厅"), heater], selected, true),
      ["climate", "plug", "sensor"],
    );
  });

  it("shows the kind row on a room cut when two tags exist", () => {
    const chips: DeviceKindTag[] = ["climate", "light"];
    assert.equal(showsKindRow(chips, { kind: "room", roomName: "客厅" }), true);
    assert.equal(showsKindRow(["light"], { kind: "all" }), false);
    assert.equal(showsKindRow(["light"], { kind: "deviceKind", tag: "light" }), true);
  });

  it("uses catalog keys for every chip title and hint", () => {
    assert.deepEqual(
      Object.entries(KIND_RANK).sort((a, b) => a[1] - b[1]).map(([tag]) => tag),
      ["climate", "light", "plug", "fan", "vacuum", "fridge", "camera", "sensor"],
    );
    assert.equal(KIND_CHIP.light.title, "灯");
    assert.equal(KIND_CHIP.climate.title, "空调");
    assert.equal(KIND_CHIP.climate.hint, "也包括电暖器、温控器和电热毯");
    assert.equal(KIND_CHIP.fan.title, "风扇");
    assert.equal(KIND_CHIP.fan.hint, "也包括净化器、新风、加湿器和除湿器");
    assert.equal(KIND_CHIP.plug.title, "插座");
    assert.equal(KIND_CHIP.plug.hint, "也包括开关、香薰，以及带开关的小家电");
    assert.equal(KIND_CHIP.vacuum.title, "扫地机");
    assert.equal(KIND_CHIP.fridge.title, "冰箱");
    assert.equal(KIND_CHIP.camera.title, "摄像机");
    assert.equal(KIND_CHIP.sensor.title, "传感器");
    assert.equal(KIND_CHIP.sensor.hint, "也包括没有开关的小家电");
    assert.equal(KIND_CHIP.light.hint, undefined);
    for (const chip of Object.values(KIND_CHIP)) {
      assert.ok(catalogEntry(chip.title), chip.title);
      if (chip.hint !== undefined) assert.ok(catalogEntry(chip.hint), chip.hint);
    }
  });
});

describe("light-group folding (#214)", () => {
  it("maps every member did to its first owning group", () => {
    const owners = memberGroupOwners(
      new Map([
        ["group.living", ["dev.a", "dev.b"]],
        ["group.bedroom", ["dev.b", "dev.c"]],
      ]),
    );
    assert.deepEqual([...owners], [
      ["dev.a", "group.living"],
      ["dev.b", "group.living"],
      ["dev.c", "group.bedroom"],
    ]);
  });

  it("folds members into a listed group card and leaves unknown devices alone", () => {
    const group = light("group.living", "客厅");
    const memberA = light("dev.a", "客厅");
    const memberB = light("dev.b", "客厅");
    const unrelated = light("dev.other", "客厅");
    const devices = [group, memberA, memberB, unrelated];
    const owners = new Map<string, string>([
      ["dev.a", "group.living"],
      ["dev.b", "group.living"],
      ["dev.outside", "group.living"],
    ]);
    const folded = foldGroupedLights(devices, owners);
    assert.notEqual(folded, devices);
    assert.deepEqual(folded.map((device) => device.id), ["group.living", "dev.other"]);
  });

  it("keeps members visible when their group card is filtered out", () => {
    const member = light("dev.a", "书房");
    const folded = foldGroupedLights([member], new Map([["dev.a", "group.away"]]));
    assert.deepEqual(folded.map((device) => device.id), ["dev.a"]);
  });

  it("copies the list unchanged when no owners are known", () => {
    const devices = [light("dev.a", "客厅"), light("dev.b", "书房")];
    const folded = foldGroupedLights(devices, new Map<string, string>());
    assert.notEqual(folded, devices);
    assert.deepEqual(folded, devices);
  });
});
