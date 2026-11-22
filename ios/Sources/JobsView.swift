import SwiftUI

struct JobsView: View {
    @EnvironmentObject var settings: ServerSettings
    @StateObject private var player = AudioPlayerBox()

    @State private var jobs: [SongJob] = []
    @State private var errorText: String?
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var downloading = false

    var body: some View {
        NavigationStack {
            Group {
                if jobs.isEmpty {
                    VStack(spacing: 12) {
                        Text(errorText ?? "暂无任务")
                            .foregroundColor(.secondary)
                        Button("刷新") { Task { await refresh() } }
                    }
                } else {
                    List(jobs) { job in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(job.trackName ?? job.modelName ?? "任务 \(job.id.prefix(8))")
                                    .font(.headline)
                                Spacer()
                                Text(job.statusText)
                                    .font(.caption)
                                    .foregroundColor(job.isFailed ? .red : (job.isDone ? .green : .orange))
                            }
                            if let p = job.percent, !job.isDone {
                                ProgressView(value: min(max(p / 100, 0), 1))
                            }
                            if let msg = job.message, !msg.isEmpty {
                                Text(msg).font(.caption).foregroundColor(.secondary)
                            }
                            if let err = job.error, !err.isEmpty {
                                Text(err).font(.caption).foregroundColor(.red).lineLimit(4)
                            }
                            HStack {
                                if job.isDone, let out = job.outputPath {
                                    Button(player.playingPath == out ? "停止" : "播放") {
                                        if let api = settings.api { player.toggle(path: out, api: api) }
                                    }
                                    Button(downloading ? "准备中…" : "保存/分享") {
                                        share(path: out)
                                    }
                                    .disabled(downloading)
                                } else if !job.isFailed {
                                    Button("停止任务") { stop(job) }
                                }
                            }
                            .font(.callout)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("任务与产物")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task {
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                }
            }
            .onDisappear { player.stop() }
            .sheet(isPresented: $showShare) {
                if let shareURL { ShareSheet(items: [shareURL]) }
            }
        }
    }

    private func refresh() async {
        guard let api = settings.api else { return }
        do {
            let resp = try await api.get("jobs")
            let list = (resp["jobs"] as? [[String: Any]] ?? []).compactMap(SongJob.init)
            jobs = list.sorted { $0.id > $1.id }
            errorText = nil
        } catch {
            errorText = "连接失败：\(error.localizedDescription)"
        }
    }

    private func stop(_ job: SongJob) {
        guard let api = settings.api else { return }
        Task {
            _ = try? await api.post("stop_job", ["jobId": job.id])
            await refresh()
        }
    }

    private func share(path: String) {
        guard let api = settings.api else { return }
        downloading = true
        Task {
            defer { downloading = false }
            do {
                let local = try await api.download(path: path)
                shareURL = local
                showShare = true
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
