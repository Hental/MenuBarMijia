import Foundation
import Testing
@testable import MijiaCore

/// #19: a provider is recognised by its exact host, and keys never go to look-alike or unencrypted endpoints.
struct AssistantEndpointTests {
    private struct ProviderGolden: Decodable {
        struct PresetCase: Decodable { let url: String; let preset: String }
        struct TransportCase: Decodable { let url: String; let allowsKey: Bool }
        let presets: [PresetCase]
        let keyTransport: [TransportCase]
    }

    private static func locateFixture(_ relativePath: String) throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "test.assistant.endpoint.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("Shared provider_golden.json: preset detection and key transport rules match Windows")
    func providerGoldenParity() throws {
        let data = try Data(contentsOf: Self.locateFixture("Tests/Fixtures/provider_golden.json"))
        let golden = try JSONDecoder().decode(ProviderGolden.self, from: data)
        #expect(golden.presets.count >= 30)
        for item in golden.presets {
            #expect(AssistantProviderPreset.infer(baseURL: item.url).rawValue == item.preset, "\(item.url)")
            let expectedIsKimiCode = item.preset == "moonshot_kimi_coding_plan"
            #expect((AssistantEndpoint(item.url)?.isKimiCodeEndpoint ?? false) == expectedIsKimiCode, "\(item.url)")
        }
        for item in golden.keyTransport {
            let allows = AssistantConfig(baseURL: item.url, model: "m", apiKey: "k").allowsSendingAPIKey
            #expect(allows == item.allowsKey, "\(item.url)")
        }
    }

    @Test("IPv4 parsing only accepts dotted-decimal literals, so 10.evil.com is not a LAN host")
    func ipv4LiteralParsing() {
        #expect(AssistantEndpoint.ipv4Octets("192.168.1.20") == [192, 168, 1, 20])
        #expect(AssistantEndpoint.ipv4Octets("10.evil.com") == nil)
        #expect(AssistantEndpoint.ipv4Octets("1.2.3") == nil)
        #expect(AssistantEndpoint.ipv4Octets("1.2.3.256") == nil)
        #expect(AssistantEndpoint.ipv4Octets("+1.2.3.4") == nil)
        #expect(AssistantConfig(baseURL: "http://10.evil.com/v1").isLoopbackEndpoint == false)
        #expect(AssistantConfig(baseURL: "http://192.168.1.20:3000/v1").isLoopbackEndpoint == true)
        #expect(AssistantEndpoint("http://[::1]:8080/v1")?.identity == "[::1]:8080")
        #expect(AssistantEndpoint("https://Proxy.Example.com:8443/v1")?.identity == "proxy.example.com:8443")
    }

