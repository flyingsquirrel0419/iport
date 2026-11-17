// SPDX-License-Identifier: GPL-3.0-or-later
// The on-screen Xbox controller: which controls there are and where they sit.
//
// Positions are fractions of the play view (x of its width, y of its height),
// sizes are fractions of its height, so one layout fits every iPhone in
// landscape. A layout is Codable: the editor saves one per game, or a global one.

public struct TouchControl: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: Codable, Hashable, Sendable {
        /// A digital button (A, B, X, Y, LB, RB, View, Menu, L3, R3, Guide).
        case button(XButtons)
        /// An analog trigger shown as a button: pressed is fully down.
        case trigger(Side)
        /// A thumbstick. Floating: a touch anywhere in its zone becomes the stick's centre.
        case stick(Side)
        /// The 8-way D-pad.
        case dpad
        /// iPort's own in-game menu (pause, quit, layout editor); never reaches the game.
        case menu
    }

    public var id: String
    public var kind: Kind
    public var label: String
    public var x: Double
    public var y: Double
    public var size: Double
    /// Face buttons share a group: a finger may slide from one to another.
    public var group: String?
    public var hidden: Bool = false

    public init(id: String, kind: Kind, label: String, x: Double, y: Double, size: Double,
                group: String? = nil, hidden: Bool = false) {
        self.id = id; self.kind = kind; self.label = label
        self.x = x; self.y = y; self.size = size
        self.group = group; self.hidden = hidden
    }
}

public struct TouchLayout: Codable, Hashable, Sendable {
    public var name: String
    public var controls: [TouchControl]
    /// 0...1, how opaque the drawn controls are.
    public var opacity: Double
    /// Stick dead zone, 0...0.5.
    public var stickDeadZone: Double
    /// Taps on the play view outside any control flash the overlay back when it auto-hid.
    public var version: Int

    public init(name: String, controls: [TouchControl], opacity: Double = 0.45,
                stickDeadZone: Double = 0.12, version: Int = 1) {
        self.name = name; self.controls = controls; self.opacity = opacity
        self.stickDeadZone = stickDeadZone; self.version = version
    }

    public func control(_ id: String) -> TouchControl? { controls.first { $0.id == id } }

    public mutating func update(_ id: String, _ change: (inout TouchControl) -> Void) {
        guard let i = controls.firstIndex(where: { $0.id == id }) else { return }
        change(&controls[i])
        controls[i].x = min(max(controls[i].x, 0), 1)
        controls[i].y = min(max(controls[i].y, 0), 1)
        controls[i].size = min(max(controls[i].size, 0.06), 0.6)
    }

    /// The standard Xbox layout for a landscape phone:
    /// sticks and D-pad on the left / bottom-right, ABXY diamond on the right,
    /// bumpers and triggers on the top corners, View · Guide · Menu at the top centre.
    public static let xbox: TouchLayout = {
        let face = 0.135
        var c: [TouchControl] = [
            .init(id: "ls", kind: .stick(.left), label: "", x: 0.14, y: 0.62, size: 0.34),
            .init(id: "dpad", kind: .dpad, label: "", x: 0.30, y: 0.83, size: 0.26),
            .init(id: "rs", kind: .stick(.right), label: "", x: 0.70, y: 0.83, size: 0.26),
            .init(id: "a", kind: .button(.a), label: "A", x: 0.875, y: 0.74, size: face, group: "face"),
            .init(id: "b", kind: .button(.b), label: "B", x: 0.945, y: 0.58, size: face, group: "face"),
            .init(id: "x", kind: .button(.x), label: "X", x: 0.805, y: 0.58, size: face, group: "face"),
            .init(id: "y", kind: .button(.y), label: "Y", x: 0.875, y: 0.42, size: face, group: "face"),
            .init(id: "lt", kind: .trigger(.left), label: "LT", x: 0.07, y: 0.10, size: 0.13),
            .init(id: "lb", kind: .button(.leftShoulder), label: "LB", x: 0.07, y: 0.27, size: 0.13),
            .init(id: "rt", kind: .trigger(.right), label: "RT", x: 0.93, y: 0.10, size: 0.13),
            .init(id: "rb", kind: .button(.rightShoulder), label: "RB", x: 0.93, y: 0.27, size: 0.13),
            .init(id: "view", kind: .button(.back), label: "⧉", x: 0.40, y: 0.08, size: 0.10),
            .init(id: "guide", kind: .menu, label: "◎", x: 0.50, y: 0.08, size: 0.11),
            .init(id: "menu", kind: .button(.start), label: "≡", x: 0.60, y: 0.08, size: 0.10),
            .init(id: "l3", kind: .button(.leftThumb), label: "L3", x: 0.23, y: 0.42, size: 0.09),
            .init(id: "r3", kind: .button(.rightThumb), label: "R3", x: 0.60, y: 0.70, size: 0.09),
        ]
        c.sort { $0.id < $1.id }
        return TouchLayout(name: "Xbox", controls: c)
    }()
}
