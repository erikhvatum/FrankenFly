// KeyboardPilot.swift — manual stick on the same BrainSignals channels as MechJeb.
// Polls CGEventSource.keyState (permission-free, like Environment idle queries).
// Overlay stays click-through; no Accessibility / event-tap required.
//
// Mixer precedence (Coordinator, after SignalBuilder.make):
//   scare/GF > keyboard (while keys held) > autopilot > brain

import Foundation
import CoreGraphics

/// Hold-to-pilot stick writing turnBias / walkDrive / escape / backward / wingDrive.
final class KeyboardPilot {
    /// When false, sample() always returns an inactive stick.
    var enabled = true

    /// Test seam: when set, hardware is ignored and this stick is used.
    var testStick: Stick?

    struct Stick: Equatable {
        var turnBias: CGFloat = 0
        var walkDrive: CGFloat = 0
        var escape = false
        var backward = false
        var wingDrive: CGFloat = 0

        var active: Bool {
            escape || backward
                || abs(turnBias) > 0.01
                || walkDrive > 0.01
                || wingDrive > 0.01
        }
    }

    /// Human-readable keybind hint for the status menu.
    static let menuHint =
        "Keys: WASD/←→↑↓ steer · Space/F takeoff · Shift reverse"

    // Carbon/HIToolbox virtual key codes (stable across macOS layouts for these).
    private enum Key {
        static let a: CGKeyCode = 0
        static let s: CGKeyCode = 1
        static let d: CGKeyCode = 2
        static let f: CGKeyCode = 3
        static let w: CGKeyCode = 13
        static let space: CGKeyCode = 49
        static let leftShift: CGKeyCode = 56
        static let rightShift: CGKeyCode = 60
        static let left: CGKeyCode = 123
        static let right: CGKeyCode = 124
        static let down: CGKeyCode = 125
        static let up: CGKeyCode = 126
    }

    private func down(_ code: CGKeyCode) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: code)
    }

    /// Snapshot hardware (or testStick). Call from the render / sim thread.
    func sample() -> Stick {
        if let testStick { return testStick }
        guard enabled else { return Stick() }

        var stick = Stick()
        let left = down(Key.a) || down(Key.left)
        let right = down(Key.d) || down(Key.right)
        let forward = down(Key.w) || down(Key.up)
        let back = down(Key.s) || down(Key.down)
        let shift = down(Key.leftShift) || down(Key.rightShift)
        let takeoff = down(Key.space) || down(Key.f)

        if left && !right { stick.turnBias = -0.9 }
        else if right && !left { stick.turnBias = 0.9 }

        if forward && !back {
            stick.walkDrive = 0.95
        } else if back && !forward {
            // S / ↓ = reverse walk (same channel as MDN / Shift).
            stick.walkDrive = 0.95
            stick.backward = true
        } else if abs(stick.turnBias) > 0.01 {
            // Pure strafe: enough drive to engage walking so turnBias applies.
            stick.walkDrive = 0.35
        }

        if shift { stick.backward = true }

        if takeoff {
            stick.escape = true
            stick.wingDrive = 1.0
        }

        return stick
    }

    /// Overlay stick onto brain/autopilot output. Scare/GF still wins.
    func mix(_ brain: BrainSignals, scareYield: Bool = true) -> BrainSignals {
        let stick = sample()
        guard stick.active else { return brain }

        if scareYield && (brain.escape || brain.nervous > 0.40) {
            return brain
        }

        var s = brain
        // Same classic walkDrive/turnBias path Autopilot uses.
        s.legCommands = nil
        s.sleep = false
        s.groomDrive = 0
        s.arousal = min(s.arousal, 0.15)
        s.nervous = min(s.nervous, 0.15)

        if abs(stick.turnBias) > 0.01 {
            s.turnBias = stick.turnBias
        }
        if stick.walkDrive > 0.01 {
            s.walkDrive = stick.walkDrive
        }
        s.backward = stick.backward
        if stick.escape {
            s.escape = true
        }
        if stick.wingDrive > 0.01 {
            s.wingDrive = max(s.wingDrive, stick.wingDrive)
        } else {
            s.wingDrive = min(s.wingDrive, 0.05)
        }

        s.turnBias = clampf(s.turnBias, -1, 1)
        s.walkDrive = clampf(s.walkDrive, 0, 1.3)
        s.wingDrive = clampf(s.wingDrive, 0, 1.3)
        return s
    }
}
