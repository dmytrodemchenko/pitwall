import SwiftUI

struct MascotStage: View {
    var state: MarkState
    var openedAt: Date?
    var reduceMotion: Bool
    @State private var changedAt = Date.distantPast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: openedAt == nil || reduceMotion)) { context in
            Canvas { ctx, size in draw(&ctx, size: size, now: context.date) }
        }
        .frame(height: 70)
        .onChange(of: state) { changedAt = Date() }
        .accessibilityElement()
        .accessibilityLabel(Mark.accessibilityText(state))
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let opened = openedAt ?? now
        let still = reduceMotion || openedAt == nil
        let sinceOpen = still ? 10 : now.timeIntervalSince(opened)
        let sinceChange = still ? 10 : now.timeIntervalSince(max(changedAt, opened))
        let clock = now.timeIntervalSinceReferenceDate
        let ground = size.height - 6
        let box: CGFloat = 48
        let feet = 10.1 * box / Mark.size.width
        let mascot = Color(.mascot), running = Color(.running), waiting = Color(.waiting)

        func walkX(_ t: TimeInterval) -> CGFloat {
            size.width / 2 + (state.mode == .running ? sin(t * 2 * .pi / 9) * (size.width / 2 - 44) : 0)
        }
        let x = walkX(clock)
        var y = ground - feet
        var pose = Mark.Pose()

        if sinceOpen < 1.8 {
            let drop = -80 * exp(-5 * sinceOpen) * cos(9 * sinceOpen)
            y += min(drop, 0)
            pose.squash = max(0, min(1, drop / 8))
            pose.wave = Mark.waveHello(sinceOpen - 0.6, until: 1.2)
        }
        if state.mode == .passed { y -= Mark.cheerHop(sinceChange) * 12 }

        var line = Path()
        line.move(to: CGPoint(x: 16, y: ground))
        line.addLine(to: CGPoint(x: size.width - 16, y: ground))
        ctx.stroke(line, with: .linearGradient(Gradient(colors: [.clear, .primary.opacity(0.15), .clear]),
                                               startPoint: CGPoint(x: 16, y: ground), endPoint: CGPoint(x: size.width - 16, y: ground)),
                   lineWidth: 1)
        let air = max(0, (ground - feet) - y)
        let shadowW = 30 * max(0.3, 1 - air / 60)
        ctx.fill(Path(ellipseIn: CGRect(x: x - shadowW / 2, y: ground - 2, width: shadowW, height: 4)),
                 with: .color(.black.opacity(0.2 * max(0.3, 1 - air / 60))))

        if state.mode == .idle {
            let h = CGPoint(x: x - 38, y: ground)
            var shell = Path()
            shell.move(to: CGPoint(x: h.x - 9, y: h.y))
            shell.addCurve(to: CGPoint(x: h.x + 9, y: h.y - 3),
                           control1: CGPoint(x: h.x - 10, y: h.y - 17), control2: CGPoint(x: h.x + 10, y: h.y - 15))
            shell.addLine(to: CGPoint(x: h.x + 9, y: h.y))
            shell.closeSubpath()
            ctx.fill(Path(ellipseIn: CGRect(x: h.x - 11, y: ground - 2, width: 22, height: 4)), with: .color(.black.opacity(0.15)))
            ctx.fill(shell, with: .color(Color(.gear)))
            var paint = ctx
            paint.clip(to: shell)
            var stripe = Path()
            stripe.move(to: CGPoint(x: h.x - 5, y: h.y))
            stripe.addQuadCurve(to: CGPoint(x: h.x + 3, y: h.y - 14), control: CGPoint(x: h.x - 5, y: h.y - 11))
            paint.stroke(stripe, with: .color(mascot), lineWidth: 3)
            paint.fill(Path(roundedRect: CGRect(x: h.x + 1, y: h.y - 9, width: 9, height: 4.5), cornerRadius: 2),
                       with: .color(.black.opacity(0.75)))
        }

        switch state.mode {
        case .running:
            for k in 0..<3 {
                let age = (clock + Double(k) * 0.3).truncatingRemainder(dividingBy: 0.9)
                let px = walkX(clock - age) + (k % 2 == 0 ? -7 : 7)
                let r = 2 + 5 * age / 0.9
                ctx.fill(Path(ellipseIn: CGRect(x: px - r, y: ground - r - 1, width: r * 2, height: r * 1.4)),
                         with: .color(.secondary.opacity(0.3 * (1 - age / 0.9))))
            }
        default: break
        }

        let t: TimeInterval = switch state.mode {
        case .running, .waiting: clock.truncatingRemainder(dividingBy: Mark.period(state)!)
        case .failed: min(sinceChange, Mark.failSettle)
        case .passed: min(sinceChange, Mark.sweepDuration)
        case .idle: clock.truncatingRemainder(dividingBy: Mark.breathPeriod)
        }
        let rect = CGRect(x: x - box / 2, y: y - box / 2, width: box, height: box)
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!
        ctx.withCGContext { cg in
            appearance.performAsCurrentDrawingAppearance {
                Mark.draw(cg, in: rect, state: state, t: t, template: false, pose: pose)
            }
        }

        let head = CGPoint(x: x, y: y - 14)
        switch state.mode {
        case .running:
            for k in 0..<4 {
                let life = 1.6, phase = clock + Double(k) * 0.4
                let age = phase.truncatingRemainder(dividingBy: life)
                let seed = floor(phase / life) * 4 + Double(k)
                let p = CGPoint(x: head.x + (Self.random(seed) - 0.5) * 44, y: head.y - 4 - age * 20)
                let fade = sin(age / life * .pi)
                let colors = [running, mascot, waiting]
                ctx.fill(Self.star(p, 2 + 2.5 * fade), with: .color(colors[k % 3].opacity(fade)))
            }
        case .waiting:
            let bob = -2 * sin(clock * 2 * .pi / 0.8)
            let c = CGPoint(x: x + 24, y: y - 24 + bob)
            ctx.fill(Path(roundedRect: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16), cornerRadius: 6), with: .color(waiting))
            var tail = Path()
            tail.move(to: CGPoint(x: c.x - 6, y: c.y + 4))
            tail.addLine(to: CGPoint(x: c.x - 10, y: c.y + 11))
            tail.addLine(to: CGPoint(x: c.x - 1, y: c.y + 7))
            ctx.fill(tail, with: .color(waiting))
            ctx.draw(Text("!").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundColor(.black.opacity(0.8)), at: c)
        case .failed:
            let cloud = CGPoint(x: x, y: y - 30)
            for (dx, dy, r) in [(-7.0, 2.0, 5.0), (0, -2, 7), (8, 2, 5)] {
                ctx.fill(Path(ellipseIn: CGRect(x: cloud.x + dx - r, y: cloud.y + dy - r, width: r * 2, height: r * 2)),
                         with: .color(.gray.opacity(0.85)))
            }
            for k in 0..<4 {
                let age = (clock + Double(k) * 0.17).truncatingRemainder(dividingBy: 0.6) / 0.6
                let dx = CGFloat(k) * 5 - 7.5
                var drop = Path()
                drop.move(to: CGPoint(x: cloud.x + dx, y: cloud.y + 7 + age * 12))
                drop.addLine(to: CGPoint(x: cloud.x + dx - 1, y: cloud.y + 10 + age * 12))
                ctx.stroke(drop, with: .color(.blue.opacity(0.7 * (1 - age))), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        case .passed:
            guard sinceChange < 2.8 else { break }
            let colors = [mascot, running, waiting, Color(.failure), .white]
            for i in 0..<30 {
                let r = Double(i)
                let vx = (Self.random(r) - 0.5) * 220, vy = -90 - Self.random(r + 50) * 110
                let tt = sinceChange
                let p = CGPoint(x: head.x + vx * tt, y: head.y + vy * tt + 0.5 * 300 * tt * tt)
                guard p.y < ground else { continue }
                var piece = ctx
                piece.translateBy(x: p.x, y: p.y)
                piece.rotate(by: .radians(tt * (4 + Self.random(r + 9) * 8)))
                piece.opacity = min(1, (2.8 - tt) / 0.6)
                piece.fill(Path(CGRect(x: -2.5, y: -1.5, width: 5, height: 3)), with: .color(colors[i % colors.count]))
            }
        case .idle:
            for k in 0..<3 {
                let life = 2.4
                let age = (clock + Double(k) * 0.8).truncatingRemainder(dividingBy: life)
                let p = CGPoint(x: x + 16 + age * 9, y: y - 12 - age * 12)
                ctx.draw(Text("z").font(.system(size: 8 + age * 3, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary.opacity(sin(age / life * .pi))), at: p)
            }
        }

        if sinceOpen > 0.3, sinceOpen < 0.95 {
            let k = (sinceOpen - 0.3) / 0.65
            for i in 0..<10 {
                let a = Double(i) / 10 * 2 * .pi
                let p = CGPoint(x: x + cos(a) * (14 + k * 34), y: ground - 12 + sin(a) * (8 + k * 18))
                ctx.fill(Self.star(p, 3 * (1 - k) + 1), with: .color((i % 2 == 0 ? mascot : waiting).opacity(1 - k)))
            }
        }
    }

    private static func random(_ n: Double) -> Double {
        let v = sin(n * 12.9898) * 43758.5453
        return v - floor(v)
    }

    private static func star(_ c: CGPoint, _ r: CGFloat) -> Path {
        var p = Path()
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4 - .pi / 2
            let rr = i % 2 == 0 ? r : r * 0.32
            let pt = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

#if DEBUG
#Preview("Stage") {
    VStack(spacing: 0) {
        ForEach([MarkState(mode: .running, gate: "developer"), MarkState(mode: .waiting, gate: "planner"), MarkState(mode: .failed, gate: "verifier"),
                 MarkState(mode: .passed), MarkState(mode: .idle)], id: \.mode) {
            MascotStage(state: $0, openedAt: Date(), reduceMotion: false)
        }
    }
    .frame(width: 360)
}
#endif
