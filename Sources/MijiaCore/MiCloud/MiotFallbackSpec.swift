import Foundation

/// Read-only MIoT spec used when the released instance cannot be loaded (#185).
/// The table is `Resources/fallbackSpecs.json`, the same document Windows reads.
public enum MiotFallbackSpec {
    public static func infer(model: String, name: String) -> MiotDeviceSpec {
        let model = model.lowercased()
        let name = name.lowercased()
        let table = Table.current
        for rule in table.rules {
            let matchesModel = rule.modelAny?.contains { model.contains($0) } ?? false
            let matchesSuffix = rule.modelSuffix?.contains { model.hasSuffix($0) } ?? false
            let matchesName = rule.nameAny?.contains { name.contains($0) } ?? false
            if matchesModel || matchesSuffix || matchesName {
                return rule.spec
            }
        }
        return table.fallback.spec
    }

    /// Bytes of the bundled table, so a test can prove it still matches the Windows file.
    static func bundledData() -> Data? {
        guard let url = Bundle.module.url(forResource: "fallbackSpecs", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    private struct Document: Decodable {
        struct Rule: Decodable {
            var modelAny: [String]?
            var modelSuffix: [String]?
            var nameAny: [String]?
            var spec: MiotDeviceSpec
        }

        struct Fallback: Decodable {
            var spec: MiotDeviceSpec
        }

        var rules: [Rule]
        var fallback: Fallback
    }

    private enum Table {
        static let current: Document = load()

        static func load() -> Document {
            if let data = MiotFallbackSpec.bundledData(),
               let document = try? JSONDecoder().decode(Document.self, from: data) {
                return document
            }
            return Document(rules: [], fallback: Document.Fallback(spec: outlet))
        }

        static let outlet = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:outlet:0000A002:fallback:1",
            services: [
                MiotService(
                    iid: 2,
                    type: "urn:miot-spec-v2:service:switch:0000780C:fallback:1",
                    properties: [
                        MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:fallback:1", format: "bool", access: ["read"])
                    ]
                )
            ]
        )
    }
}
