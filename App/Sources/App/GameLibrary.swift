// SPDX-License-Identifier: GPL-3.0-or-later
// Installed games, app settings, per-game launch settings and touch layouts.

import Foundation
import IPortCore
import SteamClientKit

@MainActor
final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    @Published private(set) var installed: [InstalledGame] = []
    private let store = JSONStore<InstalledGame>(url: AppPaths.library)

    private init() { reload() }

    func reload() {
        // Drop records whose folder is gone (deleted from Files, or a failed uninstall).
        for (k, g) in store.all where !FileManager.default.fileExists(atPath: folder(g).path) {
            store[k] = nil
        }
        installed = store.all.values.sorted { ($0.lastPlayed ?? $0.installedAt) > ($1.lastPlayed ?? $1.installedAt) }
    }

    func game(_ appID: UInt32) -> InstalledGame? { store["\(appID)"] }

    func folder(_ g: InstalledGame) -> URL {
        AppPaths.layout.gamesRoot.appendingPathComponent(g.installDir, isDirectory: true)
    }

    func recordInstall(_ g: InstalledGame) {
        var g = g
        if let old = store["\(g.appID)"] { g.lastPlayed = old.lastPlayed; g.playSeconds = old.playSeconds }
        store["\(g.appID)"] = g
        reload()
    }

    func recordPlay(_ appID: UInt32, seconds: Double) {
        guard var g = store["\(appID)"] else { return }
        g.lastPlayed = Date()
        g.playSeconds += seconds
        store["\(appID)"] = g
        reload()
    }

    func uninstall(_ g: InstalledGame) throws {
        let installer = TitleInstaller(layout: AppPaths.layout, session: nil, log: AppLog.logger)
        try installer.uninstall(installDir: g.installDir, appID: g.appID)
        store["\(g.appID)"] = nil
        reload()
    }

    /// Steam published a newer build than the installed one.
    func updateAvailable(_ g: InstalledGame, steam: SteamGame?) -> Bool {
        guard let steam, let have = g.buildID,
              let now = steam.info.depots.buildID(branch: g.branch ?? Branch.publicName) else { return false }
        return now != have
    }
}

/// App-wide settings.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    struct Values: Codable, Equatable {
        var preferARM = true
        var language = "english"
        var cellularDownloads = false
        var touchVisibility: TouchVisibility = .automatic
        var touchRevealSeconds: Double = 4
        var defaultLaunch = LaunchSettings()
        var jitWaitSeconds: Double = 60
        var haptics = true
    }

    @Published var values: Values { didSet { save() } }

    private static let key = "settings"
    private let store = JSONStore<Values>(url: AppPaths.settings)
    private let games = JSONStore<LaunchSettings>(url: AppPaths.support.appendingPathComponent("launch.json"))

    private init() { values = JSONStore<Values>(url: AppPaths.settings)[Self.key] ?? Values() }
    private func save() { store[Self.key] = values }

    var preferARM: Bool { values.preferARM }
    var language: String { values.language }
    var cellularDownloads: Bool { values.cellularDownloads }

    func launch(for appID: UInt32) -> LaunchSettings { games["\(appID)"] ?? values.defaultLaunch }
    func setLaunch(_ s: LaunchSettings, for appID: UInt32) { games["\(appID)"] = s; objectWillChange.send() }
}

/// Touch layouts: one global, optionally one per game.
@MainActor
final class LayoutStore: ObservableObject {
    static let shared = LayoutStore()
    private let store = JSONStore<TouchLayout>(url: AppPaths.layouts)

    func layout(for appID: UInt32?) -> TouchLayout {
        if let appID, let l = store["\(appID)"] { return l }
        return store["global"] ?? .xbox
    }

    func save(_ l: TouchLayout, for appID: UInt32?) {
        store[appID.map { "\($0)" } ?? "global"] = l
        objectWillChange.send()
    }

    func reset(for appID: UInt32?) {
        store[appID.map { "\($0)" } ?? "global"] = nil
        objectWillChange.send()
    }

    func hasOwn(_ appID: UInt32) -> Bool { store["\(appID)"] != nil }
}
