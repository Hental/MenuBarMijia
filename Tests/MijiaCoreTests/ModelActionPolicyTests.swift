import Foundation
import Testing
@testable import MijiaCore

/// #21: AI guesses below 80 % and risky actions (heaters, plugs, vacuums) wait for a tap.
struct ModelActionPolicyTests {
    static let devices = AssistantTests.devices
    static let scenes = AssistantTests.scenes

    static func systemOneResolver(_ answers: [String: Any]) throws -> ModelIntentResolver {
        let data = try JSONSerialization.data(withJSONObject: ["answers": answers])
        return ModelIntentResolver(
            config: AssistantConfig(baseURL: "https://openrouter.ai/api/v1", model: "~typesafe/jev-latest", apiKey: "test-token"),
            transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
    }

    static func chatResolver(_ content: String) throws -> ModelIntentResolver {
        let envelope: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return ModelIntentResolver(
            config: AssistantConfig(baseURL: "https://api.example.com/v1", model: "test-model", apiKey: "test-key"),
            transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
    }

    @Test("Probabilities come from probabilities[choice], then confidence, else count as 0")
    func probabilityReading() {
        #expect(ModelActionPolicy.probability(of: ["probabilities": ["a": 0.9], "confidence": 0.1], choice: "a") == 0.9)
        #expect(ModelActionPolicy.probability(of: ["probabilities": ["b": 0.9], "confidence": 0.3], choice: "a") == 0.3)
        #expect(ModelActionPolicy.probability(of: ["choice": "a"], choice: "a") == 0)
        #expect(ModelActionPolicy.probability(of: nil, choice: "a") == 0)
        #expect(ModelActionPolicy.probability(of: ["confidence": "85%"], choice: "a") == 0.85)
        #expect(ModelActionPolicy.probability(of: ["confidence": "50"], choice: "a") == 0.5)
        #expect(ModelActionPolicy.probability(of: ["confidence": 7], choice: "a") == 0.07)
    }

    @Test("A 50% device head only becomes a suggestion chip")
    func lowConfidenceHeadIsChipOnly() async throws {
        let resolver = try Self.systemOneResolver([
            "target": ["choice": "none", "confidence": 0.9],
            "op": ["choice": "power_on", "confidence": 0.5],
            "temp": ["choice": "none", "confidence": 0.9],
            "dev_d2": ["choice": "power_on", "probabilities": ["power_on": 0.5, "none": 0.5]]
        ])
        let plan = try await resolver.resolve("有点暗", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.intents.isEmpty)
        #expect(plan.suggestions.map(\.id) == ["jev:dev_study_desk:power_on"])
        #expect(plan.suggestions.first?.confidencePercent == 50)
        #expect(plan.reply == "没把握直接执行，点下面的建议再执行")
    }

    @Test("Answers without any probability never run by themselves, but become a chip (#21)")
    func missingNumbersDoNotRun() async throws {
        let resolver = try Self.systemOneResolver([
            "target": ["choice": "d1"],
            "op": ["choice": "power_on"],
            "temp": ["choice": "none"]
        ])
        let plan = try await resolver.resolve("开灯", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.intents.isEmpty)
        #expect(plan.suggestions.map(\.id) == ["jev:primary:d1:power_on"])
        #expect(plan.suggestions.first?.confidencePercent == nil)
        #expect(plan.reply == "没把握直接执行，点下面的建议再执行")
    }

    @Test("An explicit device answer without probabilities waits as a chip without a fake percent")
    func explicitChoiceWithoutProbabilityIsChip() async throws {
        let resolver = try Self.systemOneResolver([
            "target": ["choice": "none"],
            "op": ["choice": "none"],
            "temp": ["choice": "none"],
            "dev_d4": ["choice": "power_on"]
        ])
        let plan = try await resolver.resolve("开台灯", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.intents.isEmpty)
        #expect(plan.suggestions.map(\.id) == ["jev:dev_bedside:power_on"])
        #expect(plan.suggestions.first?.confidencePercent == nil)
    }

    @Test("A runner-up the model declined below 20% is not offered")
    func declinedRunnerUpBelowFloorIsDropped() async throws {
        let resolver = try Self.systemOneResolver([
            "target": ["choice": "none"],
            "op": ["choice": "none"],
            "temp": ["choice": "none"],
            "dev_d2": ["choice": "none", "probabilities": ["none": 0.9, "power_on": 0.1]]
        ])
        let plan = try await resolver.resolve("随便看看", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.intents.isEmpty)
        #expect(plan.suggestions.isEmpty)
    }

    @Test("A primary answer below 80% waits as one chip for the whole room")
    func lowConfidencePrimaryIsGroupChip() async throws {
        let resolver = try Self.systemOneResolver([
            "target": ["choice": "room_lights:书房", "confidence": 0.95],
            "op": ["choice": "power_on", "confidence": 0.6],
            "temp": ["choice": "none", "confidence": 0.99]
        ])
        let plan = try await resolver.resolve("书房亮一点吧", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.intents.isEmpty)
        let chip = try #require(plan.suggestions.first)
        #expect(plan.suggestions.count == 1)
        #expect(chip.confidencePercent == 60)
        #expect(chip.title.hasSuffix("等 2 台"))
        #expect(Set(chip.intents.map(\.targetId)) == ["dev_study_ceiling", "dev_study_desk"])
    }

    @Test("A confident heater-on answer still waits for a tap")
    func confidentHeaterWaits() async throws {
        let resolver = try Self.systemOneResolver([
            "target": ["choice": "d5", "confidence": 0.99],
            "op": ["choice": "power_on", "confidence": 0.99],
            "temp": ["choice": "none", "confidence": 0.99]
        ])
        let plan = try await resolver.resolve("次卧有点冷", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.intents.isEmpty)
        #expect(plan.suggestions.first?.intents == [DeviceIntent(targetId: "dev_guest_heater", operation: .power(true))])
    }

    @Test("Chat models: lights run, the heater waits, and the reply does not claim it ran")
    func chatHeaterWaits() async throws {
        let resolver = try Self.chatResolver("""
        {"actions":[
          {"device":"d4","op":"power","value":false},
          {"device":"d5","op":"power","value":true}
        ],"reply":"已关闭床头灯并打开电暖器"}
        """)
        let plan = try await resolver.resolve("我要睡了，有点冷", devices: Self.devices, scenes: Self.scenes)
        #expect(plan.intents == [DeviceIntent(targetId: "dev_bedside", operation: .power(false))])
        let chip = try #require(plan.suggestions.first)
        #expect(chip.id == "confirm:dev_guest_heater")
        #expect(chip.confidencePercent == nil)
        #expect(chip.intents == [DeviceIntent(targetId: "dev_guest_heater", operation: .power(true))])
        #expect(!plan.reply.contains("电暖器"))
        #expect(plan.reply.hasSuffix("；下面的建议要点一下才执行"))
    }
}
