// SPDX-License-Identifier: GPL-3.0-or-later
// One play: prepare the game folder (Steam API emulator), quiet the rest of
// the app (Steam session, downloads), take JIT, start Wine, launch the title,
// route the controllers, and wait for it to end.
//
// Wine runs one session per app process (vendor/playport decision 0027/0029):
// after a game ends, iPort has to be reopened before the next one.

import Combine
import Foundation
import IPortCore
import SteamClientKit
import UIKit

@MainActor
final class GameSession: ObservableObject {
    static let shared = GameSession()

    enum Phase: Equatable {
        case idle
        case preparing(String)
        case waitingForJIT
        case running
        case paused
        case ended(exitCode: Int32, seconds: Double)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var game: InstalledGame?
    @Published var menuOpen = false
    @Published var editingLayout = false

    /// Wine's one session in this process has been used.
    private(set) var sessionUsed = false
    private var surfaceReady = false
    private var surfaceWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedAt: Date?
    private var menuSub: AnyCancellable?

    var runtimeAvailable: Bool { iport_runtime_available() != 0 }
    var jitEnabled: Bool { iport_jit_enabled() != 0 }
    var isPlaying: Bool { game != nil }

    private init() {
        menuSub = ControllerHub.shared.menuPressed.sink { [weak self] in
            guard let self, self.game != nil else { return }
            self.toggleMenu()
        }
    }

    // MARK: play

    func play(_ g: InstalledGame) {
        guard game == nil else { return }
        guard runtimeAvailable else {
            game = g
            phase = .failed("This build of iPort has no Windows runtime.\nBuild it with `make runtime && make ipa RUNTIME=1` (see README).")
            return
        }
        guard !sessionUsed else {
            game = g
            phase = .failed("Wine runs one game per app launch. Close iPort from the app switcher and open it again.")
            return
        }
        game = g
        phase = .preparing("Preparing \(g.name)…")
        Task { await run(g) }
    }

    private func run(_ g: InstalledGame) async {
        let settings = AppSettings.shared.launch(for: g.appID)
        let root = GameLibrary.shared.folder(g)

        // 1. The Steam API emulator in the game's folder (achievements, DLC, persona).
        phase = .preparing("Setting up Steam API…")
        let service = SteamAccount.shared.service
        let emu = await service.emulatorSettings(appID: g.appID)
        do {
            _ = try SteamAPISwap.ensure(.emulated, in: root,
                                        emulator: AppPaths.runtimeDir.appendingPathComponent("steamapi", isDirectory: true),
                                        settings: emu)
        } catch {
            AppLog.info("play", "steamapi: \(error)")
        }

        // 2. Nothing else competes for memory and CPU while the game runs.
        await service.suspendForLaunch()
        Downloads.shared.setSuspended(true)

        // 3. The plan.
        let screen = UIScreen.main.nativeBounds.size   // portrait-native pixels
        let plan: LaunchPlan
        do {
            plan = try LaunchPlanner.plan(installDir: g.installDir, entries: g.launch.map(\.info), arch: g.arch,
                                          settings: settings,
                                          screen: (Int(max(screen.width, screen.height)), Int(min(screen.width, screen.height))))
        } catch {
            phase = .failed(String(describing: error))
            return
        }
        for (k, v) in plan.environment where k.hasPrefix("MADEIRA_SCREEN") { setenv(k, v, 1) }
        ControllerHub.shared.setPolicy(settings.touch)

        // 4. The surface the swap chain draws to must exist before Wine starts.
        await waitForSurface()

        // 5. JIT, Wine, the session.
        if !jitEnabled { phase = .waitingForJIT }
        sessionUsed = true
        let waitMs = Int32(AppSettings.shared.values.jitWaitSeconds * 1000)
        let started: (Int32, String) = await Task.detached(priority: .userInitiated) {
            var err = [CChar](repeating: 0, count: 512)
            let rc = iport_runtime_start(AppPaths.runtimeDir.path, AppPaths.prefix.path, AppPaths.runtimeLog.path,
                                         896, waitMs, { line in if let line { NSLog("wine: %s", line) } },
                                         &err, err.count)
            return (rc, String(cString: err))
        }.value
        guard started.0 == 0 else {
            phase = .failed(started.1.isEmpty ? "The runtime did not start (\(started.0))." : started.1)
            return
        }

        phase = .preparing("Starting \(g.name)…")
        let rc = launch(plan)
        guard rc == 0 else {
            phase = .failed(rc == -5 ? "The game's executable was not found. Try Verify in the game's page."
                                     : "The game could not be started (\(rc)).")
            return
        }
        ControllerHub.shared.beginRouting()
        startedAt = Date()
        phase = .running
        await waitForExit()
    }

