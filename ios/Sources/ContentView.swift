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
    @State private var draftBaseURL = ""
    @State private var draftToken = ""
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                if firstSetup {
                    Text("欢迎使用 ReplayCloud\n\n这是 Replay 的 iOS 客户端，需要连接一台已部署官方推理服务端的云服务器（部署方法见 README）。官方云端已关闭，本应用不依赖 weights.com。\n\n服务器尚未部署时可以先留空；输入完成后必须点“保存并进入”。")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Section("服务器") {
                    TextField("地址，如 http://1.2.3.4:8080", text: $draftBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("访问令牌", text: $draftToken)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                }
                Section {
                    Button(testing ? "正在测试…" : "测试连接") { test() }
                        .disabled(testing || !draftsValid)
                    Button(firstSetup ? "保存并进入" : "保存设置") { save() }
                        .disabled(!draftsValid)
                    if let result {
                        Text(result)
                            .font(.callout)
                            .foregroundColor(result.hasPrefix("✅") ? .green : .red)
                    }
                } footer: {
                    Text("访问令牌由你在部署服务器时设置；不是 GitHub 或 Replay 官方账号密码。")
                }
                Section("关于") {
                    LabeledContent("客户端", value: "ReplayCloud 1.3")
                    LabeledContent("推理", value: "官方 Replay Server（linux-x64）")
                    Text("提示：http 明文连接仅建议个人临时使用；有域名可在服务器前加 HTTPS 反代。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(firstSetup ? "初始设置" : "服务器")
            .onAppear {
                draftBaseURL = settings.baseURL
                draftToken = settings.token
            }
        }
    }

    private var draftsValid: Bool {
        !draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draftToken.isEmpty
    }

    private func save() {
        settings.baseURL = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.token = draftToken
        if !firstSetup { result = "✅ 设置已保存" }
    }

    private func test() {
        guard let url = URL(string: draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            result = "❌ 服务器地址格式不正确"
            return
        }
        let api = APIClient(baseURL: url, token: draftToken)
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
    var onError: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio])
        vc.delegate = context.coordinator
        vc.allowsMultipleSelection = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onError: onError) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onError: (String) -> Void
        init(onPick: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.onPick = onPick
            self.onError = onError
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let source = urls.first else {
                onError("没有取得所选文件")
                return
            }
            let scoped = source.startAccessingSecurityScopedResource()
            // iCloud/“文件”提供商可能要求协调读取；复制放到后台，避免卡住界面。
            DispatchQueue.global(qos: .userInitiated).async {
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                do {
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ReplayCloudImports", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = folder.appendingPathComponent(source.lastPathComponent)
                    var coordinationError: NSError?
                    var copyError: Error?
                    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinatedURL in
                        do {
                            try FileManager.default.copyItem(at: coordinatedURL, to: destination)
                        } catch {
                            copyError = error
                        }
                    }
                    if let copyError { throw copyError }
                    if let coordinationError { throw coordinationError }
                    DispatchQueue.main.async { self.onPick(destination) }
                } catch {
                    DispatchQueue.main.async { self.onError(error.localizedDescription) }
                }
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
