import Foundation
import Testing
@testable import MijiaCore

struct HAHomeSnapshotTests {
    private static let states: JSONValue = .array([
        .object(["entity_id": .string("light.visible"), "state": .string("on"), "attributes": .object(["friendly_name": .string("Desk light")])]),
        .object(["entity_id": .string("light.hidden"), "state": .string("on"), "attributes": .object([:])])
    ])
    private static let entities: JSONValue = .array([
        .object(["entity_id": .string("light.visible"), "area_id": .string("office")]),
        .object(["entity_id": .string("light.hidden"), "hidden_by": .string("user")])
    ])

    private static func reply(_ id: Int, _ result: JSONValue) -> [String: JSONValue] {
        ["type": .string("result"), "id": .number(Double(id)), "success": .bool(true), "result": result]
    }

    @Test("Initial states never publish hidden devices before their registry arrives")
    func waitsForInitialRegistries() throws {
        var projection = HAHomeSnapshot()
        let statesOnly = try projection.receive(Self.reply(4, Self.states))
        #expect(statesOnly?.devices == nil)
        let withAreas = try projection.receive(Self.reply(1, .array([.object(["area_id": .string("office"), "name": .string("Office")])])))
        #expect(withAreas?.devices == nil)
        let withoutEntities = try projection.receive(Self.reply(2, .array([])))
        #expect(withoutEntities?.devices == nil)
        let completed = try projection.receive(Self.reply(3, Self.entities))
        let home = try #require(completed)
        #expect(home.devices.map(\.id) == ["light.visible"])
        #expect(home.devices.first?.roomName == "Office")
    }

    static var responseOrders: [[Int]] {
        var result: [[Int]] = []
        for a in 1...4 {
            for b in 1...4 where b != a {
                for c in 1...4 where c != a && c != b {
                    for d in 1...4 where d != a && d != b && d != c {
                        result.append([a, b, c, d])
                    }
                }
            }
        }
        return result
    }

    private static func initialReply(_ id: Int) -> [String: JSONValue] {
        switch id {
        case 1: reply(id, .array([.object(["area_id": .string("office"), "name": .string("Office")])]))
        case 2: reply(id, .array([]))
        case 3: reply(id, entities)
        default: reply(id, states)
        }
    }

    @Test("Every initial reply order waits for authoritative metadata", arguments: responseOrders)
    func initialReplyOrder(_ order: [Int]) throws {
        var projection = HAHomeSnapshot()
        for (offset, id) in order.enumerated() {
            let result = try projection.receive(Self.initialReply(id))
            if offset < 3 {
                #expect(result?.devices == nil)
            } else {
                let home = try #require(result)
                #expect(home.devices.map(\.id) == ["light.visible"])
                #expect(home.devices.first?.roomName == "Office")
            }
        }
        let refreshed = try projection.receive(Self.reply(1001, .array([
            .object(["entity_id": .string("light.visible"), "state": .string("off"), "attributes": .object([:])])
        ])))
        let home = try #require(refreshed)
        if case .light(let light) = home.devices.first?.kind {
            #expect(!light.isOn)
        } else {
            Issue.record("Refresh lost the visible light")
        }
    }

    @Test("A rejected registry is an error rather than a successful empty registry")
    func rejectedRegistry() throws {
        var projection = HAHomeSnapshot()
        _ = try projection.receive(Self.initialReply(1))
        _ = try projection.receive(Self.initialReply(2))
        _ = try projection.receive(Self.initialReply(4))
        do {
            _ = try projection.receive(["type": .string("result"), "id": .number(3), "success": .bool(false), "error": .object(["code": .string("unauthorized")])])
            Issue.record("Rejected entity registry was accepted")
        } catch HAHomeSnapshot.ReadError.rejected {
        }
        let recovered = try projection.receive(Self.initialReply(3))
        #expect(recovered?.devices.map(\.id) == ["light.visible"])
    }

