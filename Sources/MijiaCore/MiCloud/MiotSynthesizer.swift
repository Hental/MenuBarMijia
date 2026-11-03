import Foundation

/// Entity ids handed to `SmartDevice` specs on the Xiaomi cloud backend: `miot:<did>:<siid>`.
public enum MiotAddress {
    public static func make(did: String, siid: Int) -> String { "miot:\(did):\(siid)" }

    public static func makeAction(did: String, siid: Int, aiid: Int) -> String {
        "miot-action:\(did):\(siid):\(aiid)"
    }

    public static func parseAction(_ entityId: String) -> (did: String, siid: Int, aiid: Int)? {
        guard entityId.hasPrefix("miot-action:") else { return nil }
        let parts = entityId.dropFirst("miot-action:".count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let aiid = Int(parts[parts.count - 1]), let siid = Int(parts[parts.count - 2]) else { return nil }
        let did = parts.dropLast(2).joined(separator: ":")
        return did.isEmpty ? nil : (did, siid, aiid)
    }

    public static func parse(_ entityId: String) -> (did: String, siid: Int)? {
        if let action = parseAction(entityId) { return (action.did, action.siid) }
        guard entityId.hasPrefix("miot:") else { return nil }
        let rest = entityId.dropFirst("miot:".count)
        guard let sep = rest.lastIndex(of: ":"), let siid = Int(rest[rest.index(after: sep)...]) else { return nil }
        let did = String(rest[..<sep])
        return did.isEmpty ? nil : (did, siid)
    }
}

// MARK: - Device Synthesis for MIoT Devices

public enum MiotSynthesizer {
    typealias KindBuilder = @Sendable (MiotReader, MiotService) -> DeviceKind

    /// Primary service short name → builder. Order is the fallback priority when the device
    /// type itself (urn segment 3) does not name one of these services.
    static let registry: [(service: String, build: KindBuilder)] = [
        ("air-conditioner", buildClimate),
        ("heater", buildClimate),
        ("thermostat", buildClimate),
        ("electric-blanket", buildClimate),
        ("dehumidifier", buildDehumidifier),
        ("diffuser", buildPlug),
        ("speaker", buildSpeaker),
        ("light", buildLight),
        ("fan", buildFan),
        ("air-purifier", buildAirPurifier),
        ("air-fresh", buildAirPurifier),
        ("humidifier", buildAirPurifier),
        ("vacuum", buildVacuum),
        ("fridge", buildFridge),
        ("camera-control", buildCamera),
        ("video-doorbell", buildCamera),
        ("outlet", buildPlug),
        ("switch", buildPlug),
        ("kettle", buildAppliance),
        ("ble-kettle", buildAppliance),
        ("water-dispenser", buildAppliance),
        ("cooker", buildAppliance),
        ("air-fryer", buildAppliance),
        ("oven", buildAppliance),
        ("microwave-oven", buildAppliance),
        ("health-pot", buildAppliance),
        ("lock", buildSensor),
        ("motion-sensor", buildSensor),
        ("occupancy-sensor", buildSensor),
        ("magnet-sensor", buildSensor),
        ("submersion-sensor", buildSensor),
        ("illumination-sensor", buildSensor),
        ("air-monitor", buildSensor),
        ("temperature-humidity-sensor", buildSensor),
    ]

    public static func synthesize(
        devices: [MiDeviceRecord],
        rooms: [MiRoom],
        specs: [String: MiotDeviceSpec],
        values: [MiotPropKey: JSONValue]
    ) -> SynthesizedHome {
        var roomByDid: [String: MiRoom] = [:]
        for room in rooms {
            for did in room.dids where roomByDid[did] == nil { roomByDid[did] = room }
        }

        // A panel whose keys are listed as split devices is shown through those keys only.
        let splitParents = Set(devices.compactMap(\.splitParentDid))

        var smartDevices: [SmartDevice] = []
        var readings: [EnvironmentReading] = []

        for record in devices where !splitParents.contains(record.did) {
            guard let spec = specs[record.model],
                  let (service, build) = primary(for: record, spec: spec) else { continue }
            let scopedSpec = specForRecord(record, spec: spec)
            let reader = MiotReader(did: record.miotDid, spec: scopedSpec, values: values)
            let kind = build(reader, service)

            let room = roomByDid[record.did] ?? record.splitParentDid.flatMap { roomByDid[$0] }
            let roomName = DeviceSynthesizer.normalizeRoomName(room?.name ?? "")
            let roomId = DeviceSynthesizer.normalizedRoomId(for: roomName, fallback: room.map { "mi_room_\($0.id)" } ?? "other")
            let name = DeviceSynthesizer.cleanDeviceName(record.name, roomName: roomName, model: record.model)

            let device = SmartDevice(
                id: record.did,
                name: name,
                roomId: roomId,
                roomName: roomName,
                model: record.model,
                isOnline: record.isOnline,
                kind: record.isOnline ? kind : Self.redactOfflineLockClaim(kind)
            )
            smartDevices.append(device)

            if let reading = device.environmentReading {
                readings.append(reading)
            }
        }

        return DeviceSynthesizer.assembleHome(
            devices: smartDevices,
            readings: readings,
            scenes: [],
            roomNameOrder: DeviceSynthesizer.roomNameOrder(from: rooms.map(\.name))
        )
    }

