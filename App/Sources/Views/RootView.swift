// SPDX-License-Identifier: GPL-3.0-or-later
// The shell: a left rail (Home, Library, Downloads, Settings) in landscape,
// and the play screen over everything while a game runs.

import IPortCore
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case home, library, downloads, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.grid.2x2.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootView: View {
    @State private var tab: Tab = .home
    @ObservedObject private var session = GameSession.shared
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var steam = SteamAccount.shared

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                rail
                Divider()
                NavigationStack {
                    content
                }
            }
            .sheet(isPresented: Binding(get: { needsSignIn }, set: { if !$0 { dismissedSignIn = true } })) {
                SignInView()
            }
            if session.isPlaying {
                PlayView().transition(.opacity).zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.isPlaying)
    }

    @State private var dismissedSignIn = false
    private var needsSignIn: Bool {
        if dismissedSignIn { return false }
        switch steam.state {
        case .signedOut, .expired: return tab == .home || tab == .library
        default: return false
        }
    }

    private var rail: some View {
        VStack(spacing: 6) {
            Image(systemName: "gamecontroller.fill").font(.title2).padding(.vertical, 14)
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: t.icon).font(.title3)
                            if t == .downloads && !downloads.active.isEmpty {
                                Text("\(downloads.active.count)").font(.caption2.bold())
                                    .padding(3).background(Circle().fill(.red)).offset(x: 10, y: -8)
                            }
                        }
                        Text(t.title).font(.caption2)
                    }
                    .frame(width: 76, height: 56)
                    .foregroundStyle(tab == t ? Color.accentColor : .secondary)
                    .background(tab == t ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .background(Color(white: 0.06))
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .home: HomeView(tab: $tab)
        case .library: LibraryView()
        case .downloads: DownloadsView()
        case .settings: SettingsView()
        }
    }
}

/// Store artwork, loaded through Steam's art cache.
struct GameArt: View {
    let appID: UInt32
    var kind: ArtKind = .capsule
    @State private var image: UIImage?

    enum ArtKind { case capsule, hero, header }

    var body: some View {
        ZStack {
            Rectangle().fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "gamecontroller").font(.largeTitle).foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: appID) {
            guard let info = SteamAccount.shared.game(appID)?.info else { return }
            let k: ArtworkCacheKind = kind == .capsule ? .capsule : kind == .hero ? .hero : .header
            image = await SteamAccount.shared.image(info, k)
        }
    }
}
