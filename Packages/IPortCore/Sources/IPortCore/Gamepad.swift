// SPDX-License-Identifier: GPL-3.0-or-later
// The XInput gamepad, value for value: what the runtime hands a Windows game
// through xinput1_*.dll (vendor/playport app/Sources/HostIO/include/hio_pads.h).

/// XINPUT_GAMEPAD_* button bits.
public struct XButtons: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let dpadUp = XButtons(rawValue: 0x0001)
    public static let dpadDown = XButtons(rawValue: 0x0002)
    public static let dpadLeft = XButtons(rawValue: 0x0004)
    public static let dpadRight = XButtons(rawValue: 0x0008)
    public static let start = XButtons(rawValue: 0x0010)      // Menu (≡)
    public static let back = XButtons(rawValue: 0x0020)       // View (⧉)
    public static let leftThumb = XButtons(rawValue: 0x0040)  // L3
    public static let rightThumb = XButtons(rawValue: 0x0080) // R3
    public static let leftShoulder = XButtons(rawValue: 0x0100)  // LB
    public static let rightShoulder = XButtons(rawValue: 0x0200) // RB
    public static let guide = XButtons(rawValue: 0x0400)      // Xbox button (XInputGetStateEx)
    public static let a = XButtons(rawValue: 0x1000)
    public static let b = XButtons(rawValue: 0x2000)
    public static let x = XButtons(rawValue: 0x4000)
    public static let y = XButtons(rawValue: 0x8000)

    public static let dpad: XButtons = [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]
}

public enum Side: String, Codable, Sendable, Hashable { case left, right }

/// One XInput pad's state. Triggers 0...255, thumbs -32768...32767 with +y up.
public struct GamepadState: Equatable, Hashable, Sendable {
    public var buttons: XButtons = []
    public var leftTrigger: UInt8 = 0
    public var rightTrigger: UInt8 = 0
    public var lx: Int16 = 0, ly: Int16 = 0
    public var rx: Int16 = 0, ry: Int16 = 0

    public init() {}

    public static let neutral = GamepadState()

    public var isNeutral: Bool { self == .neutral }

    /// A trigger from 0...1.
    public static func trigger(_ v: Float) -> UInt8 {
        UInt8((min(max(v, 0), 1) * 255).rounded())
    }

    /// An axis from -1...1 (+1 up / right).
    public static func axis(_ v: Float) -> Int16 {
        let c = min(max(v, -1), 1)
        return c >= 0 ? Int16((c * 32767).rounded()) : Int16((c * 32768).rounded())
    }

    public mutating func setStick(_ side: Side, x: Float, y: Float) {
        switch side {
        case .left: lx = Self.axis(x); ly = Self.axis(y)
        case .right: rx = Self.axis(x); ry = Self.axis(y)
        }
    }

    public mutating func setTrigger(_ side: Side, _ v: Float) {
        switch side {
        case .left: leftTrigger = Self.trigger(v)
        case .right: rightTrigger = Self.trigger(v)
        }
    }

    /// Two sources at once (a touch pad plus a physical pad sharing slot 0):
    /// buttons are or-ed, triggers take the larger, sticks the one further from centre.
    public func merged(with o: GamepadState) -> GamepadState {
        var m = GamepadState()
        m.buttons = buttons.union(o.buttons)
        m.leftTrigger = max(leftTrigger, o.leftTrigger)
        m.rightTrigger = max(rightTrigger, o.rightTrigger)
        func pick(_ ax: Int16, _ ay: Int16, _ bx: Int16, _ by: Int16) -> (Int16, Int16) {
            let a = Int(ax) * Int(ax) + Int(ay) * Int(ay)
            let b = Int(bx) * Int(bx) + Int(by) * Int(by)
            return a >= b ? (ax, ay) : (bx, by)
        }
        (m.lx, m.ly) = pick(lx, ly, o.lx, o.ly)
        (m.rx, m.ry) = pick(rx, ry, o.rx, o.ry)
        return m
    }
}

/// A radial dead zone with rescaling, so a stick leaves the zone at 0 rather than jumping.
public func applyDeadZone(x: Float, y: Float, deadZone: Float) -> (Float, Float) {
    let mag = (x * x + y * y).squareRoot()
    guard mag > deadZone, mag > 0 else { return (0, 0) }
    let clamped = min(mag, 1)
    let scaled = (clamped - deadZone) / (1 - deadZone)
    return (x / mag * scaled, y / mag * scaled)
}
