import Foundation

// Scenes, quick actions, 全关 and the unified undo banner (#48).
extension HomeStore {
    func invalidateUndoContext() {
        controlContextID = UUID()
        undoTimerTask?.cancel()
        undoBanner = nil
        lastAssistantUndo = nil
        setAssistantState(.idle)
        pendingCloudConsent = nil
        assistantSuggestions = []
        aiProactiveSuggestions = nil
        proactiveRefreshTask?.cancel()
        proactiveRefreshTask = nil
        isProactiveRecommending = false
        proactiveRetryEarliest = nil
        isGrokBallStageExpanded = false
        grokBallCelebrationTask?.cancel()
        grokBallCelebrationUntil = nil
        optimisticLockUntil.removeAll()
        // A different home is a different suggestion context even at the same ambient signature (Codex #116 review).
        lastProactiveRefreshSignature = nil
        for task in debounceTasks.values { task.cancel() }
        debounceTasks.removeAll()
    }

    // MARK: - Scenes & Built-In QuickActions with 5-Second Undo

    @discardableResult
    public func triggerScene(_ scene: HomeScene) -> Task<Bool, Never> {
        guard !rejectControlWhileLocked() else { return Task { false } }
        return Task {
            do {
                try await executeDeviceCommand(.activateScene(entityId: scene.entityId))
                confirmManualControl(intents: [.init(targetId: scene.id, operation: .activateScene)])
                showToast(L10n.tr("已触发场景：\(scene.name)", "Activated scene: \(scene.name)"))
                return true
            } catch {
                showToast(L10n.tr("场景「\(scene.name)」执行失败", "Scene \"\(scene.name)\" failed"), isError: true)
                return false
            }
        }
    }

