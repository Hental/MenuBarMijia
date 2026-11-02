import SwiftUI
import MijiaCore


struct GrokBallRGB: Sendable {
    var r: Double
    var g: Double
    var b: Double

    func mixed(with other: Self, amount: Double) -> Self {
        Self(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
    }
}

struct GrokBallPart: Sendable {
    var x: Double
    var y: Double
    var scaleX: Double
    var scaleY: Double
    var rotate: Double
    var open: Double
    var lookX: Double
    var lookY: Double
    var color: GrokBallRGB
    var breathe: Double
    var ribbons: Double
    var confetti: Double
    var zzz: Double
    var orbit: Double

    func mixed(with other: Self, amount: Double) -> Self {
        var result = self
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * amount }
        result.x = mix(x, other.x)
        result.y = mix(y, other.y)
        result.scaleX = mix(scaleX, other.scaleX)
        result.scaleY = mix(scaleY, other.scaleY)
        result.rotate = mix(rotate, other.rotate)
        result.open = mix(open, other.open)
        result.lookX = mix(lookX, other.lookX)
        result.lookY = mix(lookY, other.lookY)
        result.color = color.mixed(with: other.color, amount: amount)
        result.breathe = mix(breathe, other.breathe)
        result.zzz = mix(zzz, other.zzz)
        result.orbit = mix(orbit, other.orbit)
        return result
    }

    mutating func add(_ value: Double, property: String) {
        switch property {
        case "x": x += value
        case "y": y += value
        case "scale": scaleX += value; scaleY += value
        case "scaleX": scaleX += value
        case "scaleY": scaleY += value
        case "rotate": rotate += value
        case "open": open += value
        case "lookX": lookX += value
        case "lookY": lookY += value
        default: break
        }
    }
}

struct GrokBallPose: Sendable {
    var body: GrokBallPart
    var left: GrokBallPart
    var right: GrokBallPart

    func mixed(with other: Self, amount: Double) -> Self {
        Self(body: body.mixed(with: other.body, amount: amount),
             left: left.mixed(with: other.left, amount: amount),
             right: right.mixed(with: other.right, amount: amount))
    }
}

struct GrokBallEmotion: Sendable {
    struct Animation: Sendable {
        let target: String
        let prop: String
        let type: String
        let amp: Double?
        let period: Double?
        let phase: Double?
        let speed: Double?
        let decay: Double?
        let phaseMs: Double?
        let interval: Double?
        let dur: Double?
        let depth: Double?

        func value(at time: Double, seed: Double) -> Double {
            let amplitude = amp ?? 0
            let angle = .pi * 2 * time / (period ?? 2000) + (phase ?? 0)
            switch type {
            case "sine": return amplitude * sin(angle)
            case "pulse": return amplitude * 0.5 * (1 - cos(angle))
            case "jitter":
                let s = time / 1000 * (speed ?? 8)
                let noise = (sin(s * 3.1 + seed) + sin(s * 5.7 + seed * 2.3) + sin(s * 9.3 + seed * 4.1)) / 3
                return noise * amplitude * (decay.map { max(0, 1 - time / $0) } ?? 1)
            case "scan":
                let p = (time + (phaseMs ?? 0)).truncatingRemainder(dividingBy: period ?? 800) / (period ?? 800)
                return amplitude * (p < 0.5 ? p * 4 - 1 : 3 - p * 4)
            case "glance":
                let p = (time + (phaseMs ?? 0)).truncatingRemainder(dividingBy: period ?? 3600) / (period ?? 3600)
                return amplitude * tanh(2.8 * sin(.pi * 2 * p + (phase ?? 0)))
            case "blink":
                let p = (time + (phaseMs ?? 0) + seed * 97).truncatingRemainder(dividingBy: interval ?? 3800)
                return p < (dur ?? 200) ? -(depth ?? 1) * sin(.pi * p / (dur ?? 200)) : 0
            default: return 0
            }
        }
    }

    struct Frame: Sendable {
        let at: Double
        let pose: GrokBallPose
    }

    let id: String
    let name: String
    let englishName: String
    let transition: Double
    let gaze: Bool
    let pool: [Int]
    let poolMs: [Double]
    let poolSpeed: Double
    let blinkMs: [Double]?
    let openness: Double
    let antics: Bool
    let base: GrokBallPose
    let animations: [Animation]
    let frames: [Frame]
    let settle: String
    let next: String?
}

