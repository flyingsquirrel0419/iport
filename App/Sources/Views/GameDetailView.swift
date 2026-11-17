// SPDX-License-Identifier: GPL-3.0-or-later
// A game's page: art, what build iPort will download (ARM or x86), size,
// Install / Update / Play / Pause / Verify / Repair / Uninstall, and its
// launch settings (graphics backend, render height, touch controls, arguments).

import IPortCore
import SteamClientKit
import SwiftUI

struct GameDetailView: View {
    let appID: UInt32
    @ObservedObject var steam = SteamAccount.shared
    @ObservedObject var library = GameLibrary.shared
    @ObservedObject var downloads = Downloads.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var confirmUninstall = false
    @State private var error: String?
    @State private var editingLayout = false

    private var store: SteamGame? { steam.game(appID) }
    private var installed: InstalledGame? { library.game(appID) }
    private var job: DownloadJob? { downloads.job(for: appID) }
    private var name: String { store?.info.name ?? installed?.name ?? "App \(appID)" }

    private var plannedArch: GameArch? {
        guard let info = store?.info else { return installed?.arch }
        return DepotPolicy.plan(info.depots.depots.map(SteamDownloadDriver.candidate),
                                .init(preferARM: settings.preferARM, language: settings.language)).arch
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    GameArt(appID: appID, kind: .hero).frame(height: 220)
                    LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name).font(.largeTitle.bold())
                        HStack(spacing: 8) {
                            if let a = plannedArch { badge(a.runtimeNote, a == .arm64 ? .green : .blue) }
                            if let s = installed?.sizeOnDisk ?? store?.info.installSize { badge(ByteFormat.string(s), .gray) }
                            if let c = store?.info.controllerSupport { badge("Controller: \(c)", .purple) }
                            if let dev = store?.info.developer { Text(dev).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(20)
                }
                actions.padding(20)
                if let job { DownloadRow(job: job).padding(.horizontal, 20) }
                if let installed { LaunchOptionsSection(game: installed).padding(20) }
            }
        }
        .ignoresSafeArea(edges: .top)
        .alert("Uninstall \(name)?", isPresented: $confirmUninstall) {
            Button("Uninstall", role: .destructive) {
                if let g = installed { do { try library.uninstall(g) } catch { self.error = "\(error)" } }
            }
        } message: { Text("The game's files are removed from this iPhone. Saves in the Wine prefix stay.") }
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
        .fullScreenCover(isPresented: $editingLayout) {
            LayoutEditorView(appID: appID) { editingLayout = false }
        }
    }

    private func badge(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
            .background(c.opacity(0.3), in: Capsule())
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 12) {
            if let job, job.state == .running || job.state == .queued {
                Button { downloads.pause(job) } label: { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(.bordered)
                Button(role: .destructive) { downloads.cancel(job) } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(.bordered)
            } else if let job, job.isActive {
                Button { downloads.resume(job) } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Button(role: .destructive) { downloads.cancel(job) } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(.bordered)
            } else if let g = installed {
                Button { GameSession.shared.play(g) } label: {
                    Label("Play", systemImage: "play.fill").font(.headline).padding(.horizontal, 16).padding(.vertical, 4)
                }.buttonStyle(.borderedProminent)
                if library.updateAvailable(g, steam: store) {
                    Button { enqueue() } label: { Label("Update", systemImage: "arrow.down.circle") }.buttonStyle(.bordered)
                }
                Menu {
                    Button { downloads.verify(appID, name: name) } label: { Label("Verify files", systemImage: "checkmark.shield") }
                    Button { downloads.repair(appID, name: name) } label: { Label("Repair", systemImage: "wrench") }
                    Button { editingLayout = true } label: { Label("Touch layout for this game", systemImage: "square.grid.3x3") }
                    Divider()
                    Button(role: .destructive) { confirmUninstall = true } label: { Label("Uninstall", systemImage: "trash") }
                } label: { Label("More", systemImage: "ellipsis.circle") }.buttonStyle(.bordered)
            } else if store != nil {
                Button { enqueue() } label: {
                    Label("Install", systemImage: "arrow.down.circle.fill").font(.headline).padding(.horizontal, 12).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!steam.isSignedIn)
                if let need = store?.info.installSize, let free = AppPaths.freeSpace() {
                    Text("\(ByteFormat.string(need)) needed · \(ByteFormat.string(free)) free")
                        .font(.footnote).foregroundStyle(need > free ? .red : .secondary)
                }
            }
            Spacer()
        }
    }

    private func enqueue() {
        downloads.install(SteamGameRef(appID: appID, name: name, size: store?.info.installSize))
    }
}

struct LaunchOptionsSection: View {
    let game: InstalledGame
    @ObservedObject var settings = AppSettings.shared
    @State private var s: LaunchSettings = .init()
    @State private var env = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Launch settings").font(.title3.bold())
            Picker("Graphics", selection: $s.graphics) {
                ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.label) }
            }
            Picker("Render height", selection: $s.renderHeight) {
                ForEach([480, 540, 720, 900, 1080, 0], id: \.self) { Text($0 == 0 ? "Native" : "\($0)p") }
            }
            Picker("Touch controls", selection: $s.touch) {
                ForEach(TouchVisibility.allCases, id: \.self) { Text($0.label) }
            }
            Toggle("Performance HUD", isOn: $s.showHUD)
            TextField("Extra arguments", text: $s.extraArguments).textFieldStyle(.roundedBorder)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            TextField("Environment (NAME=value; …)", text: $env).textFieldStyle(.roundedBorder)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Text("Executable: " + (LaunchPlanner.entry(game.launch.map(\.info), arch: game.arch)?.executable ?? "—"))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .pickerStyle(.menu)
        .onAppear {
            s = settings.launch(for: game.appID)
            env = s.extraEnvironment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }
        .onChange(of: s) { _, v in settings.setLaunch(v, for: game.appID) }
        .onChange(of: env) { _, v in
            var d: [String: String] = [:]
            for part in v.split(separator: ";") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2, !kv[0].isEmpty { d[kv[0]] = kv[1] }
            }
            s.extraEnvironment = d
        }
    }
}