    @discardableResult
    public func executeQuickAction(
        _ action: QuickAction,
        undoBannerDuration: TimeInterval? = nil,
        recordsHabits: Bool = true,
        respectScreenLock: Bool = true
    ) -> Task<Void, Never>? {
        if respectScreenLock, rejectControlWhileLocked() { return nil }
        let previousSnapshot = devices
        var commands: [(deviceId: String, command: DeviceCommand)] = []
        var restoreCommands: [DeviceCommand] = []
        var affectedDeviceIds: Set<String> = []
        var habitIntents: [DeviceIntent] = []

        switch action {
        case .lightsOff:
            for idx in devices.indices where devices[idx].isOnline {
                guard case .light(var s) = devices[idx].kind, s.isOn, s.powerWritable else { continue }
                let deviceId = devices[idx].id
                affectedDeviceIds.insert(deviceId)
                habitIntents.append(.init(targetId: deviceId, operation: .power(false)))
                lockOptimistic(deviceId, duration: .seconds(3.0))
                commands.append((deviceId, .setLightPower(entityId: s.entityId, isOn: false)))
                restoreCommands.append(.setLightPower(entityId: s.entityId, isOn: true))
                s.isOn = false
                devices[idx].kind = .light(s)
            }

        case .softNightLight:
            var targetIndices = devices.indices.filter { idx in
                guard devices[idx].isOnline, case .light(let s) = devices[idx].kind else { return false }
                return s.isOn && s.brightnessWritable && s.colorWritable
            }
            if targetIndices.isEmpty {
                let isOnlineLight = { (dev: SmartDevice) -> Bool in
                    if dev.isOnline, case .light(let spec) = dev.kind {
                        return spec.brightnessWritable && spec.colorWritable
                    }
                    return false
                }
                // Prefer the light the user last switched on by hand; otherwise the first light (#36).
                let fallbackIdx = lastManuallyUsedLightId.flatMap { lastLightId in
                    devices.indices.first(where: { isOnlineLight(devices[$0]) && devices[$0].id == lastLightId })
                } ?? devices.indices.first(where: { isOnlineLight(devices[$0]) })
                if let fallbackIdx {
                    targetIndices = [fallbackIdx]
                    if lastManuallyUsedLightId == nil {
                        // No manual pick yet: remember the light this action chose so the next tap is stable.
                        recordManualLightUse(devices[fallbackIdx].id)
                    }
                }
            }
            for idx in targetIndices {
                guard case .light(var s) = devices[idx].kind else { continue }
                let deviceId = devices[idx].id
                affectedDeviceIds.insert(deviceId)
                habitIntents.append(.init(targetId: deviceId, operation: .brightness(15)))
                habitIntents.append(.init(targetId: deviceId, operation: .colorTemperature(max(s.minKelvin, 2700))))
                lockOptimistic(deviceId, duration: .seconds(3.0))
                let prevOn = s.isOn
                let prevBri = s.brightnessPercent ?? 80
                let prevKelvin = s.colorTempKelvin ?? 4000
                commands.append((deviceId, .setLightBrightness(entityId: s.entityId, percent: 15)))
                commands.append((deviceId, .setLightColorTemp(entityId: s.entityId, kelvin: max(s.minKelvin, 2700))))
                if prevOn {
                    restoreCommands.append(.setLightBrightness(entityId: s.entityId, percent: prevBri))
                    restoreCommands.append(.setLightColorTemp(entityId: s.entityId, kelvin: prevKelvin))
                } else {
                    restoreCommands.append(.setLightPower(entityId: s.entityId, isOn: false))
                }
                s.isOn = true
                s.brightnessPercent = 15
                s.colorTempKelvin = max(s.minKelvin, 2700)
                s.currentEffect = nil
                devices[idx].kind = .light(s)
            }

        case .climateSleepOff:
            for idx in devices.indices where devices[idx].isOnline {
                let deviceId = devices[idx].id
                switch devices[idx].kind {
                case .climate(var s) where s.isOn && s.hvacMode != "off" && s.powerWritable:
                    let prevMode = s.hvacMode
                    affectedDeviceIds.insert(deviceId)
                    habitIntents.append(.init(targetId: deviceId, operation: .power(false)))
                    lockOptimistic(deviceId, duration: .seconds(3.0))
                    commands.append((deviceId, .setClimatePower(entityId: s.entityId, isOn: false, fallbackMode: prevMode)))
                    restoreCommands.append(.setClimatePower(entityId: s.entityId, isOn: true, fallbackMode: prevMode))
                    s.isOn = false
                    s.hvacMode = "off"
                    devices[idx].kind = .climate(s)
                case .fan(var s) where s.isOn && s.powerWritable:
                    affectedDeviceIds.insert(deviceId)
                    habitIntents.append(.init(targetId: deviceId, operation: .power(false)))
                    lockOptimistic(deviceId, duration: .seconds(3.0))
                    commands.append((deviceId, .setFanPower(entityId: s.entityId, isOn: false)))
                    restoreCommands.append(.setFanPower(entityId: s.entityId, isOn: true))
                    s.isOn = false
                    devices[idx].kind = .fan(s)
                default:
                    break
                }
            }
        }

        guard !commands.isEmpty else {
            showToast(L10n.tr("当前无需执行「\(action.title)」", "No devices need \"\(action.title)\""))
            return nil
        }

        scheduleUndoBanner(
            title: L10n.tr("已执行「\(action.title)」", "Executed \"\(action.title)\""),
            restoreCommands: restoreCommands,
            previousDevices: previousSnapshot,
            deviceCount: affectedDeviceIds.count,
            habitReceipt: nil,
            duration: undoBannerDuration
        )
        guard let bannerId = undoBanner?.id else { return nil }

        let context = controlContextID
        return Task {
            var failedDeviceIds: Set<String> = []
            for item in commands {
                guard context == controlContextID else { return }
                do {
                    try await executeDeviceCommand(item.command)
                } catch {
                    failedDeviceIds.insert(item.deviceId)
                }
            }
            // Habits train only on confirmed success, and only while the banner this action
            // created is still the live one (an undo or expiry cancels the learning) (#113).
            let succeededIntents = habitIntents.filter { !failedDeviceIds.contains($0.targetId) }
            guard context == controlContextID, !succeededIntents.isEmpty, recordsHabits, undoBanner?.id == bannerId else { return }
            undoBanner?.habitReceipt = confirmManualControl(intents: succeededIntents)
        }
    }

    // MARK: - Turn All Off with Undo

    /// Plugs often power a router, fridge or NAS, and 全关 should not send a cleaning vacuum home (#23).
    public nonisolated static func joinsAllOffByDefault(_ device: SmartDevice) -> Bool {
        switch device.kind {
        case .plug, .vacuum, .camera, .cover: return false
        default: return true
        }
    }

    public func joinsAllOff(_ device: SmartDevice) -> Bool {
        allOffOverrides[device.id] ?? Self.joinsAllOffByDefault(device)
    }

    public func setJoinsAllOff(_ joins: Bool, deviceId: String) {
        guard let device = devices.first(where: { $0.id == deviceId }) else { return }
        allOffOverrides[deviceId] = joins == Self.joinsAllOffByDefault(device) ? nil : joins
    }

