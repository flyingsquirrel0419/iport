// SPDX-License-Identifier: GPL-3.0-or-later
// The download manager's Steam driver: install, update, repair and verify
// through SteamClientKit's TitleInstaller (manifest-validated, chunk-journalled,
// resumable, one atomic rename at the end), with iPort's ARM-first depot policy.

import Foundation
import IPortCore
import SteamClientKit

final class SteamDownloadDriver: DownloadDriver, @unchecked Sendable {
    let service: SteamService
    let layout: InstallLayout

    init(service: SteamService, layout: InstallLayout) {
        self.service = service
        self.layout = layout
    }

    @MainActor var blocker: String? {
        guard SteamAccount.shared.isSignedIn else { return "Sign in to Steam" }
        let net = NetworkMonitor.shared
        if !net.connected { return "Waiting for a connection" }
        if net.expensive && !AppSettings.shared.cellularDownloads { return "Waiting for Wi-Fi" }
        return nil
    }

    struct VerifyFailed: Error, CustomStringConvertible {
        var bad: Int
        var description: String { "\(bad) file(s) failed verification — run Repair" }
    }

    func run(_ job: DownloadJob, progress: @escaping @Sendable (JobProgress) -> Void) async throws {
        let installer = try await service.titleInstaller(layout: layout)
        var engine = InstallEngine.Options()
        engine.progressInterval = 0.5
        engine.reserveBytes = 512 << 20   // keep half a GB for the prefix and saves
        let map: @Sendable (InstallEngine.Progress) -> Void = { p in
            progress(JobProgress(bytesDone: p.bytesDone, bytesTotal: p.bytesTotal,
                                 filesDone: p.filesVerified, filesTotal: p.filesTotal))
        }
        let say: @Sendable (String) -> Void = { line in
            if !line.hasPrefix("progress:") { AppLog.info("install", line) }
        }

        switch job.kind {
        case .install, .update:
            let info = try await service.appInfo(job.appID)
            let prefs = await MainActor.run { (AppSettings.shared.preferARM, AppSettings.shared.language) }
            let plan = DepotPolicy.plan(info.depots.depots.map(Self.candidate),
                                        .init(preferARM: prefs.0, language: prefs.1))
            var selection = DepotSelection.Options(language: prefs.1)
            if plan.explicit { selection.explicit = plan.depots }
            say("depots: \(plan.arch.rawValue) \(plan.depots) explicit=\(plan.explicit)")
            let r = try await installer.install(.init(appID: job.appID, selection: selection, branch: job.branch, engine: engine),
                                                progress: map, say: say)
            let receipt = r.receipt
            let entries = info.launch.map {
                LaunchEntryInfo(executable: $0.executable, arguments: $0.arguments, osList: $0.osList,
                                osArch: $0.osArch, type: $0.type, description: $0.description)
            }
            let game = InstalledGame(appID: job.appID, name: info.name, installDir: receipt.installDir,
                                     buildID: receipt.buildID, branch: receipt.branch, arch: plan.arch,
                                     sizeOnDisk: receipt.bytes, launch: entries.map(LaunchEntryRecord.init))
            await MainActor.run { GameLibrary.shared.recordInstall(game) }
        case .repair:
            let report = try await installer.repair(appID: job.appID, engine: engine, progress: map, say: say)
            if !report.ok { throw VerifyFailed(bad: report.bad.count) }
        case .verify:
            let report = try await installer.verify(appID: job.appID)
            if !report.ok { throw VerifyFailed(bad: report.bad.count) }
        }
    }

    func discard(_ job: DownloadJob) async {
        let installer = TitleInstaller(layout: layout, session: nil, log: AppLog.logger)
        installer.discardStage(appID: job.appID)
    }

    static func candidate(_ d: DepotInfo) -> DepotCandidate {
        DepotCandidate(id: d.depotID, name: d.name, osList: d.osList, osArch: d.osArch, language: d.language,
                       lowViolence: d.lowViolence, hasManifest: d.publicManifestGID != nil,
                       fromOtherApp: d.depotFromApp != nil && d.sharesInstallDir != true)
    }
}