    /// The (did, siid, piid) triples the synthesizer reads for this device; poll exactly these.
    public static func requiredProps(for device: MiDeviceRecord, spec: MiotDeviceSpec) -> [MiotPropKey] {
        guard let (service, build) = primary(for: device, spec: spec) else { return [] }
        let scopedSpec = specForRecord(device, spec: spec)
        let reader = MiotReader(did: device.miotDid, spec: scopedSpec, values: [:])
        _ = build(reader, service)
        return reader.touched
    }

    /// MIoT `<siid>.<piid>` keys for a sensor's temperature and relative-humidity properties,
    /// used when querying Xiaomi Cloud's statistics / history endpoints.
    public static func sensorPropertyKeys(for device: MiDeviceRecord, spec: MiotDeviceSpec) -> (temperature: String?, humidity: String?) {
        guard let (service, _) = primary(for: device, spec: spec) else { return (nil, nil) }
        let scopedSpec = specForRecord(device, spec: spec)
        let reader = MiotReader(did: device.miotDid, spec: scopedSpec, values: [:])
        let readingServices = [service] + scopedSpec.services(named: "environment") + scopedSpec.services(named: "temperature-humidity-sensor")
        let temp = reader.first("temperature", in: readingServices)
        let hum = reader.first("relative-humidity", in: readingServices)
        let tempKey = temp.map { "\($0.service.iid).\($0.property.iid)" }
        let humKey = hum.map { "\($0.service.iid).\($0.property.iid)" }
        return (tempKey, humKey)
    }

    /// Narrows a multi-key panel spec to the switch service controlled by a split key.
    static func specForRecord(_ record: MiDeviceRecord, spec: MiotDeviceSpec) -> MiotDeviceSpec {
        guard record.splitParentDid != nil, let siid = record.splitSiid else { return spec }
        return MiotDeviceSpec(type: spec.type, services: spec.services.filter { $0.iid == siid })
    }

    /// Registry key of the builder that will handle this spec, or nil when unsupported.
    public static func supportedServiceName(for spec: MiotDeviceSpec) -> String? {
        primary(for: spec)?.0.shortName
    }

    /// Split keys use their own switch service instead of the panel's first one.
    static func primary(for record: MiDeviceRecord, spec: MiotDeviceSpec) -> (MiotService, KindBuilder)? {
        guard record.splitParentDid != nil, let siid = record.splitSiid else { return primary(for: spec) }
        guard let service = spec.service(iid: siid),
              let entry = registry.first(where: { $0.service == service.shortName }) else { return nil }
        return (service, entry.build)
    }

    static func primary(for spec: MiotDeviceSpec) -> (MiotService, KindBuilder)? {
        let deviceType = spec.shortName
        let preferredServices: [String] = switch deviceType {
        case "outlet": ["outlet", "switch"]
        case "camera", "cateye", "video-doorbell": ["camera-control", "video-doorbell"]
        case "kettle", "ble-kettle": ["kettle", "ble-kettle", "water-dispenser"]
        default: [deviceType]
        }
        for serviceName in preferredServices {
            if let entry = registry.first(where: { $0.service == serviceName }),
               let service = spec.services(named: entry.service).first {
                return (service, entry.build)
            }
        }
        for entry in registry {
            // A secondary `light` service must not claim devices whose own type is something
            // else (hood / airer / bath-heater / ceiling-fan / gateway), or those cards become
            // bare lamps that only toggle their lamp while the primary function stays hidden.
            if entry.service == "light",
               deviceType != "light", !deviceType.contains("light"), !deviceType.contains("lamp") {
                continue
            }
            if let service = spec.services(named: entry.service).first {
                return (service, entry.build)
            }
        }
        // Sensors that publish readings under a generic `environment` service.
        if deviceType.hasSuffix("sensor"),
           let env = spec.services(named: "environment").first,
           env.property(named: "temperature") != nil || env.property(named: "relative-humidity") != nil {
            return (env, buildSensor)
        }
        return nil
    }

    // MARK: Builders

    static func buildLight(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let on = r.ref("on", in: s)
        let bri = r.ref("brightness", in: s)
        let ct = r.ref("color-temperature", in: s)
        let mode = r.ref("mode", in: s)
        let isLightGroup = r.did.hasPrefix("group.")
        let effects = (!isLightGroup && mode?.property.isWritable == true)
            ? (mode?.property.valueList?.map(\.description) ?? [])
            : []
        return .light(LightSpec(
            entityId: MiotAddress.make(did: r.did, siid: s.iid),
            isOn: on?.value?.miotBool ?? false,
            brightnessPercent: bri.flatMap { ref in ref.value?.doubleValue.map { percent(fromRaw: $0, property: ref.property) } },
            colorTempKelvin: ct?.value?.intValue,
            minKelvin: ct?.property.rangeMin.map { Int($0) } ?? 2700,
            maxKelvin: ct?.property.rangeMax.map { Int($0) } ?? 6500,
            currentEffect: isLightGroup ? nil : mode?.valueDescription,
            availableEffects: effects,
            powerWritable: on?.property.isWritable == true,
            brightnessWritable: bri?.property.isWritable ?? true,
            colorWritable: ct?.property.isWritable ?? true
        ))
    }

