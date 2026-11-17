// SPDX-License-Identifier: GPL-3.0-or-later
// Who drives which XInput slot, and whether the touch controller is on screen.
//
// Physical controllers (Xbox, DualSense, MFi — anything GameController calls
// an extended gamepad) take slots 0...3 in the order they connect. The touch
// pad drives slot 0 only while no physical controller does. With the default
// policy the touch controls disappear the moment a controller connects and
// come back when the last one leaves; a touch on the screen while one is
// connected can bring them back for a while (`touchRevealSeconds`).

public enum TouchVisibility: String, Codable, Sendable, CaseIterable {
    /// Hide while a physical controller is connected (the default).
    case automatic
    /// Always show, even with a controller (two players: touch + pad share slot 0).
    case always
    /// Never show (controller only).
    case never
}

public struct ControllerArbiter<Key: Hashable & Sendable>: Sendable {
    public static var slots: Int { 4 }

    public var policy: TouchVisibility
    /// Seconds the overlay stays after a reveal touch while a controller is connected; 0 disables.
    public var touchRevealSeconds: Double

    private var assigned: [Key?] = Array(repeating: nil, count: 4)
    private var revealUntil: Double = 0

    public init(policy: TouchVisibility = .automatic, touchRevealSeconds: Double = 0) {
        self.policy = policy
        self.touchRevealSeconds = touchRevealSeconds
    }

    public var connected: [Key] { assigned.compactMap { $0 } }
    public var hasPhysical: Bool { assigned.contains { $0 != nil } }

    public func slot(of key: Key) -> Int? { assigned.firstIndex(where: { $0 == key }) }

    /// A controller connected. Returns its slot, or nil when all four are taken.
    @discardableResult
    public mutating func connect(_ key: Key) -> Int? {
        if let s = slot(of: key) { return s }
        guard let free = assigned.firstIndex(where: { $0 == nil }) else { return nil }
        assigned[free] = key
        return free
    }

    /// A controller left. Returns the slot it freed (the caller disconnects it in XInput).
    @discardableResult
    public mutating func disconnect(_ key: Key) -> Int? {
        guard let s = slot(of: key) else { return nil }
        assigned[s] = nil
        return s
    }

    /// A finger touched the play view where no control is (to bring the overlay back).
    public mutating func revealTouch(now: Double) {
        guard touchRevealSeconds > 0 else { return }
        revealUntil = now + touchRevealSeconds
    }

    public func showsTouchControls(now: Double) -> Bool {
        switch policy {
        case .always: return true
        case .never: return false
        case .automatic: return !hasPhysical || now < revealUntil
        }
    }

    /// Whether the touch pad writes slot 0 (it does whenever it is shown and slot 0
    /// has no physical owner; with `.always` it merges into slot 0's controller).
    public func touchDrivesSlot0(now: Double) -> Bool {
        showsTouchControls(now: now)
    }

    /// Slot 0's state from the touch pad and slot 0's physical controller, if any.
    public func slot0(touch: GamepadState, physical: GamepadState?, now: Double) -> GamepadState {
        guard touchDrivesSlot0(now: now) else { return physical ?? .neutral }
        guard let physical else { return touch }
        return touch.merged(with: physical)
    }
}