    @Test("Malformed registries cannot complete initialization", arguments: [JSONValue.null, .object([:]), .array([.object([:])])])
    func malformedRegistry(_ payload: JSONValue) throws {
        var projection = HAHomeSnapshot()
        _ = try projection.receive(Self.initialReply(1))
        _ = try projection.receive(Self.initialReply(2))
        _ = try projection.receive(Self.initialReply(4))
        do {
            _ = try projection.receive(Self.reply(3, payload))
            Issue.record("Malformed registry completed initialization")
        } catch HAHomeSnapshot.ReadError.invalidResponse {
        }
        let recovered = try projection.receive(Self.initialReply(3))
        #expect(recovered?.devices.map(\.id) == ["light.visible"])
    }
}

/// Deterministic fuzz pass over Home Assistant WebSocket frames (#186). A frame is untrusted
/// network input: the parser may publish a home, ignore the frame, or throw `ReadError`, and
/// nothing else — including a huge numeric id or a hostile sensor state.
@Suite("HA WebSocket message fuzz (#186)")
struct HAWebSocketFuzzTests {
    private static let seed: UInt64 = FuzzSupport.baseSeed ^ 0x00_4A5_0000

    private static let keys = [
        "type", "id", "success", "result", "error", "event", "event_type", "data",
        "new_state", "entity_id", "state", "attributes", "friendly_name", "device_class",
    ]
    private static let strings = [
        "result", "event", "state_changed", "auth_required", "auth_ok", "subscribed",
        "light.ceiling", "sensor.temperature", "sensor.pm2_5", "on", "off", "unavailable",
        "unknown", "temperature", "humidity", "battery", "pm25", "1", "-1", "1e308", "inf",
        "nan", "not-a-number", "",
    ]

    private static func reply(_ id: Int, _ result: JSONValue) -> [String: JSONValue] {
        ["type": .string("result"), "id": .number(Double(id)), "success": .bool(true), "result": result]
    }

    private static func randomNumber(_ rng: inout SeededFuzzGenerator) -> Double {
        switch rng.int(in: 0...4) {
        case 0: return Double(rng.int(in: -10_000...10_000))
        case 1: return 1e308
        case 2: return -1e308
        case 3: return Double(rng.int(in: 0...100)) / 10.0
        default: return 1e100
        }
    }

    private static func randomValue(_ rng: inout SeededFuzzGenerator, depth: Int) -> JSONValue {
        let choices = depth >= 3 ? 3 : 7
        switch rng.int(in: 0...choices) {
        case 0:
            return .null
        case 1:
            return .bool(rng.int(in: 0...1) == 1)
        case 2:
            return .number(randomNumber(&rng))
        case 3:
            return .string(strings[rng.int(in: 0...(strings.count - 1))])
        case 4:
            return .array((0..<rng.int(in: 0...2)).map { _ in randomValue(&rng, depth: depth + 1) })
        default:
            var object: [String: JSONValue] = [:]
            for _ in 0..<rng.int(in: 0...3) {
                object[keys[rng.int(in: 0...(keys.count - 1))]] = randomValue(&rng, depth: depth + 1)
            }
            return .object(object)
        }
    }

    private static func randomID(_ rng: inout SeededFuzzGenerator) -> JSONValue {
        switch rng.int(in: 0...5) {
        case 0: return .number(Double(rng.int(in: 1...4)))
        case 1: return .number(Double(rng.int(in: 1000...9999)))
        case 2: return .number(1e308)
        case 3: return .string("1e308")
        case 4: return .string("inf")
        default: return .string("not-a-number")
        }
    }

    private static func randomMessage(_ rng: inout SeededFuzzGenerator) -> [String: JSONValue] {
        switch rng.int(in: 0...3) {
        case 0:
            return [
                "type": .string("result"),
                "id": randomID(&rng),
                "success": .bool(rng.int(in: 0...4) != 0),
                "result": randomValue(&rng, depth: 0),
            ]
        case 1:
            return ["type": .string("event"), "event": randomValue(&rng, depth: 0)]
        case 2:
            var message: [String: JSONValue] = [:]
            for _ in 0..<rng.int(in: 1...4) {
                message[keys[rng.int(in: 0...(keys.count - 1))]] = randomValue(&rng, depth: 0)
            }
            return message
        default:
            let types = ["auth_required", "auth_ok", "ping", "subscribed", "unknown"]
            return ["type": .string(types[rng.int(in: 0...(types.count - 1))])]
        }
    }

