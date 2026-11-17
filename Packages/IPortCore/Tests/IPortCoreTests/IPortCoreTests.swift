// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import IPortCore

final class GamepadTests: XCTestCase {
    func testAxisAndTriggerRanges() {
        XCTAssertEqual(GamepadState.axis(1), 32767)
        XCTAssertEqual(GamepadState.axis(-1), -32768)
        XCTAssertEqual(GamepadState.axis(5), 32767)
        XCTAssertEqual(GamepadState.axis(0), 0)
        XCTAssertEqual(GamepadState.trigger(1), 255)
        XCTAssertEqual(GamepadState.trigger(-3), 0)
    }

    func testDeadZoneRescales() {
        XCTAssertEqual(applyDeadZone(x: 0.05, y: 0, deadZone: 0.1).0, 0)
        let (x, _) = applyDeadZone(x: 1, y: 0, deadZone: 0.1)
        XCTAssertEqual(x, 1, accuracy: 1e-6)
        let (h, _) = applyDeadZone(x: 0.55, y: 0, deadZone: 0.1)
        XCTAssertEqual(h, 0.5, accuracy: 1e-6)
    }

    func testMerge() {
        var a = GamepadState(); a.buttons = .a; a.lx = 100; a.leftTrigger = 10
        var b = GamepadState(); b.buttons = .b; b.lx = -20000; b.leftTrigger = 200
        let m = a.merged(with: b)
        XCTAssertEqual(m.buttons, [.a, .b])
        XCTAssertEqual(m.lx, -20000)
        XCTAssertEqual(m.leftTrigger, 200)
    }
}

final class TouchResolverTests: XCTestCase {
    let size = ViewSize(844, 390)   // iPhone 14 landscape, points

    func point(_ id: String, dx: Double = 0, dy: Double = 0) -> Point {
        let r = TouchResolver(layout: .xbox, size: size)
        let c = r.center(of: TouchLayout.xbox.control(id)!)
        return Point(c.x + dx, c.y + dy)
    }

    func testFaceButtons() {
        var r = TouchResolver(layout: .xbox, size: size)
        XCTAssertEqual(r.began(1, at: point("a"))?.id, "a")
        XCTAssertEqual(r.began(2, at: point("y"))?.id, "y")
        XCTAssertEqual(r.state().buttons, [.a, .y])
        r.ended(1)
        XCTAssertEqual(r.state().buttons, [.y])
        r.ended(2)
        XCTAssertTrue(r.state().isNeutral)
    }

    func testSlideBetweenFaceButtons() {
        var r = TouchResolver(layout: .xbox, size: size)
        r.began(1, at: point("a"))
        r.moved(1, to: point("b"))
        XCTAssertEqual(r.state().buttons, [.b])
    }

    func testFloatingStickAndDeadZone() {
        var r = TouchResolver(layout: .xbox, size: size)
        let ls = TouchLayout.xbox.control("ls")!
        let radius = r.radius(of: ls)
        let start = point("ls", dx: 20, dy: 10)   // off-centre: becomes the origin
        XCTAssertEqual(r.began(1, at: start)?.id, "ls")
        XCTAssertTrue(r.state().isNeutral)
        r.moved(1, to: Point(start.x + radius * 2, start.y))   // past full: clamped
        XCTAssertEqual(r.state().lx, 32767)
        XCTAssertEqual(r.state().ly, 0)
        r.moved(1, to: Point(start.x, start.y - radius))       // up on screen = +y
        XCTAssertEqual(r.state().ly, 32767)
        r.moved(1, to: Point(start.x + radius * 0.05, start.y)) // inside the dead zone
        XCTAssertTrue(r.state().isNeutral)
    }

    func testThumbKeepsStickAfterSlidingOff() {
        var r = TouchResolver(layout: .xbox, size: size)
        r.began(1, at: point("ls"))
        r.moved(1, to: point("a"))   // far right: still the stick
        XCTAssertGreaterThan(r.state().lx, 30000)
        XCTAssertEqual(r.state().buttons, [])
    }

