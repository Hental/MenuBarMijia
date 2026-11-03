import Foundation

/// Keeps both providers connected and publishes one merged home. Commands are routed by their
/// target address, so an entity id decides the source without a second lookup table.
public actor DualSourceHomeProvider: HomeProvider {
    public typealias CanonicalIDPersistence = @Sendable ([String: String]) -> Void

    private let homeAssistant: (any HomeProvider)?
    private let xiaomiCloud: (any HomeProvider)?
    private let knownPreferenceIDs: @Sendable () -> Set<String>
    private let pinnedBackends: @Sendable () -> [String: HomeBackend]
    private let persistCanonicalIDs: CanonicalIDPersistence

    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var started = false

    private var haStatus: ConnectionStatus = .connecting
    private var miStatus: ConnectionStatus = .connecting
    private var haSnapshot: SynthesizedHome?
    private var miSnapshot: SynthesizedHome?
    private var lastStatus: ConnectionStatus?

    private var canonical: CanonicalDeviceRegistry
    private var rooms = RoomIdentityRegistry()
    private var routes: [String: DeviceMergeRoute] = [:]
    private var activeCameraRoutes: [String: DeviceMergeRoute] = [:]

    public init(
        homeAssistant: (any HomeProvider)?,
        xiaomiCloud: (any HomeProvider)?,
        initialCanonicalIDs: [String: String] = [:],
        knownPreferenceIDs: @escaping @Sendable () -> Set<String> = { [] },
        pinnedBackends: @escaping @Sendable () -> [String: HomeBackend] = { [:] },
        persistCanonicalIDs: @escaping CanonicalIDPersistence = { _ in }
    ) {
        self.homeAssistant = homeAssistant
        self.xiaomiCloud = xiaomiCloud
        self.canonical = CanonicalDeviceRegistry(assignments: initialCanonicalIDs)
        self.knownPreferenceIDs = knownPreferenceIDs
        self.pinnedBackends = pinnedBackends
        self.persistCanonicalIDs = persistCanonicalIDs
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        continuation = cont
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        if let homeAssistant {
            tasks.append(Task { [weak self] in
                for await event in homeAssistant.events() {
                    guard let self else { return }
                    await self.handle(event, from: .homeAssistant)
                }
                await self?.sourceStreamFinished(.homeAssistant)
            })
        }
        if let xiaomiCloud {
            tasks.append(Task { [weak self] in
                for await event in xiaomiCloud.events() {
                    guard let self else { return }
                    await self.handle(event, from: .xiaomiCloud)
                }
                await self?.sourceStreamFinished(.xiaomiCloud)
            })
        }
        emitStatus(force: true)
    }

    private func handle(_ event: HomeProviderEvent, from backend: HomeBackend) {
        switch event {
        case .statusChanged(let status):
            if backend == .homeAssistant {
                haStatus = status
                if case .disconnected = status { haSnapshot = nil }
            } else if backend == .xiaomiCloud {
                miStatus = status
                if case .disconnected = status { miSnapshot = nil }
            }
            emitStatus()
            recompute()

        case .sessionExpired(let session):
            continuation?.yield(.sessionExpired(session))

        case .snapshotUpdated(let home):
            if backend == .homeAssistant {
                haStatus = .connected
                haSnapshot = home
            } else if backend == .xiaomiCloud {
                miStatus = .connected
                miSnapshot = home
            }
            emitStatus()
            recompute()
        }
    }

    private func sourceStreamFinished(_ backend: HomeBackend) {
        if backend == .homeAssistant {
            haStatus = .disconnected("")
            haSnapshot = nil
        } else if backend == .xiaomiCloud {
            miStatus = .disconnected("")
            miSnapshot = nil
        }
        emitStatus()
        recompute()
    }

    private func emitStatus(force: Bool = false) {
        guard let status = aggregateStatus() else { return }
        guard force || status != lastStatus else { return }
        lastStatus = status
        continuation?.yield(.statusChanged(status))
    }

    private func aggregateStatus() -> ConnectionStatus? {
        var statuses: [ConnectionStatus] = []
        if homeAssistant != nil { statuses.append(haStatus) }
        if xiaomiCloud != nil { statuses.append(miStatus) }
        guard !statuses.isEmpty else { return nil }
        if statuses.contains(where: { $0.isConnected }) { return .connected }
        if statuses.contains(where: { status in
            if case .connecting = status { return true }
            return false
        }) {
            return .connecting
        }
        for status in statuses {
            if case .disconnected(let reason) = status, !reason.isEmpty {
                return .disconnected(reason)
            }
        }
        return statuses.first
    }

    private func recompute() {
        guard haSnapshot != nil || miSnapshot != nil else { return }
        let result = DeviceDeduplicator.merge(
            homeAssistant: haSnapshot,
            xiaomiCloud: miSnapshot,
            canonical: canonical,
            rooms: rooms,
            knownPreferenceIDs: knownPreferenceIDs(),
            pinnedBackends: pinnedBackends()
        )
        if result.canonical != canonical {
            canonical = result.canonical
            persistCanonicalIDs(result.canonical.assignments)
        }
        rooms = result.rooms
        routes = result.routes
        for (deviceID, activeRoute) in activeCameraRoutes {
            let nextRoute = result.routes[deviceID]
            if nextRoute?.backend != activeRoute.backend || nextRoute?.sourceDeviceID != activeRoute.sourceDeviceID {
                activeCameraRoutes.removeValue(forKey: deviceID)
                let ha = homeAssistant
                let mi = xiaomiCloud
                Task {
                    switch activeRoute.backend {
                    case .homeAssistant:
                        await ha?.stopCameraStream(for: activeRoute.sourceDevice)
                    case .xiaomiCloud:
                        await mi?.stopCameraStream(for: activeRoute.sourceDevice)
                    case .demo:
                        break
                    }
                }
            }
        }
        var home = result.home
        home.sourceStatuses = configuredSourceStatuses()
        continuation?.yield(.snapshotUpdated(home))
    }

    private func configuredSourceStatuses() -> [HomeBackend: ConnectionStatus] {
        var statuses: [HomeBackend: ConnectionStatus] = [:]
        if homeAssistant != nil { statuses[.homeAssistant] = haStatus }
        if xiaomiCloud != nil { statuses[.xiaomiCloud] = miStatus }
        return statuses
    }

    // MARK: - Commands

    public func execute(_ command: DeviceCommand) async throws {
        if MiotAddress.parse(command.targetEntityId) != nil {
            guard let xiaomiCloud else {
                throw HomeProviderError.serviceCallFailed(
                    503,
                    L10n.tr("米家云端未配置", "Xiaomi Cloud is not configured")
                )
            }
            try await xiaomiCloud.execute(command)
        } else {
            guard let homeAssistant else {
                throw HomeProviderError.serviceCallFailed(
                    503,
                    L10n.tr("Home Assistant 未配置", "Home Assistant is not configured")
                )
            }
            try await homeAssistant.execute(command)
        }
    }

    public func readBack(deviceId: String) async -> ControlReadBack {
        guard let route = routes[deviceId] else { return .failed }
        switch route.backend {
        case .homeAssistant:
            guard let homeAssistant else { return .failed }
            return await homeAssistant.readBack(deviceId: route.sourceDeviceID)
        case .xiaomiCloud:
            guard let xiaomiCloud else { return .failed }
            return await xiaomiCloud.readBack(deviceId: route.sourceDeviceID)
        case .demo:
            return .unavailable
        }
    }

    // MARK: - Polling

    public func refreshNow() async {
        let ha = homeAssistant
        let mi = xiaomiCloud
        await withTaskGroup(of: Void.self) { group in
            if let ha { group.addTask { await ha.refreshNow() } }
            if let mi { group.addTask { await mi.refreshNow() } }
        }
    }

    public func setPollingContext(_ context: PollingContext) async {
        let ha = homeAssistant
        let mi = xiaomiCloud
        await withTaskGroup(of: Void.self) { group in
            if let ha { group.addTask { await ha.setPollingContext(context) } }
            if let mi { group.addTask { await mi.setPollingContext(context) } }
        }
    }

    // MARK: - History & Camera Routing

    public func fetchSensorHistory(
        deviceId: String,
        window: SensorHistoryWindow,
        now: Date
    ) async -> [SensorHistorySample] {
        guard let route = routes[deviceId] else { return [] }
        switch route.backend {
        case .homeAssistant:
            guard let homeAssistant else { return [] }
            return await homeAssistant.fetchSensorHistory(
                deviceId: route.sourceDeviceID,
                window: window,
                now: now
            )
        case .xiaomiCloud:
            guard let xiaomiCloud else { return [] }
            return await xiaomiCloud.fetchSensorHistory(
                deviceId: route.sourceDeviceID,
                window: window,
                now: now
            )
        case .demo:
            return []
        }
    }

    public func resolveCameraStream(for device: SmartDevice) async throws -> CameraStreamSource {
        try await resolveCameraStream(for: device, quality: .hd)
    }

    public func resolveCameraStream(
        for device: SmartDevice,
        quality: XiaomiCameraStreamQuality
    ) async throws -> CameraStreamSource {
        if let route = routes[device.id] {
            if let previous = activeCameraRoutes[device.id],
               (previous.backend != route.backend || previous.sourceDeviceID != route.sourceDeviceID) {
                await stopCameraStream(for: previous)
            }
            switch route.backend {
            case .homeAssistant:
                if let homeAssistant {
                    let source = try await homeAssistant.resolveCameraStream(for: route.sourceDevice, quality: quality)
                    activeCameraRoutes[device.id] = route
                    return source
                }
            case .xiaomiCloud:
                if let xiaomiCloud {
                    let source = try await xiaomiCloud.resolveCameraStream(for: route.sourceDevice, quality: quality)
                    activeCameraRoutes[device.id] = route
                    return source
                }
            case .demo:
                break
            }
        }
        if case .camera(let spec) = device.kind,
           MiotAddress.parse(spec.entityId) != nil,
           let xiaomiCloud {
            let source = try await xiaomiCloud.resolveCameraStream(for: device, quality: quality)
            activeCameraRoutes[device.id] = DeviceMergeRoute(
                backend: .xiaomiCloud,
                sourceDeviceID: device.id,
                sourceDevice: device
            )
            return source
        }
        if let homeAssistant {
            let source = try await homeAssistant.resolveCameraStream(for: device, quality: quality)
            activeCameraRoutes[device.id] = DeviceMergeRoute(
                backend: .homeAssistant,
                sourceDeviceID: device.id,
                sourceDevice: device
            )
            return source
        }
        if let xiaomiCloud {
            let source = try await xiaomiCloud.resolveCameraStream(for: device, quality: quality)
            activeCameraRoutes[device.id] = DeviceMergeRoute(
                backend: .xiaomiCloud,
                sourceDeviceID: device.id,
                sourceDevice: device
            )
            return source
        }
        throw HomeProviderError.serviceCallFailed(
            501,
            L10n.tr("未配置数据源", "No data source is configured")
        )
    }

    public func stopCameraStream(for device: SmartDevice) async {
        let activeRoute = activeCameraRoutes.removeValue(forKey: device.id)
        let currentRoute = routes[device.id]
        if let activeRoute {
            await stopCameraStream(for: activeRoute)
        }
        if let currentRoute,
           (currentRoute.backend != activeRoute?.backend || currentRoute.sourceDeviceID != activeRoute?.sourceDeviceID) {
            await stopCameraStream(for: currentRoute)
        }
        if activeRoute != nil || currentRoute != nil {
            return
        }
        if case .camera(let spec) = device.kind, MiotAddress.parse(spec.entityId) != nil {
            await xiaomiCloud?.stopCameraStream(for: device)
            return
        }
        await homeAssistant?.stopCameraStream(for: device)
        await xiaomiCloud?.stopCameraStream(for: device)
    }

    private func stopCameraStream(for route: DeviceMergeRoute) async {
        switch route.backend {
        case .homeAssistant:
            await homeAssistant?.stopCameraStream(for: route.sourceDevice)
        case .xiaomiCloud:
            await xiaomiCloud?.stopCameraStream(for: route.sourceDevice)
        case .demo:
            break
        }
    }

    public func shutdown() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        continuation?.finish()
        continuation = nil
        if let ha = homeAssistant as? HAWebSocketProvider {
            Task { await ha.shutdown() }
        }
        if let mi = xiaomiCloud as? MiAccountsProvider {
            Task { await mi.shutdown() }
        } else if let mi = xiaomiCloud as? MiCloudProvider {
            Task { await mi.shutdown() }
        }
    }
}

extension DualSourceHomeProvider: DualSourceRecomputing {
    /// Re-merges cached snapshots after a source pin changes, without polling either backend.
    public nonisolated func requestRecompute() {
        Task { await self.recompute() }
    }
}