    @Test("Random frames never escape the parser error type")
    func randomFramesNeverTrap() {
        for iteration in 0..<300 {
            let seed = FuzzSupport.iterationSeed(Self.seed, iteration)
            var rng = SeededFuzzGenerator(seed: seed)
            var snapshot = HAHomeSnapshot()
            for _ in 0..<rng.int(in: 1...4) {
                let message = Self.randomMessage(&rng)
                let input = JSONValue.object(message).compactJSONString
                do {
                    _ = try snapshot.receive(message)
                } catch is HAHomeSnapshot.ReadError {
                } catch {
                    Issue.record("seed=\(seed) iteration=\(iteration) input=\(input) error=\(error)")
                }
            }
        }
    }

    @Test("Out-of-range result ids are ignored instead of trapping")
    func hostileResultIDs() throws {
        for id in [JSONValue.number(1e308), .number(-1e308), .string("1e308"), .string("inf"), .string("nan")] {
            var snapshot = HAHomeSnapshot()
            let message: [String: JSONValue] = [
                "type": .string("result"), "id": id, "success": .bool(true), "result": .array([]),
            ]
            #expect(try snapshot.receive(message) == nil, "id=\(id)")
        }
    }

    @Test("Hostile numeric states and attributes degrade to no reading instead of trapping")
    func hostileNumericStates() throws {
        var snapshot = HAHomeSnapshot()
        _ = try snapshot.receive(Self.reply(1, .array([
            .object(["area_id": .string("study"), "name": .string("Study")]),
        ])))
        _ = try snapshot.receive(Self.reply(2, .array([
            .object(["id": .string("dev-light"), "area_id": .string("study"), "name": .string("Light")]),
            .object(["id": .string("dev-thermo"), "area_id": .string("study"), "name": .string("Thermo")]),
        ])))
        _ = try snapshot.receive(Self.reply(3, .array([
            .object(["entity_id": .string("light.ceiling"), "device_id": .string("dev-light")]),
            .object(["entity_id": .string("sensor.temperature"), "device_id": .string("dev-thermo")]),
            .object(["entity_id": .string("sensor.humidity"), "device_id": .string("dev-thermo")]),
            .object(["entity_id": .string("sensor.battery_level"), "device_id": .string("dev-thermo")]),
        ])))
        let home = try #require(try snapshot.receive(Self.reply(4, .array([
            .object([
                "entity_id": .string("light.ceiling"),
                "state": .string("on"),
                "attributes": .object(["brightness": .number(1e308)]),
            ]),
            .object([
                "entity_id": .string("sensor.temperature"),
                "state": .string("23.5"),
                "attributes": .object(["device_class": .string("temperature")]),
            ]),
            .object([
                "entity_id": .string("sensor.humidity"),
                "state": .string("45"),
                "attributes": .object(["device_class": .string("humidity")]),
            ]),
            .object([
                "entity_id": .string("sensor.battery_level"),
                "state": .string("inf"),
                "attributes": .object(["device_class": .string("battery")]),
            ]),
        ]))))

        let light = try #require(home.devices.first { $0.id == "dev-light" })
        guard case .light(let lightSpec) = light.kind else {
            Issue.record("expected the light to synthesize")
            return
        }
        #expect(lightSpec.brightnessPercent == nil)

        let thermometer = try #require(home.devices.first { $0.id == "dev-thermo" })
        guard case .sensor(let sensorSpec) = thermometer.kind else {
            Issue.record("expected the thermometer to synthesize")
            return
        }
        #expect(sensorSpec.temperature == 23.5)
        #expect(sensorSpec.humidity == 45)
        #expect(sensorSpec.battery == nil)
    }
}
