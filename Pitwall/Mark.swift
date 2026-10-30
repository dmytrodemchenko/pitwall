import AppKit
import SwiftUI

struct MarkState: Equatable {
    enum Mode { case idle, running, waiting, failed, passed }
    var mode: Mode
    var gate: String?

    init(mode: Mode, gate: String? = nil) {
        self.mode = mode
        self.gate = gate
    }

    init(session: Session?) {
        let mode: Mode = switch session?.status {
        case .failed: .failed
        case .waiting: .waiting
        case _ where session?.verifierPassed == true: .passed
        case .running: .running
        case .idle, nil: .idle
        }
        self.init(mode: mode, gate: session?.gate)
    }
}

enum Mark {
    static let size = CGSize(width: 22, height: 22)
    static let sweepDuration: TimeInterval = 1.6
    static let failSettle: TimeInterval = 2
    static let breathPeriod: TimeInterval = 3.6

    static func period(_ state: MarkState) -> TimeInterval? {
        switch state.mode {
        case .running: 4.8
        case .waiting: 3.2
        default: nil
        }
    }

    struct Pose {
        var hop: CGFloat = 0, squash: CGFloat = 0, wave: CGFloat = 0
    }

    static let introDuration: TimeInterval = 1.4

    static func intro(_ t: TimeInterval) -> Pose? {
        guard t < introDuration else { return nil }
        return Pose(hop: t < 0.45 ? sin(t / 0.45 * .pi) * 3 : 0,
                    squash: t >= 0.45 && t < 0.7 ? sin((t - 0.45) / 0.25 * .pi) : 0,
                    wave: waveHello(t - 0.5, until: introDuration - 0.5))
    }

    static func waveHello(_ t: TimeInterval, until length: TimeInterval) -> CGFloat {
        guard t > 0, t < length else { return 0 }
        return (0.75 + 0.25 * sin(t * 2 * .pi * 2.5)) * min(1, t / 0.15) * min(1, (length - t) / 0.2)
    }

    static func cheerHop(_ t: TimeInterval) -> CGFloat {
        t > 0.15 && t < 0.75 ? sin((t - 0.15) / 0.6 * .pi) : 0
    }

    private static func bump(_ t: TimeInterval, _ a: TimeInterval, _ b: TimeInterval, edge: TimeInterval = 0.12) -> CGFloat {
        guard t > a, t < b else { return 0 }
        let x = min(1, (t - a) / edge, (b - t) / edge)
        return x * x * (3 - 2 * x)
    }

    static func draw(_ cg: CGContext, in rect: CGRect, state: MarkState, t: TimeInterval, template: Bool,
                     pose: Pose = Pose()) {
        let ink = (template ? NSColor.black : NSColor.secondaryLabelColor).cgColor
        func color(_ resource: ColorResource) -> CGColor { template ? ink : NSColor(resource: resource).cgColor }
        let skin: CGColor = switch state.mode {
        case .idle: template ? ink : color(.mascot)
        case .failed: color(.failure)
        default: color(.mascot)
        }
        let face = NSColor(white: 0.08, alpha: 1).cgColor

        cg.saveGState()
        defer { cg.restoreGState() }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let detail = !template && scale >= 1.5
        cg.translateBy(x: rect.midX, y: rect.midY)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: 1.8)