    private func launch(_ plan: LaunchPlan) -> Int32 {
        let args = plan.arguments.map { strdup($0) }
        let env = plan.environment.keys.sorted().map { strdup("\($0)=\(plan.environment[$0]!)") }
        defer { (args + env).forEach { free($0) } }
        let a = args.map { UnsafePointer($0) }
        let e = env.map { UnsafePointer($0) }
        return a.withUnsafeBufferPointer { ap in
            e.withUnsafeBufferPointer { ep in
                iport_runtime_launch(plan.dosPath, ap.baseAddress, Int32(a.count), ep.baseAddress, Int32(e.count),
                                     plan.dllOverlay)
            }
        }
    }

    private func waitForExit() async {
        let code: Int32 = await Task.detached(priority: .utility) {
            var code: Int32 = 0
            while true {
                let rc = iport_runtime_wait(1000, &code)
                if rc == 0 { return code }
                if rc < 0 { return -1 }
            }
        }.value
        ControllerHub.shared.routing = false
        let seconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        if let g = game { GameLibrary.shared.recordPlay(g.appID, seconds: seconds) }
        phase = .ended(exitCode: code, seconds: seconds)
        Downloads.shared.setSuspended(false)
    }

    // MARK: the surface

    func surfaceAttached(_ layer: CALayer) {
        iport_display_set_layer(Unmanaged.passUnretained(layer).toOpaque())
        surfaceReady = true
        surfaceWaiters.forEach { $0.resume() }
        surfaceWaiters.removeAll()
    }

    private func waitForSurface() async {
        if surfaceReady { return }
        await withCheckedContinuation { surfaceWaiters.append($0) }
    }

    // MARK: in-game menu

    func toggleMenu() {
        if menuOpen { resume() } else { pause() }
    }

    func pause() {
        guard phase == .running else { menuOpen = true; return }
        ControllerHub.shared.releaseAll()
        _ = iport_runtime_suspend(1)
        phase = .paused
        menuOpen = true
    }

    func resume() {
        menuOpen = false
        guard phase == .paused else { return }
        _ = iport_runtime_suspend(0)
        phase = .running
    }

    func quit() {
        menuOpen = false
        switch phase {
        case .running, .paused:
            if phase == .paused { _ = iport_runtime_suspend(0) }
            phase = .preparing("Closing…")
            Task.detached { _ = iport_runtime_quit(3000) }
        default:
            close()
        }
    }

    /// Back to the library. After a game ran, the process cannot host another:
    /// the library shows a reopen hint (sessionUsed).
    func close() {
        game = nil
        phase = .idle
        menuOpen = false
        editingLayout = false
        Downloads.shared.setSuspended(false)
    }

    func focus(_ active: Bool) {
        guard phase == .running || phase == .paused else { return }
        if !active { ControllerHub.shared.releaseAll() }
        iport_focus(active ? 1 : 0)
    }

    static func openStikDebug() {
        let id = Bundle.main.bundleIdentifier ?? "app.iport"
        if let url = URL(string: "stikjit://enable-jit?bundle-id=\(id)") {
            UIApplication.shared.open(url)
        }
    }
}
