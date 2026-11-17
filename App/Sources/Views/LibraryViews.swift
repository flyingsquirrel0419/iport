// SPDX-License-Identifier: GPL-3.0-or-later
// Home (continue playing, downloads in progress) and Library (every owned
// Windows game, installed or not, searchable).

import IPortCore
import SteamClientKit
import SwiftUI

typealias ArtworkCacheKind = ArtworkCache.Kind

struct HomeView: View {
    @Binding var tab: Tab
    @ObservedObject var library = GameLibrary.shared
    @ObservedObject var downloads = Downloads.shared
    @ObservedObject var steam = SteamAccount.shared
    @ObservedObject var hub = ControllerHub.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let g = library.installed.first {
                    NavigationLink(value: g.appID) { ContinueCard(game: g) }.buttonStyle(.plain)
                }
                if !downloads.active.isEmpty {
                    section("Downloading") {
                        ForEach(downloads.active.prefix(3)) { DownloadRow(job: $0) }
                    }
                }
                if library.installed.count > 1 {
                    section("Installed") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(library.installed.dropFirst()) { g in
                                    NavigationLink(value: g.appID) { CapsuleTile(appID: g.appID, name: g.name, installed: true) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                if library.installed.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No games installed yet").font(.headline)
                        Text("Pick a game in your Library to download it to this iPhone.").foregroundStyle(.secondary)
                        Button("Open Library") { tab = .library }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
        }
        .navigationDestination(for: UInt32.self) { GameDetailView(appID: $0) }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("iPort").font(.largeTitle.bold())
                Text(statusLine).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Label(hub.connected.isEmpty ? "Touch controls" : "\(hub.connected.count) controller(s)",
                  systemImage: hub.connected.isEmpty ? "hand.tap" : "gamecontroller.fill")
                .font(.footnote).padding(8).background(.thinMaterial, in: Capsule())
            if !GameSession.shared.runtimeAvailable {
                Label("No runtime", systemImage: "exclamationmark.triangle").font(.footnote)
                    .padding(8).background(.orange.opacity(0.25), in: Capsule())
            }
        }
    }

    private var statusLine: String {
        switch steam.state {
        case .signedIn(let a): return "Steam · \(steam.personaName ?? a.accountTag)"
        case .offline(_, let r): return "Steam offline · \(r)"
        case .restoring: return "Connecting to Steam…"
        case .expired: return "Steam sign-in expired"
        default: return "Not signed in to Steam"
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            c()
        }
    }
}

struct ContinueCard: View {
    let game: InstalledGame
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GameArt(appID: game.appID, kind: .hero).frame(height: 190)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.lastPlayed == nil ? "Ready to play" : "Continue playing").font(.caption).foregroundStyle(.secondary)
                    Text(game.name).font(.title2.bold())
                    Text(game.arch.runtimeNote).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { GameSession.shared.play(game) } label: {
                    Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 10)
                }.buttonStyle(.borderedProminent)
            }.padding(18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct CapsuleTile: View {
    let appID: UInt32
    let name: String
    let installed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GameArt(appID: appID, kind: .capsule)
                .frame(width: 120, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if installed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).padding(6)
                    }
                }
            Text(name).font(.caption).lineLimit(2).frame(width: 120, alignment: .leading)
        }
    }
}

struct LibraryView: View {
    enum Filter: String, CaseIterable { case all = "All", installed = "Installed", arm = "ARM builds" }

    @ObservedObject var steam = SteamAccount.shared
    @ObservedObject var library = GameLibrary.shared
    @State private var search = ""
    @State private var filter: Filter = .all

    struct Entry: Identifiable { var appID: UInt32; var name: String; var id: UInt32 { appID } }

    private var games: [Entry] {
        var list = steam.games.map { Entry(appID: $0.id, name: $0.info.name) }
        // Installed games Steam no longer lists (offline, or a family-share that ended) still show.
        for g in library.installed where !list.contains(where: { $0.appID == g.appID }) {
            list.append(Entry(appID: g.appID, name: g.name))
        }
        switch filter {
        case .all: break
        case .installed: list = list.filter { library.game($0.appID) != nil }
        case .arm: list = list.filter { isARM($0.appID) }
        }
        if !search.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(search) } }
        return list
    }

    private func isARM(_ id: UInt32) -> Bool {
        if library.game(id)?.arch == .arm64 { return true }
        guard let depots = steam.game(id)?.info.depots.depots else { return false }
        return depots.map(SteamDownloadDriver.candidate).contains { $0.arch == .arm64 }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 140), spacing: 16)], spacing: 18) {
                ForEach(games) { g in
                    NavigationLink(value: g.appID) {
                        CapsuleTile(appID: g.appID, name: g.name, installed: library.game(g.appID) != nil)
                    }.buttonStyle(.plain)
                }
            }
            .padding(20)
            if steam.games.isEmpty {
                Text(steam.isSignedIn ? (steam.refreshing ? "Loading your library…" : "No Windows games found.")
                                      : "Sign in to Steam in Settings to see your games.")
                    .foregroundStyle(.secondary).padding(40)
            }
        }
        .navigationTitle("Library")
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }.pickerStyle(.segmented).frame(width: 320)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await steam.refresh() } } label: {
                    if steam.refreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .refreshable { await steam.refresh() }
        .navigationDestination(for: UInt32.self) { GameDetailView(appID: $0) }
    }
}
