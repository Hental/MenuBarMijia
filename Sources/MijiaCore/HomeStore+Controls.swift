import Foundation

// Primary toggle and detail-drawer controls backed by optimistic state (#48).
extension HomeStore {
    /// A manual card action was confirmed by the device: GrokBall celebrates (#114) and the action
    /// is recorded into the habit memory for the current time bucket (#113).
    /// Returns the receipt so an undo banner can roll the record back; nil when learning is off.
    @discardableResult
    func confirmManualControl(intents: [DeviceIntent]) -> UserHabitMemory.RecordingReceipt? {
        celebrateGrokBall()
        guard isHabitLearningEnabled, !intents.isEmpty else { return nil }
        var memory = userHabitMemory
        let receipt = memory.record(utterance: nil, intents: intents, devices: devices, scenes: scenes)
        userHabitMemory = memory
        return receipt
    }

    // MARK: - Primary Toggle & Manual Light Memory

    @discardableResult
    public func togglePrimary(_ device: SmartDevice) -> Task<Bool, Never>? {
        guard device.isOnline else {
            showToast(L10n.tr("\(device.name) 当前离线（可能断电）", "\(device.name) is offline (unplugged)"), isError: true)
            return nil
        }
        guard device.isPrimaryToggleable else {
            if device.hasDetailDrawer { toggleExpanded(device.id) }
            return nil
        }
        guard let idx = devices.firstIndex(where: { $0.id == device.id }) else { return nil }
        let previous = devices[idx]
        guard !rejectControlWhileLocked() else { return nil }
        let operation: IntentOperation
        switch previous.kind {
        case .vacuum(let spec):
            operation = .power(!spec.isCleaning)
        case .plug(let spec) where spec.switchEntityId.hasPrefix("button."):
            // A momentary plug button may toggle or trigger something; treat it as an activation.
            operation = .power(true)
        default:
            operation = .power(!previous.isActiveOn)
        }
        guard allowManualControl(operation, for: previous) else { return nil }
        var updated = previous
        var command: DeviceCommand?

        switch updated.kind {
        case .light(var s):
            s.isOn.toggle()
            updated.kind = .light(s)
            command = .setLightPower(entityId: s.entityId, isOn: s.isOn)

        case .climate(var s):
            s.isOn.toggle()
            let targetMode = s.isOn ? (s.hvacMode == "off" ? (s.availableModes.first(where: { $0 != "off" }) ?? "heat") : s.hvacMode) : "off"
            s.hvacMode = targetMode
            updated.kind = .climate(s)
            command = .setClimatePower(entityId: s.entityId, isOn: s.isOn, fallbackMode: targetMode)

        case .fan(var s):
            s.isOn.toggle()
            updated.kind = .fan(s)
            command = .setFanPower(entityId: s.entityId, isOn: s.isOn)

        case .plug(var s):
            if s.switchEntityId.hasPrefix("button.") {
                command = .pressButton(entityId: s.switchEntityId)
            } else {
                s.isOn.toggle()
                updated.kind = .plug(s)
                command = .setSwitch(entityId: s.switchEntityId, isOn: s.isOn)
            }

        case .vacuum(var s):
            let startCleaning = !s.isCleaning
            s.status = startCleaning ? "cleaning" : "returning"
            updated.kind = .vacuum(s)
            command = .vacuumAction(entityId: s.entityId, action: startCleaning ? .start : .returnToBase)

        case .tv(var s):
            let turnOn = (s.state == "off" || s.state == "standby")
            s.state = turnOn ? "on" : "standby"
            if turnOn { s.isScreenOff = false }
            updated.kind = .tv(s)
            if LGWebOSProtocol.isLGEntity(s.mediaEntityId) {
                command = .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: turnOn)
            } else if turnOn, let btnId = s.turnOnButtonId {
                command = .pressButton(entityId: btnId)
            } else {
                toggleExpanded(device.id)
                return nil
            }


        case .camera(var s):
            s.isOn.toggle()
            updated.kind = .camera(s)
            command = .setSwitch(entityId: s.entityId, isOn: s.isOn)
        case .speaker, .fridge, .sensor:
            toggleExpanded(device.id)
            return nil
        }

