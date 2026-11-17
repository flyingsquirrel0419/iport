// SPDX-License-Identifier: GPL-3.0-or-later
// The on-screen Xbox controller: a UIKit view (SwiftUI cannot track several
// fingers independently) that draws the layout and feeds every touch to
// IPortCore's TouchResolver, whose pad state goes to ControllerHub.

import IPortCore
import SwiftUI
import UIKit

final class TouchGamepadView: UIView {
    var onState: ((GamepadState) -> Void)?
    var onMenu: (() -> Void)?
    /// A touch that hit no control (to reveal the overlay, or reach the game).
    var onEmptyTouch: (() -> Void)?

    private var resolver = TouchResolver(layout: .xbox, size: ViewSize(1, 1))
    private var fingers: [ObjectIdentifier: Int] = [:]
    private var nextFinger = 1
    private var shapes: [String: ControlShape] = [:]
    private var lastState = GamepadState()

    var layout: TouchLayout {
        get { resolver.layout }
        set { resolver.setLayout(newValue); rebuild() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        resolver.setSize(ViewSize(Double(bounds.width), Double(bounds.height)))
        for c in resolver.layout.controls { shapes[c.id]?.place(c, resolver: resolver) }
        redraw()
    }

    /// Touches outside every control pass through to the game view below.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        resolver.hit(Point(Double(point.x), Double(point.y))) != nil
    }

    private func rebuild() {
        shapes.values.forEach { $0.removeFromSuperlayer() }
        shapes.removeAll()
        for c in resolver.layout.controls where !c.hidden {
            let s = ControlShape(control: c)
            layer.addSublayer(s)
            shapes[c.id] = s
        }
        alpha = CGFloat(resolver.layout.opacity) / 0.45 * 0.9   // opacity 0.45 ≈ the drawn default
        setNeedsLayout()
    }

    // MARK: touches

    private func finger(_ t: UITouch) -> Int {
        let k = ObjectIdentifier(t)
        if let f = fingers[k] { return f }
        nextFinger += 1
        fingers[k] = nextFinger
        return nextFinger
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if resolver.began(finger(t), at: Point(Double(p.x), Double(p.y))) == nil {
                onEmptyTouch?()
            } else {
                Haptics.tap()
            }
        }
        if resolver.takeMenuTap() { onMenu?() }
        emit()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            resolver.moved(finger(t), to: Point(Double(p.x), Double(p.y)))
        }
        emit()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        for t in touches {
            resolver.ended(finger(t))
            fingers[ObjectIdentifier(t)] = nil
        }
        emit()
    }

    func releaseAll() {
        resolver.cancelAll()
        fingers.removeAll()
        emit()
    }

    private func emit() {
        let s = resolver.state()
        if s != lastState {
            lastState = s
            onState?(s)
        }
        redraw()
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let held = resolver.held()
        for c in resolver.layout.controls {
            guard let shape = shapes[c.id] else { continue }
            let h = held[c.id]
            shape.update(pressed: h != nil,
                         knob: h.map { CGPoint(x: $0.current.x - $0.origin.x, y: $0.current.y - $0.origin.y) },
                         origin: h.map { CGPoint(x: $0.origin.x, y: $0.origin.y) },
                         resolver: resolver, state: lastState)
        }
        CATransaction.commit()
    }
}

/// One control, drawn with Core Animation layers.
private final class ControlShape: CALayer {
    let control: TouchControl
    private let ring = CAShapeLayer()
    private let knob = CAShapeLayer()
    private let text = CATextLayer()
    private var radius: CGFloat = 20
    private var home: CGPoint = .zero

    init(control: TouchControl) {
        self.control = control
        super.init()
        ring.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        ring.lineWidth = 2
        addSublayer(ring)
        knob.fillColor = UIColor.white.withAlphaComponent(0.45).cgColor
        if case .stick = control.kind { addSublayer(knob) }
        text.string = control.label
        text.alignmentMode = .center
        text.foregroundColor = Self.tint(control).cgColor
        text.contentsScale = 3   // sharp on every iPhone; the layer is tiny
        text.font = UIFont.systemFont(ofSize: 10, weight: .bold)
        addSublayer(text)
    }

