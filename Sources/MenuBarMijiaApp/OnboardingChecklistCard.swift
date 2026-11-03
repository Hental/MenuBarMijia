import SwiftUI
import MijiaCore

/// Compact next-steps card that rides above the live dashboard after a source is configured (#180
/// review). Keeping it outside the full-screen guide lets the user search a device and try All Off +
/// Undo while the instructions are still on screen.
struct OnboardingChecklistCard: View {
    let store: HomeStore
    var onBeginSearch: () -> Void

    var body: some View {
        let checklist = store.onboardingChecklist
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text(L10n.tr("上手清单", "Getting Started"))
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .semibold))

                Text("\(checklist.completedSteps.count)/\(OnboardingStep.allCases.count)")
                    .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Button {
                    withAnimation(AppleMotion.snappySpring) { store.completeOnboarding() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.tr("关闭上手清单", "Close getting-started checklist")))
                .panelHelp(L10n.tr("关闭清单；随时可在设置 → 通用 → 首次设置重新打开", "Close the checklist; reopen it in Settings → General → Setup"))
            }

            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { step in
                    stepPill(step, checklist: checklist)
                }
            }

            if let next = checklist.nextStep {
                HStack(alignment: .center, spacing: 6) {
                    Text(instruction(for: next, checklist: checklist))
                        .font(.system(size: DesignTokens.TypeSize.micro))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    actionButton(for: next)
                }
            } else {
                Text(L10n.tr("三步都试过了，可以关掉这张清单。", "All three tried — close this card whenever you like."))
                    .font(.system(size: DesignTokens.TypeSize.micro))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.20), lineWidth: DesignTokens.hairline)
        }
    }

    private func stepPill(_ step: OnboardingStep, checklist: OnboardingChecklist) -> some View {
        let done = checklist.isComplete(step)
        let current = checklist.nextStep == step
        return HStack(spacing: 3) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(done ? .green : (current ? Color.accentColor : Color.secondary))
            Text(title(for: step))
                .font(.system(size: DesignTokens.TypeSize.micro, weight: current ? .semibold : .regular))
                .foregroundStyle(done || current ? Color.primary.opacity(0.82) : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            (current ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)),
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title(for: step)) \(done ? L10n.tr("已完成", "done") : L10n.tr("未完成", "not done"))"))
    }

    @ViewBuilder
    private func actionButton(for step: OnboardingStep) -> some View {
        switch step {
        case .connectAccount:
            // The card only exists once a source is configured, so the connect lesson is already done.
            EmptyView()

        case .searchDevice:
            Button(L10n.tr("搜索", "Search")) {
                onBeginSearch()
            }
            .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))

        case .allOffAndUndo:
            if store.undoBanner != nil {
                Button(L10n.tr("撤销", "Undo")) {
                    withAnimation(AppleMotion.snappySpring) { _ = store.undoTurnAllOff() }
                }
                .buttonStyle(PillActionButtonStyle(isSelected: true, tintColor: .accentColor))
            } else {
                Button(L10n.tr("全关", "All Off")) {
                    withAnimation(AppleMotion.snappySpring) { store.turnAllOff() }
                }
                .buttonStyle(PillActionButtonStyle())
                .disabled(store.allOffTargets.isEmpty)
                .panelHelp(store.allOffTargets.isEmpty
                    ? L10n.tr("当前没有开启的设备", "No active devices are currently on")
                    : L10n.tr("关闭当前能关的设备，然后点撤销", "Turn off what is on, then undo"))
            }
        }
    }

    private var hotkeyLabel: String {
        HotkeySettingsState.shared.shortcut.displayString
    }

    private func title(for step: OnboardingStep) -> String {
        switch step {
        case .connectAccount:
            return L10n.tr("连接账号", "Connect")
        case .searchDevice:
            return L10n.tr("搜设备", "Search")
        case .allOffAndUndo:
            return L10n.tr("全关撤销", "All Off + Undo")
        }
    }

    private func instruction(for step: OnboardingStep, checklist: OnboardingChecklist) -> String {
        switch step {
        case .connectAccount:
            return L10n.tr(
                "扫码或填好 Home Assistant 地址后连接。",
                "Scan a QR code or enter your Home Assistant address."
            )
        case .searchDevice:
            return L10n.tr(
                "按 \(hotkeyLabel) 打开面板，直接打字搜索，↑↓ 选中，回车开关。",
                "Tap \(hotkeyLabel), type to search, use ↑↓ to choose and Return to toggle."
            )
        case .allOffAndUndo:
            if checklist.milestones.contains(.turnedAllOff), store.undoBanner != nil {
                return L10n.tr(
                    "已全关，点「撤销」恢复关闭前的状态。",
                    "Everything is off — tap Undo to restore the previous state."
                )
            }
            return L10n.tr(
                "点「全关」，10 秒内点撤销即可恢复。",
                "Tap All Off, then Undo within 10 seconds to restore it."
            )
        }
    }
}
