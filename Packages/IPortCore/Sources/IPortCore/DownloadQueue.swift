// SPDX-License-Identifier: GPL-3.0-or-later
// The download manager: one queue for every install, update, repair and
// verify, one job running at a time (the CDN pipe and the flash are the
// bottleneck, not the CPU), pause / resume / cancel / reorder, and a record
// on disk so the queue survives the app being killed. The work itself is a
// `DownloadDriver` (Steam's TitleInstaller in the app; a fake in the tests)
// whose installs are journalled, so a paused or killed job resumes where it was.

import Foundation

public enum JobKind: String, Codable, Sendable { case install, update, repair, verify }

public struct JobProgress: Codable, Equatable, Sendable {
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    public var filesDone: Int
    public var filesTotal: Int
    public init(bytesDone: UInt64 = 0, bytesTotal: UInt64 = 0, filesDone: Int = 0, filesTotal: Int = 0) {
        self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
        self.filesDone = filesDone; self.filesTotal = filesTotal
    }
    public var fraction: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }
}

public enum JobState: Codable, Equatable, Sendable {
    case queued
    case running
    case paused
    /// Waiting on something outside the queue (sign-in, network, Wi-Fi).
    case blocked(String)
    case failed(String)
    case done
}

public struct DownloadJob: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(appID):\(kind.rawValue)" }
    public var appID: UInt32
    public var name: String
    public var kind: JobKind
    public var branch: String?
    public var state: JobState
    public var progress: JobProgress
    public var addedAt: Date
    /// Bytes per second, a moving average while running.
    public var rate: Double
    public var finishedAt: Date?

    public init(appID: UInt32, name: String, kind: JobKind, branch: String? = nil, bytesTotal: UInt64 = 0,
                addedAt: Date = Date()) {
        self.appID = appID; self.name = name; self.kind = kind; self.branch = branch
        self.state = .queued
        self.progress = JobProgress(bytesTotal: bytesTotal)
        self.addedAt = addedAt
        self.rate = 0
    }

    /// Seconds left at the current rate.
    public var eta: Double? {
        guard state == .running, rate > 1, progress.bytesTotal > progress.bytesDone else { return nil }
        return Double(progress.bytesTotal - progress.bytesDone) / rate
    }

    public var isActive: Bool {
        switch state {
        case .queued, .running, .paused, .blocked: return true
        case .failed, .done: return false
        }
    }
}

/// What actually downloads. `run` must honour task cancellation (pause and
/// cancel both cancel it) and report progress as it goes.
public protocol DownloadDriver: AnyObject, Sendable {
    /// Why no job may start now ("Sign in to Steam", "Waiting for Wi-Fi"), or nil.
    @MainActor var blocker: String? { get }
    func run(_ job: DownloadJob, progress: @escaping @Sendable (JobProgress) -> Void) async throws
    /// A cancelled job's partial files go.
    func discard(_ job: DownloadJob) async
}

/// Moving average of bytes per second.
public struct RateMeter: Sendable {
    private var last: (t: Double, bytes: UInt64)?
    public private(set) var rate: Double = 0
    public let smoothing: Double
    public init(smoothing: Double = 0.25) { self.smoothing = smoothing }

    public mutating func sample(bytes: UInt64, at t: Double) -> Double {
        defer { last = (t, bytes) }
        guard let l = last, t > l.t, bytes >= l.bytes else { return rate }
        let instant = Double(bytes - l.bytes) / (t - l.t)
        rate = rate == 0 ? instant : rate + smoothing * (instant - rate)
        return rate
    }

    public mutating func reset() { last = nil; rate = 0 }
}

@MainActor
public final class DownloadQueue {
    public private(set) var jobs: [DownloadJob] = []
    /// Everything paused by the player ("Pause all").
    public private(set) var suspended = false
    public var onChange: (() -> Void)?
    /// A job finished (installed, updated, repaired): the library refreshes.
    public var onFinished: ((DownloadJob) -> Void)?

    private let driver: DownloadDriver
    private let store: URL?
    private var task: Task<Void, Never>?
    private var runningID: String?
    /// Bumped at every start, so a cancelled run winding down cannot finish its successor.
    private var runToken = 0
    private var meter = RateMeter()
    private let clock: () -> Double

    public init(driver: DownloadDriver, store: URL?, clock: @escaping () -> Double = { Date().timeIntervalSince1970 }) {
        self.driver = driver
        self.store = store
        self.clock = clock
        load()
    }

    // MARK: queue operations

