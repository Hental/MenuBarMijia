import Foundation

public enum AssistantError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidBaseURL(String)
    case httpStatus(Int)
    case emptyResponse
    case malformedResponse
    /// Plain http to a public host: the key and the user's words would travel unencrypted.
    case insecureEndpoint(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.tr("尚未配置 AI 服务的 API Key，请先在设置中填写", "AI API Key is not configured; please add it in Settings")
        case .invalidBaseURL(let url):
            return L10n.tr("AI 服务地址无效：\(url)", "Invalid AI service URL: \(url)")
        case .httpStatus(let code):
            return L10n.tr("AI 服务返回错误 (\(code))", "AI service returned error (\(code))")
        case .emptyResponse:
            return L10n.tr("AI 没有返回内容", "AI returned an empty response")
        case .malformedResponse:
            return L10n.tr("AI 返回的内容无法解析", "Could not parse AI response")
        case .insecureEndpoint(let url):
            return L10n.tr(
                "AI 服务地址不是 https：\(url)。为保护 API Key，只有本机或局域网地址可以用 http",
                "AI service URL is not https: \(url). To protect your API key, plain http is only allowed for this Mac or the local network."
            )
        }
    }

    /// What the command bar shows when the model call fails: what happened plus what to do next.
    public static func userMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return L10n.tr(
                    "AI 服务 10 秒没回应，换个简短说法再试；「关灯」这类简单指令不用联网",
                    "AI service timed out after 10s. Try a shorter phrase; direct commands like \"turn off lights\" work offline."
                )
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return L10n.tr(
                    "连不上 AI 服务，请检查网络；「打开书房灯」这类简单指令仍可直接使用",
                    "Cannot reach AI service. Check your network; direct commands like \"turn on study light\" still work offline."
                )
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return L10n.tr(
                    "和 AI 服务的安全连接失败，请检查服务地址或代理设置",
                    "TLS connection to AI service failed; check the endpoint URL or proxy settings."
                )
            default:
                return L10n.tr(
                    "AI 服务连接失败（\(urlError.code.rawValue)），稍后再试",
                    "AI service connection failed (\(urlError.code.rawValue)); try again later."
                )
            }
        }
        switch error as? AssistantError {
        case .missingAPIKey:
            return L10n.tr(
                "尚未配置 AI 服务的 API Key，请到设置里填写后再试；「打开书房灯」这类简单指令无需 Key 即可使用",
                "AI API Key is not configured. Add it in Settings; direct commands like \"turn on study light\" work without a key."
            )
        case .httpStatus(401), .httpStatus(403):
            return L10n.tr(
                "AI 服务的 API Key 无效或已过期，请到设置里重新填写",
                "AI API Key is invalid or expired; please update it in Settings."
            )
        case .httpStatus(429):
            return L10n.tr(
                "AI 服务请求太频繁，稍等几秒再试",
                "Too many requests to AI service; wait a few seconds and try again."
            )
        case .httpStatus(let code) where code >= 500:
            return L10n.tr(
                "AI 服务暂时出错（\(code)），稍后再试",
                "AI service is temporarily unavailable (\(code)); try again later."
            )
        case .malformedResponse, .emptyResponse:
            return L10n.tr(
                "AI 返回的内容看不懂，换个说法再试",
                "Could not understand AI response; try rephrasing your command."
            )
        default:
            return error.localizedDescription
        }
    }
}

/// LLM fallback for utterances the LocalIntentParser cannot resolve, via an OpenAI-compatible
/// `/chat/completions` endpoint.
public struct ModelIntentResolver: Sendable, AssistantCommandResolving {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let config: AssistantConfig
    private let transport: Transport

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    public init(config: AssistantConfig, transport: Transport? = nil) {
        self.config = config
        self.transport = transport ?? { request in
            guard config.hasAPIKey || config.isLoopbackEndpoint else {
                throw AssistantError.missingAPIKey
            }
            return try await Self.session.data(for: request)
        }
    }

