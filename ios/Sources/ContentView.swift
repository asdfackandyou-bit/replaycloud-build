import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var settings: ServerSettings

    var body: some View {
        if settings.isConfigured {
            TabView {
                CreateSongView()
                    .tabItem { Label("生成翻唱", systemImage: "waveform.badge.plus") }
                JobsView()
                    .tabItem { Label("任务与产物", systemImage: "list.bullet") }
                SettingsView()
                    .tabItem { Label("服务器", systemImage: "gearshape") }
            }
        } else {
            SettingsView(firstSetup: true)
        }
    }
}

// MARK: - 服务器设置

struct SettingsView: View {
    var firstSetup: Bool = false
    @EnvironmentObject var settings: ServerSettings
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                if firstSetup {
                    Text("欢迎使用 ReplayCloud\n\n这是 Replay 的 iOS 客户端，需要连接一台已部署官方推理服务端的云服务器（部署方法见 README）。官方云端已关闭，本应用不依赖 weights.com。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Section("服务器") {
                    TextField("地址，如 http://1.2.3.4:8080", text: $settings.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("访问令牌", text: $settings.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button(testing ? "正在测试…" : "测试连接") { test() }
                        .disabled(testing || !settings.isConfigured)
                    if let result {
                        Text(result)
                            .font(.callout)
                            .foregroundColor(result.hasPrefix("✅") ? .green : .red)
                    }
                }
                Section("关于") {
                    LabeledContent("客户端", value: "ReplayCloud 1.0")
                    LabeledContent("推理", value: "官方 Replay Server（linux-x64）")
                    Text("提示：http 明文连接仅建议个人临时使用；有域名可在服务器前加 HTTPS 反代。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(firstSetup ? "初始设置" : "服务器")
        }
    }

    private func test() {
        guard let api = settings.api else { return }
        testing = true
        result = nil
        Task {
            defer { testing = false }
            do {
                let health = try await api.get("health")
                if (health["ok"] as? Bool) == true {
                    let devices = try? await api.get("device_options")
                    let dev = (devices?["devices"] as? [String])?.joined(separator: ", ") ?? "未知"
                    result = "✅ 连接成功，推理设备：\(dev)"
                } else {
                    result = "⚠️ 服务端尚未就绪，请稍候再试"
                }
            } catch {
                result = "❌ \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 文档选择与分享

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio])
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tmp)
            do {
                try FileManager.default.copyItem(at: url, to: tmp)
                onPick(tmp)
            } catch {
                print("复制音频失败: \(error)")
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 播放器

final class AudioPlayerBox: ObservableObject {
    @Published var playingPath: String?
    private var player: AVPlayer?

    func toggle(path: String, api: APIClient) {
        if playingPath == path {
            stop()
            return
        }
        stop()
        guard let url = api.mediaURL(path: path) else { return }
        let p = AVPlayer(url: url)
        player = p
        playingPath = path
        p.play()
    }

    func stop() {
        player?.pause()
        player = nil
        playingPath = nil
    }
}
