// Autopilot.swift — MechJeb-style guidance computer that mixes/overrides
// BrainSignals on top of the LIF brain. Commands controls; never teleports.

import Foundation
import CoreGraphics

enum AutopilotMode: Equatable {
    case off
    /// Hold a locked heading via turnBias.
    case sas
    /// Walk toward a scene point (ledge midpoints and free points alike).
    case goTo(CGPoint)
    /// Circle a scene point at a fixed radius.
    case orbit(center: CGPoint, radius: CGFloat)
    /// Seek the nearest ledge and settle (idle once attached / close).
    case land
    /// Armed but passive: do not steer; GF / loom abort always wins.
    case scareYield
}

/// Guidance mixer sitting between `SignalBuilder.make` and `Fly.update`.
final class Autopilot {
    private(set) var mode: AutopilotMode = .off
    /// When true (default), escape / high loom nervousness pass the brain through.
    var scareYieldPolicy = true

    private var sasHeading: CGFloat = 0
    private var orbitPhase: CGFloat = 0
    /// Soft arrival latch so we do not fidget on the spot after GoTo / Land.
    private var arrived = false

    var engaged: Bool { mode != .off }

    var modeTitle: String {
        switch mode {
        case .off: return "Off"
        case .sas: return "SAS"
        case .goTo: return "GoTo"
        case .orbit: return "Orbit"
        case .land: return "Land"
        case .scareYield: return "Scare-yield"
        }
    }

    func disengage() {
        mode = .off
        arrived = false
    }

    func engageSAS(heading: CGFloat) {
        mode = .sas
        sasHeading = heading
        arrived = false
    }

    func engageGoTo(_ point: CGPoint) {
        mode = .goTo(point)
        arrived = false
    }

    func engageGoTo(ledge: Ledge) {
        engageGoTo(CGPoint(x: (ledge.x0 + ledge.x1) * 0.5, y: ledge.y))
    }

    func engageOrbit(center: CGPoint, radius: CGFloat = 90) {
        mode = .orbit(center: center, radius: max(40, radius))
        orbitPhase = 0
        arrived = false
    }

    func engageLand() {
        mode = .land
        arrived = false
    }

    func engageScareYield() {
        mode = .scareYield
        arrived = false
    }

    /// Mix brain output with guidance. Scare-yield policy: GF spike or hot loom
    /// detectors abort guidance for this tick so the fly can still escape.
    func mix(_ brain: BrainSignals, fly: Fly, dt: CGFloat) -> BrainSignals {
        guard engaged else { return brain }

        if scareYieldPolicy || mode == .scareYield {
            if brain.escape || brain.nervous > 0.40 {
                // Abort wins: pass brain through, keep sleep/tempo from ambient.
                return brain
            }
        }

        if mode == .scareYield {
            // Passive arm — no steering commands.
            return brain
        }

        var s = brain
        // Classic walkDrive/turnBias path: MaleCNS legCommands ignore turnBias.
        s.legCommands = nil
        s.sleep = false
        s.backward = false
        s.groomDrive = 0
        // Suppress spontaneous takeoff / wing threat while guiding.
        s.arousal = 0
        s.wingDrive = min(s.wingDrive, 0.05)
        // Do not invent escape; GF already handled above.
        s.escape = false
        s.nervous = min(s.nervous, 0.15)

        switch mode {
        case .off, .scareYield:
            break
        case .sas:
            applySAS(&s, fly: fly)
        case .goTo(let target):
            applyGoTo(&s, fly: fly, target: target, settle: false)
        case .orbit(let center, let radius):
            applyOrbit(&s, fly: fly, center: center, radius: radius, dt: dt)
        case .land:
            applyLand(&s, fly: fly)
        }

        clampSignals(&s)
        return s
    }

    // MARK: - Mode controllers

    private func applySAS(_ s: inout BrainSignals, fly: Fly) {
        let err = angleDiff(fly.heading, sasHeading)
        s.turnBias = clampf(err * 2.5, -1, 1)
        // Hold pose: enough drive to stay walking if already walking, else idle.
        if fly.state == .walking {
            s.walkDrive = max(s.walkDrive, 0.18)
        } else {
            s.walkDrive = min(s.walkDrive, 0.05)
        }
    }