    @Test("A look-alike host never receives the saved OpenRouter key")
    func lookalikeHostGetsNoSavedKey() throws {
        let (defaults, suite) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        AssistantConfig(baseURL: "https://openrouter.ai/api/v1", model: "~typesafe/jev-latest", apiKey: "sk-or-real").save(to: defaults)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: "https://openrouter.ai/api/v1", defaults: defaults) == "sk-or-real")

        for evil in ["https://openrouter.ai.evil.com/api/v1", "https://notopenrouter.ai/api/v1", "https://openrouter.ai@evil.com/api/v1"] {
            #expect(AssistantConfig.userStoredAPIKey(forBaseURL: evil, defaults: defaults) == "", "\(evil)")
            defaults.set(evil, forKey: "assistant_base_url")
            let loaded = AssistantConfig.load(from: defaults, includeAmbientKey: false)
            #expect(loaded.preset == .custom)
            #expect(loaded.apiKey == "", "\(evil)")
        }
    }

    @Test("A custom key is bound to the server it was saved for")
    func customKeyBoundToServer() throws {
        let (defaults, suite) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        AssistantConfig(baseURL: "https://proxy-a.example.com/v1", model: "gpt-4o-mini", apiKey: "sk-a").save(to: defaults)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: "https://proxy-a.example.com/v1", defaults: defaults) == "sk-a")
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: "https://PROXY-A.example.com/other/v1", defaults: defaults) == "sk-a")
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: "https://proxy-b.example.com/v1", defaults: defaults) == "")
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: "https://proxy-a.example.com:8443/v1", defaults: defaults) == "")

        // Pointing the saved URL somewhere else does not carry the key along.
        defaults.set("https://proxy-b.example.com/v1", forKey: "assistant_base_url")
        #expect(AssistantConfig.load(from: defaults, includeAmbientKey: false).apiKey == "")

        // Saving an empty key for a custom URL forgets the binding.
        AssistantConfig(baseURL: "https://proxy-a.example.com/v1", model: "gpt-4o-mini", apiKey: "").save(to: defaults)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: "https://proxy-a.example.com/v1", defaults: defaults) == "")
        #expect(defaults.string(forKey: "assistant_custom_key_endpoint") == nil)
    }

    @Test("A custom key saved before binding existed belongs to the custom URL saved with it")
    func legacyCustomKeyMigration() throws {
        let (defaults, suite) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://proxy-a.example.com/v1", forKey: "assistant_base_url")
        KeychainHelper.saveSecret("sk-legacy", account: KeychainHelper.assistantProviderAPIKeyAccount(for: .custom), defaults: defaults)

        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: "https://proxy-b.example.com/v1", defaults: defaults) == "")
        #expect(defaults.string(forKey: "assistant_custom_key_endpoint") == "proxy-a.example.com")
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: "https://proxy-a.example.com/v1", defaults: defaults) == "sk-legacy")

        // When the saved URL is a known provider, the old custom key's server is unknown, so it is not used anywhere.
        let (other, otherSuite) = try Self.makeDefaults()
        defer { other.removePersistentDomain(forName: otherSuite) }
        other.set("https://api.deepseek.com/v1", forKey: "assistant_base_url")
        KeychainHelper.saveSecret("sk-legacy", account: KeychainHelper.assistantProviderAPIKeyAccount(for: .custom), defaults: other)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: "https://proxy-a.example.com/v1", defaults: other) == "")
    }

    @Test("Custom endpoints never read ambient keys from environment variables or CodexBar")
    func customEndpointHasNoAmbientSources() throws {
        #expect(AssistantProviderPreset.custom.envVarNames.isEmpty)
        #expect(AssistantProviderPreset.custom.codexBarProviderIds.isEmpty)

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-custom-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try #"{"providers":[{"id":"openai","apiKey":"sk-openai"},{"id":"openrouter","apiKey":"sk-or"}]}"#
            .write(to: tempURL, atomically: true, encoding: .utf8)
        #expect(AssistantConfig.loadAmbientAPIKey(forBaseURL: "https://my-proxy.example.com/v1", configURL: tempURL) == nil)
        #expect(AssistantConfig.loadAmbientAPIKey(forBaseURL: "https://openrouter.ai.evil.com/v1", configURL: tempURL) == nil)
    }

    @Test("Plain http to a public host is refused before anything is sent")
    func insecureEndpointRefused() async throws {
        let calls = CallCounter()
        let resolver = ModelIntentResolver(
            config: AssistantConfig(baseURL: "http://api.deepseek.com/v1", model: "deepseek-chat", apiKey: "sk-deepseek"),
            transport: { request in
                await calls.increment()
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        await #expect(throws: AssistantError.insecureEndpoint("http://api.deepseek.com/v1")) {
            _ = try await resolver.resolve("打开书房灯", devices: AssistantTests.devices, scenes: AssistantTests.scenes)
        }
        #expect(await calls.value == 0)
        #expect(AssistantError.userMessage(for: AssistantError.insecureEndpoint("http://x")).contains("https"))
    }

    @Test("A URL typed without a scheme is sent over https; a look-alike OpenRouter host gets no /api path rewrite")
    func schemelessAndLookalikeRequestURLs() async throws {
        let seen = URLRecorder()
        let reply = #"{"choices":[{"message":{"content":"{\"actions\":[],\"reply\":\"好\"}"}}]}"#
        let transport: ModelIntentResolver.Transport = { request in
            await seen.record(request.url?.absoluteString ?? "")
            return (Data(reply.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let schemeless = ModelIntentResolver(
            config: AssistantConfig(baseURL: "api.deepseek.com/v1", model: "deepseek-chat", apiKey: "sk"),
            transport: transport
        )
        _ = try await schemeless.resolve("打开书房灯", devices: AssistantTests.devices, scenes: AssistantTests.scenes)
        let lookalike = ModelIntentResolver(
            config: AssistantConfig(baseURL: "https://openrouter.ai.evil.com", model: "gpt-4o-mini", apiKey: "sk"),
            transport: transport
        )
        _ = try await lookalike.resolve("打开书房灯", devices: AssistantTests.devices, scenes: AssistantTests.scenes)
        #expect(await seen.urls == [
            "https://api.deepseek.com/v1/chat/completions",
            "https://openrouter.ai.evil.com/v1/chat/completions"
        ])
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor URLRecorder {
    private(set) var urls: [String] = []
    func record(_ url: String) { urls.append(url) }
}