    func testDpadEightWays() {
        XCTAssertEqual(TouchResolver.dpad(dx: 10, dy: 0, radius: 10), .dpadRight)
        XCTAssertEqual(TouchResolver.dpad(dx: 0, dy: -10, radius: 10), .dpadUp)
        XCTAssertEqual(TouchResolver.dpad(dx: -7, dy: 7, radius: 10), [.dpadLeft, .dpadDown])
        XCTAssertEqual(TouchResolver.dpad(dx: 1, dy: 0, radius: 10), [])
    }

    func testTriggersAndMenu() {
        var r = TouchResolver(layout: .xbox, size: size)
        r.began(1, at: point("rt"))
        XCTAssertEqual(r.state().rightTrigger, 255)
        r.began(2, at: point("guide"))
        XCTAssertTrue(r.takeMenuTap())
        XCTAssertFalse(r.takeMenuTap())
        XCTAssertEqual(r.state().buttons, [])   // the menu never reaches the game
    }

    func testMissesEmptySpace() {
        var r = TouchResolver(layout: .xbox, size: size)
        XCTAssertNil(r.began(1, at: Point(size.width / 2, size.height / 2)))
    }

    func testLayoutRoundTripsAndClamps() throws {
        var l = TouchLayout.xbox
        l.update("a") { $0.x = 4; $0.size = 0.01 }
        XCTAssertEqual(l.control("a")!.x, 1)
        XCTAssertEqual(l.control("a")!.size, 0.06)
        let back = try JSONDecoder().decode(TouchLayout.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
    }
}

final class ArbiterTests: XCTestCase {
    func testTouchHidesWhenControllerConnects() {
        var a = ControllerArbiter<String>()
        XCTAssertTrue(a.showsTouchControls(now: 0))
        XCTAssertEqual(a.connect("xbox"), 0)
        XCTAssertFalse(a.showsTouchControls(now: 0))
        XCTAssertEqual(a.connect("dualsense"), 1)
        XCTAssertEqual(a.disconnect("xbox"), 0)
        XCTAssertFalse(a.showsTouchControls(now: 0))   // one still connected
        a.disconnect("dualsense")
        XCTAssertTrue(a.showsTouchControls(now: 0))
    }

    func testRevealAndPolicies() {
        var a = ControllerArbiter<Int>(touchRevealSeconds: 5)
        a.connect(1)
        a.revealTouch(now: 10)
        XCTAssertTrue(a.showsTouchControls(now: 12))
        XCTAssertFalse(a.showsTouchControls(now: 16))
        a.policy = .always
        XCTAssertTrue(a.showsTouchControls(now: 100))
        a.policy = .never
        a.disconnect(1)
        XCTAssertFalse(a.showsTouchControls(now: 0))
    }

    func testSlot0Merge() {
        var a = ControllerArbiter<Int>()
        var touch = GamepadState(); touch.buttons = .a
        var pad = GamepadState(); pad.buttons = .b
        XCTAssertEqual(a.slot0(touch: touch, physical: nil, now: 0).buttons, .a)
        a.connect(1)
        XCTAssertEqual(a.slot0(touch: touch, physical: pad, now: 0).buttons, .b)   // touch hidden
        a.policy = .always
        XCTAssertEqual(a.slot0(touch: touch, physical: pad, now: 0).buttons, [.a, .b])
    }

    func testFiveControllers() {
        var a = ControllerArbiter<Int>()
        for i in 0..<4 { XCTAssertEqual(a.connect(i), i) }
        XCTAssertNil(a.connect(9))
    }
}

final class DepotPolicyTests: XCTestCase {
    func testPrefersARM() {
        let p = DepotPolicy.plan([
            .init(id: 11, osList: ["windows"], osArch: "64"),
            .init(id: 12, name: "Game ARM64", osList: ["windows"]),
            .init(id: 13),                                  // neutral content
            .init(id: 14, osList: ["macos"], osArch: "64"),
            .init(id: 15, osList: ["windows"], language: "german"),
        ])
        XCTAssertEqual(p.arch, .arm64)
        XCTAssertEqual(p.depots, [12, 13])
        XCTAssertTrue(p.explicit)
    }

