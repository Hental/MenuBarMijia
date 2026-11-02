import AppKit
import Observation
import SwiftUI
import MijiaCore

/// Screen coordinates keep the ball anchored while the suggestion surface grows around it.
struct GrokBallSidecarPlacement {
    enum Side {
        case left, right, above, below
        fileprivate static let directions: [Self] = [.left, .right, .above, .below]
        var isVertical: Bool { self == .left || self == .right }
    }

    static let collapsedWidth: CGFloat = 84
    static let expandedWidth: CGFloat = 232
    static let expandedHeight: CGFloat = 218
    static let gap: CGFloat = 8
    static let topInset: CGFloat = 44
    let side: Side
    let frame: NSRect
    let ballCenter: NSPoint
    let suggestionsFrame: NSRect?
    let suggestionColumns: Int

    var localBallCenter: CGPoint {
        CGPoint(x: ballCenter.x - frame.minX, y: frame.maxY - ballCenter.y)
    }

    var localSuggestionsOrigin: CGPoint {
        guard let suggestionsFrame else { return .zero }
        return CGPoint(x: suggestionsFrame.minX - frame.minX, y: frame.maxY - suggestionsFrame.maxY)
    }

    static func resolve(parent: NSRect, visible: NSRect, expanded: Bool, ballCenter requested: NSPoint? = nil) -> Self {
        let safe = visible.insetBy(dx: 8, dy: 8)
        let defaultRight = safe.maxX - parent.maxX - gap >= expandedWidth
        let initial = requested ?? NSPoint(
            x: defaultRight ? parent.maxX + gap + 42 : parent.minX - gap - 42,
            y: parent.maxY - topInset - 42
        )
        let center = NSPoint(
            x: clamp(initial.x, lower: safe.minX + 42, upper: safe.maxX - 42),
            y: clamp(initial.y, lower: safe.minY + 42, upper: safe.maxY - 42)
        )
        let dx = (center.x - parent.midX) / max(1, parent.width / 2)
        let dy = (center.y - parent.midY) / max(1, parent.height / 2)
        let preferred: Side = abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .below : .above)
        let ball = NSRect(x: center.x - 36, y: center.y - 36, width: 72, height: 72)
        var side = preferred
        var suggestions = suggestionLayout(side: preferred, ball: ball, safe: safe)
        var bestScore = score(suggestions.frame, side: preferred, preferred: preferred, safe: safe, parent: parent)
        for candidate in Side.directions where candidate != preferred {
            let layout = suggestionLayout(side: candidate, ball: ball, safe: safe)
            let candidateScore = score(layout.frame, side: candidate, preferred: preferred, safe: safe, parent: parent)
            if candidateScore < bestScore {
                side = candidate
                suggestions = layout
                bestScore = candidateScore
            }
        }
        let frame = (expanded ? ball.union(suggestions.frame) : ball).insetBy(dx: -6, dy: -6)
        return Self(side: side, frame: frame, ballCenter: center,
                    suggestionsFrame: expanded ? suggestions.frame : nil, suggestionColumns: suggestions.columns)
    }

    private static func suggestionLayout(side: Side, ball: NSRect, safe: NSRect) -> (frame: NSRect, columns: Int) {
        let metrics = GrokBallSuggestionMetrics.self
        if side.isVertical {
            let x = side == .right ? ball.maxX + metrics.gapToBall
                : ball.minX - metrics.gapToBall - metrics.columnWidth
            let y = clamp(ball.maxY - metrics.columnHeight,
                          lower: safe.minY + 6, upper: safe.maxY - metrics.columnHeight - 6)
            return (NSRect(x: x, y: y, width: metrics.columnWidth, height: metrics.columnHeight), 1)
        }
        let available = side == .above
            ? safe.maxY - 6 - ball.maxY - metrics.gapToBall
            : ball.minY - metrics.gapToBall - safe.minY - 6
        let columns = available < metrics.rowHeight && safe.width >= metrics.singleRowWidth + 12 ? 4 : 2
        let width = columns == 4 ? metrics.singleRowWidth : metrics.rowWidth
        let height = columns == 4 ? metrics.pillHeight : metrics.rowHeight
        let x = clamp(ball.midX - width / 2, lower: safe.minX + 6, upper: safe.maxX - width - 6)
        let y = side == .above ? ball.maxY + metrics.gapToBall : ball.minY - metrics.gapToBall - height
        return (NSRect(x: x, y: y, width: width, height: height), columns)
    }

    private static func score(_ rect: NSRect, side: Side, preferred: Side, safe: NSRect, parent: NSRect) -> (CGFloat, CGFloat, Int) {
        let footprint = rect.insetBy(dx: -6, dy: -6)
        let clipped = max(0, area(footprint) - area(footprint.intersection(safe)))
        return (clipped, area(rect.intersection(parent)), side == preferred ? 0 : 1)
    }

    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }
    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat { min(max(value, lower), max(lower, upper)) }
}

