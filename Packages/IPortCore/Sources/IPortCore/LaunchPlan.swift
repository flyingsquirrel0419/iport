// SPDX-License-Identifier: GPL-3.0-or-later
// From an installed game to the one call the runtime needs: which
// executable (as a Windows path inside the prefix), its arguments, and the
// environment its graphics backend and display want.

public enum GraphicsBackend: String, Codable, Sendable, CaseIterable {
    /// DXVK (D3D 8–11) + vkd3d-proton (D3D 12) on KosmicKrisp (Vulkan on Metal). Default.
    case vulkan
    /// DXMT: D3D 10/11 straight to Metal.
    case dxmt

    public var label: String {
        switch self {
        case .vulkan: return "Vulkan (DXVK / vkd3d-proton)"
        case .dxmt: return "Metal (DXMT)"
        }
    }

    /// Runtime directories whose DLLs go before Wine's own (comma-separated), nil for none.
    public var dllOverlay: String? {
        switch self {
        case .vulkan: return "vulkan"
        case .dxmt: return nil
        }
    }

    public var environment: [String: String] {
        switch self {
        case .vulkan: return ["DXVK_CONFIG": "dxvk.tilerMode = False"]
        case .dxmt: return [:]
        }
    }
}

public struct LaunchEntryInfo: Equatable, Sendable {
    public var executable: String
    public var arguments: String?
    public var osList: [String]
    public var osArch: String?
    /// Steam's launch type: nil / "default" / "none" for the game itself; "option1"… for alternatives.
    public var type: String?
    public var description: String?

    public init(executable: String, arguments: String? = nil, osList: [String] = [], osArch: String? = nil,
                type: String? = nil, description: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.osList = osList
        self.osArch = osArch; self.type = type; self.description = description
    }
}

public struct LaunchSettings: Codable, Equatable, Sendable {
    public var graphics: GraphicsBackend = .vulkan
    /// Render height the game is asked for (the display scales up); 0 = native.
    public var renderHeight: Int = 720
    public var showHUD: Bool = false
    public var extraArguments: String = ""
    public var extraEnvironment: [String: String] = [:]
    public var touch: TouchVisibility = .automatic
    public init() {}
}

public struct LaunchPlan: Equatable, Sendable {
    public var dosPath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var dllOverlay: String?
    public var arch: GameArch
}

public enum LaunchPlanner {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noWindowsLaunch
        public var description: String { "The game lists no Windows executable." }
    }

    /// The entry Steam would run on Windows for this architecture.
    public static func entry(_ entries: [LaunchEntryInfo], arch: GameArch) -> LaunchEntryInfo? {
        let win = entries.filter { e in
            e.osList.isEmpty || e.osList.contains { $0.lowercased() == "windows" }
        }.filter { !$0.executable.isEmpty }
        func isDefault(_ e: LaunchEntryInfo) -> Bool {
            guard let t = e.type?.lowercased(), !t.isEmpty else { return true }
            return t == "default" || t == "none"
        }
        func archRank(_ e: LaunchEntryInfo) -> Int {
            let a = (e.osArch ?? "").lowercased()
            switch arch {
            case .arm64: return ["arm64", "aarch64"].contains(a) ? 0 : a == "64" ? 1 : a.isEmpty ? 2 : 3
            case .x64: return a == "64" ? 0 : a.isEmpty ? 1 : 2
            case .x86: return a == "32" ? 0 : a.isEmpty ? 1 : 2
            }
        }
        return win.enumerated().min { l, r in
            let lk = (isDefault(l.element) ? 0 : 1, archRank(l.element), l.offset)
            let rk = (isDefault(r.element) ? 0 : 1, archRank(r.element), r.offset)
            return lk < rk
        }?.element
    }

    /// `C:\Games\<installDir>\<exe>` for the prefix's drive_c/Games.
    public static func dosPath(installDir: String, executable: String) -> String {
        let exe = executable.replacingAll("/", with: "\\").trimmingLeading("\\").trimmingLeading(".\\")
        return "C:\\Games\\" + installDir.replacingAll("/", with: "\\") + "\\" + exe
    }

    /// Splits a Steam argument string the way Windows' CommandLineToArgvW would for simple cases:
    /// spaces separate, double quotes group.
    public static func splitArguments(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false, has = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); has = true; continue }
            if ch == " " && !quoted {
                if has { out.append(cur); cur = ""; has = false }
                continue
            }
            cur.append(ch); has = true
        }
        if has { out.append(cur) }
        return out
    }

    public static func plan(installDir: String, entries: [LaunchEntryInfo], arch: GameArch,
                            settings: LaunchSettings, screen: (width: Int, height: Int)) throws -> LaunchPlan {
        guard let e = entry(entries, arch: arch) else { throw Failure.noWindowsLaunch }
        var args = splitArguments(e.arguments ?? "") + splitArguments(settings.extraArguments)
        var env = settings.graphics.environment
        // The virtual monitor Wine reports: the phone's aspect at the chosen render height.
        if settings.renderHeight > 0, screen.height > 0 {
            let h = min(settings.renderHeight, screen.height)
            let w = Int((Double(screen.width) * Double(h) / Double(screen.height)).rounded()) & ~1
            env["MADEIRA_SCREEN_W"] = String(w)
            env["MADEIRA_SCREEN_H"] = String(h)
        }
        if settings.showHUD {
            env[settings.graphics == .vulkan ? "DXVK_HUD" : "MTL_HUD_ENABLED"] = settings.graphics == .vulkan ? "fps,frametimes" : "1"
        }
        for (k, v) in settings.extraEnvironment { env[k] = v }
        args = args.filter { !$0.isEmpty }
        return LaunchPlan(dosPath: dosPath(installDir: installDir, executable: e.executable),
                          arguments: args, environment: env, dllOverlay: settings.graphics.dllOverlay, arch: arch)
    }
}

extension String {
    func replacingAll(_ a: Character, with b: String) -> String {
        var s = ""
        for c in self { if c == a { s += b } else { s.append(c) } }
        return s
    }
    func trimmingLeading(_ p: String) -> String {
        var s = self
        while s.hasPrefix(p) { s.removeFirst(p.count) }
        return s
    }
}
