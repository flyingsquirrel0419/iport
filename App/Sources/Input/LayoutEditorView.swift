// SPDX-License-Identifier: GPL-3.0-or-later
// The touch layout editor: drag a control to move it, pick one to resize or
// hide it, set the overall opacity; saved globally or for one game.

import IPortCore
import SwiftUI

struct LayoutEditorView: View {
    let appID: UInt32?
    var onDone: () -> Void

    @State private var layout: TouchLayout
    @State private var selected: String?
    @State private var perGame: Bool
    @ObservedObject private var store = LayoutStore.shared

    init(appID: UInt32?, onDone: @escaping () -> Void) {
        self.appID = appID
        self.onDone = onDone
        _layout = State(initialValue: LayoutStore.shared.layout(for: appID))
        _perGame = State(initialValue: appID.map { LayoutStore.shared.hasOwn($0) } ?? false)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [.black, Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                grid(geo.size).opacity(0.15)
                ForEach(layout.controls) { c in
                    handle(c, in: geo.size)
                }
                toolbar
            }
        }
        .statusBarHidden()
    }

    private func grid(_ size: CGSize) -> some View {
        Path { p in
            stride(from: 0, through: size.width, by: size.width / 20).forEach { x in
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0, through: size.height, by: size.height / 10).forEach { y in
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
        }.stroke(.white, lineWidth: 0.5)
    }

    private func handle(_ c: TouchControl, in size: CGSize) -> some View {
        let d = c.size * size.height
        return ZStack {
            Circle().fill(.white.opacity(c.hidden ? 0.04 : 0.15))
            Circle().stroke(selected == c.id ? Color.accentColor : .white.opacity(0.7),
                            style: StrokeStyle(lineWidth: selected == c.id ? 3 : 1.5, dash: c.hidden ? [4, 4] : []))
            Text(label(c)).font(.system(size: max(10, d * 0.3), weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: d, height: d)
        .position(x: c.x * size.width, y: c.y * size.height)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                selected = c.id
                layout.update(c.id) {
                    $0.x = Double(v.location.x / size.width)
                    $0.y = Double(v.location.y / size.height)
                }
            })
    }

    private func label(_ c: TouchControl) -> String {
        switch c.kind {
        case .stick(.left): return "LS"
        case .stick(.right): return "RS"
        case .dpad: return "✚"
        default: return c.label
        }
    }

    private var toolbar: some View {
        VStack {
            HStack(spacing: 12) {
                if appID != nil {
                    Toggle("This game only", isOn: $perGame).toggleStyle(.button)
                }
                HStack {
                    Image(systemName: "circle.lefthalf.filled")
                    Slider(value: $layout.opacity, in: 0.1...1).frame(width: 120)
                }
                if let id = selected, let c = layout.control(id) {
                    HStack {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Slider(value: Binding(get: { c.size }, set: { v in layout.update(id) { $0.size = v } }),
                               in: 0.06...0.6).frame(width: 120)
                    }
                    Button(c.hidden ? "Show" : "Hide") { layout.update(id) { $0.hidden.toggle() } }
                }
                Spacer()
                Button("Reset") {
                    layout = .xbox
                    selected = nil
                }
                Button("Done") {
                    if perGame, let appID {
                        store.save(layout, for: appID)
                    } else {
                        if let appID { store.reset(for: appID) }
                        store.save(layout, for: nil)
                    }
                    onDone()
                }.buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 60)
            .padding(.top, 8)
            Spacer()
        }
    }
}
