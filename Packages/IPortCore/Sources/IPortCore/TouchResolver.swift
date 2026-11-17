// SPDX-License-Identifier: GPL-3.0-or-later
// Turns the fingers on the play view into one XInput pad state.
//
// A finger claims the control it lands on and keeps it until it lifts, so a
// thumb sliding off a stick keeps steering. Sticks float: landing anywhere in
// a stick's zone makes that point the stick's centre. A finger on a face
// button may slide onto another face button (A → B) without lifting.
// The UIKit view feeds touches in points; everything here is plain geometry.

import Foundation

public struct Point: Equatable, Hashable, Sendable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct ViewSize: Equatable, Sendable {
    public var width: Double, height: Double
    public init(_ width: Double, _ height: Double) { self.width = width; self.height = height }
}

public struct TouchResolver: Sendable {
    public private(set) var layout: TouchLayout
    public private(set) var size: ViewSize

    /// Finger id → what it holds.
    private var claims: [Int: Claim] = [:]

    private struct Claim: Sendable {
        var controlID: String
        var origin: Point
        var current: Point
    }

    /// The menu control was tapped since the last `takeMenuTap()`.
    public private(set) var menuTapped = false

    public init(layout: TouchLayout, size: ViewSize) {
        self.layout = layout
        self.size = size
    }

    public mutating func setLayout(_ l: TouchLayout) { layout = l; claims.removeAll() }
    public mutating func setSize(_ s: ViewSize) { size = s }

    public var activeFingers: Int { claims.count }

    /// Which control a finger holds (for drawing the pressed state and the stick knob).
    public func held() -> [String: (origin: Point, current: Point)] {
        var out: [String: (Point, Point)] = [:]
        for c in claims.values { out[c.controlID] = (c.origin, c.current) }
        return out
    }

    // MARK: geometry

    public func center(of c: TouchControl) -> Point { Point(c.x * size.width, c.y * size.height) }
    public func radius(of c: TouchControl) -> Double { c.size * size.height / 2 }

    /// How far beyond its drawn circle a control still takes a finger.
    static func reach(_ c: TouchControl) -> Double {
        switch c.kind {
        case .stick: return 1.7
        case .dpad: return 1.25
        default: return 1.2
        }
    }

    private func distance(_ a: Point, _ b: Point) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The control under `p`: the nearest one (relative to its size) that reaches it.
    public func hit(_ p: Point, among filter: ((TouchControl) -> Bool)? = nil) -> TouchControl? {
        var best: (TouchControl, Double)?
        for c in layout.controls where !c.hidden && (filter?(c) ?? true) {
            let r = radius(of: c)
            guard r > 0 else { continue }
            let d = distance(p, center(of: c)) / r
            guard d <= Self.reach(c) else { continue }
            if best == nil || d < best!.1 { best = (c, d) }
        }
        return best?.0
    }

    // MARK: touches

    /// A finger landed. Returns the control it claimed, if any.
    @discardableResult
    public mutating func began(_ finger: Int, at p: Point) -> TouchControl? {
        guard let c = hit(p) else { return nil }
        var origin = center(of: c)
        if case .stick = c.kind { origin = p }   // floating stick
        if case .menu = c.kind { menuTapped = true }
        claims[finger] = Claim(controlID: c.id, origin: origin, current: p)
        return c
    }

    public mutating func moved(_ finger: Int, to p: Point) {
        guard var claim = claims[finger], let c = layout.control(claim.controlID) else { return }
        claim.current = p
        // Slide between buttons of the same group (face buttons).
        if let g = c.group, case .button = c.kind, distance(p, center(of: c)) > radius(of: c) * Self.reach(c),
           let next = hit(p, among: { $0.group == g }) {
            claim.controlID = next.id
            claim.origin = center(of: next)
        }
        claims[finger] = claim
    }

    public mutating func ended(_ finger: Int) { claims[finger] = nil }

    public mutating func cancelAll() { claims.removeAll() }

    public mutating func takeMenuTap() -> Bool {
        defer { menuTapped = false }
        return menuTapped
    }

    // MARK: state

    /// The pad state the held controls make.
    public func state() -> GamepadState {
        var s = GamepadState()
        let dz = Float(layout.stickDeadZone)
        for claim in claims.values {
            guard let c = layout.control(claim.controlID) else { continue }
            switch c.kind {
            case .button(let b):
                s.buttons.formUnion(b)
            case .trigger(let side):
                s.setTrigger(side, 1)
            case .stick(let side):
                let r = radius(of: c)
                let vx = Float((claim.current.x - claim.origin.x) / r)
                let vy = Float(-(claim.current.y - claim.origin.y) / r)   // screen y grows down
                let (x, y) = applyDeadZone(x: vx, y: vy, deadZone: dz)
                s.setStick(side, x: x, y: y)
            case .dpad:
                s.buttons.formUnion(Self.dpad(dx: claim.current.x - center(of: c).x,
                                              dy: claim.current.y - center(of: c).y,
                                              radius: radius(of: c)))
            case .menu:
                break
            }
        }
        return s
    }

    /// 8-way D-pad: a centre dead spot, then 45° sectors (diagonals press two).
    public static func dpad(dx: Double, dy: Double, radius: Double) -> XButtons {
        let mag = (dx * dx + dy * dy).squareRoot()
        guard radius > 0, mag > radius * 0.22 else { return [] }
        // Angle with 0 = right, counter-clockwise, screen y flipped.
        var a = atan2Deg(-dy, dx)
        if a < 0 { a += 360 }
        let sector = Int(((a + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        switch sector {
        case 0: return .dpadRight
        case 1: return [.dpadRight, .dpadUp]
        case 2: return .dpadUp
        case 3: return [.dpadUp, .dpadLeft]
        case 4: return .dpadLeft
        case 5: return [.dpadLeft, .dpadDown]
        case 6: return .dpadDown
        default: return [.dpadDown, .dpadRight]
        }
    }
}

/// atan2 in degrees.
func atan2Deg(_ y: Double, _ x: Double) -> Double { atan2(y, x) * 180 / .pi }