        let step = t * 2 * .pi / 0.6
        var bob: CGFloat = 0, squash = pose.squash, hop = pose.hop
        var wave = pose.wave, cheer: CGFloat = 0, armDrop: CGFloat = 0, armSwing: CGFloat = 0
        var look = CGPoint.zero, blink = false
        switch state.mode {
        case .running:
            bob = -abs(sin(t * .pi / 0.3)) * 0.8
            armSwing = sin(step) * 0.6
            look.x = 0.6 * bump(t, 1.2, 1.8) - 0.6 * bump(t, 3.6, 4.2)
            blink = t.truncatingRemainder(dividingBy: 2.4) > 2.25
        case .waiting:
            wave = 0.7 + 0.3 * sin(t * 2 * .pi / 0.8)
            bob = -0.3 * (0.5 + 0.5 * sin(t * 2 * .pi / 0.8))
            look = CGPoint(x: 0.3, y: -0.7)
            blink = t > 3.05
        case .failed:
            cg.translateBy(x: sin(t * 40) * 1.3 * max(0, 1 - t / 0.6), y: 0)
            let droop = bump(t, 0.6, .infinity, edge: 0.6)
            bob = 0.5 * droop
            armDrop = 0.7 * droop
        case .passed:
            hop += cheerHop(t) * 1.4
            squash += 0.6 * bump(t, 0, 0.15, edge: 0.07)
                - 0.5 * cheerHop(t)
                + 0.8 * bump(t, 0.75, 0.95, edge: 0.1)
            cheer = bump(t, 0.1, 1.3, edge: 0.15) * (0.85 + 0.15 * sin(t * 2 * .pi * 3))
        case .idle:
            squash -= 0.2 * (0.5 - 0.5 * cos(t * 2 * .pi / breathPeriod))
        }

        cg.translateBy(x: 0, y: -hop)
        if squash != 0 {
            cg.translateBy(x: 0, y: 8.3)
            cg.scaleBy(x: 1 + 0.18 * squash, y: 1 - 0.18 * squash)
            cg.translateBy(x: 0, y: -8.3)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }
        func shade(_ c: CGColor, _ amount: CGFloat) -> CGColor {
            NSColor(cgColor: c)?.blended(withFraction: amount, of: .black)?.cgColor ?? c
        }

        cg.setFillColor(detail ? shade(skin, 0.18) : skin)
        for (i, x) in [CGFloat(-2.6), 2.6].enumerated() {
            let lift = state.mode == .running ? max(0, sin(step + Double(i) * .pi)) * 1.2 : 0
            cg.addPath(box(x, 7 - lift, 2.6, 2.6, 1.2))
        }
        cg.fillPath()

        cg.setFillColor(skin)
        for side in [CGFloat(-1), 1] {
            cg.saveGState()
            cg.translateBy(x: (5.6 + 0.5 * cheer) * side, y: 0.8 + bob + armDrop - armSwing * side - 4.6 * cheer)
            cg.rotate(by: (side > 0 ? -wave * 2.2 : 0) + 0.4 * cheer * side)
            cg.addEllipse(in: CGRect(x: 1.2 * side - 1.2, y: -0.4, width: 2.4, height: 2.8))
            cg.fillPath()
            if side > 0, detail, cheer > 0.05 {
                cg.setFillColor(color(.gear))
                cg.fill(CGRect(x: 1.3, y: -8.5, width: 0.6, height: 10))
                for row in 0..<3 {
                    for col in 0..<4 {
                        let flutter = sin(t * 14 - Double(col)) * 0.12 * Double(col)
                        cg.setFillColor((row + col) % 2 == 0 ? face : NSColor.white.cgColor)
                        cg.fill(CGRect(x: 1.9 + CGFloat(col) * 1.5, y: -8.5 + CGFloat(row) * 1.3 + flutter, width: 1.5, height: 1.3))
                    }
                }
                cg.setFillColor(skin)
            }
            cg.restoreGState()
        }

        let body = CGPath(ellipseIn: CGRect(x: -6, y: bob - 6.3, width: 12, height: 12.4), transform: nil)
        cg.addPath(body)
        cg.fillPath()
        if detail {
            cg.saveGState()
            cg.addPath(body)
            cg.clip()
            let light = [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
                         NSColor.black.withAlphaComponent(0.16).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: nil, colors: light, locations: [0, 0.4, 1]) {
                cg.drawLinearGradient(g, start: CGPoint(x: 0, y: bob - 6.3), end: CGPoint(x: 0, y: bob + 6.1), options: [])
            }
            cg.restoreGState()
        }

        cg.setStrokeColor(skin)
        cg.setLineWidth(1.1)
        cg.setLineCap(.round)
        cg.move(to: CGPoint(x: -0.4, y: bob - 6))
        cg.addQuadCurve(to: CGPoint(x: 1.6, y: bob - 9.4), control: CGPoint(x: -1.4, y: bob - 8.8))
        cg.strokePath()