private struct GrokBallSpring {
    var value: Double
    var velocity = 0.0
    var target: Double

    mutating func step(frequency: Double, dt: Double) {
        velocity += (-2 * frequency * velocity - frequency * frequency * (value - target)) * dt
        value += velocity * dt
    }
}

struct GrokBallEyeGeometry {
    let centroid: SIMD2<Double>
    let path: Path

    init(_ ring: [SIMD2<Double>]) {
        var sum = SIMD2<Double>.zero
        var path = Path()
        for (index, point) in ring.enumerated() {
            sum += point
            let position = CGPoint(x: point.x, y: point.y)
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        path.closeSubpath()
        self.centroid = sum / Double(ring.count)
        self.path = path
    }
}

/// The TimelineView owns the clock. Ring buffers retain their capacity across every frame;
/// only changing the destination expression copies the current contour into the source buffer.
@MainActor
final class GrokBallAnimator {
    private(set) var emotion = GrokBallData.emotions["02"]!
    private(set) var pose = GrokBallData.emotions["02"]!.base
    private(set) var yaw = 0.0
    private(set) var elapsed = 0.0
    private(set) var ribbonAge = Double.infinity
    private(set) var confettiAge = Double.infinity
    private var externalId: String?
    private var emotionStarted = 0.0
    private var previousTick = 0.0
    private var transitionPose: GrokBallPose?
    private var sourceLeft = GrokBallData.expressions[0][0]
    private var sourceRight = GrokBallData.expressions[0][1]
    private var leftRing = GrokBallData.expressions[0][0]
    private var rightRing = GrokBallData.expressions[0][1]
    private(set) var leftEye = GrokBallEyeGeometry(GrokBallData.expressions[0][0])
    private(set) var rightEye = GrokBallEyeGeometry(GrokBallData.expressions[0][1])
    private var ringsSettled = true
    private var renderedRingProgress = 1.0
    private var expression = 0
    private var poolPosition = 0
    private var poolNext = 0.0
    private var ringSpring = GrokBallSpring(value: 1, target: 1)
    private var ringSpeed = 8.0
    private var openSpring = GrokBallSpring(value: 1, target: 1)
    private var blinkStarted = -Double.infinity
    private var blinkNext = Double.infinity
    private var anticNext = Double.infinity
    private var bounceStarted = -Double.infinity
    private var spin: GrokBallSpring?
    private var ribbonStarted = -Double.infinity
    private var confettiStarted = -Double.infinity
    private var gaze = SIMD2<Double>.zero
    private let seed = Double.random(in: 0..<100)
    private(set) var isStatic = false