    static func buildClimate(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let on = r.ref("on", in: s)
        let mode = s.shortName == "electric-blanket" ? nil : r.ref("mode", in: s)
        let target = r.ref("target-temperature", in: s)
        let current = s.shortName == "electric-blanket" ? nil : r.first("temperature", in: [s] + r.spec.services(named: "environment") + r.spec.services(named: "temperature-humidity-sensor"))
        let fanLevel = r.first("fan-level", in: r.spec.services(named: "fan-control") + [s])

        let isOn = on?.value?.miotBool ?? false
        let onWritable = on?.property.isWritable == true
        let modeWritable = mode?.property.isWritable == true
        let exposeModes = modeWritable || (mode == nil && onWritable)
        var haModes: [String] = []
        if exposeModes {
            for item in mode?.property.valueList ?? [] {
                if let m = hvacMode(forDescription: item.description), !haModes.contains(m) { haModes.append(m) }
            }
            if haModes.isEmpty { haModes = [s.shortName == "air-conditioner" ? "cool" : "heat"] }
        }
        let activeMode = mode?.valueDescription.flatMap(hvacMode(forDescription:))
            ?? haModes.first
            ?? (s.shortName == "air-conditioner" ? "cool" : "heat")

        return .climate(ClimateSpec(
            entityId: MiotAddress.make(did: r.did, siid: s.iid),
            isOn: isOn,
            hvacMode: isOn ? activeMode : "off",
            availableModes: exposeModes ? haModes + ["off"] : [],
            targetTemperature: target?.value?.doubleValue ?? 26,
            currentTemperature: current?.value?.doubleValue,
            minTemp: target?.property.rangeMin ?? 16,
            maxTemp: target?.property.rangeMax ?? 30,
            step: target?.property.rangeStep ?? 1,
            fanMode: fanLevel?.valueDescription,
            availableFanModes: fanLevel?.property.isWritable == true ? (fanLevel?.property.valueList?.map(\.description) ?? []) : [],
            powerWritable: onWritable,
            temperatureWritable: target?.property.isWritable ?? true
        ))
    }

    static func buildFan(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let on = r.ref("on", in: s)
        let mode = r.ref("mode", in: s)
        let levels = r.refs("fan-level", in: s)
        let swing = r.ref("horizontal-swing", in: s)
        let percentRef = levels.first { $0.property.valueRange != nil }
        let presetRef = (mode?.property.valueList?.isEmpty == false) ? mode : levels.first { $0.property.valueList?.isEmpty == false }

        return .fan(FanSpec(
            entityId: MiotAddress.make(did: r.did, siid: s.iid),
            isOn: on?.value?.miotBool ?? false,
            percentage: percentRef.flatMap { ref in ref.value?.doubleValue.map { percent(fromRaw: $0, property: ref.property) } },
            presetMode: presetRef?.valueDescription,
            availablePresetModes: presetRef?.property.isWritable == true ? (presetRef?.property.valueList?.map(\.description) ?? []) : [],
            isOscillating: swing?.value?.miotBool,
            powerWritable: on?.property.isWritable == true,
            speedWritable: percentRef?.property.isWritable ?? true,
            swingWritable: swing?.property.isWritable ?? true
        ))
    }

    static func buildAirPurifier(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let on = r.ref("on", in: s)
        let mode = r.ref("mode", in: s)
        let levels = r.refs("fan-level", in: s)
        let favServices = r.spec.services(named: "air-purifier-favorite")
            + r.spec.services(named: "air-fresh-favorite")
            + r.spec.services(named: "motor-speed")
            + r.spec.services(named: "custom-service")
            + r.spec.services(named: "fan-control")
        let favSpeed = r.first("fan-level", in: favServices)
            ?? r.first("favorite-fan-level", in: favServices)
            ?? r.first("favorite-level", in: favServices)
            ?? r.first("favorite-speed", in: favServices)
        let speedRef = favSpeed
            ?? levels.first { $0.property.valueRange != nil }
            ?? levels.first { $0.property.valueList?.isEmpty == false }
        let presetRef = (mode?.property.valueList?.isEmpty == false)
            ? mode
            : levels.first { $0.property.valueList?.isEmpty == false }

        let envServices = r.spec.services(named: "environment")
            + r.spec.services(named: "temperature-humidity-sensor")
            + [s]
        let pm25 = r.first("pm2.5-density", in: envServices)
        let airQuality = r.first("air-quality", in: envServices)
        let temp = r.first("temperature", in: envServices)
        let hum = r.first("relative-humidity", in: envServices)
        let filterServices = r.spec.services(named: "filter") + [s]
        let filterLife = r.first("filter-life-level", in: filterServices)

        return .fan(FanSpec(
            entityId: MiotAddress.make(did: r.did, siid: s.iid),
            isOn: on?.value?.miotBool ?? false,
            percentage: speedRef.flatMap { ref in ref.value?.doubleValue.map { speedPercent(fromRaw: $0, property: ref.property) } },
            presetMode: presetRef?.valueDescription,
            availablePresetModes: presetRef?.property.isWritable == true ? (presetRef?.property.valueList?.map(\.description) ?? []) : [],
            isOscillating: nil,
            pm25Density: pm25?.value?.intValue,
            airQuality: airQuality?.valueDescription,
            temperature: temp?.value?.doubleValue,
            humidity: hum?.value?.doubleValue,
            filterLifePercent: filterLife?.value?.intValue,
            powerWritable: on?.property.isWritable == true,
            speedWritable: speedRef?.property.isWritable ?? true
        ))
    }