    /// What 全关 turns off: devices on screen right now (current room, not hidden) that are on,
    /// take part in 全关, and can actually be switched off from here.
    public var allOffTargets: [SmartDevice] {
        filteredDevices.filter { $0.isActiveOn && joinsAllOff($0) && Self.allOffChange(for: $0) != nil }
    }

    public var allOffScopeName: String? {
        switch listCut {
        case .all:
            return nil
        case .room(let id):
            return rooms.first { $0.id == id }?.name
        case .kind(let tag):
            return tag.chipTitle
        }
    }

    /// The command that switches `device` off, the one that brings it back, and the optimistic state.
    nonisolated static func allOffChange(for device: SmartDevice) -> (off: DeviceCommand, restore: DeviceCommand, kind: DeviceKind)? {
        guard device.kind.canTogglePower else { return nil }
        switch device.kind {
        case .light(var s):
            s.isOn = false
            return (.setLightPower(entityId: s.entityId, isOn: false), .setLightPower(entityId: s.entityId, isOn: true), .light(s))
        case .climate(var s):
            let prevMode = s.hvacMode
            s.isOn = false
            s.hvacMode = "off"
            return (
                .setClimatePower(entityId: s.entityId, isOn: false, fallbackMode: prevMode),
                .setClimatePower(entityId: s.entityId, isOn: true, fallbackMode: prevMode),
                .climate(s)
            )
        case .fan(var s):
            s.isOn = false
            return (.setFanPower(entityId: s.entityId, isOn: false), .setFanPower(entityId: s.entityId, isOn: true), .fan(s))
        case .plug(var s):
            s.isOn = false
            return (.setSwitch(entityId: s.switchEntityId, isOn: false), .setSwitch(entityId: s.switchEntityId, isOn: true), .plug(s))
        case .vacuum(var s):
            s.status = "returning"
            return (.vacuumAction(entityId: s.entityId, action: .returnToBase), .vacuumAction(entityId: s.entityId, action: .start), .vacuum(s))
        case .tv(var s):
            guard LGWebOSProtocol.isLGEntity(s.mediaEntityId) else { return nil }
            s.state = "standby"
            return (
                .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: false),
                .setSwitch(entityId: LGWebOSProtocol.powerEntityId, isOn: true),
                .tv(s)
            )
        case .camera(var s):
            s.isOn = false
            return (.setSwitch(entityId: s.entityId, isOn: false), .setSwitch(entityId: s.entityId, isOn: true), .camera(s))
        case .speaker, .fridge, .sensor, .cover:
            return nil
        }
    }

    public func turnAllOff() {
        guard !rejectControlWhileLocked() else { return }
        let targetIds = Set(allOffTargets.map(\.id))
        guard !targetIds.isEmpty else {
            showToast(L10n.tr("当前没有开启的设备", "No active devices are currently on"))
            return
        }
        recordOnboardingMilestone(.turnedAllOff)

        let previousSnapshot = devices
        var offCommands: [(deviceId: String, command: DeviceCommand)] = []
        var restoreCommands: [DeviceCommand] = []
        var habitIntents: [DeviceIntent] = []

        for idx in devices.indices where targetIds.contains(devices[idx].id) {
            guard let change = Self.allOffChange(for: devices[idx]) else { continue }
            let deviceId = devices[idx].id
            // A vacuum returning home has no power op, so it executes but does not train a habit (#113).
            if UserHabitMemory.isPowerToggleable(devices[idx]) {
                habitIntents.append(.init(targetId: deviceId, operation: .power(false)))
            }
            lockOptimistic(deviceId, duration: .seconds(3.0))
            offCommands.append((deviceId, change.off))
            restoreCommands.append(change.restore)
            devices[idx].kind = change.kind
        }

        scheduleUndoBanner(
            title: L10n.tr("已关闭 \(offCommands.count) 台设备", "Turned off \(offCommands.count) device(s)"),
            restoreCommands: restoreCommands,
            previousDevices: previousSnapshot,
            deviceCount: targetIds.count,
            habitReceipt: nil,
            isAllOff: true
        )
        guard let bannerId = undoBanner?.id else { return }

        let context = controlContextID
        Task {
            var failedDeviceIds: Set<String> = []
            for item in offCommands {
                guard context == controlContextID else { return }
                do {
                    try await executeDeviceCommand(item.command)
                } catch {
                    failedDeviceIds.insert(item.deviceId)
                }
            }
            // Habits train only on confirmed success while this action's banner is live (#113).
            let succeededIntents = habitIntents.filter { !failedDeviceIds.contains($0.targetId) }
            guard context == controlContextID, !succeededIntents.isEmpty, undoBanner?.id == bannerId else { return }
            undoBanner?.habitReceipt = confirmManualControl(intents: succeededIntents)
        }
    }

    /// How long the 撤销 banner stays after 全关 and similar bulk actions (#23): 10 s for one or two
    /// devices, 15 s from three on so the user can read which devices the AI touched (#53).
    nonisolated static func undoBannerSeconds(forDeviceCount count: Int) -> Double {
        count >= 3 ? 15 : 10
    }

    func scheduleUndoBanner(
        title: String,
        restoreCommands: [DeviceCommand],
        previousDevices: [SmartDevice],
        deviceCount: Int,
        habitReceipt: UserHabitMemory.RecordingReceipt? = nil,
        duration: TimeInterval? = nil,
        isAllOff: Bool = false
    ) {
        let banner = UndoBanner(
            title: title,
            restoreCommands: restoreCommands,
            previousDevices: previousDevices,
            habitReceipt: habitReceipt,
            duration: duration,
            isAllOff: isAllOff
        )
        self.undoBanner = banner
        undoTimerTask?.cancel()
        // `duration` overrides the panel's 10/15 s rule for automation, which usually fires while
        // the panel is closed (#59).
        let seconds = duration ?? Self.undoBannerSeconds(forDeviceCount: deviceCount)
        undoTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if self?.undoBanner?.id == banner.id {
                self?.undoBanner = nil
            }
        }
    }

    @discardableResult
    public func undoTurnAllOff() -> Task<Void, Never>? {
        guard let banner = undoBanner else { return nil }
        lastAssistantUndo = nil
        undoTimerTask?.cancel()
        self.undoBanner = nil
        let undoRevision = undoStateRevision
        let preUndoById = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        let applicable = applyUndoCommands(banner.restoreCommands, previousDevices: banner.previousDevices)
        if applicable.isEmpty, !banner.restoreCommands.isEmpty {
            showToast(L10n.tr("设备状态已变化，无法撤销", "Device state changed; cannot undo"), isError: true)
            return nil
        }
        if !applicable.isEmpty, banner.isAllOff { recordOnboardingMilestone(.undidAllOff) }

        let context = controlContextID
        return Task {
            var failedCommands: [DeviceCommand] = []
            var failedDeviceIds: Set<String> = []
            var failedNames: [String] = []
            for item in applicable {
                guard context == controlContextID else { return }
                if failedDeviceIds.contains(item.deviceId) {
                    failedCommands.append(item.command)
                    continue
                }
                do {
                    try await executeDeviceCommand(item.command)
                } catch {
                    failedCommands.append(item.command)
                    failedDeviceIds.insert(item.deviceId)
                    if !failedNames.contains(item.deviceName) {
                        failedNames.append(item.deviceName)
                    }
                }
            }
            guard context == controlContextID else { return }
            if failedCommands.isEmpty {
                if let receipt = banner.habitReceipt {
                    var memory = userHabitMemory
                    memory.unrecord(receipt)
                    userHabitMemory = memory
                }
                showToast(L10n.tr("已恢复关闭前的状态", "Restored previous device states"))
                return
            }

            rollbackFailedUndoDevices(failedDeviceIds, applicable: applicable, preUndoById: preUndoById)

            var remainingReceipt: UserHabitMemory.RecordingReceipt?
            if let receipt = banner.habitReceipt {
                let (succeededPart, remainingPart) = Self.partitionHabitReceipt(receipt, failedDeviceIds: failedDeviceIds)
                if let succeededPart {
                    var memory = userHabitMemory
                    memory.unrecord(succeededPart)
                    userHabitMemory = memory
                }
                remainingReceipt = remainingPart
            }

            if undoStateRevision == undoRevision {
                scheduleUndoBanner(
                    title: banner.title,
                    restoreCommands: failedCommands,
                    previousDevices: banner.previousDevices,
                    deviceCount: failedDeviceIds.count,
                    habitReceipt: remainingReceipt,
                    duration: banner.duration,
                    isAllOff: banner.isAllOff
                )
            }
            let sep = L10n.isEnglish ? ", " : "、"
            let list = failedNames.joined(separator: sep)
            showToast(
                L10n.tr(
                    "撤销未完成：\(list) 未响应，可再次点击撤销重试",
                    "Undo incomplete: \(list) did not respond; tap Undo to retry"
                ),
                isError: true
            )
        }
    }

    struct UndoApplicableCommand: Sendable {
        let command: DeviceCommand
        let deviceId: String
        let deviceName: String
        let lockRevision: UInt64
    }

    func applyUndoCommands(
        _ commands: [DeviceCommand],
        previousDevices: [SmartDevice] = []
    ) -> [UndoApplicableCommand] {
        var applicable: [UndoApplicableCommand] = []
        for command in commands {
            if let idx = devices.indices.first(where: { Self.undoEffect(of: command, on: devices[$0]) != nil }),
               let restored = Self.undoEffect(of: command, on: devices[idx]) {
                let name = devices[idx].name
                devices[idx] = restored
                let rev = lockOptimistic(restored.id, duration: .seconds(3.0))
                applicable.append(
                    UndoApplicableCommand(
                        command: command,
                        deviceId: restored.id,
                        deviceName: name,
                        lockRevision: rev
                    )
                )
                continue
            }

            guard let prev = previousDevices.first(where: { Self.undoEffect(of: command, on: $0) != nil }),
                  let idx = devices.indices.first(where: { devices[$0].id == prev.id && devices[$0].isOnline }),
                  let retargeted = Self.retargetedUndoEffect(of: command, on: devices[idx]) else {
                continue
            }
            let name = devices[idx].name
            devices[idx] = retargeted.updated
            let rev = lockOptimistic(retargeted.updated.id, duration: .seconds(3.0))
            applicable.append(
                UndoApplicableCommand(
                    command: retargeted.command,
                    deviceId: retargeted.updated.id,
                    deviceName: name,
                    lockRevision: rev
                )
            )
        }
        return applicable
    }

    func rollbackFailedUndoDevices(
        _ failedDeviceIds: Set<String>,
        applicable: [UndoApplicableCommand],
        preUndoById: [String: SmartDevice]
    ) {
        var expectedRevisions: [String: UInt64] = [:]
        for item in applicable {
            expectedRevisions[item.deviceId] = item.lockRevision
        }
        for failedId in failedDeviceIds {
            guard optimisticLockRevision[failedId] == expectedRevisions[failedId] else { continue }
            if let pre = preUndoById[failedId],
               let idx = devices.firstIndex(where: { $0.id == failedId }) {
                devices[idx] = pre
            }
            optimisticLockUntil.removeValue(forKey: failedId)
        }
    }

    nonisolated static func partitionHabitReceipt(
        _ receipt: UserHabitMemory.RecordingReceipt,
        failedDeviceIds: Set<String>
    ) -> (succeeded: UserHabitMemory.RecordingReceipt?, remaining: UserHabitMemory.RecordingReceipt?) {
        if failedDeviceIds.isEmpty {
            return (receipt, nil)
        }
        let succeededEntries = receipt.entries.filter { !failedDeviceIds.contains($0.targetId) }
        let remainingEntries = receipt.entries.filter { failedDeviceIds.contains($0.targetId) }
        let succeededSequences = receipt.sequences.filter { !failedDeviceIds.contains($0.targetId) }
        let remainingSequences = receipt.sequences.filter { failedDeviceIds.contains($0.targetId) }

        let lastRemainingEntry = remainingEntries.last
        let fallbackLastAction: UserHabitMemory.LastAction? = lastRemainingEntry.flatMap { entry in
            receipt.recordedLastAction.map { recorded in
                UserHabitMemory.LastAction(
                    targetId: entry.targetId,
                    operationKey: entry.operationKey,
                    recordedAt: recorded.recordedAt
                )
            }
        }
        let preserveOnSucceeded = lastRemainingEntry != nil && fallbackLastAction == nil

        let succeeded: UserHabitMemory.RecordingReceipt? =
            (succeededEntries.isEmpty && succeededSequences.isEmpty)
            ? nil
            : UserHabitMemory.RecordingReceipt(
                entries: succeededEntries,
                phrase: nil,
                sequences: succeededSequences,
                previousLastAction: lastRemainingEntry != nil ? fallbackLastAction : receipt.previousLastAction,
                recordedLastAction: receipt.recordedLastAction,
                preserveLastAction: preserveOnSucceeded
            )
        let remaining: UserHabitMemory.RecordingReceipt? =
            (remainingEntries.isEmpty && remainingSequences.isEmpty && receipt.phrase == nil)
            ? nil
            : UserHabitMemory.RecordingReceipt(
                entries: remainingEntries,
                phrase: receipt.phrase,
                sequences: remainingSequences,
                previousLastAction: receipt.previousLastAction,
                recordedLastAction: fallbackLastAction ?? receipt.recordedLastAction
            )
        return (succeeded, remaining)
    }
}