    override init(layer: Any) {
        control = (layer as! ControlShape).control
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func tint(_ c: TouchControl) -> UIColor {
        guard case .button(let b) = c.kind else { return .white }
        switch b {
        case .a: return UIColor(red: 0.36, green: 0.80, blue: 0.29, alpha: 1)
        case .b: return UIColor(red: 0.93, green: 0.27, blue: 0.27, alpha: 1)
        case .x: return UIColor(red: 0.25, green: 0.55, blue: 0.98, alpha: 1)
        case .y: return UIColor(red: 0.98, green: 0.80, blue: 0.20, alpha: 1)
        default: return .white
        }
    }

    func place(_ c: TouchControl, resolver: TouchResolver) {
        let center = resolver.center(of: c)
        radius = CGFloat(resolver.radius(of: c))
        home = CGPoint(x: center.x, y: center.y)
        frame = CGRect(x: home.x - radius, y: home.y - radius, width: radius * 2, height: radius * 2)
        let rect = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        switch c.kind {
        case .dpad:
            ring.path = Self.cross(in: rect)
        case .trigger, .button(.leftShoulder), .button(.rightShoulder):
            ring.path = UIBezierPath(roundedRect: rect.insetBy(dx: 0, dy: radius * 0.3), cornerRadius: radius * 0.35).cgPath
        default:
            ring.path = UIBezierPath(ovalIn: rect).cgPath
        }
        ring.frame = rect
        let k = radius * 0.45
        knob.path = UIBezierPath(ovalIn: CGRect(x: -k, y: -k, width: k * 2, height: k * 2)).cgPath
        knob.position = CGPoint(x: radius, y: radius)
        let fs = max(10, radius * 0.7)
        text.fontSize = fs
        text.frame = CGRect(x: 0, y: radius - fs * 0.62, width: radius * 2, height: fs * 1.3)
    }

    func update(pressed: Bool, knob offset: CGPoint?, origin: CGPoint?, resolver: TouchResolver, state: GamepadState) {
        ring.fillColor = UIColor.white.withAlphaComponent(pressed ? 0.38 : 0.12).cgColor
        guard case .stick = control.kind else { return }
        if let offset, let origin {
            // The floating stick is drawn where the thumb landed.
            position = origin
            let mag = (offset.x * offset.x + offset.y * offset.y).squareRoot()
            let s = mag > radius ? radius / mag : 1
            knob.position = CGPoint(x: radius + offset.x * s, y: radius + offset.y * s)
        } else {
            position = home
            knob.position = CGPoint(x: radius, y: radius)
        }
    }

    static func cross(in r: CGRect) -> CGPath {
        let w = r.width / 3
        let p = UIBezierPath()
        p.move(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: 2 * w, y: 0))
        p.addLine(to: CGPoint(x: 2 * w, y: w)); p.addLine(to: CGPoint(x: 3 * w, y: w))
        p.addLine(to: CGPoint(x: 3 * w, y: 2 * w)); p.addLine(to: CGPoint(x: 2 * w, y: 2 * w))
        p.addLine(to: CGPoint(x: 2 * w, y: 3 * w)); p.addLine(to: CGPoint(x: w, y: 3 * w))
        p.addLine(to: CGPoint(x: w, y: 2 * w)); p.addLine(to: CGPoint(x: 0, y: 2 * w))
        p.addLine(to: CGPoint(x: 0, y: w)); p.addLine(to: CGPoint(x: w, y: w))
        p.close()
        return p.cgPath
    }
}

/// SwiftUI wrapper.
struct TouchGamepad: UIViewRepresentable {
    var layout: TouchLayout
    var onMenu: () -> Void

    func makeUIView(context: Context) -> TouchGamepadView {
        let v = TouchGamepadView()
        v.layout = layout
        v.onState = { s in MainActor.assumeIsolated { ControllerHub.shared.touchChanged(s) } }   // UIKit touches: main thread, no hop
        v.onMenu = onMenu
        v.onEmptyTouch = { MainActor.assumeIsolated { ControllerHub.shared.revealTouch() } }
        return v
    }

    func updateUIView(_ v: TouchGamepadView, context: Context) {
        if v.layout != layout { v.layout = layout }
        v.onMenu = onMenu
    }

    static func dismantleUIView(_ v: TouchGamepadView, coordinator: ()) {
        v.releaseAll()
    }
}