    static func buildDehumidifier(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let on = r.ref("on", in: s)
        let mode = r.ref("mode", in: s)
        let environment = r.spec.services(named: "environment")
        let temperature = r.first("temperature", in: environment)
        let humidity = r.first("relative-humidity", in: environment)
        return .fan(FanSpec(
            entityId: MiotAddress.make(did: r.did, siid: s.iid),
            isOn: on?.value?.miotBool ?? false,
            presetMode: mode?.valueDescription,
            availablePresetModes: mode?.property.isWritable == true ? mode?.property.valueList?.map(\.description) ?? [] : [],
            temperature: temperature?.value?.doubleValue,
            humidity: humidity?.value?.doubleValue,
            powerWritable: on?.property.isWritable == true
        ))
    }

    static func buildSpeaker(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let volume = r.ref("volume", in: s)
        let mute = r.ref("mute", in: s)
        let playing = r.first("playing-state", in: r.spec.services(named: "play-control"))
        let intelligent = r.spec.services(named: "intelligent-speaker").first
        let sleep = intelligent.flatMap { r.ref("sleep-mode", in: $0) }
        func actionAddress(_ service: MiotService?, _ name: String, inputs: [String]) -> String? {
            guard let service, let action = service.action(named: name),
                  action.inputProperties.count == inputs.count,
                  zip(action.inputProperties, inputs).allSatisfy({ id, name in
                      service.properties.contains { $0.iid == id && $0.shortName == name }
                  }) else { return nil }
            return MiotAddress.makeAction(did: r.did, siid: service.iid, aiid: action.iid)
        }
        let state: String = switch playing?.valueDescription?.lowercased() {
        case "playing", "play": "playing"
        case "paused", "pause": "paused"
        default: "idle"
        }
        return .speaker(SpeakerSpec(
            mediaEntityId: MiotAddress.make(did: r.did, siid: s.iid),
            state: state,
            volumePercent: volume.flatMap { ref in ref.value?.doubleValue.map { percent(fromRaw: $0, property: ref.property) } } ?? 0,
            isMuted: mute?.value?.miotBool ?? false,
            muteSwitchEntityId: mute?.property.isWritable == true ? MiotAddress.make(did: r.did, siid: s.iid) : nil,
            sleepModeEntityId: sleep?.property.isWritable == true ? intelligent.map { MiotAddress.make(did: r.did, siid: $0.iid) } : nil,
            isSleepMode: sleep?.value?.miotBool ?? false,
            ttsNotifyEntityId: actionAddress(intelligent, "play-text", inputs: ["text-content"]),
            directiveNotifyEntityId: actionAddress(intelligent, "execute-text-directive", inputs: ["text-content", "silent-execution"]),
            playMusicButtonId: actionAddress(intelligent, "play-music", inputs: []),
            stopAlarmButtonId: actionAddress(r.spec.services(named: "clock").first, "stop-alarm", inputs: [])
        ))
    }

    static func buildPlug(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let on = r.ref("on", in: s)
        let consumptionServices = r.spec.services(named: "power-consumption") + r.spec.services
        let power = r.first("electric-power", in: consumptionServices)
        let energy = r.first("power-consumption", in: consumptionServices, where: { energyScale(for: $0) != nil })
        let energyKwh = energy.flatMap { ref -> Double? in
            guard let raw = ref.value?.doubleValue, raw.isFinite, raw >= 0,
                  let scale = energyScale(for: ref.property) else { return nil }
            return (raw * scale * 1000).rounded() / 1000
        }
        let lockService = r.spec.services(named: "physical-controls-locked").first
        let lock = lockService.flatMap { r.ref("physical-controls-locked", in: $0) }

        return .plug(PlugSpec(
            switchEntityId: MiotAddress.make(did: r.did, siid: s.iid),
            isOn: on?.value?.miotBool ?? false,
            powerWatts: power.flatMap { ref in
                guard let raw = ref.value?.doubleValue, raw.isFinite, raw >= 0,
                      let scale = powerScale(for: ref.property) else { return nil }
                let watts = raw * scale
                return watts.isFinite ? watts : nil
            },
            energyKwh: energyKwh,
            childLockEntityId: lock.map { MiotAddress.make(did: r.did, siid: $0.service.iid) },
            isChildLocked: lock?.value?.miotBool ?? false,
            powerWritable: on?.property.isWritable == true
        ))
    }

