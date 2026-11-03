import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { inferFallbackSpec, miotShortName } from "../src/core/miCloudClient.js";

const cases: ReadonlyArray<readonly [string, string, string, string]> = [
  ["model", "vendor.light.1", "测试灯", "light"],
  ["model", "vendor.aircondition.1", "空调", "air-conditioner"],
  ["model", "vendor.fan.1", "风扇", "fan"],
  ["model", "vendor.airpurifier.1", "净化器", "air-purifier"],
  ["model", "vendor.vacuum.1", "扫地", "vacuum"],
  ["model", "vendor.camera.1", "摄像", "camera"],
  ["model", "vendor.sensor_ht.1", "温湿度", "temperature-humidity-sensor"],
  ["model", "vendor.kettle.1", "水壶", "kettle"],
  ["model", "vendor.sensor_motion.1", "人体", "motion-sensor"],
  ["model", "vendor.lock.1", "门锁", "lock"],
  ["model", "vendor.fridge.1", "冰箱", "fridge"],
  ["name", "vendor.unknown.1", "空调", "air-conditioner"],
  ["suffix", "vendor.thing.fan", "未知", "fan"],
  ["default", "vendor.unknown.1", "未知", "outlet"],
];

describe("fallback spec table (#185)", () => {
  for (const [kind, model, name, expected] of cases) {
    it(`${kind} match for ${expected}`, () => {
      assert.equal(miotShortName(inferFallbackSpec({ model, name }).type), expected);
    });
  }

  it("keeps every guessed property read-only", () => {
    for (const [, model, name] of cases) {
      for (const service of inferFallbackSpec({ model, name }).services) {
        for (const property of service.properties) {
          assert.deepEqual(property.access, ["read"]);
        }
      }
    }
  });

  it("returns a fresh spec so callers cannot mutate the table", () => {
    const first = inferFallbackSpec({ model: "vendor.light.1", name: "测试灯" });
    const second = inferFallbackSpec({ model: "vendor.light.1", name: "测试灯" });
    assert.notEqual(first, second);
    assert.notEqual(first.services, second.services);
  });
});