    func testFallsBackToX64() {
        let p = DepotPolicy.plan([
            .init(id: 1, osList: ["windows"], osArch: "64"),
            .init(id: 2, osList: ["windows"], osArch: "32"),
            .init(id: 3, osList: ["windows"]),
        ])
        XCTAssertEqual(p.arch, .x64)
        XCTAssertEqual(p.depots, [1, 3])
        XCTAssertFalse(p.explicit)
    }

    func testX86Only() {
        XCTAssertEqual(DepotPolicy.plan([.init(id: 1, osList: ["windows"], osArch: "32")]).arch, .x86)
    }

    func testARMOptOut() {
        let p = DepotPolicy.plan([.init(id: 1, osArch: "64"), .init(id: 2, osArch: "arm64")], .init(preferARM: false))
        XCTAssertEqual(p.arch, .x64)
    }
}

final class LaunchPlanTests: XCTestCase {
    let entries = [
        LaunchEntryInfo(executable: "tools/editor.exe", osList: ["windows"], type: "option1"),
        LaunchEntryInfo(executable: "bin/x64/game.exe", arguments: "-dx11 \"-name=Big Guy\"", osList: ["windows"], osArch: "64"),
        LaunchEntryInfo(executable: "bin/arm64/game.exe", osList: ["windows"], osArch: "arm64"),
        LaunchEntryInfo(executable: "game.sh", osList: ["linux"]),
    ]

    func testPicksEntryByArch() {
        XCTAssertEqual(LaunchPlanner.entry(entries, arch: .x64)?.executable, "bin/x64/game.exe")
        XCTAssertEqual(LaunchPlanner.entry(entries, arch: .arm64)?.executable, "bin/arm64/game.exe")
    }

    func testPlan() throws {
        var s = LaunchSettings()
        s.renderHeight = 720
        let p = try LaunchPlanner.plan(installDir: "Big Game", entries: entries, arch: .x64, settings: s,
                                       screen: (2556, 1179))
        XCTAssertEqual(p.dosPath, "C:\\Games\\Big Game\\bin\\x64\\game.exe")
        XCTAssertEqual(p.arguments, ["-dx11", "-name=Big Guy"])
        XCTAssertEqual(p.environment["MADEIRA_SCREEN_H"], "720")
        XCTAssertEqual(p.environment["MADEIRA_SCREEN_W"], "1560")
        XCTAssertEqual(p.dllOverlay, "vulkan")
    }

    func testNoWindowsEntry() {
        XCTAssertThrowsError(try LaunchPlanner.plan(installDir: "x", entries: [entries[3]], arch: .x64,
                                                    settings: .init(), screen: (1, 1)))
    }
}

// MARK: download queue

final class FakeDriver: DownloadDriver, @unchecked Sendable {
    var blockerValue: String?
    var runs: [String] = []
    var discarded: [UInt32] = []
    var fail: Bool = false
    /// Steps each run takes; each step sleeps briefly so pause can land mid-run.
    var steps = 5

    @MainActor var blocker: String? { blockerValue }

    func run(_ job: DownloadJob, progress: @escaping @Sendable (JobProgress) -> Void) async throws {
        runs.append(job.id)
        for i in 1...steps {
            try await Task.sleep(nanoseconds: 2_000_000)
            try Task.checkCancellation()
            progress(JobProgress(bytesDone: UInt64(i * 100), bytesTotal: UInt64(steps * 100)))
        }
        if fail { throw NSError(domain: "fake", code: 1) }
    }