    public func resolve(
        _ utterance: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        context: AssistantContext = AssistantContext()
    ) async throws -> IntentPlan {
        let catalog = IntentCatalog(devices: devices, scenes: scenes)
        if Self.isSystemOneModel(config.model) {
            let request = try makeSystemOneRequest(
                utterance: utterance,
                catalog: catalog,
                context: context
            )
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AssistantError.httpStatus(http.statusCode)
            }
            return try Self.planFromSystemOne(data: data, catalog: catalog, devices: devices, scenes: scenes)
        }
        let request = try makeRequest(utterance: utterance, catalog: catalog, context: context)
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AssistantError.httpStatus(http.statusCode)
        }
        let content = try Self.messageContent(from: data)
        return try Self.plan(fromModelContent: content, catalog: catalog, devices: devices, scenes: scenes)
    }

    /// Proactive zero-input inference: evaluates current time, indoor sensor readings,
    /// active devices, and personal habit memory to recommend top actions with calibrated probabilities.
    /// Supports both System One (`/v1/systemone` for Jev) and OpenAI-compatible `/chat/completions` (for DeepSeek, Qwen, GLM, OpenAI, Gemini, etc.).
    public func recommendProactiveSuggestions(
        devices: [SmartDevice],
        scenes: [HomeScene],
        context: AssistantContext
    ) async throws -> [AssistantSuggestion] {
        let catalog = IntentCatalog(devices: devices, scenes: scenes)
        if Self.isSystemOneModel(config.model) {
            let request = try makeProactiveSystemOneRequest(catalog: catalog, context: context)
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw AssistantError.httpStatus(http.statusCode)
            }
            return try Self.proactiveSuggestionsFromSystemOne(data: data, catalog: catalog, devices: devices, scenes: scenes)
        }
        let request = try makeProactiveChatRequest(catalog: catalog, context: context)
        let (data, response) = try await transport(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AssistantError.httpStatus(http.statusCode)
        }
        let content = try Self.messageContent(from: data)
        return try Self.proactiveSuggestionsFromChat(content: content, catalog: catalog, devices: devices, scenes: scenes)
    }

    /// Sends a lightweight probe request to verify the configured endpoint, model, and API key, returning round-trip latency in milliseconds.
    public func testConnection() async throws -> Int {
        let probeDevice = SmartDevice(
            id: "probe_study_light",
            name: "书房灯",
            roomId: "shu_fang",
            roomName: "书房",
            model: "yeelink.light.ceiling20",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.probe_study", isOn: false, availableEffects: ["Day", "Night"]))
        )
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await resolve("打开书房灯", devices: [probeDevice], scenes: [])
        let elapsed = clock.now - start
        let ms = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        return max(1, ms)
    }

    /// System One protocol (`/v1/systemone`) backs TypeSafe Jev (`~typesafe/jev-latest`),
    /// Cloudflare Clef (`@cf/cloudflare/clef-flash`), and Bailian decision (`qwen-decision`).
    public static func isSystemOneModel(_ model: String) -> Bool {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("jev-router") { return false }
        return lower.contains("jev") || lower.contains("clef") || lower.contains("decision")
    }

    // MARK: - Request

    func makeRequest(
        utterance: String,
        catalog: IntentCatalog,
        context: AssistantContext = AssistantContext()
    ) throws -> URLRequest {
        let url = try endpointURL(path: "/chat/completions")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = effectiveAPIKey()
        // Local routers accept any bearer value but some reject a missing header.
        request.setValue("Bearer \(key.isEmpty ? "local" : key)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": Self.systemPrompt(catalog: catalog, context: context)],
                ["role": "user", "content": utterance]
            ],
            "temperature": 0,
            "max_tokens": 800,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func makeSystemOneRequest(
        utterance: String,
        catalog: IntentCatalog,
        context: AssistantContext = AssistantContext()
    ) throws -> URLRequest {
        let url = try endpointURL(path: "/systemone")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = effectiveAPIKey()
        request.setValue("Bearer \(key.isEmpty ? "local" : key)", forHTTPHeaderField: "Authorization")

        let resolvedModel = resolvedSystemOneModel(for: url)

        var targetCriteria = catalog.criteriaByAlias
        targetCriteria["none"] = "无匹配设备或场景"
        let opCriteria: [String: String] = [
            "power_on": "打开设备电源",
            "power_off": "关闭设备电源",
            "effect_night": "切换月光/夜灯模式 (Night)",
            "effect_day": "切换日光模式 (Day)",
            "bri_20": "调暗灯光 (亮度 20%)",
            "bri_50": "中等亮度 (亮度 50%)",
            "bri_100": "调亮/最亮灯光 (亮度 100%)",
            "bri_down_20": "相对调暗一点 (-20%)",
            "bri_up_20": "相对调亮一点 (+20%)",
            "ct_2700": "暖光/黄光 (色温 2700K)",
            "ct_4000": "自然光 (色温 4000K)",
            "ct_6500": "白光/冷光 (色温 6500K)",
            "hvac_cool": "空调制冷模式",
            "hvac_heat": "空调制热模式",
            "hvac_dry": "空调除湿模式",
            "hvac_fan": "空调送风模式",
            "hvac_auto": "空调自动模式",
            "temp": "仅调节空调温度",
            "temp_up_2": "空调温度相对调高 2°C",
            "temp_down_2": "空调温度相对调低 2°C",
            "fan_low": "风速调为低档/一档",
            "fan_medium": "风速调为中档/二档",
            "fan_high": "风速调为高档/三档",
            "fan_auto": "风速调为自动档",
            "osc_on": "开启风扇摇头/摆风",
            "osc_off": "停止风扇摇头/摆风",
            "scene": "执行智能场景"
        ]
        let tempCriteria: [String: String] = [
            "none": "不指定具体温度",
            "18": "18°C", "19": "19°C", "20": "20°C", "21": "21°C", "22": "22°C",
            "23": "23°C", "24": "24°C", "25": "25°C", "26": "26°C", "27": "27°C", "28": "28°C"
        ]

        var questions: [String: Any] = [
            "target": [
                "type": "choice",
                "instructions": "Select the primary target device, room light group, or scene id for the command",
                "criteria": targetCriteria
            ],
            "op": [
                "type": "choice",
                "instructions": "Select the primary operation to perform on the target",
                "criteria": opCriteria
            ],
            "temp": [
                "type": "choice",
                "instructions": "If the command sets an air-conditioner temperature, select the degree in Celsius; otherwise none",
                "criteria": tempCriteria
            ]
        ]

        // Add per-device parallel decision heads for every controllable device so Jev can
        // orchestrate the whole home for ambient commands ("准备写代码，有点热") and surface
        // secondary probabilities. No truncation: device 11+ must stay visible (#33).
        for (alias, device) in catalog.aliasDevices {
            questions["dev_\(alias)"] = [
                "type": "choice",
                "instructions": Self.deviceHeadInstruction(alias: alias),
                "criteria": Self.deviceSpecificCriteria(for: device)
            ]
        }

        var stateDict: [String: Any] = [
            "catalog": catalog.text,
            "command": utterance
        ]
        if let time = Self.promptField(context.timeSummary) { stateDict["time"] = time }
        if let environment = Self.promptField(context.environmentSummary) { stateDict["environment"] = environment }
        if let active = Self.promptField(context.activeDevicesSummary) { stateDict["active_devices"] = active }
        if let habits = Self.promptField(context.habitSummary) { stateDict["user_habits"] = habits }

        let body: [String: Any] = [
            "model": resolvedModel,
            "state": stateDict,
            "questions": questions
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func makeProactiveSystemOneRequest(
        catalog: IntentCatalog,
        context: AssistantContext
    ) throws -> URLRequest {
        let url = try endpointURL(path: "/systemone")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = effectiveAPIKey()
        request.setValue("Bearer \(key.isEmpty ? "local" : key)", forHTTPHeaderField: "Authorization")

        let resolvedModel = resolvedSystemOneModel(for: url)
        var questions: [String: Any] = [:]
        for (alias, device) in catalog.aliasDevices {
            questions["dev_\(alias)"] = [
                "type": "choice",
                "instructions": Self.proactiveHeadInstruction(alias: alias),
                "criteria": Self.deviceSpecificCriteria(for: device)
            ]
        }

        let stateDict: [String: Any] = [
            "catalog": catalog.text,
            "time": Self.promptField(context.timeSummary) ?? "",
            "environment": Self.promptField(context.environmentSummary) ?? "",
            "active_devices": Self.promptField(context.activeDevicesSummary) ?? "",
            "user_habits": Self.promptField(context.habitSummary) ?? ""
        ]

        let body: [String: Any] = [
            "model": resolvedModel,
            "state": stateDict,
            "questions": questions
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func makeProactiveChatRequest(
        catalog: IntentCatalog,
        context: AssistantContext
    ) throws -> URLRequest {
        let url = try endpointURL(path: "/chat/completions")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = effectiveAPIKey()
        request.setValue("Bearer \(key.isEmpty ? "local" : key)", forHTTPHeaderField: "Authorization")

        let system = """
        你是智能家居主动建议引擎。根据当前时间、室内温湿度、开启中的设备与用户习惯，推荐最多 3 个最值得立即执行的设备调整建议，只输出 JSON，不要解释。
        \(catalog.text)
        schema: {"suggestions":[{"device":"id","op":"power|brightness|color_temp|effect|hvac_mode|temperature|fan_speed|oscillation|scene","value":...,"confidence":85}]}
        规则：confidence 为 20-99 的整数置信度；如果当前环境已处于理想状态无需操作，输出 {"suggestions":[]}。只能使用上面列出的 id。
        """
        let userState = "时间：\(Self.promptField(context.timeSummary) ?? "")\n环境：\(Self.promptField(context.environmentSummary) ?? "")\n开启中：\(Self.promptField(context.activeDevicesSummary) ?? "")\n习惯：\(Self.promptField(context.habitSummary) ?? "")"

        let body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userState]
            ],
            "temperature": 0,
            "max_tokens": 600,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func resolvedSystemOneModel(for url: URL) -> String {
        let trimmedModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerModel = trimmedModel.lowercased()
        if AssistantEndpoint(url.absoluteString)?.hostMatches(domain: "openrouter.ai") == true {
            if lowerModel.contains("jev"), !trimmedModel.hasPrefix("~") {
                if lowerModel.hasPrefix("typesafe/") {
                    return "~" + trimmedModel
                }
                return "~typesafe/\(trimmedModel)"
            }
            return trimmedModel
        }
        // Native TypeSafe endpoint (e.g. api.typesafe.ai) or non-OpenRouter SystemOne gateway:
        // Strip OpenRouter's "~typesafe/" or "typesafe/" prefix so "jev-latest" is sent cleanly.
        if lowerModel.hasPrefix("~typesafe/") {
            return String(trimmedModel.dropFirst("~typesafe/".count))
        }
        if lowerModel.hasPrefix("typesafe/") {
            return String(trimmedModel.dropFirst("typesafe/".count))
        }
        return trimmedModel.isEmpty ? "jev-latest" : trimmedModel
    }

    private func effectiveAPIKey() -> String {
        var key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return key
    }

    private func endpointURL(path: String) throws -> URL {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        for suffix in ["/chat/completions", "/systemone"] {
            if base.lowercased().hasSuffix(suffix) {
                base = String(base.dropLast(suffix.count))
                while base.hasSuffix("/") { base.removeLast() }
            }
        }
        if !base.isEmpty, !base.contains("://") {
            base = "https://" + base
        }
        guard let endpoint = AssistantEndpoint(base),
              let baseURL = URL(string: base) else {
            throw AssistantError.invalidBaseURL(config.baseURL)
        }
        guard endpoint.allowsSendingSecrets else {
            throw AssistantError.insecureEndpoint(config.baseURL)
        }
        let basePath = baseURL.path
        if endpoint.hostMatches(domain: "openrouter.ai") {
            if basePath.isEmpty {
                base += "/api/v1"
            } else if basePath == "/api" {
                base += "/v1"
            }
        } else if basePath.isEmpty {
            base += "/v1"
        }
        guard let url = URL(string: base + path) else {
            throw AssistantError.invalidBaseURL(config.baseURL)
        }
        return url
    }

    static func systemPrompt(catalog: IntentCatalog, context: AssistantContext = AssistantContext()) -> String {
        let contextParts = [context.timeSummary, context.environmentSummary, context.activeDevicesSummary, context.habitSummary]
            .compactMap { promptField($0) }
        let contextBlock = contextParts.isEmpty ? "" : "\n当前环境与习惯：\(contextParts.joined(separator: "；"))\n"
        return """
        你是智能家居指令解析器。把用户的中文指令转换为 JSON，只输出 JSON，不要解释。\(contextBlock)
        \(catalog.text)
        schema: {"actions":[{"device":"id","op":"power|brightness|brightness_step|color_temp|effect|hvac_mode|temperature|temperature_step|fan_speed|oscillation|scene","value":...}],"reply":"一句话中文回执"}
        规则：power 的 value 为 true/false；brightness 为 1-100（调暗用 20，调亮用 100）；color_temp 为开尔文；\
        effect 取 Day（日光模式）或 Night（月光/夜灯模式），且必须是该灯具的可用模式；\
        hvac_mode 取 cool/heat/dry/fan_only/auto/off 且必须是该设备的可用模式；temperature 为摄氏度数字；\
        brightness_step / temperature_step 是相对调节（"再暗一点"=-20，"调高两度"=2），优先用于"再…一点"类说法；\
        fan_speed 取 high/medium/low/auto 或该设备"可选风速"里的原名；oscillation 为 true/false（风扇摇头）；\
        scene 的 device 填场景 id，value 填 null。只能使用上面列出的 id。\
        无法执行时 actions 为空数组，并在 reply 中简短说明原因。
        """
    }

    // MARK: - Response Boundary

    static func messageContent(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AssistantError.malformedResponse
        }
        let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !content.isEmpty else { throw AssistantError.emptyResponse }
        return content
    }

    /// Parses model output into typed intents, dropping unknown targets and invalid operations.
    static func plan(
        fromModelContent content: String,
        catalog: IntentCatalog,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) throws -> IntentPlan {
        guard let jsonText = firstJSONObject(in: content),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.malformedResponse
        }
        let actions = object["actions"] as? [[String: Any]] ?? []
        let chosen: [ChosenAction] = actions.flatMap { action -> [ChosenAction] in
            guard let alias = action["device"] as? String,
                  let opName = action["op"] as? String,
                  let op = operation(named: opName, value: action["value"]) else { return [] }
            return catalog.realIds(forTargetChoice: alias).map { targetId in
                ChosenAction(
                    intent: DeviceIntent(targetId: targetId, operation: op),
                    confidence: nil,
                    primaryChoice: false
                )
            }
        }
        let rawSuggestions = object["suggestions"] as? [[String: Any]] ?? []
        let modelReply = (object["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plan(
            chosenActions: chosen,
            rawSuggestions: rawSuggestions,
            modelReply: modelReply,
            catalog: catalog,
            devices: devices,
            scenes: scenes
        )
    }

    /// The single policy boundary for both cloud JSON and Apple's on-device guided generation:
    /// alias expansion already happened, so this applies `ModelActionPolicy`/`IntentValidator`,
    /// merges follow-up suggestions, and picks the reply shown in the command bar.
    static func plan(
        chosenActions chosen: [ChosenAction],
        rawSuggestions: [[String: Any]] = [],
        modelReply: String,
        catalog: IntentCatalog,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> IntentPlan {
        let decision = ModelActionPolicy.decide(
            devices: devices,
            scenes: scenes,
            payload: ModelDecisionPayload(actions: chosen)
        )
        let intents = decision.intents
        let confirmChips = decision.suggestions
        let primaryTargetIds = Set((intents + confirmChips.flatMap(\.intents)).map(\.targetId))
        let parsedSuggestions = parseChatSuggestionItems(
            rawSuggestions,
            catalog: catalog,
            devices: devices,
            scenes: scenes
        ).filter { suggestion in
            !suggestion.intents.contains(where: { primaryTargetIds.contains($0.targetId) })
        }
        let reply: String
        if !confirmChips.isEmpty {
            // The model's own reply may claim the waiting actions already happened.
            let ran = IntentReply.describe(intents, devices: devices, scenes: scenes)
            reply = ModelActionPolicy.confirmationReply(ranReply: intents.isEmpty ? nil : ran)
        } else {
            reply = modelReply.isEmpty ? IntentReply.describe(intents, devices: devices, scenes: scenes) : modelReply
        }
        return IntentPlan(intents: intents, reply: reply, source: .model, suggestions: confirmChips + parsedSuggestions)
    }

    static func proactiveSuggestionsFromChat(
        content: String,
        catalog: IntentCatalog,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) throws -> [AssistantSuggestion] {
        guard let jsonText = firstJSONObject(in: content),
              let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.malformedResponse
        }
        let items = (object["suggestions"] as? [[String: Any]])
            ?? (object["actions"] as? [[String: Any]])
            ?? []
        return parseChatSuggestionItems(items, catalog: catalog, devices: devices, scenes: scenes)
    }

    private static func parseChatSuggestionItems(
        _ items: [[String: Any]],
        catalog: IntentCatalog,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> [AssistantSuggestion] {
        var scored: [(pct: Int, suggestion: AssistantSuggestion)] = []
        for (idx, item) in items.enumerated() {
            guard let alias = item["device"] as? String,
                  let opName = item["op"] as? String,
                  let op = operation(named: opName, value: item["value"]) else {
                continue
            }
            let targetIds = catalog.realIds(forTargetChoice: alias)
            let sanitized = IntentValidator.sanitize(
                targetIds.map { DeviceIntent(targetId: $0, operation: op) },
                devices: devices,
                scenes: scenes
            )
            guard let primary = sanitized.first,
                  let title = UserHabitMemory.suggestionTitle(for: primary, devices: devices, scenes: scenes) else {
                continue
            }
            let rawConf = number(from: item["confidence"]) ?? 80
            let normalizedConf = rawConf <= 1.0 ? Int((rawConf * 100).rounded()) : Int(rawConf.rounded())
            let pct = max(18, min(99, normalizedConf))
            scored.append((
                pct,
                AssistantSuggestion(
                    id: "chat:\(primary.targetId):\(idx)",
                    title: title,
                    confidencePercent: pct,
                    intents: [primary]
                )
            ))
        }
        return scored
            .sorted { $0.pct > $1.pct }
            .prefix(3)
            .map(\.suggestion)
    }

    static func planFromSystemOne(
        data: Data,
        catalog: IntentCatalog,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) throws -> IntentPlan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else {
            throw AssistantError.malformedResponse
        }
        let targetChoice = (answers["target"] as? [String: Any])?["choice"] as? String ?? "none"
        let opChoice = (answers["op"] as? [String: Any])?["choice"] as? String ?? ""
        let tempChoice = (answers["temp"] as? [String: Any])?["choice"] as? String ?? "none"

        var actions: [ChosenAction] = []
        var runnerUps: [(prob: Double, suggestion: AssistantSuggestion)] = []

        let targetIds = catalog.realIds(forTargetChoice: targetChoice)
        let hasPrimaryTarget = targetChoice != "none" && !targetIds.isEmpty
        if hasPrimaryTarget {
            var ops: [IntentOperation] = []
            var confidence = ModelActionPolicy.probability(of: answers["target"] as? [String: Any], choice: targetChoice)
            if let primaryOp = systemOneOperation(for: opChoice) {
                ops.append(primaryOp)
                confidence = min(confidence, ModelActionPolicy.probability(of: answers["op"] as? [String: Any], choice: opChoice))
            }
            if tempChoice != "none", let degree = Double(tempChoice) {
                ops.append(.targetTemperature(degree))
                confidence = min(confidence, ModelActionPolicy.probability(of: answers["temp"] as? [String: Any], choice: tempChoice))
            }
            for id in targetIds {
                for op in ops {
                    actions.append(ChosenAction(
                        intent: DeviceIntent(targetId: id, operation: op),
                        confidence: confidence,
                        primaryChoice: true
                    ))
                }
            }
        }

        for (alias, device) in catalog.aliasDevices {
            guard let answer = answers["dev_\(alias)"] as? [String: Any] else { continue }
            let choice = answer["choice"] as? String ?? "none"
            let probs = answer["probabilities"] as? [String: Any] ?? [:]
            let choiceProb = ModelActionPolicy.probability(of: answer, choice: choice)
            let isFallbackPowerOnForEffect = opChoice.hasPrefix("effect_") && choice == "power_on" && !targetIds.contains(device.id)

            if choice != "none", !isFallbackPowerOnForEffect {
                for op in systemOneDeviceOperations(for: choice) {
                    actions.append(ChosenAction(
                        intent: DeviceIntent(targetId: device.id, operation: op),
                        confidence: choiceProb,
                        primaryChoice: false
                    ))
                }
                continue
            }

            let candidate: (String, Double)?
            if choice != "none" {
                candidate = (choice, choiceProb)
            } else {
                candidate = bestNonNoneProbability(in: probs)
            }
            if let (runnerUpChoice, runnerUpProb) = candidate,
               choice != "none" || runnerUpProb >= ModelActionPolicy.suggestionFloor {
                let ops = IntentValidator.sanitize(
                    systemOneDeviceOperations(for: runnerUpChoice).map { DeviceIntent(targetId: device.id, operation: $0) },
                    devices: devices,
                    scenes: scenes
                )
                if let first = ops.first,
                   let title = UserHabitMemory.suggestionTitle(for: first, devices: devices, scenes: scenes) {
                    let pct: Int? = runnerUpProb > 0 ? max(20, min(99, Int((runnerUpProb * 100).rounded()))) : nil
                    runnerUps.append((
                        runnerUpProb,
                        AssistantSuggestion(
                            id: "jev:\(device.id):\(runnerUpChoice)",
                            title: title,
                            confidencePercent: pct,
                            intents: ops
                        )
                    ))
                }
            }
        }

        let decision = ModelActionPolicy.decide(
            devices: devices,
            scenes: scenes,
            payload: ModelDecisionPayload(actions: actions)
        )
        let taken = Set((decision.intents + decision.suggestions.flatMap(\.intents)).map(\.targetId))
        var seenTargetSets: Set<Set<String>> = []
        let extras = runnerUps
            .filter { item in
                Set(item.suggestion.intents.map(\.targetId)).isDisjoint(with: taken)
            }
            .sorted { $0.prob > $1.prob }
            .filter { item in seenTargetSets.insert(Set(item.suggestion.intents.map(\.targetId))).inserted }
            .prefix(3)
            .map(\.suggestion)
        let suggestions = decision.suggestions + extras
        let described = IntentReply.describe(decision.intents, devices: devices, scenes: scenes)
        let reply = suggestions.isEmpty
            ? described
            : ModelActionPolicy.confirmationReply(ranReply: decision.intents.isEmpty ? nil : described)
        return IntentPlan(
            intents: decision.intents,
            reply: reply,
            source: .model,
            suggestions: suggestions
        )
    }

    static func proactiveSuggestionsFromSystemOne(
        data: Data,
        catalog: IntentCatalog,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) throws -> [AssistantSuggestion] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else {
            throw AssistantError.malformedResponse
        }

        var scored: [(prob: Double, suggestion: AssistantSuggestion)] = []
        for (alias, device) in catalog.aliasDevices {
            guard let answer = answers["dev_\(alias)"] as? [String: Any] else { continue }
            let probs = answer["probabilities"] as? [String: Any] ?? [:]
            let topChoice = answer["choice"] as? String ?? "none"

            let chosenKey: String
            let chosenProb: Double
            if topChoice != "none" {
                chosenKey = topChoice
                chosenProb = number(from: probs[topChoice]) ?? (number(from: answer["confidence"]) ?? 0.65)
            } else if let (runnerUp, prob) = bestNonNoneProbability(in: probs), prob >= 0.18 {
                chosenKey = runnerUp
                chosenProb = prob
            } else {
                continue
            }

            let ops = IntentValidator.sanitize(
                systemOneDeviceOperations(for: chosenKey).map { DeviceIntent(targetId: device.id, operation: $0) },
                devices: devices,
                scenes: scenes
            )
            guard ops.contains(where: { UserHabitMemory.isActionable($0, devices: devices, scenes: scenes) }),
                  let primary = ops.first,
                  let firstTitle = UserHabitMemory.suggestionTitle(for: primary, devices: devices, scenes: scenes) else {
                continue
            }
            let title: String
            if ops.count >= 2,
               case .hvacMode = ops[0].operation,
               case .targetTemperature(let celsius) = ops[1].operation {
                title = "\(firstTitle) · \(L10n.temperature(celsius))"
            } else {
                title = firstTitle
            }
            let pct = max(18, min(99, Int((chosenProb * 100).rounded())))
            scored.append((
                chosenProb,
                AssistantSuggestion(
                    id: "proactive:\(device.id):\(chosenKey)",
                    title: title,
                    confidencePercent: pct,
                    intents: ops
                )
            ))
        }

        return scored
            .sorted { $0.prob > $1.prob }
            .prefix(3)
            .map(\.suggestion)
    }

    public static func deviceHeadInstruction(alias: String) -> String {
        "What action should be taken on device \(alias) for this command? Choose none if unrelated."
    }

    public static func proactiveHeadInstruction(alias: String) -> String {
        "What proactive adjustment for device \(alias)? Select none if current state is already ideal."
    }

    private static func promptField(_ raw: String) -> String? {
        let cleaned = PromptText.sanitize(raw, limit: PromptText.contextLimit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func deviceSpecificCriteria(for device: SmartDevice) -> [String: String] {
        var criteria: [String: String] = [
            "none": "保持不变，不操作此设备",
            "power_on": "打开此设备",
            "power_off": "关闭此设备"
        ]
        switch device.kind {
        case .light(let spec):
            if spec.availableEffects.contains(where: { $0.caseInsensitiveCompare("Day") == .orderedSame }) {
                criteria["effect_day"] = "切换为日光模式（专注照明）"
            }
            if spec.availableEffects.contains(where: { $0.caseInsensitiveCompare("Night") == .orderedSame }) {
                criteria["effect_night"] = "切换为月光/夜灯模式（柔和助眠）"
            }
            criteria["bri_20"] = "调暗灯光 (20%)"
            criteria["bri_100"] = "调亮灯光 (100%)"
            if spec.isOn {
                criteria["bri_down_20"] = "再暗一点 (-20%)"
                criteria["bri_up_20"] = "再亮一点 (+20%)"
            }
        case .climate(let spec):
            if spec.availableModes.contains("cool") {
                criteria["cool_24"] = "开启制冷 24°C（快速降温）"
                criteria["cool_25"] = "开启制冷 25°C"
                criteria["cool_26"] = "开启制冷 26°C（舒适恒温）"
            }
            if spec.availableModes.contains("heat") {
                criteria["heat_22"] = "开启制热 22°C"
                criteria["heat_24"] = "开启制热 24°C"
            }
            if spec.availableModes.contains("dry") {
                criteria["hvac_dry"] = "开启除湿模式"
            }
            if spec.isOn {
                criteria["temp_up_2"] = "温度相对调高 2°C"
                criteria["temp_down_2"] = "温度相对调低 2°C"
            }
        case .fan(let spec):
            if !spec.availablePresetModes.isEmpty {
                criteria["fan_low"] = "风速调为低档"
                criteria["fan_medium"] = "风速调为中档"
                criteria["fan_high"] = "风速调为高档"
            }
            criteria["osc_on"] = "开启摇头"
            criteria["osc_off"] = "停止摇头"
        default:
            break
        }
        return criteria
    }

    private static func systemOneDeviceOperations(for choice: String) -> [IntentOperation] {
        switch choice {
        case "cool_24": return [.hvacMode("cool"), .targetTemperature(24)]
        case "cool_25": return [.hvacMode("cool"), .targetTemperature(25)]
        case "cool_26": return [.hvacMode("cool"), .targetTemperature(26)]
        case "heat_22": return [.hvacMode("heat"), .targetTemperature(22)]
        case "heat_24": return [.hvacMode("heat"), .targetTemperature(24)]
        default:
            if let op = systemOneOperation(for: choice) {
                return [op]
            }
            return []
        }
    }

    private static func bestNonNoneProbability(in probabilities: [String: Any]) -> (String, Double)? {
        var bestKey: String?
        var bestProb: Double = 0
        for (key, rawVal) in probabilities where key != "none" {
            if let p = number(from: rawVal), p > bestProb {
                bestProb = p
                bestKey = key
            }
        }
        guard let key = bestKey else { return nil }
        return (key, bestProb)
    }

    private static func systemOneOperation(for choice: String) -> IntentOperation? {
        switch choice {
        case "power_on": return .power(true)
        case "power_off": return .power(false)
        case "effect_night": return .lightEffect("Night")
        case "effect_day": return .lightEffect("Day")
        case "bri_20": return .brightness(20)
        case "bri_50": return .brightness(50)
        case "bri_100": return .brightness(100)
        case "bri_down_20": return .brightnessStep(-20)
        case "bri_up_20": return .brightnessStep(20)
        case "ct_2700": return .colorTemperature(2700)
        case "ct_4000": return .colorTemperature(4000)
        case "ct_6500": return .colorTemperature(6500)
        case "hvac_cool": return .hvacMode("cool")
        case "hvac_heat": return .hvacMode("heat")
        case "hvac_dry": return .hvacMode("dry")
        case "hvac_fan": return .hvacMode("fan_only")
        case "hvac_auto": return .hvacMode("auto")
        case "temp_up_2": return .temperatureStep(2)
        case "temp_down_2": return .temperatureStep(-2)
        case "fan_low": return .fanSpeed("low")
        case "fan_medium": return .fanSpeed("medium")
        case "fan_high": return .fanSpeed("high")
        case "fan_auto": return .fanSpeed("auto")
        case "osc_on": return .oscillation(true)
        case "osc_off": return .oscillation(false)
        case "scene": return .activateScene
        default: return nil
        }
    }

    static func operation(named name: String, value: Any?) -> IntentOperation? {
        switch name.lowercased() {
        case "power":
            return bool(from: value).map(IntentOperation.power)
        case "brightness":
            return number(from: value).map { .brightness(Int($0.rounded())) }
        case "color_temp", "color_temperature":
            return number(from: value).map { .colorTemperature(Int($0.rounded())) }
        case "effect", "light_effect":
            return (value as? String).map(IntentOperation.lightEffect)
        case "hvac_mode", "mode":
            return (value as? String).map(IntentOperation.hvacMode)
        case "temperature", "target_temperature":
            return number(from: value).map(IntentOperation.targetTemperature)
        case "scene":
            return .activateScene
        case "brightness_step":
            return number(from: value).map { .brightnessStep(Int($0.rounded())) }
        case "temperature_step":
            return number(from: value).map(IntentOperation.temperatureStep)
        case "fan_speed", "fan_mode", "preset":
            return (value as? String).map(IntentOperation.fanSpeed)
        case "oscillation", "swing":
            return bool(from: value).map(IntentOperation.oscillation)
        default:
            return nil
        }
    }

    private static func bool(from value: Any?) -> Bool? {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.intValue != 0
        case let s as String:
            switch s.lowercased() {
            case "true", "on", "1", "开": return true
            case "false", "off", "0", "关": return false
            default: return nil
            }
        default: return nil
        }
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: CharacterSet(charactersIn: " %°CcKk")))
        default: return nil
        }
    }

    /// Extracts the first balanced `{...}` JSON object, tolerating `<think>...</think>` blocks,
    /// ```json fences, and surrounding prose.
    static func firstJSONObject(in text: String) -> String? {
        let stripped: String
        if let closeRange = text.range(of: "</think>", options: [.caseInsensitive, .backwards]) {
            stripped = String(text[closeRange.upperBound...])
        } else {
            stripped = text
        }
        if let found = extractBalancedJSONObject(from: stripped) {
            return found
        }
        if stripped != text {
            return extractBalancedJSONObject(from: text)
        }
        return nil
    }

    private static func extractBalancedJSONObject(from text: String) -> String? {
        var searchStart = text.startIndex
        var firstBalanced: String?
        while searchStart < text.endIndex,
              let start = text[searchStart...].firstIndex(of: "{") {
            var depth = 0
            var inString = false
            var escaped = false
            var index = start
            var matchedEnd: String.Index?
            while index < text.endIndex {
                let ch = text[index]
                if inString {
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == "\"" { inString = false }
                } else if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        matchedEnd = index
                        break
                    }
                }
                index = text.index(after: index)
            }
            if let end = matchedEnd {
                let candidate = String(text[start...end])
                if firstBalanced == nil { firstBalanced = candidate }
                if let data = candidate.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil {
                    return candidate
                }
                searchStart = text.index(after: end)
            } else {
                break
            }
        }
        return firstBalanced
    }
}
