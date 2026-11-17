// SPDX-License-Identifier: GPL-3.0-or-later
// Settings (account, downloads, controls, runtime/JIT, storage) and the
// Steam sign-in sheet (QR code from the Steam Mobile app, or password + Guard).

import IPortCore
import SteamClientKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var steam = SteamAccount.shared
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var hub = ControllerHub.shared
    @State private var signIn = false
    @State private var editLayout = false

    var body: some View {
        Form {
            Section("Steam") {
                HStack {
                    Text(accountLine)
                    Spacer()
                    if steam.state.account != nil {
                        Button("Sign out", role: .destructive) { Task { await steam.signOut() } }
                    } else {
                        Button("Sign in") { signIn = true }.buttonStyle(.borderedProminent)
                    }
                }
                Picker("Game language", selection: $settings.values.language) {
                    ForEach(["english", "koreana", "japanese", "schinese", "tchinese", "german", "french", "spanish", "russian"], id: \.self) {
                        Text($0.capitalized)
                    }
                }
            }
            Section {
                Toggle("Prefer ARM64 builds", isOn: $settings.values.preferARM)
                Toggle("Download over cellular", isOn: $settings.values.cellularDownloads)
            } header: { Text("Downloads") } footer: {
                Text("When a game ships a Windows-on-ARM build, iPort downloads it and runs it natively. Otherwise the x64 build runs through FEX.")
            }
            Section {
                Picker("Touch controller", selection: $settings.values.touchVisibility) {
                    ForEach(TouchVisibility.allCases, id: \.self) { Text($0.label) }
                }
                Stepper("Reveal on tap: \(Int(settings.values.touchRevealSeconds)) s",
                        value: $settings.values.touchRevealSeconds, in: 0...15)
                Toggle("Haptics", isOn: $settings.values.haptics)
                Button("Edit touch layout") { editLayout = true }
                ForEach(hub.connected.sorted { $0.key < $1.key }, id: \.key) { e in
                    Label("Player \(e.key + 1): \(e.value)", systemImage: "gamecontroller.fill")
                }
                if hub.connected.isEmpty {
                    Text("No controller connected. Pair an Xbox, PlayStation or MFi controller in iOS Settings › Bluetooth.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Controls") }
            Section("Default launch settings") {
                Picker("Graphics", selection: $settings.values.defaultLaunch.graphics) {
                    ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.label) }
                }
                Picker("Render height", selection: $settings.values.defaultLaunch.renderHeight) {
                    ForEach([480, 540, 720, 900, 1080, 0], id: \.self) { Text($0 == 0 ? "Native" : "\($0)p") }
                }
            }
            Section {
                LabeledContent("Windows runtime", value: String(cString: iport_runtime_describe()))
                LabeledContent("JIT", value: iport_jit_enabled() != 0 ? "Enabled" : "Not enabled")
                Stepper("Wait for JIT: \(Int(settings.values.jitWaitSeconds)) s", value: $settings.values.jitWaitSeconds, in: 10...300, step: 10)
                Button("Open StikDebug") { GameSession.openStikDebug() }
            } header: { Text("Runtime") } footer: {
                Text("Games need JIT. Enable it with StikDebug (with LocalDevVPN) or launch iPort from LiveContainer with JIT. Install with a signer that keeps the Increased Memory Limit entitlement.")
            }
            Section("Storage") {
                if let free = AppPaths.freeSpace() { LabeledContent("Free", value: ByteFormat.string(free)) }
                LabeledContent("Installed games", value: "\(GameLibrary.shared.installed.count)")
                LabeledContent("Games folder", value: "Files › iPort › prefix › drive_c › Games")
            }
            Section("About") {
                Text("iPort is free software under the GPL-3.0-or-later. It builds on Playport (playportdev/playport), Wine, FEX, DXVK, vkd3d-proton, DXMT and Mesa KosmicKrisp.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $signIn) { SignInView() }
        .fullScreenCover(isPresented: $editLayout) { LayoutEditorView(appID: nil) { editLayout = false } }
        .onChange(of: settings.values) { _, _ in hub.applySettings(); Downloads.shared.queue.conditionsChanged() }
    }

    private var accountLine: String {
        switch steam.state {
        case .signedIn(let a): return "Signed in · \(steam.personaName ?? a.accountTag)"
        case .offline(let a, _): return "Offline · \(a.accountTag)"
        case .restoring: return "Connecting…"
        case .expired: return "Sign-in expired"
        case .pairing: return "Signing in…"
        default: return "Not signed in"
        }
    }
}

struct SignInView: View {
    @ObservedObject var steam = SteamAccount.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("", selection: $mode) {
                        Text("QR code").tag(0)
                        Text("Password").tag(1)
                    }.pickerStyle(.segmented)
                    if mode == 0 {
                        Text("Open the Steam app on another device, tap the shield (Steam Guard) and scan this code.")
                            .foregroundStyle(.secondary)
                        Button("Show code") { steam.beginQR() }.buttonStyle(.borderedProminent)
                    } else {
                        TextField("Account name", text: $account).textContentType(.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password).textContentType(.password)
                        Button("Sign in") { steam.beginCredentials(account: account, password: password); password = "" }
                            .buttonStyle(.borderedProminent).disabled(account.isEmpty || password.isEmpty)
                    }
                    phaseView
                    Spacer()
                }
                .frame(maxWidth: 380)
                qr
            }
            .padding(24)
            .navigationTitle("Sign in to Steam")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { steam.cancelSignIn(); dismiss() } }
            }
            .onChange(of: steam.isSignedIn) { _, on in if on { dismiss() } }
        }
    }

    @ViewBuilder private var qr: some View {
        if case .qr(let c) = steam.signIn, let img = SteamAccount.qrImage(c) {
            VStack {
                Image(uiImage: img).interpolation(.none).resizable().frame(width: 220, height: 220)
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12))
                Text(c.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var phaseView: some View {
        switch steam.signIn {
        case .waitingForCode: ProgressView()
        case .scanned: Label("Approve the sign-in on your other device…", systemImage: "iphone.radiowaves.left.and.right")
        case .confirm(let approve, let email, let takesCode):
            VStack(alignment: .leading, spacing: 8) {
                if approve { Text("Approve this sign-in in the Steam Mobile app,") }
                if takesCode {
                    Text(email ? "or enter the code Steam emailed you:" : "or enter the Steam Guard code:")
                    HStack {
                        TextField("Code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder).frame(width: 140)
                        Button("Submit") { steam.submitGuardCode(code); code = "" }.disabled(code.count < 5)
                    }
                }
            }
        case .codeRejected: Text("That code was not accepted. Try again.").foregroundStyle(.red)
        case .failed(let s): Text(s).foregroundStyle(.red)
        default: EmptyView()
        }
    }
}
