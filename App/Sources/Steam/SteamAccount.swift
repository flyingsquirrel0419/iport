// SPDX-License-Identifier: GPL-3.0-or-later
// The Steam account: sign-in (QR code from the Steam Mobile app, or account
// name + password + Steam Guard), the owned library and its artwork.
// The protocol work — CM WebSocket, auth sessions, PICS, depots — is
// SteamClientKit (vendor/playport app/SteamClient).

import CoreImage.CIFilterBuiltins
import Foundation
import SteamClientKit
import SwiftUI
import UIKit

@MainActor
final class SteamAccount: ObservableObject {
    static let shared = SteamAccount()

    enum SignInPhase: Equatable {
        case idle
        case waitingForCode
        case qr(QRCode)
        case scanned
        /// Credential sign-in: Steam wants an approval in the app and/or a code.
        case confirm(approveInApp: Bool, codeByEmail: Bool, takesCode: Bool)
        case codeRejected
        case failed(String)
    }

    let service: SteamService
    let art: ArtworkCache

    @Published private(set) var state: SteamService.AccountState = .unknown
    @Published private(set) var games: [SteamGame] = []
    @Published private(set) var refreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var signIn: SignInPhase = .idle
    @Published private(set) var personaName: String?

    private var signInTask: Task<Void, Never>?
    private var guardCodes: GuardCodeInbox?
    private var started = false
    /// Decoded artwork, by "appID:kind".
    private var images: [String: UIImage] = [:]

    var isSignedIn: Bool { if case .signedIn = state { return true }; return false }

    private init() {
        AppPaths.prepare()
        let log = AppLog.logger
        service = SteamService(backend: SteamSession(store: KeychainSecretStore(service: "app.iport.steam"), log: log),
                               log: log, stateDirectory: AppPaths.steamState)
        art = ArtworkCache(directory: AppPaths.art, log: log)
    }

    /// At launch: restore the stored session, then refresh the library.
    func start() {
        guard !started else { return }
        started = true
        Task {
            let stream = await service.observe()
            Task { for await s in stream { self.state = s; self.stateChanged() } }
            if let cached = await service.cachedGames() { games = sorted(cached.games) }
            state = await service.restoreIfPossible()
            stateChanged()
            if isSignedIn { await refresh(force: false) }
        }
    }

    private func stateChanged() {
        Downloads.shared.queue.conditionsChanged()
    }

    func refresh(force: Bool = true) async {
        guard isSignedIn, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            games = sorted(try await service.ownedGames(refresh: force))
            lastError = nil
            if personaName == nil { personaName = try? await service.backend.personaName() }
        } catch {
            lastError = InstallCopy.reason(error)
        }
    }

    private func sorted(_ g: [SteamGame]) -> [SteamGame] {
        g.filter { $0.info.isPlayable }.sorted { $0.info.name.localizedCaseInsensitiveCompare($1.info.name) == .orderedAscending }
    }

    func game(_ appID: UInt32) -> SteamGame? { games.first { $0.id == appID } }

    // MARK: sign-in

    func beginQR() { begin(.qr()) }

    func beginCredentials(account: String, password: String) {
        let inbox = GuardCodeInbox()
        guardCodes = inbox
        begin(.credentials(CredentialLogin(accountName: account, password: Secret(password), codes: inbox)))
    }

    func submitGuardCode(_ code: String) {
        guardCodes?.submit(code.trimmingCharacters(in: .whitespaces).uppercased())
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = .idle
    }

    private func begin(_ method: SignInMethod) {
        signInTask?.cancel()
        signIn = .waitingForCode
        let events = service.signIn(method: method)
        signInTask = Task {
            do {
                for try await e in events {
                    switch e {
                    case .code(let c): signIn = .qr(c)
                    case .scanned: signIn = .scanned
                    case .approved: signIn = .scanned
                    case .confirm(let allowed):
                        let c = CredentialSignInModel.Confirmation(allowed)
                        var email = false
                        if case .email? = c?.code { email = true }
                        signIn = .confirm(approveInApp: c?.approve != nil, codeByEmail: email, takesCode: c?.code != nil)
                    case .codeAccepted: signIn = .scanned
                    case .codeRejected: signIn = .codeRejected
                    case .signedIn:
                        signIn = .idle
                        state = await service.state
                        stateChanged()
                        await refresh(force: true)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                signIn = .failed(Self.describe(error))
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? SignInFailure {
        case .expired?: return "The code expired. Try again."
        case .denied?: return "The sign-in was declined on the other device."
        case .cancelled?: return "Cancelled."
        case .busy?: return "Another sign-in is running."
        case .wrongPassword?: return "Wrong account name or password."
        case .throttled?: return "Steam is refusing sign-ins from here for a while. Try again later."
        case .network(let s)?: return "Steam could not be reached (\(s))."
        case .failed(let s)?: return s
        case nil: return String(describing: error)
        }
    }

    func signOut() async {
        Downloads.shared.queue.setSuspended(true)
        _ = try? await service.signOut()
        state = await service.state
        games = []
        Downloads.shared.queue.setSuspended(false)
    }

    // MARK: artwork

    func image(_ app: SteamAppInfo, _ kind: ArtworkCache.Kind) async -> UIImage? {
        let key = "\(app.appID):\(kind.rawValue)"
        if let i = images[key] { return i }
        guard let url = try? await art.image(app, kind),
              let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        images[key] = img
        return img
    }

    static func qrImage(_ code: QRCode) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(code.payload.value.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Human wording for install and network failures.
enum InstallCopy {
    static func reason(_ error: Error) -> String {
        if error is CancellationError { return "Paused" }
        if let e = error as? SteamError { return e.description }
        return (error as NSError).localizedDescription
    }
}
