import SwiftUI

/// Native projection and effects for the pinned GrokBall contours. Coordinates match upstream's
/// -15 -15 259 259 viewBox, including its silhouette sampling and cosine eye compression.
@MainActor
enum GrokBallRenderer {
    private static let center = 114.2705
    private static let headPath = polygon(GrokBallData.head)
    private static let silhouette: [(low: Double, high: Double)] = {
        let ring = GrokBallData.head
        return (0...115).map { row in
            let y = Double(row) * 2
            var low = Double.infinity
            var high = -Double.infinity
            for index in ring.indices {
                let a = ring[index]
                let b = ring[(index + 1) % ring.count]
                if (a.y <= y && b.y >= y) || (b.y <= y && a.y >= y) {
                    let fraction = a.y == b.y ? 0 : (y - a.y) / (b.y - a.y)
                    let x = a.x + (b.x - a.x) * fraction
                    low = min(low, x)
                    high = max(high, x)
                }
            }
            return low > high ? (center - 4, center + 4) : (low, high)
        }
    }()

    static func draw(_ animator: GrokBallAnimator, in context: inout GraphicsContext, size: CGSize) {
        let scale = min(size.width, size.height) / 259
        context.translateBy(x: (size.width - 259 * scale) / 2, y: (size.height - 259 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 15, y: 15)
        drawRibbons(animator, context: &context, front: false)

        let pose = animator.pose
        // Sleeping, idle and curious are the resolver's neutral moods, including hover and gaze.
        let isNeutral: Bool
        switch animator.emotion.id {
        case "00", "02", "03": isNeutral = true
        default: isNeutral = false
        }
        let bodyColor = isNeutral ? DesignTokens.GrokBall.neutralBody : pose.body.color
        let highlight = isNeutral ? DesignTokens.GrokBall.neutralHighlight : 0.22
        var body = context
        body.translateBy(x: center + pose.body.x, y: center + pose.body.y)
        body.rotate(by: .degrees(pose.body.rotate))
        body.scaleBy(x: pose.body.scaleX, y: pose.body.scaleX)
        body.translateBy(x: -center, y: -center)
        body.fill(headPath, with: .radialGradient(
            Gradient(stops: [
                .init(color: DesignTokens.GrokBall.color(bodyColor, shade: highlight), location: 0),
                .init(color: DesignTokens.GrokBall.color(bodyColor), location: 0.62),
                .init(color: DesignTokens.GrokBall.color(bodyColor, shade: -0.12), location: 1)
            ]),
            center: CGPoint(x: 228.54 * 0.38, y: 228.44 * 0.32), startRadius: 0, endRadius: 228.54 * 0.75
        ))
        drawEye(animator.leftEye, pose: pose.left, yaw: animator.yaw, isNeutral: isNeutral, context: &body)
        drawEye(animator.rightEye, pose: pose.right, yaw: animator.yaw, isNeutral: isNeutral, context: &body)
        drawRibbons(animator, context: &context, front: true)
        drawConfetti(animator, context: &context)
        drawSleepLetters(animator, context: &context)
    }

    private static func drawEye(_ geometry: GrokBallEyeGeometry, pose: GrokBallPart, yaw: Double, isNeutral: Bool,
                                context: inout GraphicsContext) {
        let centroid = geometry.centroid
        let open = min(2.4, max(0.02, pose.open))
        let scaleY = min(2.4, max(0.02, pose.scaleY * open))
        let halfHeight = 21 * scaleY + 2
        let eyeY = min(228.44 - halfHeight, max(halfHeight, centroid.y + pose.y + pose.lookY))
        let row = min(silhouette.count - 1, max(0, Int((eyeY / 2).rounded())))
        let bounds = silhouette[row]
        let localCenter = (bounds.low + bounds.high) / 2
        let halfWidth = max(12, (bounds.high - bounds.low) / 2)
        let offset = centroid.x - center + pose.x + pose.lookX
        let longitude = min(1.15, max(-1.15, offset / halfWidth)) + yaw
        let compression = cos(longitude)
        guard compression > 0.02 else { return }
        let eyeX = localCenter + halfWidth * sin(longitude) * 0.985
        let normalizedY = (eyeY - center) / 130
        let verticalFit = sqrt(1 - normalizedY * normalizedY * 0.22)
        var eye = context
        eye.translateBy(x: eyeX, y: eyeY)
        eye.rotate(by: .degrees(pose.rotate))
        eye.scaleBy(x: pose.scaleX * compression, y: scaleY * verticalFit)
        eye.translateBy(x: -centroid.x, y: -centroid.y)
        let color = isNeutral ? DesignTokens.GrokBall.neutralEye : pose.color
        eye.fill(geometry.path, with: .color(DesignTokens.GrokBall.color(color)))
    }

    private static func drawRibbons(_ animator: GrokBallAnimator, context: inout GraphicsContext, front: Bool) {
        let orbit = animator.pose.body.orbit > 0.01
        let age = animator.ribbonAge
        let spinning = !animator.isStatic && age < 2.8
        guard orbit || spinning else { return }
        let count = orbit ? 2 : 4
        for index in 0..<count {
            let isOrbit = orbit
            let life = animator.isStatic ? 1 : isOrbit ? animator.elapsed - Double(index) * 0.7 : age - Double(index) * 0.08
            guard life >= 0 else { continue }
            let retract = isOrbit ? 0 : min(1, max(0, (life - 1.8) / 0.5))
            let grow = min(1, life / 0.34)
            let fade = min(1, life / 0.26) * (1 - retract)
            let radius = isOrbit ? 124 + Double(index) * 16 : 116 + Double(index) * 12
            let tilt = isOrbit ? 0.16 : 0.32
            let roll = isOrbit ? -0.05 : 0.22
            let phase = animator.isStatic ? Double(index) * .pi :
                isOrbit ? life * (index == 0 ? 2.0 : -1.8) + Double(index) * .pi : animator.yaw * 0.84 + life
            let span = 2.8 * (1 - retract * retract * (3 - 2 * retract)) * grow
            let width = (isOrbit ? 6.3 : 7.5) * 1.7 * grow * (1 - 0.72 * retract * retract)
            guard width > 0.5, fade > 0 else { continue }
            var ribbon = Path()
            let steps = 48
            for step in 0..<steps {
                let fraction0 = Double(step) / Double(steps)
                let fraction1 = Double(step + 1) / Double(steps)
                let angle0 = phase - span + span * fraction0
                let angle1 = phase - span + span * fraction1
                let a = orbitPoint(angle: angle0, radius: radius, tilt: tilt, roll: roll)
                let b = orbitPoint(angle: angle1, radius: radius, tilt: tilt, roll: roll)
                guard (cos((angle0 + angle1) / 2) >= 0) == front else { continue }
                let delta = b - a
                let length = max(0.001, hypot(delta.x, delta.y))
                let normal = SIMD2(-delta.y, delta.x) / length
                let half0 = width * (0.5 + fraction0 * 0.5) / 2
                let half1 = width * (0.5 + fraction1 * 0.5) / 2
                ribbon.move(to: point(a + normal * half0))
                ribbon.addLine(to: point(b + normal * half1))
                ribbon.addLine(to: point(b - normal * half1))
                ribbon.addLine(to: point(a - normal * half0))
                ribbon.closeSubpath()
                if step == steps - 1 {
                    ribbon.addEllipse(in: CGRect(x: b.x - half1, y: b.y - half1, width: half1 * 2, height: half1 * 2))
                }
            }
            let tail = orbitPoint(angle: phase - span, radius: radius, tilt: tilt, roll: roll)
            let head = orbitPoint(angle: phase, radius: radius, tilt: tilt, roll: roll)
            var layer = context
            layer.opacity = fade
            layer.fill(ribbon, with: .linearGradient(DesignTokens.GrokBall.ribbonGradient,
                startPoint: point(tail), endPoint: point(head)))
        }
    }

    private static func orbitPoint(angle: Double, radius: Double, tilt: Double, roll: Double) -> SIMD2<Double> {
        let x = radius * sin(angle)
        let y = -radius * cos(angle) * sin(tilt)
        return SIMD2(center + x * cos(roll) - y * sin(roll), center + x * sin(roll) + y * cos(roll))
    }

    private static func drawConfetti(_ animator: GrokBallAnimator, context: inout GraphicsContext) {
        let age = animator.confettiAge
        guard !animator.isStatic, age >= 0, age < 0.85 else { return }
        let drag = -log(0.94) * 60
        let travel = (1 - exp(-drag * age)) / drag
        for index in 0..<20 {
            let variation = Double((index * 37 + 17) % 101) / 101
            let lifetime = 0.45 + variation * 0.4
            guard age < lifetime else { continue }
            let angle = Double(index) / 20 * .pi * 2 + (variation - 0.5) * 0.7
            let speed = 170 + variation * 190
            let radius = 96 + variation * 20
            let x = center + cos(angle) * (radius + speed * travel)
            let initialY = sin(angle) * speed - 20 - variation * 55
            let y = center + sin(angle) * radius + initialY * travel + 40 / drag * (age - travel)
            let progress = age / lifetime
            let opacity = progress < 0.1 ? progress / 0.1 : pow(1 - (progress - 0.1) / 0.9, 1.7)
            let size = max(0.5, (3.5 + variation * 4.5) * (1 - 0.4 * progress))
            var piece = context
            piece.opacity = opacity
            piece.translateBy(x: x, y: y)
            piece.rotate(by: .degrees(variation * 360 + (variation - 0.5) * 520 * age))
            piece.scaleBy(x: size, y: size)
            if index % 6 == 0 {
                piece.fill(starPath, with: .color(DesignTokens.GrokBall.star))
            } else if index % 3 == 0 {
                piece.fill(confettiCircle,
                    with: .color(DesignTokens.GrokBall.confetti[index % DesignTokens.GrokBall.confetti.count]))
            } else {
                piece.fill(confettiRectangle,
                    with: .color(DesignTokens.GrokBall.confetti[index % DesignTokens.GrokBall.confetti.count]))
            }
        }
    }

    private static func drawSleepLetters(_ animator: GrokBallAnimator, context: inout GraphicsContext) {
        let intensity = animator.pose.body.zzz
        guard intensity > 0.01 else { return }
        for index in 0..<3 {
            let fraction = animator.isStatic ? Double(index + 1) / 4 :
                (animator.elapsed * 0.33 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let opacity = (fraction < 0.18 ? fraction / 0.18 : 1 - (fraction - 0.18) / 0.82) * 0.8 * intensity
            var letter = context
            letter.opacity = opacity
            letter.translateBy(x: 180 + fraction * 34 + 4 * sin(fraction * 9), y: 48 - fraction * 42)
            letter.rotate(by: .degrees(-10 + fraction * 14))
            let scale = (12 + fraction * 11) / DesignTokens.TypeSize.title
            letter.scaleBy(x: scale, y: scale)
            letter.draw(Text("z").font(.system(size: DesignTokens.TypeSize.title, weight: .bold)).italic()
                .foregroundColor(DesignTokens.GrokBall.sleepLetter), at: .zero)
        }
    }

    private static let confettiCircle = Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2))
    private static let confettiRectangle = Path(roundedRect: CGRect(x: -0.5, y: -0.95, width: 1, height: 1.9), cornerRadius: 0.24)

    private static let starPath: Path = {
        var path = Path()
        for index in 0..<10 {
            let angle = -.pi / 2 + Double(index) * .pi / 5
            let radius = index.isMultiple(of: 2) ? 1.0 : 0.42
            let point = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }()

    private static func polygon(_ ring: [SIMD2<Double>]) -> Path {
        var path = Path()
        for (index, position) in ring.enumerated() {
            if index == 0 { path.move(to: point(position)) } else { path.addLine(to: point(position)) }
        }
        path.closeSubpath()
        return path
    }

    private static func point(_ position: SIMD2<Double>) -> CGPoint {
        CGPoint(x: position.x, y: position.y)
    }
}