    func sample(at date: Date, emotionId: String, pointer: SIMD2<Double>, reduceMotion: Bool) {
        let now = date.timeIntervalSinceReferenceDate
        let dt = previousTick == 0 ? 1 / 60 : min(0.05, max(0, now - previousTick))
        previousTick = now
        isStatic = reduceMotion
        if externalId != emotionId {
            externalId = emotionId
            enter(GrokBallData.emotions[emotionId] ?? GrokBallData.emotions["02"]!, at: now)
        }
        elapsed = max(0, now - emotionStarted)
        if reduceMotion {
            pose = emotion.base
            pose.left.open *= emotion.openness
            pose.right.open *= emotion.openness
            setStaticRings()
            yaw = 0
            spin = nil
            gaze = .zero
            ribbonStarted = -.infinity
            confettiStarted = -.infinity
            openSpring = GrokBallSpring(value: emotion.openness, target: emotion.openness)
            return
        }
        if let last = emotion.frames.last, elapsed * 1000 > last.at,
           let next = emotion.next, let definition = GrokBallData.emotions[next] {
            enter(definition, at: now)
            elapsed = 0
        }
        var target = sequencePose(at: elapsed * 1000)
        let phase = .pi * 2 * now / 3.6
        target.body.scaleX += target.body.breathe * sin(phase)
        target.body.y += target.body.breathe * 55 * sin(phase + 0.6)
        for animation in emotion.animations {
            let value = animation.value(at: elapsed * 1000, seed: seed)
            switch animation.target {
            case "body": target.body.add(value, property: animation.prop)
            case "left": target.left.add(value, property: animation.prop)
            case "right": target.right.add(value, property: animation.prop)
            case "eyes":
                target.left.add(value, property: animation.prop)
                target.right.add(value, property: animation.prop)
            default: break
            }
        }
        if now >= poolNext {
            if emotion.pool.count > 1 {
                poolPosition = (poolPosition + Int.random(in: 1..<emotion.pool.count)) % emotion.pool.count
                setExpression(emotion.pool[poolPosition], speed: emotion.poolSpeed)
            }
            poolNext = now + randomSeconds(emotion.poolMs)
        }
        if now >= blinkNext {
            blinkStarted = now
            blinkNext = emotion.blinkMs.map { now + randomSeconds($0) } ?? .infinity
        }
        if now >= anticNext, emotion.antics {
            switch Int.random(in: 0..<3) {
            case 0: beginSpin(turns: 1, at: now)
            case 1: bounceStarted = now
            default: blinkStarted = now
            }
            anticNext = now + Double.random(in: 9...18)
        }
        let blinkAge = now - blinkStarted
        openSpring.target = blinkAge < 0.07 ? 0.05 : blinkAge < 0.15 ? 1.08 : emotion.openness
        let steps = max(1, Int(ceil(dt * 120)))
        for _ in 0..<steps {
            let step = dt / Double(steps)
            if !ringsSettled { ringSpring.step(frequency: ringSpeed, dt: step) }
            openSpring.step(frequency: 26, dt: step)
            spin?.step(frequency: 6.2, dt: step)
        }
        if let current = spin, abs(current.target - current.value) < 0.01, abs(current.velocity) < 0.05 {
            spin = nil
        }
        yaw = spin?.value ?? 0
        ribbonAge = now - ribbonStarted
        confettiAge = now - confettiStarted
        target.body.y += bounceOffset(age: now - bounceStarted)
        interpolateRings()
        let gazeTarget = emotion.gaze ? pointer * SIMD2(24, 15) : .zero
        gaze += (gazeTarget - gaze) * (1 - exp(-5.66 * dt))
        target.left.lookX += gaze.x
        target.right.lookX += gaze.x
        target.left.lookY += gaze.y
        target.right.lookY += gaze.y
        if emotion.gaze {
            target.left.lookX += 1.4 * sin(0.42 * now) + 0.5 * sin(now)
            target.right.lookX += 1.4 * sin(0.42 * now + 1) + 0.5 * sin(now + 2)
            target.left.lookY += 0.9 * sin(0.58 * now)
            target.right.lookY += 0.9 * sin(0.58 * now + 1)
        }
        let openness = min(1.5, max(0.02, openSpring.value))
        target.left.open = min(1.3, max(0, target.left.open)) * openness
        target.right.open = min(1.3, max(0, target.right.open)) * openness
        target.left.scaleX = max(0.05, target.left.scaleX)
        target.left.scaleY = max(0.05, target.left.scaleY)
        target.right.scaleX = max(0.05, target.right.scaleX)
        target.right.scaleY = max(0.05, target.right.scaleY)
        if let previous = transitionPose, elapsed < emotion.transition {
            let fraction = elapsed / emotion.transition
            let eased = Self.ease(fraction)
            target = previous.mixed(with: target, amount: eased)
        } else {
            transitionPose = nil
        }
        pose = target
    }

    private func enter(_ definition: GrokBallEmotion, at now: Double) {
        transitionPose = externalId == nil ? nil : pose
        emotion = definition
        emotionStarted = now
        poolPosition = 0
        setExpression(definition.pool[0], speed: definition.poolSpeed >= 10 ? 10 : 8)
        poolNext = now + randomSeconds(definition.poolMs)
        blinkNext = definition.blinkMs.map { now + randomSeconds($0) } ?? .infinity
        anticNext = now + Double.random(in: 2.5...5)
        if definition.blinkMs != nil { blinkStarted = now }
        if definition.base.body.ribbons > 0 { beginSpin(turns: 2, at: now) }
        if definition.base.body.confetti > 0 { confettiStarted = now }
    }