    static func buildVacuum(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let status = r.ref("status", in: s)
        let mode = r.ref("mode", in: s)
        let battery = r.first("battery-level", in: r.spec.services(named: "battery") + [s])

        let vacuumStartActions = ["start-sweep", "start-clean", "start-sweep-mop", "start-mop"]
        return .vacuum(VacuumSpec(
            entityId: MiotAddress.make(did: r.did, siid: s.iid),
            status: vacuumStatus(forDescription: status?.valueDescription),
            battery: battery?.value?.intValue,
            modeEntityId: mode.map { MiotAddress.make(did: r.did, siid: $0.service.iid) },
            currentMode: mode?.valueDescription,
            availableModes: mode?.property.valueList?.map(\.description) ?? [],
            actionsWritable: vacuumStartActions.contains { s.action(named: $0) != nil }
        ))
    }

    static func buildCamera(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let on = r.ref("on", in: s)
        let nightShot = r.ref("night-shot", in: s)
        let motionService = r.spec.services(named: "motion-detection").first
        let motion = motionService.flatMap { r.ref("motion-detection", in: $0) }
        let streamService = r.spec.services(named: "camera-stream-for-google-home")
            .first { $0.action(named: "start-hls-stream") != nil }

        return .camera(CameraSpec(
            entityId: MiotAddress.make(did: r.did, siid: s.iid),
            isOn: on?.value?.miotBool ?? false,
            nightShot: nightShot?.valueDescription,
            availableNightShots: nightShot?.property.isWritable == true ? (nightShot?.property.valueList?.map(\.description) ?? []) : [],
            motionDetectionEntityId: motion?.property.isWritable == true ? motion.map { MiotAddress.make(did: r.did, siid: $0.service.iid) } : nil,
            isMotionDetectionOn: motion?.value?.miotBool,
            streamEntityId: streamService.map { MiotAddress.make(did: r.did, siid: $0.iid) },
            powerWritable: on?.property.isWritable == true
        ))
    }

    static func buildFridge(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let mode = r.ref("mode", in: s)
        let chambers = r.spec.services(named: "fridge-chamber")
        let fridgeChamber = chambers.first(where: { ($0.property(named: "target-temperature")?.rangeMin ?? 0) >= 0 }) ?? chambers.first
        let freezerChamber = chambers.first(where: { ($0.property(named: "target-temperature")?.rangeMin ?? 0) < 0 }) ?? (chambers.count > 1 ? chambers[1] : nil)

        let fridgeTemp = fridgeChamber.flatMap { r.ref("temperature", in: $0) }
        let fridgeTarget = fridgeChamber.flatMap { r.ref("target-temperature", in: $0) }
        let freezerTemp = freezerChamber.flatMap { r.ref("temperature", in: $0) }
        let freezerTarget = freezerChamber.flatMap { r.ref("target-temperature", in: $0) }

        return .fridge(FridgeSpec(
            modeEntityId: mode?.property.isWritable == true ? MiotAddress.make(did: r.did, siid: s.iid) : nil,
            currentMode: mode?.valueDescription ?? "None",
            availableModes: mode?.property.isWritable == true ? (mode?.property.valueList?.map(\.description) ?? []) : [],
            fridgeCurrentTemp: fridgeTemp?.value?.doubleValue,
            fridgeTargetTemp: fridgeTarget?.value?.doubleValue ?? 4,
            fridgeTargetEntityId: fridgeTarget?.property.isWritable == true ? fridgeChamber.map { MiotAddress.make(did: r.did, siid: $0.iid) } : nil,
            freezerCurrentTemp: freezerTemp?.value?.doubleValue,
            freezerTargetTemp: freezerTarget?.value?.doubleValue ?? -18,
            freezerTargetEntityId: freezerTarget?.property.isWritable == true ? freezerChamber.map { MiotAddress.make(did: r.did, siid: $0.iid) } : nil
        ))
    }

