// SPDX-License-Identifier: GPL-3.0-or-later
// The play screen: the game's Metal surface, the touch controller over it
// (only while no physical controller is connected), and iPort's in-game menu.

import IPortCore
import QuartzCore
import SwiftUI
import UIKit

struct PlayView: View {
    @ObservedObject var session = GameSession.shared
    @ObservedObject var hub = ControllerHub.shared
    @ObservedObject var layouts = LayoutStore.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GameSurface().ignoresSafeArea()

            if session.phase == .running && hub.showsTouch && !session.menuOpen {
                TouchGamepad(layout: layouts.layout(for: session.game?.appID)) { session.toggleMenu() }
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            if session.phase == .running && !hub.showsTouch && !session.menuOpen {
                // With a controller: a small corner button still opens the menu.
                VStack {
                    HStack {
                        Spacer()
                        Button { session.pause() } label: {
                            Image(systemName: "pause.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.35))
                        }.padding(12)
                    }
                    Spacer()
                }
            }
            status
            if session.menuOpen { InGameMenu() }
            if session.editingLayout {
                LayoutEditorView(appID: session.game?.appID) { session.editingLayout = false }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hub.showsTouch)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
    }

    @ViewBuilder private var status: some View {
        switch session.phase {
        case .preparing(let s):
            VStack(spacing: 14) { ProgressView().tint(.white); Text(s).foregroundStyle(.white) }
        case .waitingForJIT:
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Text("Waiting for JIT").font(.headline).foregroundStyle(.white)
                Text("Enable JIT for iPort in StikDebug (or launch iPort from LiveContainer with JIT).")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open StikDebug") { GameSession.openStikDebug() }.buttonStyle(.borderedProminent)
                Button("Cancel") { session.close() }.foregroundStyle(.white)
            }.padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        case .failed(let s):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text(s).foregroundStyle(.white).multilineTextAlignment(.center)
                Button("Back") { session.close() }.buttonStyle(.borderedProminent)
            }.padding(30).frame(maxWidth: 520).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        case .ended(let code, let seconds):
            VStack(spacing: 14) {
                Text(session.game?.name ?? "Game").font(.title2.bold()).foregroundStyle(.white)
                let played: String = "Played " + ByteFormat.duration(seconds) + (code != 0 ? " · exit code \(code)" : "")
                Text(played).foregroundStyle(.secondary)
                Text("Wine runs one game per launch: iPort closes now. Open it again to play.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Close iPort") { exit(0) }.buttonStyle(.borderedProminent)
            }.padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        default:
            EmptyView()
        }
    }
}

/// The in-game menu: resume, controls, quit. A controller's Xbox/Home button,
/// the touch pad's ◎ or the corner pause button opens it.
struct InGameMenu: View {
    @ObservedObject var session = GameSession.shared
    @ObservedObject var hub = ControllerHub.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { session.resume() }
            VStack(alignment: .leading, spacing: 16) {
                Text(session.game?.name ?? "").font(.title2.bold())
                Text(hub.connected.isEmpty ? "Touch controls" :
                        "Controllers: " + hub.connected.sorted { $0.key < $1.key }.map { "P\($0.key + 1) \($0.value)" }.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button { session.resume() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                    Button { session.menuOpen = false; session.editingLayout = true } label: {
                        Label("Edit touch layout", systemImage: "square.grid.3x3")
                    }.buttonStyle(.bordered)
                    Menu {
                        ForEach(TouchVisibility.allCases, id: \.self) { v in
                            Button(v.label) { hub.setPolicy(v) }
                        }
                    } label: { Label("Touch controls", systemImage: "hand.tap") }
                        .buttonStyle(.bordered)
                    Button(role: .destructive) { session.quit() } label: { Label("Quit game", systemImage: "xmark") }
                        .buttonStyle(.bordered)
                }
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

extension TouchVisibility {
    var label: String {
        switch self {
        case .automatic: return "Hide when a controller connects"
        case .always: return "Always show"
        case .never: return "Never show"
        }
    }
}

/// The CAMetalLayer-backed view the game's swap chain presents to.
struct GameSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> GameSurfaceView { GameSurfaceView() }
    func updateUIView(_ v: GameSurfaceView, context: Context) {}
}

final class GameSurfaceView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var registered = false
    private var windowsLayer: CALayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        if let p = iport_display_windows_layer() {
            let l = Unmanaged<CALayer>.fromOpaque(p).takeUnretainedValue()
            layer.addSublayer(l)
            windowsLayer = l
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        windowsLayer?.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        // Vulkan/Metal WSI sizes the swap chain by bounds × contentsScale: use native pixels.
        contentScaleFactor = window.screen.nativeScale
        window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        if !registered {
            registered = true
            GameSession.shared.surfaceAttached(layer)
        }
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }

    // A touch on the game (not on a control) brings a hidden touch pad back for a moment.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        ControllerHub.shared.revealTouch()
    }

    // Hardware keyboard → Windows virtual keys.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses { if let vk = p.key.flatMap({ VirtualKey.code($0.keyCode) }) { iport_key(vk, 1); handled = true } }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses { if let vk = p.key.flatMap({ VirtualKey.code($0.keyCode) }) { iport_key(vk, 0); handled = true } }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}

/// USB HID usage → Windows virtual-key code, for the keys games use.
enum VirtualKey {
    static func code(_ k: UIKeyboardHIDUsage) -> Int32? {
        let r = k.rawValue
        switch r {
        case 0x04...0x1D: return Int32(0x41 + (r - 0x04))           // A–Z
        case 0x1E...0x26: return Int32(0x31 + (r - 0x1E))           // 1–9
        case 0x27: return 0x30                                      // 0
        case 0x3A...0x45: return Int32(0x70 + (r - 0x3A))           // F1–F12
        default: break
        }
        switch k {
        case .keyboardReturnOrEnter: return 0x0D
        case .keyboardEscape: return 0x1B
        case .keyboardDeleteOrBackspace: return 0x08
        case .keyboardTab: return 0x09
        case .keyboardSpacebar: return 0x20
        case .keyboardRightArrow: return 0x27
        case .keyboardLeftArrow: return 0x25
        case .keyboardDownArrow: return 0x28
        case .keyboardUpArrow: return 0x26
        case .keyboardLeftShift: return 0xA0
        case .keyboardRightShift: return 0xA1
        case .keyboardLeftControl: return 0xA2
        case .keyboardRightControl: return 0xA3
        case .keyboardLeftAlt: return 0xA4
        case .keyboardRightAlt: return 0xA5
        case .keyboardHyphen: return 0xBD
        case .keyboardEqualSign: return 0xBB
        case .keyboardOpenBracket: return 0xDB
        case .keyboardCloseBracket: return 0xDD
        case .keyboardSemicolon: return 0xBA
        case .keyboardQuote: return 0xDE
        case .keyboardGraveAccentAndTilde: return 0xC0
        case .keyboardComma: return 0xBC
        case .keyboardPeriod: return 0xBE
        case .keyboardSlash: return 0xBF
        case .keyboardBackslash: return 0xDC
        default: return nil
        }
    }
}
