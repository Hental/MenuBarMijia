import type { SmartDevice } from "../models.js";

export type IntentCategory = "light" | "climate" | "heater" | "fan" | "airPurifier" | "dehumidifier" | "diffuser" | "plug" | "vacuum" | "tv" | "camera" | "other";


export function isAirPurifierDevice(dev: SmartDevice): boolean {
  if (dev.kind.kind !== "fan") return false;
  const m = dev.model.toLowerCase();
  return (
    m.includes("airp") ||
    m.includes("purifier") ||
    m.includes("airfresh") ||
    m.includes("humidifier") ||
    dev.name.includes("净化") ||
    dev.name.includes("空净") ||
    dev.name.includes("新风") ||
    dev.name.includes("加湿") ||
    dev.kind.pm25Density != null ||
    dev.kind.airQuality != null ||
    dev.kind.filterLifePercent != null
  );
}

export function deviceCategory(dev: SmartDevice): IntentCategory {
  if (dev.kind.kind === "light") return "light";
  if (dev.kind.kind === "climate") {
    return dev.model.includes("heater") || dev.model.includes("blanket") || dev.name.includes("暖") ? "heater" : "climate";
  }
  if (dev.kind.kind === "fan" && dev.model.includes(".derh.")) return "dehumidifier";
  if (dev.kind.kind === "plug" && dev.model.includes(".diffuser.")) return "diffuser";
  if (dev.kind.kind === "fan") return isAirPurifierDevice(dev) ? "airPurifier" : "fan";
  if (dev.kind.kind === "plug") return "plug";
  if (dev.kind.kind === "vacuum") return "vacuum";
  if (dev.kind.kind === "camera") return "camera";
  return "other";
}

export function isAssistantControllable(cat: IntentCategory): boolean {
  return cat !== "other";
}