    static func buildAppliance(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        if s.properties.contains(where: { $0.shortName == "on" && $0.isWritable }) {
            return buildPlug(r, s)
        }
        let status = r.ref("status", in: s)
        let hasActionControl = s.actions.contains {
            ["start-cook", "cancel-cooking", "pause"].contains($0.shortName) && $0.inputProperties.isEmpty
        }
        if hasActionControl {
            let desc = (status?.valueDescription ?? "").lowercased()
            let isActive = desc.contains("running") || desc.contains("cooking") || desc.contains("heating")
                || desc.contains("boiling") || desc.contains("preheat") || desc.contains("keep warm")
                || desc.contains("warming") || desc.contains("busy")
            return .plug(PlugSpec(
                switchEntityId: MiotAddress.make(did: r.did, siid: s.iid),
                isOn: isActive
            ))
        }
        let temp = r.ref("temperature", in: s) ?? r.ref("target-temperature", in: s)
        let leftTime = r.ref("left-time", in: s)
        _ = r.ref("ble-keep-warm-time", in: s)

        var parts: [String] = []
        if let desc = status?.valueDescription {
            parts.append(applianceStatusText(forDescription: desc))
        }
        if let t = temp?.value?.doubleValue, t.isFinite {
            parts.append("\(Int(t.rounded()))°C")
        }
        if let left = leftTime?.value?.intValue, left > 0 {
            parts.append(L10n.tr("剩余 \(left) 分", "\(left) min left"))
        }
        let fallbackText: String = switch s.shortName {
        case "kettle", "ble-kettle", "water-dispenser":
            L10n.tr("保温监控", "Water Monitor")
        default:
            L10n.tr("待机", "Standby")
        }
        return .sensor(SensorSpec(
            temperature: nil,
            humidity: nil,
            battery: nil,
            statusText: parts.isEmpty ? fallbackText : parts.joined(separator: " · ")
        ))
    }

    static func buildSensor(_ r: MiotReader, _ s: MiotService) -> DeviceKind {
        let readingServices = [s] + r.spec.services(named: "environment") + r.spec.services(named: "temperature-humidity-sensor")
        let temp = r.first("temperature", in: readingServices)
        let hum = r.first("relative-humidity", in: readingServices)
        let battery = r.first("battery-level", in: r.spec.services(named: "battery") + [s])

        var statusText: String?
        if temp == nil && hum == nil {
            switch s.shortName {
            case "lock":
                statusText = lockStatusText(r, s)
            case "motion-sensor", "occupancy-sensor":
                let motion = r.ref("motion-state", in: s) ?? r.ref("occupancy-status", in: s)
                let lux = r.first("illumination", in: [s] + r.spec.services(named: "illumination-sensor"))
                var parts: [String] = []
                if let m = motion?.value?.miotBool {
                    parts.append(m ? L10n.tr("有人移动", "Motion") : L10n.tr("无人移动", "Clear"))
                } else {
                    parts.append(L10n.tr("移动监测", "Motion Sensor"))
                }
                if let lx = lux?.value?.doubleValue, lx.isFinite {
                    parts.append("\(Int(lx.rounded())) lx")
                }
                statusText = parts.joined(separator: " · ")
            case "magnet-sensor":
                let contact = r.ref("contact-state", in: s)
                if let open = contact?.value?.miotBool {
                    statusText = open ? L10n.tr("已闭合", "Closed") : L10n.tr("已打开", "Open")
                } else {
                    statusText = L10n.tr("门窗监测", "Contact Sensor")
                }
            case "submersion-sensor":
                let sub = r.ref("submersion-state", in: s)
                if let wet = sub?.value?.miotBool {
                    statusText = wet ? L10n.tr("浸水告警", "Leak Detected") : L10n.tr("正常", "Dry")
                } else {
                    statusText = L10n.tr("水浸监测", "Leak Sensor")
                }
            case "illumination-sensor":
                let lux = r.ref("illumination", in: s)
                if let lx = lux?.value?.doubleValue, lx.isFinite {
                    statusText = "\(Int(lx.rounded())) lx"
                } else {
                    statusText = L10n.tr("光照监测", "Light Sensor")
                }
            default:
                break
            }
        }

        return .sensor(SensorSpec(
            temperature: temp?.value?.doubleValue,
            humidity: hum?.value?.doubleValue,
            battery: battery?.value?.intValue,
            statusText: statusText
        ))
    }