        let gear = color(.gear)
        cg.setStrokeColor(gear)
        cg.setLineWidth(1)
        cg.move(to: CGPoint(x: -6.1, y: bob - 1.8))
        cg.addCurve(to: CGPoint(x: 6.1, y: bob - 1.8), control1: CGPoint(x: -6.4, y: bob - 9.6), control2: CGPoint(x: 6.4, y: bob - 9.6))
        cg.strokePath()
        cg.setFillColor(gear)
        for x in [CGFloat(-6.3), 6.3] { cg.addPath(box(x, bob - 0.9, 2, 3.2, 1)) }
        cg.fillPath()

        if state.mode == .running, detail {
            let c = CGPoint(x: 10.6, y: bob + 0.2 - armSwing)
            cg.setFillColor(gear)
            cg.addPath(box(c.x, c.y, 5.4, 7, 0.9))
            cg.fillPath()
            cg.setFillColor(face)
            cg.addPath(box(c.x, c.y, 4.4, 6, 0.5))
            cg.fillPath()
            let w = 2 * .pi / period(state)!
            cg.setStrokeColor(color(.running))
            cg.setLineWidth(0.45)
            for i in 0...8 {
                let p = CGPoint(x: c.x - 1.8 + CGFloat(i) * 0.45,
                                y: c.y - 1 + 0.9 * sin(Double(i) * 0.8 - t * w * 4) + 0.3 * sin(Double(i) * 2.1 - t * w * 7))
                if i == 0 { cg.move(to: p) } else { cg.addLine(to: p) }
            }
            cg.strokePath()
            cg.setFillColor(color(.mascot))
            for i in 0..<3 {
                let h = 0.6 + 0.5 * (1 + sin(t * w * Double(3 + i * 2) + Double(i)))
                cg.fill(CGRect(x: c.x - 1.6 + CGFloat(i) * 1.2, y: c.y + 2.5 - h, width: 0.8, height: h))
            }
        }

        if state.mode == .waiting {
            let a = 0.45 + 0.55 * CGFloat(0.5 + 0.5 * cos(t * 2 * .pi / 1.6))
            let dot = color(.waiting)
            cg.setFillColor(dot.copy(alpha: 0.3 * a) ?? dot)
            cg.fillEllipse(in: CGRect(x: 6.6 - 2.6, y: -8.4 - 2.6, width: 5.2, height: 5.2))
            cg.setFillColor(dot.copy(alpha: a) ?? dot)
            cg.fillEllipse(in: CGRect(x: 6.6 - 1.6, y: -8.4 - 1.6, width: 3.2, height: 3.2))
        }
        if state.mode == .failed, t < failSettle {
            let glow = color(.failure)
            cg.setStrokeColor(glow.copy(alpha: 0.5 * CGFloat(1 - t / failSettle)) ?? glow)
            cg.setLineWidth(1.6)
            cg.addEllipse(in: CGRect(x: -7.4, y: bob - 7.7, width: 14.8, height: 15.2))
            cg.strokePath()
            let k = CGFloat(max(0, (t - 0.7) / (failSettle - 0.7)))
            if k > 0, !template {
                let p = CGPoint(x: 4.2, y: bob - 4.4 + 2.4 * k)
                cg.setFillColor(NSColor.white.withAlphaComponent(0.9 * sin(k * .pi)).cgColor)
                cg.move(to: CGPoint(x: p.x, y: p.y - 1.3))
                cg.addQuadCurve(to: CGPoint(x: p.x + 0.7, y: p.y + 0.2), control: CGPoint(x: p.x + 0.6, y: p.y - 0.4))
                cg.addArc(center: CGPoint(x: p.x, y: p.y + 0.2), radius: 0.7, startAngle: 0, endAngle: .pi, clockwise: false)
                cg.addQuadCurve(to: CGPoint(x: p.x, y: p.y - 1.3), control: CGPoint(x: p.x - 0.6, y: p.y - 0.4))
                cg.fillPath()
            }
        }
        if state.mode == .passed, !template {
            let blush = color(.failure)
            cg.setFillColor(blush.copy(alpha: 0.45) ?? blush)
            for x in [CGFloat(-3.9), 3.9] { cg.fillEllipse(in: CGRect(x: x - 1, y: bob + 1.8, width: 2, height: 1.1)) }
        }