    func discard(_ job: DownloadJob) async { discarded.append(job.appID) }
}

@MainActor
final class DownloadQueueTests: XCTestCase {
    func waitUntil(_ cond: @escaping () -> Bool, timeout: Double = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    func testRunsInOrderOneAtATime() async {
        let d = FakeDriver()
        let q = DownloadQueue(driver: d, store: nil)
        var finished: [UInt32] = []
        q.onFinished = { finished.append($0.appID) }
        q.enqueue(DownloadJob(appID: 1, name: "One", kind: .install))
        q.enqueue(DownloadJob(appID: 2, name: "Two", kind: .install))
        XCTAssertEqual(q.running?.appID, 1)
        XCTAssertEqual(q.jobs[1].state, .queued)
        await waitUntil { finished.count == 2 }
        XCTAssertEqual(finished, [1, 2])
        XCTAssertEqual(q.jobs.map(\.state), [.done, .done])
    }

    func testPauseResumeCancel() async {
        let d = FakeDriver(); d.steps = 200
        let q = DownloadQueue(driver: d, store: nil)
        q.enqueue(DownloadJob(appID: 1, name: "One", kind: .install))
        q.enqueue(DownloadJob(appID: 2, name: "Two", kind: .install))
        q.pause("1:install")
        XCTAssertEqual(q.jobs[0].state, .paused)
        XCTAssertEqual(q.running?.appID, 2)
        q.cancel("2:install")
        await waitUntil { d.discarded == [2] }
        XCTAssertNil(q.running)
        q.resume("1:install")
        XCTAssertEqual(q.running?.appID, 1)
        q.cancel("1:install")
    }

    func testBlockedUntilConditionsChange() async {
        let d = FakeDriver(); d.blockerValue = "Sign in to Steam"
        let q = DownloadQueue(driver: d, store: nil)
        q.enqueue(DownloadJob(appID: 7, name: "Seven", kind: .install))
        XCTAssertEqual(q.jobs[0].state, .blocked("Sign in to Steam"))
        d.blockerValue = nil
        q.conditionsChanged()
        XCTAssertEqual(q.jobs[0].state, .running)
        await waitUntil { q.jobs[0].state == .done }
    }

    func testFailureAndRunNext() async {
        let d = FakeDriver(); d.fail = true
        let q = DownloadQueue(driver: d, store: nil)
        q.enqueue(DownloadJob(appID: 1, name: "One", kind: .install))
        await waitUntil { if case .failed = q.jobs[0].state { return true }; return false }
        d.fail = false; d.steps = 200
        q.enqueue(DownloadJob(appID: 2, name: "Two", kind: .install))
        q.runNext("1:install")
        XCTAssertEqual(q.running?.appID, 1)
        XCTAssertEqual(q.jobs.first?.appID, 1)
        q.setSuspended(true)
        XCTAssertNil(q.running)
    }

    func testPersistsAndRequeuesRunningJob() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("downloads.json")
        let d = FakeDriver(); d.steps = 500
        let q = DownloadQueue(driver: d, store: url)
        q.enqueue(DownloadJob(appID: 3, name: "Three", kind: .update))
        XCTAssertEqual(q.running?.appID, 3)
        q.setSuspended(true)   // stops the run; the record says queued
        let d2 = FakeDriver(); d2.steps = 1
        let q2 = DownloadQueue(driver: d2, store: url)
        XCTAssertEqual(q2.jobs.map(\.appID), [3])
        XCTAssertEqual(q2.jobs[0].state, .queued)
        try? FileManager.default.removeItem(at: dir)
    }

    func testRateMeterAndFormat() {
        var m = RateMeter(smoothing: 0.5)
        _ = m.sample(bytes: 0, at: 0)
        XCTAssertEqual(m.sample(bytes: 1000, at: 1), 1000)
        XCTAssertEqual(m.sample(bytes: 4000, at: 2), 2000)
        XCTAssertEqual(ByteFormat.string(512), "512 B")
        XCTAssertEqual(ByteFormat.string(1536), "1.5 KB")
        XCTAssertEqual(ByteFormat.string(300 * 1024 * 1024), "300 MB")
        XCTAssertEqual(ByteFormat.duration(3725), "1h 2m")
    }
}

final class StoreTests: XCTestCase {
    func testJSONStore() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let s = JSONStore<TouchLayout>(url: url)
        s["global"] = .xbox
        XCTAssertEqual(JSONStore<TouchLayout>(url: url)["global"], .xbox)
        try? FileManager.default.removeItem(at: url)
    }
}