    /// Adds a job, or brings an existing one for the same app and kind back to the queue.
    public func enqueue(_ job: DownloadJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            if !jobs[i].isActive || jobs[i].state == .paused { jobs[i].state = .queued }
        } else {
            jobs.append(job)
        }
        changed()
        pump()
    }

    public func pause(_ id: String) {
        guard let i = index(id), jobs[i].isActive else { return }
        jobs[i].state = .paused
        if runningID == id { stopRunning() }
        changed()
        pump()
    }

    public func resume(_ id: String) {
        guard let i = index(id), jobs[i].state == .paused || isFailed(jobs[i]) else { return }
        jobs[i].state = .queued
        changed()
        pump()
    }

    /// Removes a job; an unfinished one's partial files are discarded.
    public func cancel(_ id: String) {
        guard let i = index(id) else { return }
        let job = jobs.remove(at: i)
        if runningID == id { stopRunning() }
        if job.state != .done { Task { await driver.discard(job) } }
        changed()
        pump()
    }

    /// Moves a job to the front: it runs next (the running one is paused for it).
    public func runNext(_ id: String) {
        guard let i = index(id) else { return }
        var job = jobs.remove(at: i)
        if job.state == .paused || isFailed(job) { job.state = .queued }
        jobs.insert(job, at: 0)
        if let r = runningID, r != id, let ri = index(r) {
            jobs[ri].state = .queued
            stopRunning()
        }
        changed()
        pump()
    }

    public func move(_ id: String, by offset: Int) {
        guard let i = index(id) else { return }
        let j = min(max(i + offset, 0), jobs.count - 1)
        guard i != j else { return }
        let job = jobs.remove(at: i)
        jobs.insert(job, at: j)
        changed()
    }

    public func setSuspended(_ on: Bool) {
        suspended = on
        if on, let r = runningID, let i = index(r) {
            jobs[i].state = .queued
            stopRunning()
        }
        changed()
        pump()
    }

    public func clearFinished() {
        jobs.removeAll { !$0.isActive }
        changed()
    }

    /// Something the driver's blocker depends on changed (sign-in, network): try again.
    public func conditionsChanged() { pump() }

    public func job(appID: UInt32) -> DownloadJob? {
        jobs.first { $0.appID == appID && $0.isActive }
    }

    public var running: DownloadJob? { runningID.flatMap { id in jobs.first { $0.id == id } } }

    // MARK: the pump

    private func pump() {
        guard runningID == nil, !suspended else { return }
        guard let i = jobs.firstIndex(where: { $0.state == .queued || isBlocked($0) }) else { return }
        if let why = driver.blocker {
            if jobs[i].state != .blocked(why) { jobs[i].state = .blocked(why); changed() }
            return
        }
        start(i)
    }

    private func start(_ i: Int) {
        jobs[i].state = .running
        jobs[i].rate = 0
        let job = jobs[i]
        runningID = job.id
        runToken += 1
        let token = runToken
        meter.reset()
        changed()
        let driver = self.driver
        let sink: @Sendable (JobProgress) -> Void = { [weak self] p in
            Task { @MainActor in self?.progress(token, job.id, p) }
        }
        task = Task { [weak self] in
            do {
                try await driver.run(job, progress: sink)
                self?.finish(token, job.id, error: nil)
            } catch {
                self?.finish(token, job.id, error: error)
            }
        }
    }

    private func progress(_ token: Int, _ id: String, _ p: JobProgress) {
        guard token == runToken, runningID == id, let i = index(id) else { return }
        jobs[i].progress = p
        jobs[i].rate = meter.sample(bytes: p.bytesDone, at: clock())
        onChange?()   // not persisted every tick
    }

    private func finish(_ token: Int, _ id: String, error: Error?) {
        guard token == runToken, runningID == id else { return }   // paused or cancelled: already handled
        runningID = nil
        task = nil
        if let i = index(id) {
            if let error {
                jobs[i].state = error is CancellationError ? .paused : .failed(String(describing: error))
            } else {
                jobs[i].state = .done
                jobs[i].progress.bytesDone = jobs[i].progress.bytesTotal
                jobs[i].finishedAt = Date()
                onFinished?(jobs[i])
            }
            jobs[i].rate = 0
        }
        changed()
        pump()
    }

    private func stopRunning() {
        task?.cancel()
        task = nil
        runningID = nil
    }

    private func index(_ id: String) -> Int? { jobs.firstIndex { $0.id == id } }
    private func isFailed(_ j: DownloadJob) -> Bool { if case .failed = j.state { return true }; return false }
    private func isBlocked(_ j: DownloadJob) -> Bool { if case .blocked = j.state { return true }; return false }

    // MARK: persistence

    private func changed() {
        save()
        onChange?()
    }

    private func save() {
        guard let store else { return }
        var saved = jobs
        for i in saved.indices where saved[i].state == .running { saved[i].state = .queued }
        if let data = try? JSONEncoder().encode(saved) {
            try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: store, options: .atomic)
        }
    }

    private func load() {
        guard let store, let data = try? Data(contentsOf: store),
              let saved = try? JSONDecoder().decode([DownloadJob].self, from: data) else { return }
        // A job that was running when the app died resumes from its journal.
        jobs = saved.map { var j = $0; if j.state == .running || isBlocked(j) { j.state = .queued }; return j }
    }
}

public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(bytes), u = 0
        while v >= 1024 && u < units.count - 1 { v /= 1024; u += 1 }
        if u == 0 { return "\(bytes) B" }
        let n = v >= 100 ? String(Int(v.rounded())) : String(Double(Int((v * 10).rounded())) / 10)
        return "\(n) \(units[u])"
    }

    public static func rate(_ bps: Double) -> String { string(UInt64(max(0, bps))) + "/s" }

    public static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t >= 3600 { return "\(t / 3600)h \(t % 3600 / 60)m" }
        if t >= 60 { return "\(t / 60)m \(t % 60)s" }
        return "\(t)s"
    }
}
