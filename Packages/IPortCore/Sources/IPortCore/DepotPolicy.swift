// SPDX-License-Identifier: GPL-3.0-or-later
// Which build of a Steam game to download: ARM first.
//
// The phone is ARM64. A game whose Steam app ships Windows-on-ARM depots
// (osarch "arm64", or a depot named for ARM64) is downloaded as that build and
// runs as native aarch64 code under Wine, with no x86 translation. Every other
// game falls back to its x64 build (run through ARM64EC + FEX), then x86
// (run in a 32-bit WoW64 window). Architecture-neutral depots (data, shared
// content) always come along. Language and low-violence rules are the store's.

public enum GameArch: String, Codable, Sendable, CaseIterable {
    case arm64, x64, x86

    /// How the runtime runs it.
    public var runtimeNote: String {
        switch self {
        case .arm64: return "Native ARM64"
        case .x64: return "x64 via FEX (ARM64EC)"
        case .x86: return "x86 via FEX (WoW64)"
        }
    }
}

public struct DepotCandidate: Equatable, Sendable {
    public var id: UInt32
    public var name: String?
    public var osList: [String]
    public var osArch: String?
    /// Empty / nil for the default-language depot.
    public var language: String?
    public var lowViolence: Bool
    /// The depot has a public manifest (encrypted-only and branch-only depots do not).
    public var hasManifest: Bool
    /// Shared from another app (redistributables): never part of the title's own plan.
    public var fromOtherApp: Bool

    public init(id: UInt32, name: String? = nil, osList: [String] = [], osArch: String? = nil, language: String? = nil,
                lowViolence: Bool = false, hasManifest: Bool = true, fromOtherApp: Bool = false) {
        self.id = id; self.name = name; self.osList = osList; self.osArch = osArch
        self.language = language; self.lowViolence = lowViolence
        self.hasManifest = hasManifest; self.fromOtherApp = fromOtherApp
    }

    public var isWindows: Bool {
        osList.isEmpty || osList.contains { $0.lowercased() == "windows" }
    }

    /// The architecture the depot is for, or nil when it is neutral.
    public var arch: GameArch? {
        let a = (osArch ?? "").lowercased()
        let n = (name ?? "").lowercased()
        if ["arm64", "aarch64", "arm"].contains(a) || n.contains("arm64") || n.contains("aarch64") { return .arm64 }
        if a == "64" { return .x64 }
        if a == "32" { return .x86 }
        return nil
    }
}

public struct DepotPlan: Equatable, Sendable {
    public var arch: GameArch
    public var depots: [UInt32]
    /// True when the plan had to name depots explicitly (an ARM build was chosen);
    /// otherwise the store's own selection is used as is.
    public var explicit: Bool
}

public enum DepotPolicy {
    public struct Options: Equatable, Sendable {
        public var preferARM: Bool
        public var language: String
        public init(preferARM: Bool = true, language: String = "english") {
            self.preferARM = preferARM; self.language = language
        }
    }

    public static func plan(_ depots: [DepotCandidate], _ o: Options = .init()) -> DepotPlan {
        let usable = depots.filter { $0.isWindows && $0.hasManifest && !$0.fromOtherApp && !$0.lowViolence }
            .filter { d in
                guard let l = d.language, !l.isEmpty else { return true }
                return l.caseInsensitiveCompare(o.language) == .orderedSame
            }
        let archs = Set(usable.compactMap(\.arch))
        let neutral = usable.filter { $0.arch == nil }.map(\.id)
        if o.preferARM, archs.contains(.arm64) {
            let arm = usable.filter { $0.arch == .arm64 }.map(\.id)
            return DepotPlan(arch: .arm64, depots: (neutral + arm).sorted(), explicit: true)
        }
        // No ARM build: the store's selection (it already keeps 64-bit and neutral).
        let arch: GameArch = archs.contains(.x64) || archs.isEmpty ? .x64 : .x86
        let chosen = usable.filter { $0.arch == nil || $0.arch == arch }.map(\.id)
        return DepotPlan(arch: arch, depots: chosen.sorted(), explicit: false)
    }
}
