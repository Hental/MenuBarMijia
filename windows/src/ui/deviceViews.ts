import { t } from "../core/i18n.js";
import { IntentReply } from "../core/assistant.js";
import {
  deviceReadout,
  localizeAirQuality,
  localizeFanPreset,
  localizeFridgeMode,
  localizeNightShot,
  type SmartDevice,
} from "../core/models.js";
import { comfort, localizeEffect, localizeFanMode } from "./panelPrefs.js";
import {
  formatTemperature,
  formatTemperatureValue,
  getTemperatureUnit,
  displayStep,
  temperatureSymbol,
} from "../core/temperature.js";
import { SF_ICONS } from "./appConstants.js";

  export function renderSensorCard(
    dev: SmartDevice,
    k: Extract<SmartDevice["kind"], { kind: "sensor" }>,
    compact: boolean,
    attrs: string,
    motion: string,
    badge: string,
    selectedRoom: string,
    valuesAreStale: boolean,
    escapeHtml: (value: string) => string,
  ): string {
    const c = comfort(k.temperature, k.humidity);
    const name = dev.name.replace(t("米家智能温湿度计"), t("温湿度计")) || dev.name;
    if (valuesAreStale) {
      const label = t("可能过期");
      return `
        <div class="cc-tile cc-sensor is-stale ${motion}" ${attrs} role="group" aria-label="${escapeHtml(`${name}，${label}`)}">
          ${badge}
          <div class="cc-sensor-top"><span class="cc-sensor-name">${escapeHtml(name)}</span></div>
          <div class="cc-sensor-main"><span class="cc-sensor-temp">${label}</span></div>
        </div>`;
    }
    const temp = k.temperature !== null ? formatTemperatureValue(k.temperature, undefined, 1) : "--";
    const hum = k.humidity !== null ? Math.round(k.humidity) : null;
    const room = selectedRoom === "全部" ? `<span class="cc-sensor-room">${escapeHtml(dev.roomName)}</span>` : "";
    const sensorAria = `${t("{name}，温度 {temp}", { name, temp: k.temperature !== null ? formatTemperature(k.temperature, undefined, 1) : "--" })}${hum !== null ? t("，湿度 {humidity}%", { humidity: hum }) : ""}${dev.isOnline ? "" : t("，离线")}`;
    if (compact) {
      return `
        <div class="cc-tile cc-sensor is-compact ${dev.isOnline ? "" : "is-offline"} ${motion}" ${attrs} role="group" aria-label="${escapeHtml(sensorAria)}">
          ${badge}
          <div class="cc-sensor-top">
            <span class="cc-sensor-name">${escapeHtml(name)}</span>
            <span class="cc-comfort is-${c.level}">${c.label}</span>
          </div>
          <div class="cc-sensor-main">
            <span class="cc-sensor-temp">${temp}<small>${temperatureSymbol()}</small></span>
            ${hum !== null ? `<span class="cc-sensor-hum">💧 ${hum}%</span>` : ""}
          </div>
          <div class="cc-hum-bar"><span style="width:${hum ?? 0}%"></span></div>
        </div>`;
    }
    const ring = hum !== null
      ? `<div class="cc-hum-ring" style="--h:${hum}">
          <svg viewBox="0 0 64 64"><circle class="track" cx="32" cy="32" r="27"/><circle class="comfy" cx="32" cy="32" r="27" pathLength="100"/><circle class="val" cx="32" cy="32" r="27" pathLength="100"/></svg>
          <span>${hum}%</span>
        </div>`
      : "";
    return `
      <div class="cc-tile cc-sensor ${dev.isOnline ? "" : "is-offline"} ${motion}" ${attrs} role="group" aria-label="${escapeHtml(sensorAria)}">
        ${badge}
        <div class="cc-sensor-wide">
          <div class="cc-sensor-info">
            <div class="cc-sensor-top"><span class="cc-sensor-name is-strong">${escapeHtml(name)}</span>${room}</div>
            <span class="cc-sensor-temp is-big">${temp}<small>${temperatureSymbol()}</small></span>
            <div class="cc-sensor-meta">
              <span class="cc-comfort is-${c.level}">${c.label}</span>
              ${k.battery !== null ? `<span class="cc-sensor-batt ${k.battery <= 20 ? "is-low" : ""}">🔋 ${k.battery}%</span>` : ""}
            </div>
          </div>
          ${ring}
        </div>
      </div>`;
  }

  export function renderClimateStrip(
    dev: SmartDevice,
    k: Extract<SmartDevice["kind"], { kind: "climate" }>,
    forceOpen: boolean,
    attrs: string,
    motion: string,
    badge: string,
    expandedDeviceId: string | null,
    selectedRoom: string,
    valuesAreStale: boolean,
    waitingDeviceIds: ReadonlySet<string>,
    escapeHtml: (value: string) => string,
  ): string {
    const readout = deviceReadout(waitingDeviceIds.has(dev.id), valuesAreStale);
    const running = readout !== "possiblyStale" && dev.isOnline && k.isOn && k.hvacMode !== "off";
    const powerWritable = k.powerWritable !== false;
    const temperatureWritable = k.temperatureWritable !== false;
    const canExpand = temperatureWritable || k.availableModes.length > 0 || k.availableFanModes.length > 0;
    const open = canExpand && (forceOpen || expandedDeviceId === dev.id);
    const id = escapeHtml(dev.id);
    const modeLabel: Record<string, string> = { cool: t("制冷"), heat: t("制热"), dry: t("除湿"), fan_only: t("送风"), auto: t("自动") };
    const status = readout === "waiting"
      ? t("等待中")
      : readout === "possiblyStale"
        ? t("可能过期")
        : running
          ? [
              modeLabel[k.hvacMode] ?? k.hvacMode,
              k.currentTemperature !== null
                ? t("室温 {temp}", { temp: formatTemperature(k.currentTemperature, undefined, 1) })
                : "",
            ].filter(Boolean).join(" · ")
          : t("已关闭");
    const subtitle = selectedRoom === "全部" ? `${dev.roomName} · ${status}` : status;
    const span = Math.max(k.maxTemp - k.minTemp, 1);
    const progress = Math.min(Math.max((k.targetTemperature - k.minTemp) / span, 0), 1) * 100;
    const modes = (
      k.availableModes.length > 0
        ? k.availableModes
        : !k.entityId.startsWith("miot:") && powerWritable
          ? ["cool", "heat", "dry", "fan_only"]
          : []
    ).filter((m) => m !== "off");
    const unit = getTemperatureUnit();
    const temp = formatTemperatureValue(k.targetTemperature);
    const power = powerWritable
      ? `<button class="cc-climate-power ${running ? "is-on" : ""}" data-toggle-device="${id}" title="${running ? t("关闭空调") : t("打开空调")}" aria-label="${running ? t("关闭 {name}", { name: escapeHtml(dev.name) }) : t("打开 {name}", { name: escapeHtml(dev.name) })}" aria-pressed="${running}">
            <span aria-hidden="true" ${k.hvacMode === "heat" ? "" : "hidden"}>🔥</span><span aria-hidden="true" ${k.hvacMode === "heat" ? "hidden" : ""}>${SF_ICONS.snowflake}</span>
          </button>`
      : `<span class="cc-climate-power ${running ? "is-on" : ""}" aria-hidden="true">
            <span ${k.hvacMode === "heat" ? "" : "hidden"}>🔥</span><span ${k.hvacMode === "heat" ? "hidden" : ""}>${SF_ICONS.snowflake}</span>
          </span>`;
    const steps = readout === "possiblyStale"
      ? ""
      : temperatureWritable
      ? `<button class="cc-climate-step" data-acstep="${id}:-1" title="${t("降低温度")}" aria-label="${t("降低目标温度")}">−</button>
          <span class="cc-climate-temp" aria-label="${t("目标温度 {temp}", { temp: formatTemperature(k.targetTemperature) })}">${temp}<small>${temperatureSymbol(unit)}</small></span>
          <button class="cc-climate-step" data-acstep="${id}:1" title="${t("升高温度")}" aria-label="${t("升高目标温度")}">＋</button>`
      : `<span class="cc-climate-temp" aria-label="${t("目标温度 {temp}", { temp: formatTemperature(k.targetTemperature) })}">${temp}<small>${temperatureSymbol(unit)}</small></span>`;
    return `
      <div class="cc-tile cc-climate ${running ? "is-active" : ""} ${dev.isOnline ? "" : "is-offline"} ${readout === "possiblyStale" ? "is-stale" : ""} ${motion}" ${attrs}>
        ${badge}
        <div class="cc-climate-strip">
          ${power}
          <button class="cc-climate-name" ${canExpand ? `data-expand-device="${id}"` : ""} aria-label="${escapeHtml(dev.name)}，${escapeHtml(subtitle)}" aria-expanded="${open}">
            <span class="cc-tile-name">${escapeHtml(dev.name)}</span>
            <span class="cc-tile-status">${escapeHtml(subtitle)} ${!canExpand || forceOpen ? "" : `<i class="cc-mini-caret ${open ? "is-open" : ""}">${SF_ICONS.chevronDown}</i>`}</span>
          </button>
          ${steps}
        </div>
        ${readout === "possiblyStale" ? "" : `<div class="cc-climate-gauge" role="progressbar" aria-label="${t("目标温度进度")}" aria-valuemin="${k.minTemp}" aria-valuemax="${k.maxTemp}" aria-valuenow="${k.targetTemperature}"><span style="width:${progress}%"></span></div>`}
        ${
          open
            ? `<div class="cc-climate-more">
                <div class="cc-segmented-pills is-even">
                  ${modes.map((m) => `<button class="cc-seg-pill ${running && k.hvacMode === m ? "is-active" : ""}" data-acmode="${id}:${m}" aria-pressed="${running && k.hvacMode === m}">${modeLabel[m] ?? m}</button>`).join("")}
                </div>
                ${
                  k.availableFanModes.length > 0
                    ? `<div class="cc-segmented-pills"><span class="cc-pill-label">${t("风速")}</span>${k.availableFanModes
                        .map((f) => `<button class="cc-seg-pill ${k.fanMode === f ? "is-active" : ""}" data-acfan="${id}:${escapeHtml(f)}" aria-pressed="${k.fanMode === f}">${escapeHtml(localizeFanMode(f))}</button>`)
                        .join("")}</div>`
                    : ""
                }
              </div>`
            : ""
        }
      </div>`;
  }

