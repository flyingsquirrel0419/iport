// SPDX-License-Identifier: GPL-3.0-or-later
// Physical controllers (Xbox, DualSense, DualShock, Switch Pro, MFi) through
// GameController, into XInput slots; and the touch pad into slot 0 while no
// controller is connected. When a controller connects the touch controls
// disappear (IPortCore ControllerArbiter); when the last one leaves, they return.

import Combine
import Foundation
import GameController
import IPortCore
import UIKit

@MainActor
final class ControllerHub: ObservableObject {
    static let shared = ControllerHub()

    /// Whether the on-screen controller is shown now.
    @Published private(set) var showsTouch = true
    /// Names of the connected controllers, by slot.
    @Published private(set) var connected: [Int: String] = [:]
    /// The guide / home button was pressed (opens iPort's in-game menu).
    let menuPressed = PassthroughSubject<Void, Never>()

    private var arbiter = ControllerArbiter<ObjectIdentifier>()
    private var physical: [Int: GamepadState] = [:]
    private var touchState = GamepadState()
    private var lastSent: [Int: GamepadState] = [:]
    /// Pads reach the runtime only while a game runs.
    var routing = false { didSet { if !routing { releaseAll() } } }

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if let c = n.object as? GCController { self.attach(c) } }
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if let c = n.object as? GCController { self.detach(c) } }
        }
        GCController.shouldMonitorBackgroundEvents = false
        for c in GCController.controllers() { attach(c) }
        GCController.startWirelessControllerDiscovery {}
        applySettings()
    }

    func applySettings() {
        arbiter.policy = AppSettings.shared.values.touchVisibility
        arbiter.touchRevealSeconds = AppSettings.shared.values.touchRevealSeconds
        refreshVisibility()
    }

    /// A per-game override of the visibility policy for this play.
    func setPolicy(_ p: TouchVisibility) {
        arbiter.policy = p
        refreshVisibility()
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func refreshVisibility() {
        let show = arbiter.showsTouchControls(now: now)
        if show != showsTouch { showsTouch = show }
        if !show { touchState = .neutral }
        pushSlot0()
    }

    // MARK: physical controllers

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad, let slot = arbiter.connect(ObjectIdentifier(c)) else { return }
        c.playerIndex = GCControllerPlayerIndex(rawValue: slot) ?? .indexUnset
        connected[slot] = c.vendorName ?? c.productCategory
        physical[slot] = .neutral
        pad.valueChangedHandler = { [weak self] g, _ in
            MainActor.assumeIsolated { self?.read(g, slot: slot) }
        }
        // The Xbox / PS / Home button opens iPort's menu; iOS may take it for the
        // system's own overlay unless the app says it handles it.
        pad.buttonHome?.preferredSystemGestureState = .disabled
        pad.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { MainActor.assumeIsolated { self?.menuPressed.send() } }
        }
        refreshVisibility()
        Haptics.connected(c)
    }

    private func detach(_ c: GCController) {
        guard let slot = arbiter.disconnect(ObjectIdentifier(c)) else { return }
        connected[slot] = nil
        physical[slot] = nil
        lastSent[slot] = nil
        if routing { iport_pad_disconnect(Int32(slot)) }
        refreshVisibility()
    }

    private func read(_ g: GCExtendedGamepad, slot: Int) {
        var s = GamepadState()
        func on(_ b: GCControllerButtonInput?, _ x: XButtons) { if b?.isPressed == true { s.buttons.insert(x) } }
        on(g.buttonA, .a); on(g.buttonB, .b); on(g.buttonX, .x); on(g.buttonY, .y)
        on(g.leftShoulder, .leftShoulder); on(g.rightShoulder, .rightShoulder)
        on(g.buttonMenu, .start); on(g.buttonOptions, .back)
        on(g.leftThumbstickButton, .leftThumb); on(g.rightThumbstickButton, .rightThumb)
        on(g.dpad.up, .dpadUp); on(g.dpad.down, .dpadDown); on(g.dpad.left, .dpadLeft); on(g.dpad.right, .dpadRight)
        s.setTrigger(.left, g.leftTrigger.value)
        s.setTrigger(.right, g.rightTrigger.value)
        s.setStick(.left, x: g.leftThumbstick.xAxis.value, y: g.leftThumbstick.yAxis.value)
        s.setStick(.right, x: g.rightThumbstick.xAxis.value, y: g.rightThumbstick.yAxis.value)
        physical[slot] = s
        if slot == 0 { pushSlot0() } else { push(slot, s) }
    }

    // MARK: touch

    func touchChanged(_ s: GamepadState) {
        touchState = s
        pushSlot0()
    }

    /// A finger on the play view away from any control: brings the overlay back for a while.
    func revealTouch() {
        arbiter.revealTouch(now: now)
        refreshVisibility()
        let delay = arbiter.touchRevealSeconds
        guard delay > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.refreshVisibility() }
        }
    }

    // MARK: to the runtime

    private func pushSlot0() {
        let s = arbiter.slot0(touch: touchState, physical: physical[0], now: now)
        push(0, s)
    }

    private func push(_ slot: Int, _ s: GamepadState) {
        guard routing, lastSent[slot] != s else { return }
        lastSent[slot] = s
        var p = iport_pad(buttons: s.buttons.rawValue, left_trigger: s.leftTrigger, right_trigger: s.rightTrigger,
                          thumb_lx: s.lx, thumb_ly: s.ly, thumb_rx: s.rx, thumb_ry: s.ry)
        iport_pad_set(Int32(slot), &p)
    }

    /// Focus loss / pause: every held button lets go in the game.
    func releaseAll() {
        lastSent.removeAll()
        touchState = .neutral
        _ = iport_pads_release_all()
    }

    /// When a game starts: tell XInput which slots have a pad (slot 0 always does).
    func beginRouting() {
        routing = true
        lastSent.removeAll()
        push(0, arbiter.slot0(touch: touchState, physical: physical[0], now: now))
        for (slot, s) in physical where slot != 0 { push(slot, s) }
    }
}

enum Haptics {
    @MainActor static func tap() {
        guard AppSettings.shared.values.haptics else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @MainActor static func connected(_ c: GCController) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