        guard let cmd = command else { return nil }
        let isMomentaryButton = device.isMomentaryButton
        if isMomentaryButton {
            return Task {
                do {
                    try await self.executeDeviceCommand(cmd)
                    self.celebrateGrokBall()
                    self.showToast(L10n.tr("已触发 \(device.name)", "Triggered \(device.name)"), isError: false)
                    return true
                } catch {
                    self.showToast(L10n.tr("\(device.name) 触发失败", "Failed to trigger \(device.name)"), isError: true)
                    return false
                }
            }
        }

        guard let ticket = self.claimReadBack(device.id) else { return nil }

        return Task {
            defer { self.finishReadBack(device.id, ticket: ticket) }
            do {
                try await self.executeDeviceCommand(cmd)
                switch await self.confirmToggleReadBack(deviceId: device.id, requested: updated, ticket: ticket) {
                case .matched:
                    let shown = self.devices.first(where: { $0.id == device.id }) ?? updated
                    self.confirmManualControl(intents: [DeviceIntent(targetId: device.id, operation: .power(updated.isActiveOn))])
                    if case .light = shown.kind, shown.isActiveOn {
                        self.recordManualLightUse(device.id)
                    }
                    return true
                case .unmatched:
                    self.showToast(
                        L10n.tr("\(device.name) 未能读回状态", "\(device.name) state was not read back"),
                        isError: true
                    )
                    return false
                case .superseded:
                    return true
                }
            } catch {
                self.showToast(L10n.tr("\(device.name) 响应失败", "\(device.name) failed to respond"), isError: true)
                return false
            }
        }
    }

    private enum ReadBackConfirm {
        case matched
        case unmatched
        case superseded
    }

    private func claimReadBack(_ deviceId: String) -> UInt64? {
        guard readBackOwner[deviceId] == nil else { return nil }
        nextReadBackTicket &+= 1
        let ticket = nextReadBackTicket
        readBackOwner[deviceId] = ticket
        latestReadBackTicket[deviceId] = ticket
        readBackInFlightTicket[deviceId] = ticket
        waitingDeviceIds.insert(deviceId)
        return ticket
    }

    /// Releases the tap and the waiting label before the echo retry, while the read-back stays
    /// in flight so its snapshots still bypass an older optimistic lock.
    private func releaseReadBackOwner(_ deviceId: String, ticket: UInt64) {
        guard readBackOwner[deviceId] == ticket else { return }
        readBackOwner[deviceId] = nil
        waitingDeviceIds.remove(deviceId)
    }

    private func finishReadBack(_ deviceId: String, ticket: UInt64) {
        if readBackOwner[deviceId] == ticket {
            readBackOwner[deviceId] = nil
            waitingDeviceIds.remove(deviceId)
        }
        // The echo release may already have cleared the owner; only the latest task clears
        // the lock exemption, so a newer toggle keeps it alive.
        if readBackInFlightTicket[deviceId] == ticket {
            readBackInFlightTicket[deviceId] = nil
        }
    }

    /// Applies a provider snapshot when one was published. Providers with no property read
    /// keep the accepted power and leave every other field on the current row. A published
    /// read that still shows the old power is polled once more, because a device often
    /// reports the previous value immediately after a write. That second wait releases the
    /// tap so a newer toggle, such as the next keyboard press, is not discarded.
    private func confirmToggleReadBack(deviceId: String, requested: SmartDevice, ticket: UInt64) async -> ReadBackConfirm {
        if case .tv(let spec) = requested.kind, LGWebOSProtocol.isLGEntity(spec.mediaEntityId) {
            // The LAN client confirms TV writes; the cloud has no row for this device, and a
            // stale provider snapshot must not revert the accepted power.
            applyConfirmedPower(from: requested, deviceId: deviceId)
            lockOptimistic(deviceId, duration: .seconds(2.0))
            return powerMatches(deviceId, requested: requested) ? .matched : .unmatched
        }
        let before = snapshotGeneration
        let read = await provider.readBack(deviceId: deviceId)
        await settleSnapshot(after: before)
        switch read {
        case .failed:
            return .unmatched
        case .unavailable:
            applyConfirmedPower(from: requested, deviceId: deviceId)
            // HA rebuilds the whole home on every state_changed event, so an unrelated sensor
            // update could restore the old power before the device's own update arrives.
            lockOptimistic(deviceId, duration: .seconds(2.0))
            return powerMatches(deviceId, requested: requested) ? .matched : .unmatched
        case .published:
            guard snapshotGeneration != before else { return .unmatched }
            if powerMatches(deviceId, requested: requested) { return .matched }
            releaseReadBackOwner(deviceId, ticket: ticket)
            let again = snapshotGeneration
            if holdReadBackEcho {
                isHoldingReadBackEcho = true
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.readBackEchoHold = cont
                }
            } else {
                try? await Task.sleep(for: readBackEchoDelay)
            }
            if latestReadBackTicket[deviceId] != ticket { return .superseded }
            let second = await provider.readBack(deviceId: deviceId)
            if latestReadBackTicket[deviceId] != ticket { return .superseded }
            if case .failed = second { return .unmatched }
            await settleSnapshot(after: again)
            // A newer toggle may have started and even finished during the second read.
            if latestReadBackTicket[deviceId] != ticket { return .superseded }
            return powerMatches(deviceId, requested: requested) ? .matched : .unmatched
        }
    }

    private func powerMatches(_ deviceId: String, requested: SmartDevice) -> Bool {
        devices.first(where: { $0.id == deviceId })?.isActiveOn == requested.isActiveOn
    }

    private func applyConfirmedPower(from requested: SmartDevice, deviceId: String) {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[idx] = devices[idx].applyingConfirmedPower(from: requested)
    }

    private func settleSnapshot(after generation: UInt64) async {
        guard snapshotGeneration == generation else { return }
        for _ in 0..<20 where snapshotGeneration == generation {
            await Task.yield()
            if snapshotGeneration != generation { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func recordManualLightUse(_ deviceId: String) {
        if let current = lastManuallyUsedLightId, current == deviceId { return }
        lastManuallyUsedLightId = deviceId
        userDefaults.set(deviceId, forKey: Self.lastManualLightIdKey)
    }

    // MARK: - Detail Drawer Controls (Debounced & Optimistic)

    public func setLightBrightness(_ deviceId: String, percent: Int) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .light(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isOn = percent > 0
        s.brightnessPercent = percent
        devices[idx].kind = .light(s)
        if s.isOn { recordManualLightUse(deviceId) }
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchDebounced(
            key: "\(deviceId).brightness",
            deviceId: deviceId,
            fallback: previous,
            command: .setLightBrightness(entityId: s.entityId, percent: percent),
            habitIntents: [.init(targetId: deviceId, operation: .brightness(percent))]
        )
    }

    public func setLightColorTemp(_ deviceId: String, kelvin: Int) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .light(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isOn = true
        s.colorTempKelvin = kelvin
        s.currentEffect = nil
        devices[idx].kind = .light(s)
        recordManualLightUse(deviceId)
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchDebounced(
            key: "\(deviceId).colortemp",
            deviceId: deviceId,
            fallback: previous,
            command: .setLightColorTemp(entityId: s.entityId, kelvin: kelvin),
            habitIntents: [.init(targetId: deviceId, operation: .colorTemperature(kelvin))]
        )
    }

    public func setLightEffect(_ deviceId: String, effect: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .light(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isOn = true
        s.currentEffect = effect
        devices[idx].kind = .light(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        recordManualLightUse(deviceId)

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setLightEffect(entityId: s.entityId, effect: effect),
            habitIntents: [.init(targetId: deviceId, operation: .lightEffect(effect))]
        )
    }

    public func stepClimateTemperature(_ deviceId: String, delta: Double) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .climate(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        let nextTemp = max(s.minTemp, min(s.maxTemp, s.targetTemperature + delta))
        guard allowManualControl(.targetTemperature(nextTemp), for: previous) else { return }
        s.targetTemperature = nextTemp
        devices[idx].kind = .climate(s)
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchDebounced(
            key: "\(deviceId).temp",
            deviceId: deviceId,
            fallback: previous,
            command: .setClimateTemperature(entityId: s.entityId, temperature: nextTemp),
            habitIntents: [.init(targetId: deviceId, operation: .targetTemperature(nextTemp))]
        )
    }

    public func setClimateMode(_ deviceId: String, mode: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .climate(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        guard allowManualControl(.hvacMode(mode), for: previous) else { return }
        s.hvacMode = mode
        s.isOn = (mode != "off")
        devices[idx].kind = .climate(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setClimateMode(entityId: s.entityId, hvacMode: mode),
            habitIntents: [.init(targetId: deviceId, operation: .hvacMode(mode))]
        )
    }

    public func setClimateFanMode(_ deviceId: String, fanMode: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .climate(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        guard allowManualControl(.fanSpeed(fanMode), for: previous) else { return }
        s.fanMode = fanMode
        devices[idx].kind = .climate(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setClimateFanMode(entityId: s.entityId, fanMode: fanMode),
            habitIntents: [.init(targetId: deviceId, operation: .fanSpeed(fanMode))]
        )
    }

    public func setClimateSwingMode(_ deviceId: String, swingMode: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .climate(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        guard allowManualControl(.oscillation(swingMode.caseInsensitiveCompare("off") != .orderedSame), for: previous) else { return }
        s.swingMode = swingMode
        devices[idx].kind = .climate(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setClimateSwingMode(entityId: s.entityId, swingMode: swingMode)
        )
    }

    public func setFanPercentage(_ deviceId: String, percent: Int) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .fan(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        let clamped = max(1, min(100, percent))
        s.isOn = true
        s.percentage = clamped
        if let favMode = s.availablePresetModes.first(where: { $0.caseInsensitiveCompare("Favorite") == .orderedSame }) {
            s.presetMode = favMode
        }
        devices[idx].kind = .fan(s)
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchDebounced(
            key: "\(deviceId).fanpercent",
            deviceId: deviceId,
            fallback: previous,
            command: .setFanPercentage(entityId: s.entityId, percent: clamped),
            habitIntents: s.availablePresetModes.first(where: { $0.caseInsensitiveCompare("Favorite") == .orderedSame })
                .map { [DeviceIntent(targetId: deviceId, operation: .fanSpeed($0))] } ?? []
        )
    }

    public func setFanPresetMode(_ deviceId: String, preset: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .fan(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isOn = true
        s.presetMode = preset
        devices[idx].kind = .fan(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setFanPresetMode(entityId: s.entityId, presetMode: preset),
            habitIntents: [.init(targetId: deviceId, operation: .fanSpeed(preset))]
        )
    }

    public func setPlugChildLock(_ deviceId: String, locked: Bool) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .plug(var s) = devices[idx].kind,
              let lockEid = s.childLockEntityId else { return }
        let previous = devices[idx]
        s.isChildLocked = locked
        devices[idx].kind = .plug(s)
        lockOptimistic(deviceId, duration: .seconds(2.0))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSwitch(entityId: lockEid, isOn: locked)
        )
    }

    public func setFridgeMode(_ deviceId: String, mode: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .fridge(var s) = devices[idx].kind,
              let modeEid = s.modeEntityId else { return }
        let previous = devices[idx]
        s.currentMode = mode
        devices[idx].kind = .fridge(s)
        lockOptimistic(deviceId, duration: .seconds(2.0))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSelectOption(entityId: modeEid, option: mode)
        )
    }

    public func stepFridgeTargetTemp(_ deviceId: String, isFreezer: Bool, delta: Double) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .fridge(var s) = devices[idx].kind else { return }
        let previous = devices[idx]

        if isFreezer {
            guard let eid = s.freezerTargetEntityId else { return }
            let next = max(-24, min(-15, s.freezerTargetTemp + delta))
            s.freezerTargetTemp = next
            devices[idx].kind = .fridge(s)
            lockOptimistic(deviceId, duration: .seconds(2.5))
            dispatchDebounced(
                key: "\(deviceId).freezer",
                deviceId: deviceId,
                fallback: previous,
                command: .setNumberValue(entityId: eid, value: next)
            )
        } else {
            guard let eid = s.fridgeTargetEntityId else { return }
            let next = max(2, min(8, s.fridgeTargetTemp + delta))
            s.fridgeTargetTemp = next
            devices[idx].kind = .fridge(s)
            lockOptimistic(deviceId, duration: .seconds(2.5))
            dispatchDebounced(
                key: "\(deviceId).fridge",
                deviceId: deviceId,
                fallback: previous,
                command: .setNumberValue(entityId: eid, value: next)
            )
        }
    }

    public func performVacuumAction(_ deviceId: String, action: VacuumAction) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .vacuum(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        guard allowManualControl(action == .start ? .power(true) : .power(false), for: previous) else { return }
        switch action {
        case .start: s.status = "cleaning"
        case .pause: s.status = "paused"
        case .returnToBase: s.status = "returning"
        }
        devices[idx].kind = .vacuum(s)
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .vacuumAction(entityId: s.entityId, action: action)
        )
    }

    public func setSpeakerVolume(_ deviceId: String, percent: Int) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        let previous = devices[idx]
        let clamped = max(0, min(100, percent))

        let mediaEid: String
        switch devices[idx].kind {
        case .speaker(var s):
            s.volumePercent = clamped
            devices[idx].kind = .speaker(s)
            mediaEid = s.mediaEntityId
        case .tv(var s):
            s.volumePercent = clamped
            devices[idx].kind = .tv(s)
            mediaEid = s.mediaEntityId
        default:
            return
        }

        lockOptimistic(deviceId, duration: .seconds(2.5))
        dispatchDebounced(
            key: "\(deviceId).volume",
            deviceId: deviceId,
            fallback: previous,
            command: .mediaSetVolume(entityId: mediaEid, volumeLevel: Double(clamped) / 100.0)
        )
    }

    public func toggleSpeakerMute(_ deviceId: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .speaker(var s) = devices[idx].kind,
              let muteEid = s.muteSwitchEntityId else { return }
        let previous = devices[idx]
        s.isMuted.toggle()
        devices[idx].kind = .speaker(s)
        lockOptimistic(deviceId, duration: .seconds(2.0))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSwitch(entityId: muteEid, isOn: s.isMuted)
        )
    }

    public func toggleTVMute(_ deviceId: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .tv(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isMuted.toggle()
        devices[idx].kind = .tv(s)
        lockOptimistic(deviceId, duration: .seconds(2.0))

        let entityId = LGWebOSProtocol.isLGEntity(s.mediaEntityId) ? LGWebOSProtocol.muteEntityId : s.mediaEntityId
        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSwitch(entityId: entityId, isOn: s.isMuted)
        )
    }

    public func toggleTVScreenOff(_ deviceId: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .tv(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.isScreenOff.toggle()
        if !s.isScreenOff && (s.state == "off" || s.state == "standby") {
            s.state = "on"
        }
        devices[idx].kind = .tv(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSwitch(entityId: LGWebOSProtocol.screenOffEntityId, isOn: s.isScreenOff)
        )
    }

    public func selectTVSource(_ deviceId: String, source: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .tv(var s) = devices[idx].kind else { return }
        let previous = devices[idx]
        s.currentSource = source
        s.state = "on"
        s.isScreenOff = false
        devices[idx].kind = .tv(s)
        lockOptimistic(deviceId, duration: .seconds(2.5))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .mediaSelectSource(entityId: s.mediaEntityId, source: source)
        )
    }

    public func sendSpeakerText(_ deviceId: String, text: String, asDirective: Bool) {
        guard !rejectControlWhileLocked() else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .speaker(let s) = devices[idx].kind else { return }

        let targetEid = asDirective ? s.directiveNotifyEntityId : s.ttsNotifyEntityId
        guard let eid = targetEid else {
            showToast(L10n.tr("该音箱不支持此指令通道", "This speaker does not support that channel"), isError: true)
            return
        }

        Task {
            do {
                try await executeDeviceCommand(.sendNotifyMessage(entityId: eid, message: trimmed))
                showToast(
                    asDirective
                        ? L10n.tr("已向小爱下发指令：「\(trimmed)」", "Sent command to XiaoAi: \"\(trimmed)\"")
                        : L10n.tr("小爱已播报：「\(trimmed)」", "XiaoAi announced: \"\(trimmed)\"")
                )
            } catch {
                showToast(L10n.tr("发送失败：\(error.localizedDescription)", "Failed to send: \(error.localizedDescription)"), isError: true)
            }
        }
    }

    public func pressDeviceButton(_ buttonEntityId: String, label: String) {
        guard !rejectControlWhileLocked() else { return }
        Task {
            do {
                try await executeDeviceCommand(.pressButton(entityId: buttonEntityId))
                showToast(L10n.tr("已触发：\(label)", "Triggered: \(label)"))
            } catch {
                showToast(L10n.tr("\(label) 执行失败", "\(label) failed"), isError: true)
            }
        }
    }

    // MARK: - Camera Controls & Live Stream Resolution (#97)

    public func setCameraMotionDetection(_ deviceId: String, enabled: Bool) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .camera(var s) = devices[idx].kind,
              let motionEid = s.motionDetectionEntityId else { return }
        let previous = devices[idx]
        s.isMotionDetectionOn = enabled
        devices[idx].kind = .camera(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSwitch(entityId: motionEid, isOn: enabled)
        )
    }

    public func setCameraNightShot(_ deviceId: String, mode: String) {
        guard !rejectControlWhileLocked() else { return }
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }),
              case .camera(var s) = devices[idx].kind,
              s.availableNightShots.contains(mode) else { return }
        let previous = devices[idx]
        s.nightShot = mode
        devices[idx].kind = .camera(s)
        lockOptimistic(deviceId, duration: .seconds(2.2))

        dispatchImmediate(
            deviceId: deviceId,
            fallback: previous,
            command: .setSelectOption(entityId: s.entityId, option: mode)
        )
    }

    public func openCameraLiveView(_ deviceId: String) {
        guard let device = devices.first(where: { $0.id == deviceId }),
              case .camera = device.kind else { return }
        guard device.isOnline else {
            showToast(L10n.tr("\(device.name) 当前离线", "\(device.name) is offline"), isError: true)
            return
        }
        activeLiveCameraDeviceId = device.id
        onOpenCameraLiveView?(device)
    }

    public func cameraCustomStreamURL(for deviceId: String) -> String? {
        guard let map = userDefaults.dictionary(forKey: Self.cameraStreamURLsKey) as? [String: String],
              let raw = map[deviceId]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    public func setCameraCustomStreamURL(_ urlString: String?, for deviceId: String) {
        var map = (userDefaults.dictionary(forKey: Self.cameraStreamURLsKey) as? [String: String]) ?? [:]
        let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            map.removeValue(forKey: deviceId)
        } else {
            map[deviceId] = trimmed
        }
        userDefaults.set(map, forKey: Self.cameraStreamURLsKey)
    }

    public func cameraStreamQuality(for deviceId: String) -> XiaomiCameraStreamQuality {
        guard let map = userDefaults.dictionary(forKey: Self.cameraStreamQualityKey) as? [String: String],
              let raw = map[deviceId],
              let quality = XiaomiCameraStreamQuality(rawValue: raw) else {
            return .storageDefault
        }
        return quality
    }

    public func setCameraStreamQuality(_ quality: XiaomiCameraStreamQuality, for deviceId: String) {
        var map = (userDefaults.dictionary(forKey: Self.cameraStreamQualityKey) as? [String: String]) ?? [:]
        map[deviceId] = quality.rawValue
        userDefaults.set(map, forKey: Self.cameraStreamQualityKey)
    }

    public func resolveCameraStream(for deviceId: String) async throws -> CameraStreamSource {
        guard let device = devices.first(where: { $0.id == deviceId }),
              case .camera = device.kind else {
            throw HomeProviderError.serviceCallFailed(400, L10n.tr("未找到该摄像头设备", "Camera device not found"))
        }
        if let custom = cameraCustomStreamURL(for: deviceId),
           let url = URL(string: custom),
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https") {
            let lower = custom.lowercased()
            if lower.contains("stream.mp4") {
                return .liveMP4(url, mjpegFallback: nil)
            }
            if lower.contains("mjpeg") || lower.contains("mpjpeg") {
                return .mjpeg(url)
            }
            if lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains("snapshot") || lower.contains("camera_proxy") || lower.contains("frame.jpeg") {
                return .snapshot(url)
            }
            return .hls(url)
        }
        return try await provider.resolveCameraStream(for: device, quality: cameraStreamQuality(for: deviceId))
    }

    public func stopCameraStream(for deviceId: String) async {
        guard let device = devices.first(where: { $0.id == deviceId }) else { return }
        await provider.stopCameraStream(for: device)
    }

    // MARK: - Internal Dispatch Helpers

    private func dispatchImmediate(
        deviceId: String,
        fallback: SmartDevice,
        command: DeviceCommand,
        habitIntents: [DeviceIntent] = []
    ) {
        let expectedRevision = optimisticLockRevision[deviceId]
        Task {
            do {
                try await executeDeviceCommand(command)
                confirmManualControl(intents: habitIntents)
            } catch {
                if self.optimisticLockRevision[deviceId] == expectedRevision {
                    if let idx = self.devices.firstIndex(where: { $0.id == deviceId }) {
                        self.devices[idx] = fallback
                    }
                    self.optimisticLockUntil.removeValue(forKey: deviceId)
                }
                self.showToast(L10n.tr("\(fallback.name) 操作未生效", "\(fallback.name) action failed"), isError: true)
            }
        }
    }

    private func dispatchDebounced(
        key: String,
        deviceId: String,
        fallback: SmartDevice,
        command: DeviceCommand,
        habitIntents: [DeviceIntent] = []
    ) {
        let expectedRevision = optimisticLockRevision[deviceId]
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: self?.controlDebounceInterval ?? .milliseconds(280))
            guard !Task.isCancelled, let self, self.optimisticLockRevision[deviceId] == expectedRevision else { return }
            do {
                try await self.executeDeviceCommand(command)
                self.confirmManualControl(intents: habitIntents)
            } catch {
                if self.optimisticLockRevision[deviceId] == expectedRevision {
                    if let idx = self.devices.firstIndex(where: { $0.id == deviceId }) {
                        self.devices[idx] = fallback
                    }
                    self.optimisticLockUntil.removeValue(forKey: deviceId)
                }
                self.showToast(L10n.tr("\(fallback.name) 调节未生效", "\(fallback.name) adjustment failed"), isError: true)
            }
        }
    }
}
