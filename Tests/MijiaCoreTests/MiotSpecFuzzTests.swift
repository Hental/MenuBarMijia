import Foundation
import Testing
@testable import MijiaCore

/// Deterministic fuzz pass over MIoT instance JSON (#186). miot-spec.org is an external
/// service, so a spec change must never crash the decoder: every payload decodes or throws.
@Suite("MIoT spec fuzz (#186)")
struct MiotSpecFuzzTests {
    private static let seed: UInt64 = FuzzSupport.baseSeed ^ 0x00_3107_5EC0

    private static func fixtureData() throws -> Data {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("Tests/Fixtures/contracts/miot_spec_light.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func decode(_ data: Data) throws -> MiotDeviceSpec {
        try JSONDecoder().decode(MiotDeviceSpec.self, from: data)
    }

    /// A structurally plausible spec whose field types and numbers are random, so type
    /// coercions (`try?` defaults, numeric ids, value lists) are exercised rather than only
    /// JSON syntax errors.
    private static func randomSpecData(_ rng: inout SeededFuzzGenerator) throws -> Data {
        func randomInt() -> JSONValue { .number(Double(rng.int(in: -100...10_000))) }
        func randomRange() -> JSONValue {
            .array((0..<rng.int(in: 0...4)).map { _ in
                switch rng.int(in: 0...3) {
                case 0: return .number(1e308)
                case 1: return .number(-1e308)
                case 2: return randomInt()
                default: return .number(Double(rng.int(in: 0...1000)) / 10.0)
                }
            })
        }
        func randomProperty() -> JSONValue {
            var property: [String: JSONValue] = [
                "iid": randomInt(),
                "type": .string("urn:miot-spec-v2:property:p\(rng.int(in: 0...9)):0000000D:contract:1"),
                "format": .string(["bool", "uint8", "int32", "float", "string", ""][rng.int(in: 0...5)]),
                "access": .array([.string("read"), .string("write"), .string("notify")]),
            ]
            if rng.int(in: 0...1) == 0 { property["value-range"] = randomRange() }
            if rng.int(in: 0...1) == 0 {
                property["value-list"] = .array((0..<rng.int(in: 0...3)).map { _ in
                    .object([
                        "value": rng.int(in: 0...2) == 0 ? .number(1e308) : randomInt(),
                        "description": .string("v\(rng.int(in: 0...9))"),
                    ])
                })
            }
            return .object(property)
        }
        func randomAction() -> JSONValue {
            .object([
                "iid": randomInt(),
                "type": .string("urn:miot-spec-v2:action:a\(rng.int(in: 0...9)):00002811:contract:1"),
                "in": .array((0..<rng.int(in: 0...3)).map { _ in randomInt() }),
            ])
        }

        let services: [JSONValue] = (0..<rng.int(in: 0...3)).map { _ in
            .object([
                "iid": randomInt(),
                "type": .string("urn:miot-spec-v2:service:s\(rng.int(in: 0...9)):00007802:contract:1"),
                "properties": .array((0..<rng.int(in: 0...4)).map { _ in randomProperty() }),
                "actions": .array((0..<rng.int(in: 0...2)).map { _ in randomAction() }),
            ])
        }
        let root: JSONValue = .object([
            "type": .string("urn:miot-spec-v2:device:light:0000A001:contract:2"),
            "description": .string("Contract Light"),
            "services": .array(services),
        ])
        return try JSONEncoder().encode(root)
    }

    @Test("Mutated instance JSON either decodes or throws, never traps")
    func mutatedSpecsNeverTrap() throws {
        let base = try Self.fixtureData()
        for iteration in 0..<250 {
            let seed = FuzzSupport.iterationSeed(Self.seed, iteration)
            var rng = SeededFuzzGenerator(seed: seed)
            let mutated = FuzzSupport.mutate(base, rng: &rng)
            do {
                let spec = try Self.decode(mutated)
                #expect(spec.shortName == miotShortName(spec.type))
                for service in spec.services {
                    #expect(service.shortName == miotShortName(service.type))
                    for property in service.properties {
                        #expect(property.isReadable == property.access.contains("read"))
                        #expect(property.isWritable == property.access.contains("write"))
                        #expect(property.rangeMin == property.valueRange.flatMap { $0.count >= 2 ? $0[0] : nil })
                        #expect(property.rangeMax == property.valueRange.flatMap { $0.count >= 2 ? $0[1] : nil })
                        if let list = property.valueList {
                            for item in list {
                                _ = property.description(forValue: item.value)
                            }
                        }
                    }
                }
            } catch is DecodingError {
            } catch {
                Issue.record("seed=\(seed) iteration=\(iteration) input=\(FuzzSupport.hex(mutated)) error=\(error)")
            }
        }
    }

    @Test("Random field types and numbers either decode or throw, never trap")
    func randomSpecsNeverTrap() throws {
        for iteration in 0..<150 {
            let seed = FuzzSupport.iterationSeed(Self.seed &+ 1, iteration)
            var rng = SeededFuzzGenerator(seed: seed)
            let data: Data
            do {
                data = try Self.randomSpecData(&rng)
            } catch {
                Issue.record("seed=\(seed) iteration=\(iteration) could not encode generated spec: \(error)")
                continue
            }
            do {
                let spec = try Self.decode(data)
                #expect(spec.shortName == miotShortName(spec.type))
                for service in spec.services {
                    for property in service.properties {
                        _ = property.rangeStep
                        _ = property.description(forValue: rng.int(in: -10...10))
                    }
                    for action in service.actions {
                        #expect(action.shortName == miotShortName(action.type))
                    }
                }
            } catch is DecodingError {
            } catch {
                Issue.record("seed=\(seed) iteration=\(iteration) input=\(FuzzSupport.hex(data)) error=\(error)")
            }
        }
    }

    @Test("Value-list numbers outside Int range are rejected instead of trapping")
    func outOfRangeValueListNumber() throws {
        for raw in ["1e308", "-1e308", "1e100"] {
            let json = #"{"type":"urn:miot-spec-v2:device:light:0000A001:contract:1","services":[{"iid":2,"type":"urn:miot-spec-v2:service:light:00007802:contract:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:mode:00000008:contract:1","format":"uint8","access":["read","write"],"value-list":[{"value":\#(raw),"description":"Bad"}]}]}]}"#
            let spec = try Self.decode(Data(json.utf8))
            let property = try #require(spec.services.first?.properties.first)
            // The optional field decode drops the unusable list instead of trapping.
            #expect(property.valueList == nil, "value=\(raw)")
        }
    }

    @Test("Fractional value-list numbers keep the historical truncation")
    func fractionalValueListNumber() throws {
        let json = #"{"type":"urn:miot-spec-v2:device:light:0000A001:contract:1","services":[{"iid":2,"type":"urn:miot-spec-v2:service:light:00007802:contract:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:mode:00000008:contract:1","format":"uint8","access":["read","write"],"value-list":[{"value":2.9,"description":"Truncated"}]}]}]}"#
        let spec = try Self.decode(Data(json.utf8))
        let item = try #require(spec.services.first?.properties.first?.valueList?.first)
        #expect(item.value == 2)
        #expect(item.description == "Truncated")
    }
}