        if template { cg.setBlendMode(.clear) }
        cg.setFillColor(face)
        cg.setStrokeColor(face)
        cg.setLineWidth(1.1)
        cg.setLineCap(.round)
        let eyeY = -0.2 + bob
        for x in [CGFloat(-2.4), 2.4] {
            switch state.mode {
            case .running, .waiting:
                let e = CGPoint(x: x + look.x, y: eyeY + look.y)
                cg.setFillColor(face)
                let h: CGFloat = blink ? 0.5 : 2.8
                cg.fillEllipse(in: CGRect(x: e.x - 1.4, y: e.y - h / 2, width: 2.8, height: h))
                if detail, !blink {
                    cg.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                    cg.fillEllipse(in: CGRect(x: e.x - 0.1, y: e.y - 1, width: 0.8, height: 0.8))
                }
            case .failed:
                cg.move(to: CGPoint(x: x - 1.1, y: eyeY - 1.1)); cg.addLine(to: CGPoint(x: x + 1.1, y: eyeY + 1.1))
                cg.move(to: CGPoint(x: x + 1.1, y: eyeY - 1.1)); cg.addLine(to: CGPoint(x: x - 1.1, y: eyeY + 1.1))
                cg.strokePath()
            case .passed:
                cg.move(to: CGPoint(x: x - 1.3, y: eyeY + 0.6))
                cg.addLine(to: CGPoint(x: x, y: eyeY - 0.7))
                cg.addLine(to: CGPoint(x: x + 1.3, y: eyeY + 0.6))
                cg.strokePath()
            case .idle:
                cg.move(to: CGPoint(x: x - 1.2, y: eyeY + 0.4)); cg.addLine(to: CGPoint(x: x + 1.2, y: eyeY + 0.4))
                cg.strokePath()
            }
        }

        cg.setStrokeColor(template ? face : gear)
        cg.setLineWidth(0.8)
        cg.move(to: CGPoint(x: -6.3, y: bob + 0.4))
        cg.addQuadCurve(to: CGPoint(x: -2.4, y: bob + 3.6), control: CGPoint(x: -5.8, y: bob + 3.6))
        cg.strokePath()
        cg.setFillColor(template ? face : state.mode == .waiting ? color(.waiting) : gear)
        cg.fillEllipse(in: CGRect(x: -2.9, y: bob + 2.8, width: 1.6, height: 1.6))
    }

    static func image(_ state: MarkState, t: TimeInterval, dark: Bool, pose: Pose = Pose()) -> NSImage {
        let template = state.mode == .idle
        let image = NSImage(size: size, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                draw(cg, in: rect, state: state, t: t, template: template, pose: pose)
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = accessibilityText(state)
        return image
    }

    static func accessibilityText(_ state: MarkState) -> String {
        let gate = state.gate.map { ", \($0)" } ?? ""
        return switch state.mode {
        case .idle: "Pitwall: idle"
        case .running: "Pitwall: running" + gate
        case .waiting: "Pitwall: waiting for input" + gate
        case .failed: "Pitwall: verifier failed"
        case .passed: "Pitwall: all gates passed"
        }
    }
}

@MainActor
final class MarkAnimator {
    static let fps = 24.0
    var onFrame: () -> Void = {}
    private(set) var state = MarkState(mode: .idle)
    private(set) var t: TimeInterval = 0
    private var start = Date()
    private var timer: Timer?

    func show(_ new: MarkState) {
        guard new != state else { return }
        state = new
        start = Date()
        timer?.invalidate()
        timer = nil
        defer { onFrame() }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            t = switch new.mode {
            case .passed: Mark.sweepDuration
            case .idle: 0
            default: Mark.failSettle
            }
            return
        }
        t = 0
        guard new.mode != .idle else { return }
        let timer = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        t = Date().timeIntervalSince(start)
        switch state.mode {
        case .failed where t > Mark.failSettle:
            stop()
        case .passed where t > Mark.sweepDuration:
            state.mode = .idle
            stop()
        default: break
        }
        onFrame()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