export function renderDeviceDrawer(dev: SmartDevice, escapeHtml: (value: string) => string): string {
    const k = dev.kind;
    if (k.kind === "light") {
      const showBrightness = k.brightnessWritable !== false;
      const showColor = k.colorWritable !== false;
      if (!showBrightness && !showColor && k.availableEffects.length === 0) return "";
      const bri = k.brightnessPercent ?? 80;
      const ct = k.colorTempKelvin ?? 4000;
      return `
        <div class="cc-tile-drawer">
          ${showBrightness ? `<div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>${t("亮度")}</span>
              <strong>${bri}%</strong>
            </div>
            <input class="cc-range is-amber" type="range" min="1" max="100" value="${bri}" data-brightness="${escapeHtml(dev.id)}" aria-label="${t("亮度")}" aria-valuemin="1" aria-valuemax="100" aria-valuenow="${bri}" />
          </div>` : ""}
          ${showColor ? `<div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>${t("色温")}</span>
              <strong>${ct}K</strong>
            </div>
            <input class="cc-range is-kelvin" type="range" min="${k.minKelvin}" max="${k.maxKelvin}" step="100" value="${ct}" data-colortemp="${escapeHtml(dev.id)}" aria-label="${t("色温")}" aria-valuemin="${k.minKelvin}" aria-valuemax="${k.maxKelvin}" aria-valuenow="${ct}" />
          </div>` : ""}
          ${k.availableEffects.length > 0 ? `
            <div class="cc-segmented-pills">
              ${k.availableEffects.map((effect) => `
                <button class="cc-seg-pill ${k.currentEffect === effect ? "is-active" : ""}"
                  data-lighteffect="${escapeHtml(dev.id)}" data-effect="${escapeHtml(effect)}"
                  aria-pressed="${k.currentEffect === effect}">
                  ${escapeHtml(localizeEffect(effect))}
                </button>
              `).join("")}
            </div>
          ` : ""}
        </div>
      `;
    }
    if (k.kind === "climate") {
      const showTemp = k.temperatureWritable !== false;
      const showModes = k.availableModes.some((mode) => mode !== "off") || (!k.entityId.startsWith("miot:") && k.powerWritable !== false);
      if (!showTemp && !showModes) return "";
      const modes: ReadonlyArray<{ readonly code: string; readonly label: string }> = [
        { code: "cool", label: t("制冷") },
        { code: "heat", label: t("制热") },
        { code: "dry", label: t("除湿") },
        { code: "fan_only", label: t("送风") },
        { code: "auto", label: t("自动") },
      ];
      return `
        <div class="cc-tile-drawer">
          ${showTemp ? `<div class="cc-slider-group">
            <div class="cc-slider-label">
              <span>${t("目标温度")}</span>
              <strong>${formatTemperature(k.targetTemperature)}</strong>
            </div>
            <input class="cc-range is-blue" type="range" min="${formatTemperatureValue(k.minTemp)}" max="${formatTemperatureValue(k.maxTemp)}" step="${displayStep(k.step)}" value="${formatTemperatureValue(k.targetTemperature)}" data-actemp="${escapeHtml(dev.id)}" aria-label="${t("目标温度")}" aria-valuemin="${formatTemperatureValue(k.minTemp)}" aria-valuemax="${formatTemperatureValue(k.maxTemp)}" aria-valuetext="${formatTemperature(k.targetTemperature)}" />
          </div>` : ""}
          ${showModes ? `<div class="cc-segmented-pills">
            ${modes
              .map(
                (m) => `
              <button class="cc-seg-pill ${k.hvacMode === m.code ? "is-active" : ""}" data-acmode="${escapeHtml(dev.id)}:${m.code}">
                ${m.label}
              </button>
            `,
              )
              .join("")}
          </div>` : ""}
        </div>
      `;
    }
    if (k.kind === "fan") {
      const modes =
        k.availablePresetModes.length > 0
          ? k.availablePresetModes
          : k.powerWritable === false
            ? []
            : ["Level 1", "Level 2", "Level 3", "Level 4"];
      const telemetryParts: string[] = [];
      if (k.pm25Density !== undefined && k.pm25Density !== null) {
        const aq = localizeAirQuality(k.airQuality, k.pm25Density);
        telemetryParts.push(`${t("空气质量")} PM2.5 ${k.pm25Density}${aq ? ` (${aq})` : ""}`);
      } else if (k.airQuality) {
        const aq = localizeAirQuality(k.airQuality, null);
        if (aq) telemetryParts.push(`${t("空气质量")} ${aq}`);
      }
      if (k.temperature !== undefined && k.temperature !== null && k.humidity !== undefined && k.humidity !== null) {
        telemetryParts.push(`${t("温湿度")} ${formatTemperature(k.temperature, undefined, 1)} · ${Math.round(k.humidity)}%`);
      } else if (k.temperature !== undefined && k.temperature !== null) {
        telemetryParts.push(formatTemperature(k.temperature, undefined, 1));
      } else if (k.humidity !== undefined && k.humidity !== null) {
        telemetryParts.push(`${Math.round(k.humidity)}%`);
      }
      if (k.filterLifePercent !== undefined && k.filterLifePercent !== null) {
        telemetryParts.push(`${t("滤芯余量")} ${k.filterLifePercent}%`);
      }
      return `
        <div class="cc-tile-drawer">
          ${
            telemetryParts.length > 0
              ? `<div class="cc-slider-label"><span>${escapeHtml(telemetryParts.join(" · "))}</span></div>`
              : ""
          }
          ${
            k.speedWritable !== false && k.percentage !== null
              ? `<div class="cc-slider-group">
                  <div class="cc-slider-label">
                    <span>${t("风速")}</span>
                    <strong>${k.percentage}%</strong>
                  </div>
                  <input class="cc-range is-blue" type="range" min="1" max="100" value="${Math.max(1, k.percentage)}" data-fanpercent="${escapeHtml(dev.id)}" aria-label="${t("风速")}" aria-valuemin="1" aria-valuemax="100" aria-valuenow="${Math.max(1, k.percentage)}" />
                </div>`
              : ""
          }
          ${
            modes.length > 0 || (k.swingWritable !== false && k.isOscillating !== null)
              ? `<div class="cc-segmented-pills">
            ${modes
              .map(
                (preset) => `
              <button class="cc-seg-pill ${k.presetMode === preset ? "is-active" : ""}" data-fanpreset="${escapeHtml(dev.id)}:${escapeHtml(preset)}" aria-pressed="${k.presetMode === preset}">
                ${escapeHtml(localizeFanPreset(IntentReply.fanSpeedLabel(preset)))}
              </button>
            `,
              )
              .join("")}
            ${
              k.swingWritable !== false && k.isOscillating !== null
                ? `<button class="cc-seg-pill ${k.isOscillating ? "is-active" : ""}" data-fanosc="${escapeHtml(dev.id)}" aria-pressed="${k.isOscillating}">
                    摇头 ${k.isOscillating ? t("开") : t("关")}
                  </button>`
                : ""
            }
          </div>`
              : ""
          }
        </div>
      `;
    }
    if (k.kind === "camera") {
      if (k.powerWritable === false && k.availableNightShots.length === 0 && !k.motionDetectionEntityId) return "";
      const id = escapeHtml(dev.id);
      const motionOn = Boolean(k.isMotionDetectionOn);
      return `
        <div class="cc-tile-drawer">
          <div class="cc-segmented-pills">
            <button class="cc-seg-pill is-active" data-camera-live="${id}">
              ${t("放大实时画面")}
            </button>
            ${k.powerWritable === false ? "" : `<button class="cc-seg-pill ${!k.isOn ? "is-active" : ""}" data-toggle-device="${id}" aria-pressed="${!k.isOn}">
              ${k.isOn ? t("镜头休眠") : t("唤醒镜头")}
            </button>`}
            ${
              k.motionDetectionEntityId
                ? `<button class="cc-seg-pill ${motionOn ? "is-active" : ""}" data-cameramotion="${id}" aria-pressed="${motionOn}">
                    ${motionOn ? t("移动侦测：开") : t("移动侦测：关")}
                  </button>`
                : ""
            }
          </div>
          ${
            k.availableNightShots.length > 0
              ? `<div class="cc-segmented-pills">
                  ${k.availableNightShots
                    .map(
                      (mode) => `<button class="cc-seg-pill ${k.nightShot === mode ? "is-active" : ""}" data-cameranight="${id}:${escapeHtml(mode)}" aria-pressed="${k.nightShot === mode}">
                        ${escapeHtml(localizeNightShot(mode))}
                      </button>`
                    )
                    .join("")}
                </div>`
              : ""
          }
        </div>
      `;
    }
    if (k.kind === "fridge") {
      const id = escapeHtml(dev.id);
      const fridgeStep = k.fridgeTargetEntityId
        ? `<button class="cc-seg-pill" data-fridgestep="${id}:fridge:-1" aria-label="${t("降低冷藏室温度")}">−</button>
            <button class="cc-seg-pill" data-fridgestep="${id}:fridge:1" aria-label="${t("升高冷藏室温度")}">＋</button>`
        : "";
      const freezerStep = k.freezerTargetEntityId
        ? `<button class="cc-seg-pill" data-fridgestep="${id}:freezer:-1" aria-label="${t("降低冷冻室温度")}">−</button>
            <button class="cc-seg-pill" data-fridgestep="${id}:freezer:1" aria-label="${t("升高冷冻室温度")}">＋</button>`
        : "";
      return `
        <div class="cc-tile-drawer">
          <div class="cc-segmented-pills">
            <span class="cc-pill-label">${t("冷藏室")} (${formatTemperature(k.fridgeTargetTemp)})</span>
            ${fridgeStep}
          </div>
          <div class="cc-segmented-pills">
            <span class="cc-pill-label">${t("冷冻室")} (${formatTemperature(k.freezerTargetTemp)})</span>
            ${freezerStep}
          </div>
          ${
            k.availableModes.length > 0
              ? `<div class="cc-segmented-pills">
                  ${k.availableModes
                    .map(
                      (mode) => `<button class="cc-seg-pill ${k.currentMode === mode ? "is-active" : ""}" data-fridgemode="${id}:${escapeHtml(mode)}" aria-pressed="${k.currentMode === mode}">
                        ${escapeHtml(localizeFridgeMode(mode))}
                      </button>`
                    )
                    .join("")}
                </div>`
              : ""
          }
        </div>
      `;
    }
    return "";
  }