@Observable
@MainActor
final class GrokBallSidecarState {
    var placement: GrokBallSidecarPlacement?
    var isVisible = false
    let pointer = GrokBallPointerState()
}

/// Owns placement and mouse arbitration; the SwiftUI button retains keyboard/accessibility actions.
@MainActor
final class GrokBallSidecarController {
    let panelWindow: NSPanel
    private let store: HomeStore
    private weak var parent: NSPanel?
    private let state = GrokBallSidecarState()
    private let beginVoice: () -> Void
    private let endVoice: () -> Void
    private var pointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var holdTask: Task<Void, Never>?
    private var ballOffset: NSPoint?
    private var isTornDown = false
    private enum Gesture {
        case pressed(origin: NSPoint, center: NSPoint)
        case dragging(origin: NSPoint, center: NSPoint)
        case voice
    }
    private var gesture: Gesture?

    init(store: HomeStore, parent: NSPanel, beginVoice: @escaping () -> Void,
         endVoice: @escaping () -> Void, closePanel: @escaping () -> Void) {
        self.store = store
        self.parent = parent
        self.beginVoice = beginVoice
        self.endVoice = endVoice
        let panel = GrokBallSidecarPanel(contentRect: NSRect(x: 0, y: 0, width: 84, height: 84),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        panelWindow = panel
        panel.isFloatingPanel = true
        panel.level = parent.level
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        let hosting = NSHostingView(rootView: GrokBallSidecarView(store: store, state: state))
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.onCancel = { [weak store] in
            if let store, store.isGrokBallStageExpanded { store.dismissGrokBallStage() }
            else { closePanel() }
        }
        parent.acceptsMouseMovedEvents = true
        observePresentation()
    }

    func synchronize() {
        guard !isTornDown, let parent else { return }
        panelWindow.appearance = parent.appearance
        guard parent.isVisible, !store.shouldShowOnboarding, store.enableGrokBall else { hide(); return }
        let requested = ballOffset.map { NSPoint(x: parent.frame.midX + $0.x, y: parent.frame.midY + $0.y) }
        let visible = screen(at: requested)?.visibleFrame ?? parent.screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let placement = GrokBallSidecarPlacement.resolve(parent: parent.frame, visible: visible,
                                                        expanded: store.isGrokBallStageExpanded, ballCenter: requested)
        state.placement = placement
        panelWindow.setFrame(placement.frame, display: true)
        if panelWindow.parent !== parent { parent.addChildWindow(panelWindow, ordered: .above) }
        state.isVisible = true
        panelWindow.orderFront(nil)
        installPointerMonitor()
        updatePointer(at: NSEvent.mouseLocation)
    }

    func hide() {
        cancelGesture()
        state.isVisible = false
        state.pointer.position = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        pointerMonitor = nil
        globalPointerMonitor = nil
        parent?.removeChildWindow(panelWindow)
        panelWindow.orderOut(nil)
    }

    func tearDown() {
        isTornDown = true
        hide()
        parent?.removeChildWindow(panelWindow)
        panelWindow.contentView = nil
        parent = nil
    }

    private func screen(at point: NSPoint?) -> NSScreen? {
        guard let point else { return nil }
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func observePresentation() {
        guard !isTornDown else { return }
        withObservationTracking {
            _ = store.isGrokBallStageExpanded
            _ = store.shouldShowOnboarding
            _ = store.enableGrokBall
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isTornDown else { return }
                self.synchronize()
                self.observePresentation()
            }
        }
    }

    private func installPointerMonitor() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                if self.handlePointer(event, at: point) { return true }
                self.updatePointer(at: point)
                return false
            }
            return consumed ? nil : event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let point = NSEvent.mouseLocation
                if event.type == .leftMouseUp {
                    _ = self.handlePointer(event, at: point)
                }
                self.updatePointer(at: point)
            }
        }
    }

    func containsScreenPoint(_ point: NSPoint) -> Bool {
        guard state.isVisible, let placement = state.placement else { return false }
        let ballRect = NSRect(x: placement.ballCenter.x - 42, y: placement.ballCenter.y - 42, width: 84, height: 84)
        if ballRect.contains(point) { return true }
        if let suggestions = placement.suggestionsFrame?.insetBy(dx: -6, dy: -6), suggestions.contains(point) {
            return true
        }
        return false
    }

    private func handlePointer(_ event: NSEvent, at point: NSPoint) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard event.window === panelWindow, let placement = state.placement,
                  abs(point.x - placement.ballCenter.x) <= 42, abs(point.y - placement.ballCenter.y) <= 42 else { return false }
            gesture = .pressed(origin: point, center: placement.ballCenter)
            panelWindow.makeKey()
            holdTask?.cancel()
            holdTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, case .pressed = self.gesture else { return }
                self.gesture = .voice
                self.store.dismissGrokBallStage()
                self.beginVoice()
            }
            return true
        case .leftMouseDragged:
            guard let gesture else { return false }
            switch gesture {
            case let .pressed(origin, center):
                guard hypot(point.x - origin.x, point.y - origin.y) >= 6 else { return true }
                holdTask?.cancel()
                self.gesture = .dragging(origin: origin, center: center)
                store.dismissGrokBallStage()
                moveBall(to: NSPoint(x: center.x + point.x - origin.x, y: center.y + point.y - origin.y))
            case let .dragging(origin, center):
                moveBall(to: NSPoint(x: center.x + point.x - origin.x, y: center.y + point.y - origin.y))
            case .voice: break
            }
            return true
        case .leftMouseUp:
            guard let gesture else { return false }
            holdTask?.cancel()
            holdTask = nil
            self.gesture = nil
            switch gesture {
            case .pressed: store.toggleGrokBallStage(); synchronize()
            case .dragging: break
            case .voice: endVoice()
            }
            return true
        default: return false
        }
    }

    private func moveBall(to point: NSPoint) {
        guard let parent else { return }
        ballOffset = NSPoint(x: point.x - parent.frame.midX, y: point.y - parent.frame.midY)
        synchronize()
        if let actual = state.placement?.ballCenter {
            ballOffset = NSPoint(x: actual.x - parent.frame.midX, y: actual.y - parent.frame.midY)
        }
    }

    private func cancelGesture() {
        holdTask?.cancel()
        holdTask = nil
        if case .voice = gesture { SpeechInputController.shared.stop(andSubmit: false, store: store) }
        gesture = nil
    }

    private func updatePointer(at point: NSPoint) {
        guard state.isVisible, let parent else { return }
        if parent.frame.contains(point) || panelWindow.frame.contains(point) {
            let windowPoint = panelWindow.convertPoint(fromScreen: point)
            state.pointer.position = panelWindow.contentView?.convert(windowPoint, from: nil)
        } else { state.pointer.position = nil }
    }
}

private final class GrokBallSidecarPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct GrokBallSidecarView: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    let store: HomeStore
    let state: GrokBallSidecarState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let placement = state.placement {
                GrokBallControl(store: store, pointer: state.pointer, center: placement.localBallCenter, isVisible: state.isVisible)
                    .frame(width: 72, height: 72)
                    .position(placement.localBallCenter)
                if let suggestions = placement.suggestionsFrame {
                    GrokBallSuggestions(store: store, columnCount: placement.suggestionColumns)
                        .frame(width: suggestions.width, height: suggestions.height, alignment: .topLeading)
                        .position(x: placement.localSuggestionsOrigin.x + suggestions.width / 2,
                                  y: placement.localSuggestionsOrigin.y + suggestions.height / 2)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
        .accessibilityElement(children: .contain)
    }
}
