import type { DeviceKind, SmartDevice } from "../core/models.js";

export type DeviceKindTag = DeviceKind["kind"];

export type DeviceListCut =
  | { readonly kind: "all" }
  | { readonly kind: "room"; readonly roomName: string }
  | { readonly kind: "deviceKind"; readonly tag: DeviceKindTag };

export const KIND_RANK: Record<DeviceKindTag, number> = {
  climate: 0,
  light: 1,
  plug: 2,
  fan: 3,
  vacuum: 4,
  fridge: 5,
  camera: 6,
  sensor: 7,
};

export const KIND_CHIP: Record<
  DeviceKindTag,
  { readonly title: string; readonly hint?: string }
> = {
  climate: { title: "空调", hint: "也包括电暖器、温控器和电热毯" },
  light: { title: "灯" },
  plug: { title: "插座", hint: "也包括开关、香薰，以及带开关的小家电" },
  fan: { title: "风扇", hint: "也包括净化器、新风、加湿器和除湿器" },
  vacuum: { title: "扫地机" },
  fridge: { title: "冰箱" },
  camera: { title: "摄像机" },
  sensor: { title: "传感器", hint: "也包括没有开关的小家电" },
};

function visible(devices: readonly SmartDevice[], hideOffline: boolean): SmartDevice[] {
  return hideOffline ? devices.filter((dev) => dev.isOnline) : [...devices];
}

export function filterByListCut(
  devices: readonly SmartDevice[],
  cut: DeviceListCut,
  hideOffline: boolean,
): SmartDevice[] {
  return visible(devices, hideOffline).filter((dev) => {
    if (cut.kind === "room") return dev.roomName === cut.roomName;
    if (cut.kind === "deviceKind") return dev.kind.kind === cut.tag;
    return true;
  });
}

export function kindChips(
  devices: readonly SmartDevice[],
  cut: DeviceListCut,
  hideOffline: boolean,
): DeviceKindTag[] {
  const tags = new Set(visible(devices, hideOffline).map((dev) => dev.kind.kind));
  if (cut.kind === "deviceKind") tags.add(cut.tag);
  return [...tags].sort((a, b) => KIND_RANK[a] - KIND_RANK[b]);
}

export function showsKindRow(chips: readonly DeviceKindTag[], cut: DeviceListCut): boolean {
  return cut.kind === "deviceKind" || chips.length >= 2;
}