    /// Readable `door-state` properties the poll must refresh. A missing one is a failed read.
    static func doorStateKeys(for device: MiDeviceRecord, spec: MiotDeviceSpec) -> [MiotPropKey] {
        let scoped = specForRecord(device, spec: spec)
        var keys: [MiotPropKey] = []
        for service in scoped.services where service.shortName == "lock" || service.shortName == "door" {
            for property in service.properties where property.shortName == "door-state" && property.isReadable {
                let key = MiotPropKey(did: device.miotDid, siid: service.iid, piid: property.iid)
                if !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }

    /// `door-state` is the only property treated as the current lock condition.
    /// Event fields (`lock-action`, `abnormal-condition`) and toggles (`child-lock`, `anti-lock`)
    /// are not a fresh locked/unlocked reading. An unreadable or unmapped value stays unknown
    /// instead of claiming the door is guarding (#149).
    static func lockStatusText(_ r: MiotReader, _ s: MiotService) -> String {
        let doors = [s] + r.spec.services(named: "door")
        if let door = r.first("door-state", in: doors),
           let description = door.valueDescription,
           let text = interpretedLockStatus(description) {
            return text
        }
        return L10n.tr("锁状态未知", "Lock status unknown")
    }

    static func interpretedLockStatus(_ description: String) -> String? {
        let lower = description.lowercased()
        if lower.contains("child") || lower.contains("童锁") || lower.contains("反锁")
            || lower.contains("anti-lock") || lower.contains("antilock") {
            return nil
        }
        if lower.contains("unlock") || lower.contains("已开锁") || lower.contains("未上锁")
            || lower.contains("not locked") || lower.contains("未锁") {
            return L10n.tr("已开锁", "Unlocked")
        }
        if (lower.contains("ajar") || lower.contains("虚掩")),
           !lower.contains("解除"), !lower.contains("clear"), !lower.contains("release") {
            return L10n.tr("门虚掩", "Ajar")
        }
        if lower.contains("not closed") || lower.contains("not close") || lower.contains("未关") || lower.contains("没关") {
            return L10n.tr("门未关", "Not Closed")
        }
        if lower.contains("jam") || lower.contains("卡住") {
            return L10n.tr("门锁卡住", "Jammed")
        }
        if lower.contains("locked") || lower.contains("已上锁") || lower.contains("已锁") {
            return L10n.tr("已上锁", "Locked")
        }
        return nil
    }

    /// A cached door reading must not keep claiming a security state after the device goes offline.
    static func redactOfflineLockClaim(_ kind: DeviceKind) -> DeviceKind {
        guard case .sensor(var sensor) = kind,
              let text = sensor.statusText,
              affirmativeLockStatuses.contains(text) else { return kind }
        sensor.statusText = L10n.tr("锁状态未知", "Lock status unknown")
        return .sensor(sensor)
    }

    private static var affirmativeLockStatuses: Set<String> {
        [
            L10n.tr("已上锁", "Locked"),
            L10n.tr("已开锁", "Unlocked"),
            L10n.tr("门虚掩", "Ajar"),
            L10n.tr("门未关", "Not Closed"),
            L10n.tr("门锁卡住", "Jammed"),
            L10n.tr("正在上锁", "Locking"),
            L10n.tr("正在开锁", "Unlocking"),
            L10n.tr("守护中", "Guarding"),
        ]
    }

    // MARK: Value Translation

    static func percent(fromRaw raw: Double, property: MiotProperty) -> Int {
        let scaled: Double
        if let max = property.rangeMax, max > 0, max != 100 {
            scaled = raw / max * 100
        } else {
            scaled = raw
        }
        return Swift.max(0, Swift.min(100, Int(scaled.rounded())))
    }

    static func speedPercent(fromRaw raw: Double, property: MiotProperty) -> Int {
        if let lo = property.rangeMin, let hi = property.rangeMax, hi > lo {
            let scaled = lo > 1 ? (raw - lo) / (hi - lo) * 100 : (hi != 100 ? raw / hi * 100 : raw)
            return Swift.max(0, Swift.min(100, Int(scaled.rounded())))
        }
        if let list = property.valueList, !list.isEmpty {
            let vals = list.map(\.value)
            if let hi = vals.max(), let lo = vals.min(), hi > lo {
                let scaled = lo > 1
                    ? (raw - Double(lo)) / Double(hi - lo) * 100
                    : raw / Double(hi) * 100
                return Swift.max(0, Swift.min(100, Int(scaled.rounded())))
            }
        }
        return percent(fromRaw: raw, property: property)
    }

    private static func hasScaleToken(_ comment: String, _ token: String) -> Bool {
        var searchRange = comment.startIndex..<comment.endIndex
        while let range = comment.range(of: token, range: searchRange) {
            let prevIndex = range.lowerBound > comment.startIndex ? comment.index(before: range.lowerBound) : nil
            let prevChar = prevIndex.map { comment[$0] }
            let isPartOfOtherNumber = prevChar.map { $0.isNumber || $0 == "." } ?? false
            if !isPartOfOtherNumber {
                return true
            }
            searchRange = range.upperBound..<comment.endIndex
        }
        return false
    }

    /// Some released specs declare watt but document centiwatts in the comment (#129).
    /// Only explicit metadata changes the scale; magnitude and range-step never do.
    static func powerScale(for property: MiotProperty) -> Double? {
        let unit = (property.unit ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        let comment = (property.comment ?? "").lowercased()
            .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
        for (token, scale) in [("0.001", 0.001), ("0.01", 0.01), ("0.1", 0.1)] {
            let pattern = "(?<![0-9.])" + NSRegularExpression.escapedPattern(for: token) + "(?:watt|w)(?![a-z])"
            if comment.range(of: pattern, options: .regularExpression) != nil || unit == token + "w" || unit == token + "watt" {
                return scale
            }
        }
        switch unit {
        case "", "none", "w", "watt": return 1
        case "kw", "kilowatt": return 1000
        case "mw", "milliwatt": return 0.001
        default: return nil
        }
    }

    /// Scale factor that converts a MIoT `power-consumption` reading into kWh (#62).
    /// Returns `nil` when an integer property has neither a recognized `unit` nor an explicit
    /// scale in `comment` (e.g. "0.01kwh"), so ambiguous raw integers are never guessed.
    static func energyScale(for property: MiotProperty) -> Double? {
        let unit = (property.unit ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        let comment = (property.comment ?? "")
            .lowercased()
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        if unit == "wh" || unit == "watt-hour" || unit == "0.001kwh" || hasScaleToken(comment, "0.001kwh") {
            return 0.001
        }
        if unit == "0.01kwh" || hasScaleToken(comment, "0.01kwh") {
            return 0.01
        }
        if unit == "kwh" || unit == "kilowatt-hour" || unit == "1kwh" || hasScaleToken(comment, "1kwh") {
            return 1.0
        }
        if property.format == "float", unit.isEmpty || unit == "none" {
            return 1.0
        }
        return nil
    }

    /// MIoT mode descriptions → the HA hvac vocabulary the UI already localizes.
    static func hvacMode(forDescription description: String) -> String? {
        switch description.lowercased().trimmingCharacters(in: .whitespaces) {
        case "cool", "cooling", "cold": return "cool"
        case "heat", "heating", "warm": return "heat"
        case "dry", "dehumidify", "dehumidification", "dehumidifier": return "dry"
        case "fan", "fan only", "fan-only", "fan_only", "wind", "ventilate": return "fan_only"
        case "auto", "automatic", "smart": return "auto"
        default: return nil
        }
    }

    static func vacuumStatus(forDescription description: String?) -> String {
        guard let d = description?.lowercased() else { return "idle" }
        if d.contains("go charging") || d.contains("returning") || d.contains("go home") || d.contains("back to") || d.contains("recharge") {
            return "returning"
        }
        if d.contains("paus") { return "paused" }
        if d.contains("sweep") || d.contains("clean") || d.contains("mop") || d.contains("working") || d.contains("busy") {
            return "cleaning"
        }
        if d.contains("charg") || d.contains("dock") || d.contains("full") { return "docked" }
        return "idle"
    }

    static func applianceStatusText(forDescription description: String) -> String {
        let lower = description.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("idle") || lower.contains("standby") || lower.contains("off") || lower.contains("shutdown") {
            return L10n.tr("待机", "Standby")
        }
        if lower.contains("keep warm") || lower.contains("keep-warm") || lower.contains("warm") || lower.contains("insulation") {
            return L10n.tr("保温中", "Keep Warm")
        }
        if lower.contains("cook") || lower.contains("work") || lower.contains("busy") || lower.contains("run") || lower.contains("boil") || lower.contains("heat") {
            return L10n.tr("运行中", "Running")
        }
        if lower.contains("preheat") {
            return L10n.tr("预热中", "Preheating")
        }
        if lower.contains("delay") || lower.contains("appoint") || lower.contains("reservation") {
            return L10n.tr("预约中", "Scheduled")
        }
        if lower.contains("paus") {
            return L10n.tr("已暂停", "Paused")
        }
        if lower.contains("finish") || lower.contains("complete") || lower.contains("cooked") {
            return L10n.tr("已完成", "Completed")
        }
        if lower.contains("error") || lower.contains("fault") {
            return L10n.tr("故障", "Fault")
        }
        return description
    }
}

// MARK: - Recording Property Reader

/// Resolves properties by short name and records every readable (did, siid, piid) it touches,
/// so `requiredProps` is derived from the builders themselves instead of a parallel list.
final class MiotReader {
    struct Ref {
        let service: MiotService
        let property: MiotProperty
        let value: JSONValue?

        var valueDescription: String? {
            value?.intValue.flatMap { property.description(forValue: $0) }
        }
    }

    let did: String
    let spec: MiotDeviceSpec
    private let values: [MiotPropKey: JSONValue]
    private(set) var touched: [MiotPropKey] = []

    init(did: String, spec: MiotDeviceSpec, values: [MiotPropKey: JSONValue]) {
        self.did = did
        self.spec = spec
        self.values = values
    }

    func ref(_ name: String, in service: MiotService) -> Ref? {
        refs(name, in: service).first
    }

    func refs(_ name: String, in service: MiotService) -> [Ref] {
        service.properties.filter { $0.shortName == name && $0.isReadable }.map { make(service, $0) }
    }

    /// First readable match across `services` in order (duplicates ignored).
    func first(
        _ name: String,
        in services: [MiotService],
        where predicate: (MiotProperty) -> Bool = { _ in true }
    ) -> Ref? {
        var seen: Set<Int> = []
        for service in services where seen.insert(service.iid).inserted {
            if let p = service.properties.first(where: { $0.shortName == name && $0.isReadable && predicate($0) }) {
                return make(service, p)
            }
        }
        return nil
    }

    private func make(_ service: MiotService, _ property: MiotProperty) -> Ref {
        let key = MiotPropKey(did: did, siid: service.iid, piid: property.iid)
        if !touched.contains(key) { touched.append(key) }
        return Ref(service: service, property: property, value: values[key])
    }
}

extension JSONValue {
    /// MIoT booleans occasionally arrive as 0/1.
    var miotBool: Bool? {
        if let b = boolValue { return b }
        return doubleValue.map { $0 != 0 }
    }
}