    private func applyGoTo(_ s: inout BrainSignals, fly: Fly, target: CGPoint, settle: Bool) {
        let dx = target.x - fly.pos.x
        let dy = target.y - fly.pos.y
        let dist = hypot(dx, dy)
        let arriveR: CGFloat = settle ? 55 : 40

        if dist < arriveR || (fly.ledge != nil && abs(fly.pos.y - target.y) < 12
                              && fly.pos.x >= target.x - 80 && fly.pos.x <= target.x + 80) {
            arrived = true
        }

        if arrived || dist < arriveR {
            // Soft hold near target — respect idle hysteresis (stateAge ≥ 0.4).
            s.turnBias = 0
            s.walkDrive = fly.state == .walking && fly.stateAge < 0.5 ? 0.12 : 0.04
            return
        }

        let desired = atan2(dy, dx)
        let err = angleDiff(fly.heading, desired)
        s.turnBias = clampf(err * 2.8, -1, 1)
        // Slow while misaligned so turns look fly-like, not tank-steering.
        let align = clampf(1 - abs(err) / (.pi * 0.65), 0.15, 1)
        // Above idle→walk threshold (0.22) so brainBehavior engages walking
        // after the ≥0.4 s dwell; capped like SignalBuilder.
        s.walkDrive = clampf(0.35 + 0.55 * align, 0.28, 1.0)
    }

    private func applyOrbit(_ s: inout BrainSignals, fly: Fly,
                            center: CGPoint, radius: CGFloat, dt: CGFloat) {
        let dx = fly.pos.x - center.x
        let dy = fly.pos.y - center.y
        let ang = atan2(dy, dx)
        // Advance a pursuit point along the circle (~35 deg/s tangential).
        orbitPhase = ang + 0.55 * dt * 60 / 60  // ~0.55 rad/s along ring
        let chase = ang + 0.7
        let target = CGPoint(x: center.x + cos(chase) * radius,
                             y: center.y + sin(chase) * radius)
        // Also nudge radius error into the chase point.
        let radial = hypot(dx, dy)
        let radialErr = radius - radial
        let corrected = CGPoint(x: target.x + cos(ang) * clampf(radialErr * 0.3, -30, 30),
                                y: target.y + sin(ang) * clampf(radialErr * 0.3, -30, 30))
        let desired = atan2(corrected.y - fly.pos.y, corrected.x - fly.pos.x)
        let err = angleDiff(fly.heading, desired)
        s.turnBias = clampf(err * 2.5, -1, 1)
        let align = clampf(1 - abs(err) / (.pi * 0.7), 0.2, 1)
        s.walkDrive = clampf(0.45 + 0.4 * align, 0.30, 1.0)
        _ = orbitPhase
    }

    private func applyLand(_ s: inout BrainSignals, fly: Fly) {
        if fly.state == .flying {
            // Cannot teleport-land; wait out the geometric flight with low drive.
            s.walkDrive = 0
            s.turnBias = 0
            s.arousal = 0
            s.wingDrive = 0
            return
        }
        if let L = fly.ledge {
            // Settled on a ledge — idle.
            arrived = true
            s.turnBias = 0
            s.walkDrive = fly.stateAge < 0.5 && fly.state == .walking ? 0.10 : 0.03
            _ = L
            return
        }
        // Seek nearest terrain ledge midpoint.
        guard let L = nearestLedge(to: fly.pos, in: fly.terrain) else {
            // No ledge: hold SAS-like stillness.
            s.walkDrive = 0.04
            s.turnBias = 0
            return
        }
        let mid = CGPoint(x: (L.x0 + L.x1) * 0.5, y: L.y)
        applyGoTo(&s, fly: fly, target: mid, settle: true)
    }

    // MARK: - Helpers

    private func clampSignals(_ s: inout BrainSignals) {
        s.nervous = clampf(s.nervous, 0, 1)
        s.turnBias = clampf(s.turnBias, -1, 1)
        s.walkDrive = clampf(s.walkDrive, 0, 1.3)
        s.groomDrive = clampf(s.groomDrive, 0, 1.5)
        s.wingDrive = clampf(s.wingDrive, 0, 1.3)
        s.arousal = clampf(s.arousal, 0, 1)
        if !s.tempo.isFinite { s.tempo = 1 }
        s.tempo = clampf(s.tempo, 0.5, 2)
    }
}

func nearestLedge(to p: CGPoint, in ledges: [Ledge]) -> Ledge? {
    guard !ledges.isEmpty else { return nil }
    return ledges.min { a, b in
        let am = CGPoint(x: clampf(p.x, a.x0, a.x1), y: a.y)
        let bm = CGPoint(x: clampf(p.x, b.x0, b.x1), y: b.y)
        return hypot(am.x - p.x, am.y - p.y) < hypot(bm.x - p.x, bm.y - p.y)
    }
}
