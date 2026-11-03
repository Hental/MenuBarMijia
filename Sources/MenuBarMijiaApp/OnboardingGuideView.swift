import SwiftUI
import AppKit
import MijiaCore

/// First launch teaches three things only (#180): connect an account, find a device with the
/// global shortcut, and try All Off + Undo. Everything else — AI, GrokBall, cameras, automation,
/// URL control — lives behind the collapsed "Advanced" disclosure.
public struct OnboardingGuideView: View {
    @Environment(\.colorScheme) private var colorScheme
    public let store: HomeStore

    @State private var haURLDraft: String = ""
    @State private var haTokenDraft: String = ""
    @State private var selectedPreset: AssistantProviderPreset = .openRouterJev
    @State private var apiKeyDraft: String = ""
    @State private var voiceAuthorized: Bool = false
    @State private var isRequestingVoice: Bool = false
    /// Advanced stays shut on first launch; the user opens it only when they need it.
    @State private var isAdvancedExpanded: Bool = false

    public init(store: HomeStore) {
        self.store = store
    }

    public var body: some View {
        let _ = store.effectiveLanguage
        let checklist = store.onboardingChecklist
        VStack(alignment: .leading, spacing: 0) {
            headerBar
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    step1ConnectionCard
                    step2SearchCard(checklist: checklist)
                    step3AllOffUndoCard(checklist: checklist)
                    advancedDisclosure
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
            }
            .frame(maxHeight: .infinity)

            Divider()
                .overlay(Color.primary.opacity(0.07))

            bottomActionRow
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .onAppear {
            haURLDraft = store.serverURLString
            haTokenDraft = KeychainHelper.loadToken()
            let currentBase = store.assistantConfig.baseURL
            selectedPreset = AssistantProviderPreset.infer(baseURL: currentBase)
            apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: currentBase)
            voiceAuthorized = SpeechInputController.shared.hasVoicePermissions
            if store.miSessionMaskedUserId == nil,
               haTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               store.homeBackend == .homeAssistant {
                // Never pull a user who chose the offline demo back into a cloud login (#47).
                store.switchBackend(.xiaomiCloud)
            }
            Task {
                let found = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: true)
                if let first = found.first {
                    let normDraft = HAWebSocketProvider.normalizeBaseURL(haURLDraft)
                    if haURLDraft.isEmpty || normDraft == KeychainHelper.defaultNASURL {
                        haURLDraft = first.baseURL
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.orange, Color(red: 0.92, green: 0.38, blue: 0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)

                Image(systemName: "house.fill")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1.5) {
                Text(L10n.tr("三步上手", "Three Steps to Start"))
                    .font(.system(size: 14, weight: .bold))
                    .tracking(-0.2)

                Text(L10n.tr(
                    "连接账号 · 按 \(hotkeyLabel) 搜设备 · 全关后还能撤销",
                    "Connect an account · Search with \(hotkeyLabel) · Turn all off, then undo"
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(store.effectiveLanguage == .en ? "中文" : "EN") {
                withAnimation(AppleMotion.snappySpring) {
                    store.appLanguagePreference = (store.effectiveLanguage == .en) ? .zhHans : .en
                }
            }
            .buttonStyle(PillActionButtonStyle())
            .help(L10n.tr("切换为英文界面 / Switch to English", "Switch to Chinese / 切换为中文界面"))

            Button(L10n.tr("跳过", "Skip")) {
                withAnimation(AppleMotion.snappySpring) {
                    store.completeOnboarding()
                }
            }
            .buttonStyle(PillActionButtonStyle())
            .help(L10n.tr("跳过引导，直接开始", "Skip the guide and start now"))
        }
    }

    // MARK: - Step 1: Connect Devices

    private var step1ConnectionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                stepBadge("1", isDone: store.hasConnectedHomeSource)
                Text(L10n.tr("连接账号（米家扫码 / Home Assistant）", "Connect an Account (Mi QR / Home Assistant)"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if store.hasConnectedHomeSource {
                    Label(L10n.tr("已连接", "Connected"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else if let firstHA = store.discoveredHAInstances.first {
                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            haURLDraft = firstHA.baseURL
                            store.applyDiscoveredHAInstance(firstHA, reconnectProvider: false)
                            store.switchBackend(.homeAssistant)
                        }
                    } label: {
                        Label(
                            L10n.tr("已发现局域网 HA · \(firstHA.hostAndPort)", "Found LAN HA · \(firstHA.hostAndPort)"),
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(L10n.tr("推荐手机扫码", "QR Login Recommended"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }

            Picker(
                "",
                selection: Binding(
                    get: { store.homeBackend },
                    set: { newBackend in
                        withAnimation(AppleMotion.snappySpring) {
                            store.switchBackend(newBackend)
                        }
                    }
                )
            ) {
                ForEach(HomeBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            Text(L10n.tr(
                "Home Assistant 与米家云端可以同时配置；这里只切换当前填写的连接表单，已配置的另一端会继续连接。",
                "Home Assistant and Xiaomi Cloud can be configured together. This only switches the form below; the other configured source keeps running."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // #47: let people try the panel before signing any account in.
            if store.homeBackend == .demo {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text(L10n.tr(
                        "演示模式已开启：内置虚拟家庭，完全离线，不发起任何网络请求。选择上方「米家云端直连」或「Home Assistant」即可切回真实账号。",
                        "Demo mode is on: a built-in virtual home, fully offline, no network requests. Pick Xiaomi Cloud or Home Assistant above to switch back to a real account."
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(AppleMotion.snappySpring) {
                            store.switchBackend(.demo)
                            // No `completeOnboarding()`: once demo devices arrive the guide hides by
                            // itself, and switching to an account without credentials shows it again.
                            store.showToast(L10n.tr("已进入演示模式，可随时在设置里切回真实账号", "Demo mode on; switch back anytime in Settings"))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.rectangle")
                            Text(L10n.tr("先看看演示（无需账号）", "Try the Demo (No Account)"))
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))

                    Text(L10n.tr("用虚拟设备体验面板与皮肤", "Explore the dashboard with virtual devices"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            if store.homeBackend == .xiaomiCloud {
                MiAccountSection(store: store)
            } else if store.homeBackend == .homeAssistant {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        TextField("https://your-home.ui.nabu.casa", text: $haURLDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))

                        Button(store.isDiscoveringHA ? L10n.tr("扫描中…", "Scanning…") : L10n.tr("自动扫描", "Auto Scan")) {
                            Task {
                                let found = await store.discoverHomeAssistantOnLAN(autoApplyIfDefault: false)
                                if let first = found.first {
                                    haURLDraft = first.baseURL
                                    store.showToast(L10n.tr("已发现：\(first.displaySummary)", "Found: \(first.displaySummary)"))
                                } else {
                                    store.showToast(L10n.tr("未在局域网扫描到 Home Assistant", "No Home Assistant found on LAN"), isError: true)
                                }
                            }
                        }
                        .buttonStyle(PillActionButtonStyle())
                        .disabled(store.isDiscoveringHA)
                    }

                    if let address = URL(string: HAWebSocketProvider.normalizeBaseURL(haURLDraft)),
                       address.scheme == "http",
                       let host = address.host,
                       !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) {
                        Label(L10n.tr("令牌将以明文在网络上传输，建议使用 HTTPS 或 Nabu Casa 地址。", "Your token will travel unencrypted. Use HTTPS or a Nabu Casa address."), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let firstHA = store.discoveredHAInstances.first {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                            Text(L10n.tr("已自动识别局域网 HA：\(firstHA.displaySummary)", "Detected LAN HA: \(firstHA.displaySummary)"))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if let secURL = URL(string: "\(HAWebSocketProvider.normalizeBaseURL(haURLDraft))/profile/security") {
                                Button(L10n.tr("打开网页取令牌", "Open Security Page")) {
                                    NSWorkspace.shared.open(secURL)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        SecureField(L10n.tr("粘贴 HA 长期访问令牌", "Paste HA Long-Lived Access Token"), text: $haTokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .font(.system(size: 11, design: .monospaced))

                        Button(L10n.tr("连接", "Connect")) {
                            store.updateConnection(serverURL: haURLDraft, token: haTokenDraft)
                        }
                        .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
                    }
                }
            }
        }
        .padding(11)
        .glassTile(isActive: store.hasConnectedHomeSource, cornerRadius: 12)
    }

    // MARK: - Step 2: Search with the global shortcut

    private func step2SearchCard(checklist: OnboardingChecklist) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                stepBadge("2", isDone: checklist.isComplete(.searchDevice))
                Text(L10n.tr("按 \(hotkeyLabel) 搜一个设备", "Press \(hotkeyLabel) to Find a Device"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if checklist.isComplete(.searchDevice) {
                    Label(L10n.tr("已试过", "Tried"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            Text(L10n.tr(
                "短按 \(hotkeyLabel) 打开面板，直接输入设备名或拼音首字母；↑↓ 选择，回车开关。长按 \(hotkeyLabel) 可以直接说话。",
                "Tap \(hotkeyLabel) to open the panel, then type a device name or pinyin initials. ↑↓ chooses, Return toggles. Hold \(hotkeyLabel) to speak instead."
            ))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                shortcutTipRow(
                    icon: "magnifyingglass",
                    title: L10n.tr("打字就是搜索", "Typing Is the Search"),
                    detail: L10n.tr(
                        "「书房灯」和 sfd 都能找到，房间名也会匹配；隐藏的设备不会出现。",
                        "\"Study light\" and sfd both match, room names work too, and hidden devices stay out."
                    )
                )
                shortcutTipRow(
                    icon: "arrow.up.arrow.down",
                    title: L10n.tr("↑↓ 选中，回车开关", "↑↓ to Choose, Return to Toggle"),
                    detail: L10n.tr(
                        "搜索结果按最匹配排序；按 Esc 退出搜索，再按一次关闭面板。",
                        "Results rank the best match first. Esc leaves search; a second Esc closes the panel."
                    )
                )
            }
        }
        .padding(11)
        .glassTile(isActive: false, cornerRadius: 12)
    }

    // MARK: - Step 3: All Off + Undo

    private func step3AllOffUndoCard(checklist: OnboardingChecklist) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                stepBadge("3", isDone: checklist.isComplete(.allOffAndUndo))
                Text(L10n.tr("试一次全关，再撤销", "Try All Off, Then Undo"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if checklist.isComplete(.allOffAndUndo) {
                    Label(L10n.tr("已试过", "Tried"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            Text(L10n.tr(
                "点面板底部的「全关」，10 秒内点撤销横幅就能恢复；3 台以上有 15 秒。",
                "Tap All Off at the bottom of the panel, then tap the undo banner within 10 seconds (15 seconds for three or more devices)."
            ))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                shortcutTipRow(
                    icon: "power",
                    title: L10n.tr("全关只碰当前能关的设备", "All Off Only Touches What Is On"),
                    detail: L10n.tr(
                        "隐藏的设备、插座和扫地机默认不动，避免关掉路由器和还在工作的家电。",
                        "Hidden devices, plugs and vacuums stay as they are, so a router or a working appliance is not switched off."
                    )
                )
                shortcutTipRow(
                    icon: "arrow.uturn.backward",
                    title: L10n.tr("撤销是一次性的", "Undo Is One Shot"),
                    detail: L10n.tr(
                        "撤销后横幅消失，再想改回来就点设备卡片。",
                        "The banner disappears after undo; toggle the device card if you change your mind again."
                    )
                )
            }
        }
        .padding(11)
        .glassTile(isActive: false, cornerRadius: 12)
    }

    // MARK: - Advanced (collapsed by default)

    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $isAdvancedExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.tr(
                    "这些功能第一次用到时再打开也不迟；下面每一行都标了在哪里配置。",
                    "You will not need these on day one. Each row says where it lives."
                ))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                advancedAIModelCard

                advancedPointerRow(
                    icon: "sparkles",
                    title: L10n.tr("GrokBall 情绪球", "GrokBall Sidecar"),
                    detail: L10n.tr(
                        "设置 → 通用 → 启用侧边情绪智能球，点一下看推荐、拖到顺手的位置。",
                        "Settings → General → Enable Sidecar Grok Ball. Click for suggestions, drag it where it fits."
                    ),
                    actionTitle: L10n.tr("打开设置", "Open Settings")
                ) {
                    SettingsWindowOpener.shared.show(tab: .general)
                }

                advancedPointerRow(
                    icon: "video",
                    title: L10n.tr("摄像机直播", "Camera Live View"),
                    detail: L10n.tr(
                        "连上摄像头后，点设备卡片上的摄像机图标就能看直播，无需在此配置。",
                        "Once a camera is connected, click the camera icon on its card for live view. Nothing to set up here."
                    )
                )

                advancedPointerRow(
                    icon: "gearshape.2",
                    title: L10n.tr("自动化与 URL 直控", "Automation & URL Control"),
                    detail: L10n.tr(
                        "设置 → 连接 → 自动化；URL 直控默认每次先确认。",
                        "Settings → Connections → Automation. URL control asks first by default."
                    ),
                    actionTitle: L10n.tr("打开设置", "Open Settings")
                ) {
                    SettingsWindowOpener.shared.show(tab: .connection)
                }

                advancedVoiceAndShortcutsCard
            }
            .padding(.top, 9)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.tr("进阶功能（用到再看）", "Advanced (Only When Needed)"))
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(L10n.tr(
                        "AI 指令、GrokBall、摄像机、自动化与 URL 直控",
                        "AI commands, GrokBall, cameras, automation and URL control"
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(L10n.tr("默认收起", "Collapsed"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Color.accentColor)
        .padding(11)
        .glassTile(isActive: false, cornerRadius: 12)
    }

    // MARK: - Advanced: AI Decision Model

    private var advancedAIModelCard: some View {
        let effectiveBase = selectedPreset.defaultBaseURL.isEmpty ? store.assistantConfig.baseURL : selectedPreset.defaultBaseURL
        let hasCustomKey = !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let importedSource = hasCustomKey ? AssistantConfig.importedKeySource(forBaseURL: effectiveBase) : nil
        let isLoopback = AssistantConfig(baseURL: effectiveBase, model: selectedPreset.defaultModel, apiKey: "").isLoopbackEndpoint

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16, alignment: .center)
                Text(L10n.tr("AI 决策模型（可选）", "AI Decision Model (Optional)"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let importedSource {
                    Label(L10n.tr("已从 \(importedSource) 导入", "Imported from \(importedSource)"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else if hasCustomKey {
                    Label(L10n.tr("已配置密钥", "Key Configured"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else if isLoopback {
                    Label(L10n.tr("本机免密接口", "Local Endpoint"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Text(L10n.tr("不填也能用本机规则", "Local Rules Work Without It"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Text(L10n.tr(
                "常规指令本机直接执行，不需要 AI。想要一次统筹多台设备或更口语的说法，再接 Jev、DeepSeek 等服务。",
                "Simple commands run on this Mac without AI. Connect Jev, DeepSeek or another service only for multi-device phrasing."
            ))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Picker(
                    "",
                    selection: Binding(
                        get: { selectedPreset },
                        set: { newPreset in
                            selectedPreset = newPreset
                            if newPreset != .custom {
                                apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: newPreset.defaultBaseURL)
                            } else {
                                apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: store.assistantConfig.baseURL)
                            }
                        }
                    )
                ) {
                    ForEach(AssistantProviderPreset.allCases) { preset in
                        Text(preset.shortTitle).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 96)
                .controlSize(.small)

                SecureField(selectedPreset.keyPlaceholder, text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11, design: .monospaced))

                Button(L10n.tr("保存", "Save")) {
                    persistOnboardingAssistantDraft()
                    store.showToast(L10n.tr("已保存 \(selectedPreset.shortTitle) 配置", "Saved \(selectedPreset.shortTitle) config"))
                }
                .buttonStyle(PillActionButtonStyle(isSelected: !apiKeyDraft.isEmpty, tintColor: .accentColor))
            }

            if selectedPreset.supportsKeyImport && !hasCustomKey {
                Button(L10n.tr("已在 CodexBar 或环境变量里配过？点此导入 Key", "Already set up in CodexBar or env vars? Import the key")) {
                    if let label = AssistantConfig.importAmbientAPIKey(forBaseURL: effectiveBase) {
                        apiKeyDraft = AssistantConfig.userStoredAPIKey(forBaseURL: effectiveBase)
                        store.showToast(L10n.tr("已从 \(label) 导入 \(selectedPreset.shortTitle) 的 Key", "Imported the \(selectedPreset.shortTitle) key from \(label)"))
                    } else {
                        store.showToast(
                            L10n.tr("CodexBar 和环境变量里都没有 \(selectedPreset.shortTitle) 的 Key", "No \(selectedPreset.shortTitle) key in CodexBar or environment variables"),
                            isError: true
                        )
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func persistOnboardingAssistantDraft() {
        let base = selectedPreset.defaultBaseURL.isEmpty ? store.assistantConfig.baseURL : selectedPreset.defaultBaseURL
        let model = selectedPreset.defaultModel.isEmpty ? store.assistantConfig.model : selectedPreset.defaultModel
        store.assistantConfig = AssistantConfig(
            baseURL: base,
            model: model,
            apiKey: apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Advanced: Voice & Shortcuts

    private var advancedVoiceAndShortcutsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16, alignment: .center)
                Text(L10n.tr("语音与快捷键（可选）", "Voice & Shortcuts (Optional)"))
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                if voiceAuthorized {
                    Label(L10n.tr("语音已授权", "Voice Authorized"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            Text(L10n.tr(
                "长按菜单栏图标或 \(hotkeyLabel) 直接说话，例如「书房灯月光模式」「10 分钟后关灯」，松手即执行。",
                "Hold the menu bar icon or \(hotkeyLabel) and speak, e.g. \"study light moonlight mode\" or \"turn off the lights in 10 minutes\", then release."
            ))
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !voiceAuthorized {
                HStack {
                    Spacer()
                    Button {
                        isRequestingVoice = true
                        Task { @MainActor in
                            let granted = await SpeechInputController.shared.requestPermissions()
                            voiceAuthorized = granted
                            isRequestingVoice = false
                            if granted {
                                store.showToast(L10n.tr("已开启麦克风与语音识别权限", "Microphone & Speech Recognition enabled"))
                            } else {
                                store.showToast(
                                    L10n.tr("可在「系统设置 → 隐私与安全性」中开启权限", "Enable permissions in System Settings → Privacy & Security"),
                                    isError: true
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                            Text(isRequestingVoice
                                 ? L10n.tr("正在请求系统授权…", "Requesting Authorization…")
                                 : L10n.tr("授权麦克风与语音", "Authorize Microphone & Speech"))
                        }
                    }
                    .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .orange))
                    .disabled(isRequestingVoice)
                }
                .padding(.top, 2)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Footer

    private var bottomActionRow: some View {
        HStack {
            Text(L10n.tr("随时可在「设置 → 通用 → 首次设置」重新打开", "Reopen anytime in Settings → General → Setup"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let currentPreset = AssistantProviderPreset.infer(baseURL: store.assistantConfig.baseURL)
                if !trimmedKey.isEmpty || selectedPreset != currentPreset {
                    persistOnboardingAssistantDraft()
                }
                withAnimation(AppleMotion.snappySpring) {
                    store.completeOnboarding()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.tr("开始使用", "Get Started"))
                    Image(systemName: "arrow.right")
                }
                .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
        }
    }

    // MARK: - Subviews

    private var hotkeyLabel: String {
        HotkeySettingsState.shared.shortcut.displayString
    }

    private func stepBadge(_ number: String, isDone: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isDone ? Color.green.opacity(0.2) : Color.accentColor.opacity(0.18))
                .frame(width: 18, height: 18)
            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.green)
            } else {
                Text(number)
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func shortcutTipRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func advancedPointerRow(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PillActionButtonStyle())
            }
        }
    }
}
