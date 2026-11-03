import AppKit
import Foundation
import MijiaCore
import Observation

// MARK: - On-demand "unsupported devices" scan (#45)

/// Why an on-demand scan could not run. Localized so the settings row can show the reason.
enum UnsupportedDeviceScanError: LocalizedError {
    case notSignedIn
    case invalidURL
    case invalidResponse
    case unauthorized
    case rejected

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return L10n.tr("尚未登录对应账号，无法扫描", "Sign in first to scan")
        case .invalidURL:
            return L10n.tr("地址无效", "Invalid address")
        case .invalidResponse:
            return L10n.tr("服务端返回了无法识别的数据", "The server returned unrecognized data")
        case .unauthorized:
            return L10n.tr("令牌被拒绝", "The token was rejected")
        case .rejected:
            return L10n.tr("请求被服务端拒绝", "The request was rejected by the server")
        }
    }
}

/// Reads the raw device registry of the current backend *on demand* and reports what the panel
/// skipped. It is deliberately a separate read-only path: the live providers are untouched, so
/// opening Settings cannot change what the dashboard shows.
@Observable
@MainActor
final class UnsupportedDeviceScanner {
    static let shared = UnsupportedDeviceScanner()

    private(set) var devices: [UnsupportedDevice] = []
    private(set) var isScanning = false
    private(set) var errorMessage: String?
    private(set) var lastScannedAt: Date?

    private init() {}