    private func beginSpin(turns: Double, at now: Double) {
        guard spin == nil else { return }
        spin = GrokBallSpring(value: 0, target: turns * .pi * 2)
        ribbonStarted = now
    }

    private func sequencePose(at milliseconds: Double) -> GrokBallPose {
        guard let first = emotion.frames.first, let last = emotion.frames.last else { return emotion.base }
        if milliseconds <= first.at { return first.pose }
        for index in 1..<emotion.frames.count {
            let next = emotion.frames[index]
            if milliseconds <= next.at {
                let previous = emotion.frames[index - 1]
                let fraction = (milliseconds - previous.at) / max(1, next.at - previous.at)
                return previous.pose.mixed(with: next.pose, amount: Self.ease(fraction))
            }
        }
        if emotion.settle == "hold" { return last.pose }
        let fraction = min(1, (milliseconds - last.at) / (emotion.transition * 1000))
        return last.pose.mixed(with: emotion.base, amount: Self.ease(fraction))
    }

    private func setExpression(_ index: Int, speed: Double) {
        guard index != expression || !ringsSettled else { return }
        for i in leftRing.indices {
            sourceLeft[i] = leftRing[i]
            sourceRight[i] = rightRing[i]
        }
        expression = index
        ringSpring = GrokBallSpring(value: 0, target: 1)
        ringsSettled = false
        renderedRingProgress = -1
        ringSpeed = speed
    }

    private func interpolateRings() {
        guard !ringsSettled else { return }
        let settled = abs(ringSpring.target - ringSpring.value) < 0.001 && abs(ringSpring.velocity) < 0.001
        if settled {
            ringSpring = GrokBallSpring(value: 1, target: 1)
        }
        let amount = min(1.35, max(0, ringSpring.value))
        guard amount != renderedRingProgress || settled else { return }
        for i in leftRing.indices {
            let left = GrokBallData.expressions[expression][0][i]
            let right = GrokBallData.expressions[expression][1][i]
            leftRing[i] = settled ? left : sourceLeft[i] + (left - sourceLeft[i]) * amount
            rightRing[i] = settled ? right : sourceRight[i] + (right - sourceRight[i]) * amount
        }
        renderedRingProgress = amount
        ringsSettled = settled
        refreshEyeGeometry()
    }

    private func setStaticRings() {
        guard expression != emotion.pool[0] || !ringsSettled else { return }
        expression = emotion.pool[0]
        for i in leftRing.indices {
            leftRing[i] = GrokBallData.expressions[emotion.pool[0]][0][i]
            rightRing[i] = GrokBallData.expressions[emotion.pool[0]][1][i]
        }
        ringSpring = GrokBallSpring(value: 1, target: 1)
        ringsSettled = true
        renderedRingProgress = 1
        refreshEyeGeometry()
    }

    private func refreshEyeGeometry() {
        leftEye = GrokBallEyeGeometry(leftRing)
        rightEye = GrokBallEyeGeometry(rightRing)
    }

    private func randomSeconds(_ bounds: [Double]) -> Double {
        Double.random(in: bounds[0]...bounds[1]) / 1000
    }

    private static let bounceSegments = [(48.0, 0.5), (28.0, 0.382), (14.0, 0.27), (6.0, 0.177)]

    private func bounceOffset(age: Double) -> Double {
        var time = age
        for (height, duration) in Self.bounceSegments {
            if time >= 0, time < duration {
                let fraction = time / duration
                return -4 * height * fraction * (1 - fraction)
            }
            time -= duration
        }
        return 0
    }

