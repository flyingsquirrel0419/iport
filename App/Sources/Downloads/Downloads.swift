// SPDX-License-Identifier: GPL-3.0-or-later
// The download manager as the UI sees it: IPortCore's DownloadQueue with
// Steam's driver, published for SwiftUI, kept alive in the background as long
// as iOS allows, and with the screen kept awake while a download runs in front.

import Combine
import Foundation
import IPortCore
import Network
import UIKit
import UserNotifications

@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()

    let queue: DownloadQueue
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var suspended = false

    private var background: UIBackgroundTaskIdentifier = .invalid

    private init() {
        AppPaths.prepare()
        let driver = SteamDownloadDriver(service: SteamAccount.shared.service, layout: AppPaths.layout)
        queue = DownloadQueue(driver: driver, store: AppPaths.downloads)
        queue.onChange = { [weak self] in self?.sync() }
        queue.onFinished = { job in
            GameLibrary.shared.reload()
            Notifier.downloadFinished(job)
        }
        sync()
    }

    private func sync() {
        jobs = queue.jobs
        suspended = queue.suspended
        let running = queue.running != nil
        UIApplication.shared.isIdleTimerDisabled = running
        if running { holdBackground() } else { releaseBackground() }
    }

    var active: [DownloadJob] { jobs.filter(\.isActive) }
    var finished: [DownloadJob] { jobs.filter { !$0.isActive } }

    func job(for appID: UInt32) -> DownloadJob? { jobs.first { $0.appID == appID && $0.isActive } }

    // MARK: actions

    func install(_ game: SteamGameRef, branch: String? = nil) {
        let installed = GameLibrary.shared.game(game.appID) != nil
        queue.enqueue(DownloadJob(appID: game.appID, name: game.name, kind: installed ? .update : .install,
                                  branch: branch, bytesTotal: installed ? 0 : (game.size ?? 0)))
    }
    func repair(_ appID: UInt32, name: String) { queue.enqueue(DownloadJob(appID: appID, name: name, kind: .repair)) }
    func verify(_ appID: UInt32, name: String) { queue.enqueue(DownloadJob(appID: appID, name: name, kind: .verify)) }
    func pause(_ j: DownloadJob) { queue.pause(j.id) }
    func resume(_ j: DownloadJob) { queue.resume(j.id) }
    func cancel(_ j: DownloadJob) { queue.cancel(j.id) }
    func runNext(_ j: DownloadJob) { queue.runNext(j.id) }
    func move(_ j: DownloadJob, by d: Int) { queue.move(j.id, by: d) }
    func setSuspended(_ on: Bool) { queue.setSuspended(on) }
    func clearFinished() { queue.clearFinished() }

    // MARK: background

    /// iOS gives a backgrounded app a few minutes; the journal makes the rest resume on return.
    private func holdBackground() {
        guard background == .invalid else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "iPort download") { [weak self] in
            MainActor.assumeIsolated {
                // Out of time: pause cleanly (journalled) and resume when back in front.
                guard let self else { return }
                if let r = self.queue.running { self.queue.pause(r.id); self.resumeOnForeground.insert(r.id) }
                self.releaseBackground()
            }
        }
    }

    private func releaseBackground() {
        guard background != .invalid else { return }
        UIApplication.shared.endBackgroundTask(background)
        background = .invalid
    }

    private var resumeOnForeground: Set<String> = []

    func enteredForeground() {
        for id in resumeOnForeground { queue.resume(id) }
        resumeOnForeground.removeAll()
        queue.conditionsChanged()
    }
}

/// What the queue needs to know about a store game to enqueue it.
struct SteamGameRef {
    var appID: UInt32
    var name: String
    var size: UInt64?
}

/// Connectivity for the "Waiting for Wi-Fi" rule.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published private(set) var connected = true
    @Published private(set) var expensive = false
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in
                let s = NetworkMonitor.shared
                s.connected = path.status == .satisfied
                s.expensive = path.isExpensive
                Downloads.shared.queue.conditionsChanged()
            }
        }
        monitor.start(queue: DispatchQueue(label: "iport.network"))
    }
}

/// A local notification when a download finishes in the background.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func downloadFinished(_ job: DownloadJob) {
        guard UIApplication.shared.applicationState != .active else { return }
        let c = UNMutableNotificationContent()
        c.title = job.name
        c.body = job.kind == .install ? "Ready to play." : "Finished."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: job.id, content: c, trigger: nil))
    }
}
