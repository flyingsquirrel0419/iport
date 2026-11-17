// SPDX-License-Identifier: GPL-3.0-or-later
// Where iPort keeps things inside its container.
//
//   Documents/prefix/                the Wine prefix (C: is prefix/drive_c)
//   Documents/prefix/drive_c/Games/  installed games (one folder each)
//   Library/titles/.staging/         downloads in progress (journalled, resumable)
//   Library/Application Support/iPort/
//       steam/        Steam's non-secret state (owned-games cache, renewal record)
//       art/          store artwork
//       state/        install receipts and manifests (SteamClientKit)
//       library.json  installed games;  downloads.json  the queue
//       layouts.json  touch layouts;    settings.json   per-game launch settings
//   Library/Logs/iPort/runtime.log   Wine's log

import Foundation
import SteamClientKit

enum AppPaths {
    static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    static let documents = home.appendingPathComponent("Documents", isDirectory: true)
    static let prefix = documents.appendingPathComponent("prefix", isDirectory: true)
    static let support = home.appendingPathComponent("Library/Application Support/iPort", isDirectory: true)
    static let logs = home.appendingPathComponent("Library/Logs/iPort", isDirectory: true)

    static let layout = InstallLayout(
        stagingRoot: home.appendingPathComponent("Library/titles/.staging", isDirectory: true),
        gamesRoot: prefix.appendingPathComponent("drive_c/Games", isDirectory: true),
        stateRoot: support.appendingPathComponent("state", isDirectory: true))

    static let steamState = support.appendingPathComponent("steam", isDirectory: true)
    static let art = support.appendingPathComponent("art", isDirectory: true)
    static let library = support.appendingPathComponent("library.json")
    static let downloads = support.appendingPathComponent("downloads.json")
    static let layouts = support.appendingPathComponent("layouts.json")
    static let settings = support.appendingPathComponent("settings.json")
    static let runtimeLog = logs.appendingPathComponent("runtime.log")

    /// The bundle holds the runtime's guest files at its root (aarch64-windows/, nls/ …).
    static let runtimeDir = Bundle.main.bundleURL

    static func prepare() {
        for d in [documents, prefix, support, logs, layout.stagingRoot, layout.gamesRoot, layout.stateRoot, steamState, art] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        // Games are big and re-downloadable: keep them out of iCloud / iTunes backups.
        var games = layout.gamesRoot
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? games.setResourceValues(v)
    }

    static func freeSpace() -> UInt64? {
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }
}

/// One app-wide log: the console, and the file Wine also writes.
enum AppLog {
    static let logger = Logger { line in
        NSLog("%@", line)
    }
    static func info(_ category: String, _ message: String) { logger.info(category, message) }
}
