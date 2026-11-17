// SPDX-License-Identifier: GPL-3.0-or-later
// What iPort keeps about each installed game, and per-game settings
// (launch options, touch layout), in small JSON files under Application Support.

import Foundation

public struct InstalledGame: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt32 { appID }
    public var appID: UInt32
    public var name: String
    /// Folder name under drive_c/Games.
    public var installDir: String
    public var buildID: UInt32?
    public var branch: String?
    public var arch: GameArch
    public var sizeOnDisk: UInt64
    public var installedAt: Date
    public var lastPlayed: Date?
    public var playSeconds: Double
    public var launch: [LaunchEntryRecord]

    public init(appID: UInt32, name: String, installDir: String, buildID: UInt32?, branch: String?, arch: GameArch,
                sizeOnDisk: UInt64, installedAt: Date = Date(), launch: [LaunchEntryRecord]) {
        self.appID = appID; self.name = name; self.installDir = installDir; self.buildID = buildID
        self.branch = branch; self.arch = arch; self.sizeOnDisk = sizeOnDisk; self.installedAt = installedAt
        self.lastPlayed = nil; self.playSeconds = 0; self.launch = launch
    }
}

/// LaunchEntryInfo, stored.
public struct LaunchEntryRecord: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: String?
    public var osList: [String]
    public var osArch: String?
    public var type: String?
    public var description: String?

    public init(_ e: LaunchEntryInfo) {
        executable = e.executable; arguments = e.arguments; osList = e.osList
        osArch = e.osArch; type = e.type; description = e.description
    }

    public var info: LaunchEntryInfo {
        LaunchEntryInfo(executable: executable, arguments: arguments, osList: osList, osArch: osArch,
                        type: type, description: description)
    }
}

/// A Codable dictionary in one JSON file, written atomically.
public final class JSONStore<Value: Codable>: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cache: [String: Value]

    public init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder.iport.decode([String: Value].self, from: d) {
            cache = v
        } else {
            cache = [:]
        }
    }

    public subscript(key: String) -> Value? {
        get { lock.lock(); defer { lock.unlock() }; return cache[key] }
        set {
            lock.lock()
            cache[key] = newValue
            let snapshot = cache
            lock.unlock()
            write(snapshot)
        }
    }

    public var all: [String: Value] { lock.lock(); defer { lock.unlock() }; return cache }

    private func write(_ v: [String: Value]) {
        guard let d = try? JSONEncoder.iport.encode(v) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    public static var iport: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    public static var iport: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