    func scan(store: HomeStore) async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }

        if store.homeBackend == .demo {
            // Strictly offline: nothing is skipped, and nothing may be requested (#47).
            devices = []
            lastScannedAt = Date()
            return
        }

        let scanMi = store.hasMiSource || (!store.hasHASource && store.homeBackend == .xiaomiCloud)
        let scanHA = store.hasHASource || (!store.hasMiSource && store.homeBackend == .homeAssistant)
        var results: [UnsupportedDevice] = []
        var errors: [String] = []

        if scanMi {
            do {
                results += try await Self.scanMiCloud()
            } catch {
                errors.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        if scanHA {
            do {
                results += try await Self.scanHomeAssistant(baseURL: store.serverURLString)
            } catch {
                errors.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }

        devices = results
        errorMessage = errors.first
        lastScannedAt = Date()
    }

    // MARK: Mi Cloud

    private nonisolated static func scanMiCloud() async throws -> [UnsupportedDevice] {
        guard let session = MiSessionStore.loadAccounts().first?.session else {
            throw UnsupportedDeviceScanError.notSignedIn
        }
        let api = MiCloudClient(session: session)
        let records = try await api.deviceList()

        var specs: [String: MiotDeviceSpec] = [:]
        var pending: [String: String?] = [:]
        for record in records where specs[record.model] == nil {
            pending[record.model] = record.specType
        }
        let source = MiotSpecStore()
        for (model, specType) in pending {
            // Cached specs answer instantly; a miss costs one request and only affects this scan.
            if let spec = try? await source.spec(model: model, specType: specType) {
                specs[model] = spec
            }
        }

        let home = MiotSynthesizer.synthesize(devices: records, rooms: [], specs: specs, values: [:])
        return UnsupportedDeviceCollector.miCloud(devices: records, specs: specs, synthesized: home)
    }

    // MARK: Home Assistant

    private nonisolated static func scanHomeAssistant(baseURL: String) async throws -> [UnsupportedDevice] {
        let token = KeychainHelper.loadToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw UnsupportedDeviceScanError.notSignedIn
        }
        let registry = try await readHomeAssistantRegistry(baseURL: baseURL, token: token)
        let home = DeviceSynthesizer.synthesize(
            areas: registry.areas,
            devices: registry.devices,
            entities: registry.entities,
            states: registry.states
        )
        return UnsupportedDeviceCollector.homeAssistant(
            devices: registry.devices,
            entities: registry.entities,
            synthesized: home
        )
    }

    private struct HomeAssistantRegistry: Sendable {
        var areas: [HAAreaEntry]
        var devices: [HADeviceEntry]
        var entities: [HAEntityEntry]
        var states: [String: HAEntityState]
    }

    /// One-shot WebSocket read of the four registries. Uses the unchanged public decoding types and
    /// the same synthesis entry point as the live provider.
    private nonisolated static func readHomeAssistantRegistry(
        baseURL: String,
        token: String
    ) async throws -> HomeAssistantRegistry {
        guard let url = webSocketURL(from: baseURL) else {
            throw UnsupportedDeviceScanError.invalidURL
        }

        let configuration = URLSessionConfiguration.ephemeral
        // Same as the live provider: talk to the LAN directly instead of through a system proxy.
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 15
        // Bounds the whole socket read so a half-open connection cannot leave Settings spinning.
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        // Local closures keep the non-Sendable socket inside this one task.
        func send(_ object: [String: JSONValue]) async throws {
            let data = try JSONEncoder().encode(JSONValue.object(object))
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        }
        func receive() async throws -> [String: JSONValue] {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case .string(let text):
                data = Data(text.utf8)
            case .data(let payload):
                data = payload
            @unknown default:
                throw UnsupportedDeviceScanError.invalidResponse
            }
            let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
            guard case .object(let object) = decoded else {
                throw UnsupportedDeviceScanError.invalidResponse
            }
            return object
        }

        // 1. auth_required, then the token.
        _ = try await receive()
        try await send(["type": .string("auth"), "access_token": .string(token)])
        let auth = try await receive()
        guard auth["type"]?.stringValue == "auth_ok" else {
            throw UnsupportedDeviceScanError.unauthorized
        }

        // 2. Ask for areas, devices, entities and states in one batch.
        let commands: [(Int, String)] = [
            (1, "config/area_registry/list"),
            (2, "config/device_registry/list"),
            (3, "config/entity_registry/list"),
            (4, "get_states"),
        ]
        for (id, type) in commands {
            try await send(["id": .number(Double(id)), "type": .string(type)])
        }

        var results: [Int: JSONValue] = [:]
        while results.count < commands.count {
            let message = try await receive()
            guard message["type"]?.stringValue == "result", let id = message["id"]?.intValue else { continue }
            guard message["success"]?.boolValue == true else {
                throw UnsupportedDeviceScanError.rejected
            }
            if let result = message["result"] {
                results[id] = result
            }
        }

        guard let areasValue = results[1],
              let devicesValue = results[2],
              let entitiesValue = results[3],
              let statesValue = results[4] else {
            throw UnsupportedDeviceScanError.invalidResponse
        }

        return HomeAssistantRegistry(
            areas: try decode([HAAreaEntry].self, from: areasValue),
            devices: try decode([HADeviceEntry].self, from: devicesValue),
            entities: try decode([HAEntityEntry].self, from: entitiesValue),
            states: parseStates(statesValue)
        )
    }

    // MARK: Wire helpers

    private nonisolated static func webSocketURL(from baseURLString: String) -> URL? {
        guard var components = URLComponents(string: HAWebSocketProvider.normalizeBaseURL(baseURLString)) else {
            return nil
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/api/websocket"
        return components.url
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }

    private nonisolated static func parseStates(_ value: JSONValue) -> [String: HAEntityState] {
        guard case .array(let entries) = value else { return [:] }
        var states: [String: HAEntityState] = [:]
        for entry in entries {
            guard case .object(let object) = entry,
                  let entityId = object["entity_id"]?.stringValue,
                  let state = object["state"]?.stringValue else { continue }
            let attributes: [String: JSONValue]
            if case .object(let values) = object["attributes"] {
                attributes = values
            } else {
                attributes = [:]
            }
            states[entityId] = HAEntityState(entityId: entityId, state: state, attributes: attributes)
        }
        return states
    }
}
