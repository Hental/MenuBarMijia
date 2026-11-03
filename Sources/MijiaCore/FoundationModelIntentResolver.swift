import Foundation

#if canImport(FoundationModels)
import FoundationModels

// Apple's on-device model, used when no cloud provider is configured. Guided generation is a good
// fit here because the whole action vocabulary is a closed set (`IntentOperation`), so the schema
// itself can reject unknown operations instead of asking the model to print strict JSON and
// repairing it afterwards. The generated plan still goes through `AssistantLocalPlanMapper` and the
// existing `ModelActionPolicy`/`IntentValidator` boundary before anything executes.

@available(macOS 26.0, *)
@Generable
enum FoundationAssistantOperation: Equatable {
    case power(Bool)
    case brightness(Int)
    case colorTemperature(Int)
    case lightEffect(String)
    case hvacMode(String)
    case targetTemperature(Double)
    case activateScene
    case fanSpeed(String)
    case oscillation(Bool)
    case brightnessStep(Int)
    case temperatureStep(Double)
}

@available(macOS 26.0, *)
@Generable
struct FoundationAssistantAction {
    @Guide(description: "Catalog id: dN for one device, room_lights:N for a room light group, all_lights/all_devices for the whole home, or sN for a scene")
    var target: String

    var operation: FoundationAssistantOperation

    var localAction: AssistantLocalAction {
        AssistantLocalAction(
            target: target.trimmingCharacters(in: .whitespacesAndNewlines),
            operation: operation.intentOperation
        )
    }
}

@available(macOS 26.0, *)
@Generable
struct FoundationAssistantPlan {
    var actions: [FoundationAssistantAction]
    var reply: String
}

@available(macOS 26.0, *)
extension FoundationAssistantOperation {
    var intentOperation: IntentOperation {
        switch self {
        case .power(let isOn): return .power(isOn)
        case .brightness(let percent): return .brightness(percent)
        case .colorTemperature(let kelvin): return .colorTemperature(kelvin)
        case .lightEffect(let effect): return .lightEffect(effect)
        case .hvacMode(let mode): return .hvacMode(mode)
        case .targetTemperature(let celsius): return .targetTemperature(celsius)
        case .activateScene: return .activateScene
        case .fanSpeed(let speed): return .fanSpeed(speed)
        case .oscillation(let isOn): return .oscillation(isOn)
        case .brightnessStep(let delta): return .brightnessStep(delta)
        case .temperatureStep(let delta): return .temperatureStep(delta)
        }
    }
}

/// Local-only resolver backed by Apple's Foundation Model. No network call is made here.
@available(macOS 26.0, *)
public struct FoundationModelIntentResolver: AssistantCommandResolving {
    public init() {}

    public static var availability: AssistantLocalModelAvailability {
        availability(for: SystemLanguageModel.default.availability)
    }

    static func availability(
        for availability: SystemLanguageModel.Availability
    ) -> AssistantLocalModelAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(L10n.tr(
                    "这台 Mac 不支持 Apple Intelligence 本机模型",
                    "This Mac does not support the Apple Intelligence on-device model"
                ))
            case .appleIntelligenceNotEnabled:
                return .unavailable(L10n.tr(
                    "请在系统设置中开启 Apple Intelligence 后使用本机 AI",
                    "Turn on Apple Intelligence in System Settings to use the on-device AI"
                ))
            case .modelNotReady:
                return .unavailable(L10n.tr(
                    "本机 AI 模型仍在下载或准备中，请稍后再试",
                    "The on-device model is still downloading or getting ready"
                ))
            @unknown default:
                return .unavailable(L10n.tr(
                    "本机 AI 当前不可用",
                    "The on-device AI is currently unavailable"
                ))
            }
        }
    }

    public func resolve(
        _ utterance: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        context: AssistantContext,
        confirmation: ModelActionPolicy.ConfirmationPolicy = .default
    ) async throws -> IntentPlan {
        let availability = Self.availability
        guard availability == .available else {
            if case .unavailable(let reason) = availability {
                throw AssistantLocalModelError.unavailable(reason)
            }
            throw AssistantLocalModelError.failed
        }

        let catalog = IntentCatalog(devices: devices, scenes: scenes)
        var preferredDeviceIds = Set(context.favoriteDeviceIds)
        preferredDeviceIds.formUnion(devices.filter { $0.isOnline && $0.isActiveOn }.map(\.id))
        let instructions = AssistantLocalPrompt.instructions(
            catalog: catalog,
            context: context,
            mention: utterance,
            preferredDeviceIds: preferredDeviceIds
        )
        // A fresh session per command keeps the small on-device context from filling up with
        // unrelated earlier commands; the store already serializes user-facing assistant work.
        let session = LanguageModelSession(model: .default, instructions: instructions)
        do {
            let response = try await session.respond(
                to: utterance,
                generating: FoundationAssistantPlan.self,
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 600)
            )
            return AssistantLocalPlanMapper.plan(
                actions: response.content.actions.map(\.localAction),
                reply: response.content.reply,
                catalog: catalog,
                devices: devices,
                scenes: scenes,
                confirmation: confirmation
            )
        } catch {
            throw AssistantLocalModelError.failed
        }
    }
}
#endif
