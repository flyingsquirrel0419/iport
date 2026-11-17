// SPDX-License-Identifier: GPL-3.0-or-later
// The download manager: the queue in order with progress, speed and time
// left; pause / resume / cancel / run next / reorder; pause all; history.

import IPortCore
import SwiftUI

struct DownloadsView: View {
    @ObservedObject var downloads = Downloads.shared
    @ObservedObject var net = NetworkMonitor.shared

    var body: some View {
        List {
            Section {
                HStack {
                    if let free = AppPaths.freeSpace() {
                        Label("\(ByteFormat.string(free)) free on this iPhone", systemImage: "internaldrive")
                    }
                    Spacer()
                    Label(net.connected ? (net.expensive ? "Cellular" : "Wi-Fi") : "Offline",
                          systemImage: net.connected ? "wifi" : "wifi.slash")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            Section("Queue") {
                if downloads.active.isEmpty {
                    Text("Nothing downloading.").foregroundStyle(.secondary)
                }
                ForEach(Array(downloads.active.enumerated()), id: \.element.id) { i, job in
                    DownloadRow(job: job)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { downloads.cancel(job) } label: { Label("Cancel", systemImage: "xmark") }
                        }
                        .swipeActions(edge: .leading) {
                            if i > 0 {
                                Button { downloads.runNext(job) } label: { Label("Run next", systemImage: "arrow.up.to.line") }
                                    .tint(.blue)
                            }
                        }
                        .contextMenu {
                            Button { downloads.runNext(job) } label: { Label("Download now", systemImage: "bolt") }
                            Button { downloads.move(job, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                            Button { downloads.move(job, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                            Button(role: .destructive) { downloads.cancel(job) } label: { Label("Cancel", systemImage: "xmark") }
                        }
                }
            }
            if !downloads.finished.isEmpty {
                Section {
                    ForEach(downloads.finished) { DownloadRow(job: $0) }
                } header: {
                    HStack { Text("Finished"); Spacer(); Button("Clear") { downloads.clearFinished() }.font(.caption) }
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(downloads.suspended ? "Resume all" : "Pause all") { downloads.setSuspended(!downloads.suspended) }
            }
        }
    }
}

struct DownloadRow: View {
    let job: DownloadJob
    @ObservedObject var downloads = Downloads.shared

    var body: some View {
        HStack(spacing: 14) {
            GameArt(appID: job.appID, kind: .capsule).frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.name).font(.headline).lineLimit(1)
                    Text(job.kind.rawValue.capitalized).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }
                if job.state == .running || job.state == .paused || job.progress.bytesDone > 0 {
                    ProgressView(value: job.progress.fraction)
                }
                Text(detail).font(.caption).foregroundStyle(stateColor)
            }
            Spacer()
            control
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        let p = job.progress
        let bytes = p.bytesTotal > 0 ? "\(ByteFormat.string(p.bytesDone)) / \(ByteFormat.string(p.bytesTotal))" : ""
        switch job.state {
        case .running:
            var s = bytes
            if job.rate > 0 { s += " · " + ByteFormat.rate(job.rate) }
            if let eta = job.eta { s += " · " + ByteFormat.duration(eta) + " left" }
            return s.isEmpty ? "Starting…" : s
        case .queued: return "Queued" + (bytes.isEmpty ? "" : " · " + bytes)
        case .paused: return "Paused" + (bytes.isEmpty ? "" : " · " + bytes)
        case .blocked(let why): return why
        case .failed(let why): return why
        case .done: return job.finishedAt.map { "Done · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Done"
        }
    }

    private var stateColor: Color {
        switch job.state {
        case .failed: return .red
        case .blocked: return .orange
        case .done: return .green
        default: return .secondary
        }
    }

    @ViewBuilder private var control: some View {
        switch job.state {
        case .running, .queued, .blocked:
            Button { downloads.pause(job) } label: { Image(systemName: "pause.circle.fill").font(.title2) }.buttonStyle(.plain)
        case .paused, .failed:
            Button { downloads.resume(job) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title2) }.buttonStyle(.plain)
        case .done:
            if let g = GameLibrary.shared.game(job.appID) {
                Button("Play") { GameSession.shared.play(g) }.buttonStyle(.borderedProminent)
            }
        }
    }
}