    private static func ease(_ value: Double) -> Double {
        value < 0.5 ? 4 * value * value * value : 1 - pow(-2 * value + 2, 3) / 2
    }
}

@Observable
@MainActor
final class GrokBallPointerState {
    var position: CGPoint?
}

struct GrokBallControl: View {
    @Environment(\.effectiveReduceMotion) private var reduceMotion
    let store: HomeStore
    let pointer: GrokBallPointerState
    let center: CGPoint
    let isVisible: Bool
    @State private var animator = GrokBallAnimator()

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !isVisible)) { clock in
            let emotionId = store.grokBallEmotionId(
                speechListening: SpeechInputController.shared.isListening,
                isPointerTracking: pointer.position != nil,
                now: clock.date
            )
            Button {
                withAnimation(reduceMotion ? nil : AppleMotion.snappySpring) { store.toggleGrokBallStage() }
            } label: {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isVisible)) { timeline in
                    Canvas { context, size in
                        let gaze = normalizedPointer
                        animator.sample(at: timeline.date, emotionId: emotionId, pointer: gaze, reduceMotion: reduceMotion)
                        GrokBallRenderer.draw(animator, in: &context, size: size)
                    }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.tr("GrokBall 家居助手", "GrokBall home assistant")))
            .accessibilityValue(Text(localizedEmotion(emotionId)))
            .accessibilityHint(Text(L10n.tr("轻点展开或收起建议，拖动调整位置，长按开始语音输入", "Click to toggle suggestions, drag to reposition, or hold to start voice input")))
            .help(L10n.tr("轻点推荐 · 拖动移位 · 长按说话", "Click for suggestions · Drag to move · Hold to speak"))
        }
    }

    private var normalizedPointer: SIMD2<Double> {
        guard let point = pointer.position else { return .zero }
        return SIMD2(max(-1, min(1, Double(point.x - center.x) / 150)),
                     max(-1, min(1, Double(point.y - center.y) / 150)))
    }

    private func localizedEmotion(_ id: String) -> String {
        guard let emotion = GrokBallData.emotions[id] else { return "" }
        return L10n.tr(emotion.name, emotion.englishName)
    }
}

/// Single owner for the sizes the placement math reserves and the pills actually draw.
/// Both sides read these, so a wider pill can never silently clip inside a narrower footprint (#123).
enum GrokBallSuggestionMetrics {
    static let pillWidth: CGFloat = 132
    static let pillHeight: CGFloat = 44
    static let spacing: CGFloat = 10
    static let gapToBall: CGFloat = 16

    static let columnWidth = pillWidth
    static let columnHeight = 4 * pillHeight + 3 * spacing
    static let rowWidth = 2 * pillWidth + spacing
    static let rowHeight = 2 * pillHeight + spacing
    static let singleRowWidth = 4 * pillWidth + 3 * spacing
}

/// Suggestions use a column beside the ball and adapt to one or two rows above/below it.
struct GrokBallSuggestions: View {
    let store: HomeStore
    var columnCount = 1

    var body: some View {
        let items = store.grokBallRadialSuggestions
        Grid(horizontalSpacing: GrokBallSuggestionMetrics.spacing,
             verticalSpacing: GrokBallSuggestionMetrics.spacing) {
            if columnCount == 4 {
                GridRow { ForEach(items) { suggestionPill($0.suggestion) } }
            } else if columnCount == 2 {
                GridRow { ForEach(items.prefix(2)) { suggestionPill($0.suggestion) } }
                GridRow { ForEach(items.dropFirst(2)) { suggestionPill($0.suggestion) } }
            } else {
                ForEach(items) { item in GridRow { suggestionPill(item.suggestion) } }
            }

            if items.isEmpty {
                Text(L10n.tr("暂无可用建议，先试着控制设备", "No suggestions yet. Try controlling a device first."))
                    .font(.system(size: DesignTokens.TypeSize.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .adaptiveGlass(in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
                    .gridCellColumns(columnCount)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("猜你想控", "Suggested controls")))
    }

    private func suggestionPill(_ suggestion: AssistantSuggestion) -> some View {
        Button {
            store.dismissGrokBallStage()
            Task { await store.applyGrokBallSuggestion(suggestion) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: suggestion.confidencePercent == nil ? "clock.arrow.circlepath" : "sparkles")
                    .foregroundStyle(Color.accentColor)
                Text(suggestion.title)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let percent = suggestion.confidencePercent {
                    Text("\(percent)%")
                        .font(.system(size: DesignTokens.TypeSize.micro, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: DesignTokens.TypeSize.control, weight: .medium))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: GrokBallSuggestionMetrics.pillHeight)
            .adaptiveGlass(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(L10n.tr("立即执行，可撤销", "Run now; undo is available")))
        .help(L10n.tr("点击立即执行，可撤销", "Click to execute with undo"))
        .frame(width: GrokBallSuggestionMetrics.pillWidth, height: GrokBallSuggestionMetrics.pillHeight)
    }
}
