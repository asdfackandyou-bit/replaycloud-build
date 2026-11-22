import SwiftUI

struct CreateSongView: View {
    @EnvironmentObject var settings: ServerSettings

    @State private var models: [RVCModel] = []
    @State private var selectedModel = ""
    @State private var pickedFile: URL?
    @State private var pickedName = ""
    @State private var remoteURL = ""
    @State private var useRemoteURL = false

    @State private var pitch: Double = 0
    @State private var f0Method = "rmvpe"
    @State private var indexRatio: Double = 0.75
    @State private var preStemmed = false
    @State private var deEcho = false
    @State private var outputFormat = "mp3_192k"

    @State private var showPicker = false
    @State private var busy = false
    @State private var importing = false
    @State private var log: String?
    @State private var loadingModels = false

    var body: some View {
        NavigationStack {
            Form {
                Section("声音模型") {
                    if loadingModels {
                        ProgressView()
                    } else if models.isEmpty {
                        Text("服务器暂无模型。可先用电脑把 RVC 模型 zip 放入服务器 /opt/replay/models，或在此页面上传。")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    Picker("选择模型", selection: $selectedModel) {
                        ForEach(models) { m in
                            Text(m.name + (m.hasIndex ? "（含索引）" : "")).tag(m.id)
                        }
                    }
                    .disabled(models.isEmpty)
                    Button("刷新模型列表") { loadModels() }
                }

                Section("歌曲来源") {
                    Toggle("使用在线链接（YouTube/直链）", isOn: $useRemoteURL)
                    if useRemoteURL {
                        TextField("https://…", text: $remoteURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("链接下载由服务器完成；部分站点可能因 yt-dlp 版本过旧而失败。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button(importing ? "正在导入音频…" : (pickedFile == nil ? "选择音频文件" : "已选：\(pickedName)")) {
                            showPicker = true
                        }
                        .disabled(importing)
                        Text("支持 mp3 / wav / flac / m4a 等，将上传到服务器。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("转换参数") {
                    Stepper(value: $pitch, in: -24...24, step: 1) {
                        LabeledContent("变调（半音）", value: "\(Int(pitch))")
                    }
                    Picker("音高提取算法", selection: $f0Method) {
                        Text("RMVPE（推荐）").tag("rmvpe")
                        Text("CREPE").tag("crepe")
                        Text("CREPE Tiny").tag("crepe-tiny")
                        Text("Mangio CREPE").tag("mangio-crepe")
                        Text("Mangio CREPE Tiny").tag("mangio-crepe-tiny")
                    }
                    VStack(alignment: .leading) {
                        Text("索引影响 \(String(format: "%.2f", indexRatio))")
                        Slider(value: $indexRatio, in: 0...1)
                    }
                    Toggle("输入已是纯人声（跳过分离）", isOn: $preStemmed)
                    Toggle("去回声/混响", isOn: $deEcho)
                    Picker("输出格式", selection: $outputFormat) {
                        Text("MP3 192k").tag("mp3_192k")
                        Text("MP3 320k").tag("mp3_320k")
                        Text("WAV").tag("wav")
                    }
                }

                Section {
                    Button(busy ? "正在提交…" : "开始生成") { submit() }
                        .disabled(busy || selectedModel.isEmpty || (!useRemoteURL && pickedFile == nil) || (useRemoteURL && remoteURL.isEmpty))
                        .frame(maxWidth: .infinity)
                    if let log {
                        Text(log)
                            .font(.callout)
                            .foregroundColor(log.hasPrefix("✅") ? .green : .secondary)
                    }
                }
            }
            .navigationTitle("生成翻唱")
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                handlePickedFiles(result)
            }
            .onAppear(perform: loadModels)
        }
    }

    private func handlePickedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importing = false
            log = "❌ 文件选择失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let source = urls.first else {
                log = "❌ 没有取得所选音频"
                return
            }
            importing = true
            pickedFile = nil
            pickedName = ""
            log = "正在把音频导入 App…"
            let scoped = source.startAccessingSecurityScopedResource()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                do {
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ReplayCloudImports", isDirectory: true)
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = folder.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.copyItem(at: source, to: destination)
                    DispatchQueue.main.async {
                        pickedFile = destination
                        pickedName = source.lastPathComponent
                        importing = false
                        log = "✅ 音频已导入，可以开始生成"
                    }
                } catch {
                    DispatchQueue.main.async {
                        importing = false
                        pickedFile = nil
                        log = "❌ 音频导入失败：\(error.localizedDescription)\n请先在“文件”App 中把音频下载到本机，再重新选择。"
                    }
                }
            }
        }
    }

    private func loadModels() {
        guard let api = settings.api else { return }
        loadingModels = true
        Task {
            defer { loadingModels = false }
            do {
                let resp = try await api.get("models")
                let list = (resp["models"] as? [[String: Any]] ?? []).compactMap(RVCModel.init)
                models = list
                if selectedModel.isEmpty || !list.contains(where: { $0.id == selectedModel }) {
                    selectedModel = list.first?.id ?? ""
                }
            } catch {
                log = "模型列表获取失败：\(error.localizedDescription)"
            }
        }
    }

    private func submit() {
        guard let api = settings.api else { return }
        busy = true
        log = nil
        Task {
            defer { busy = false }
            do {
                var source = remoteURL.trimmingCharacters(in: .whitespaces)
                if !useRemoteURL {
                    guard let file = pickedFile else { return }
                    log = "正在上传音频…"
                    let up = try await api.upload("upload_audio", fileURL: file, filename: pickedName)
                    guard let path = up["path"] as? String else { throw APIError.decode("上传响应缺少 path") }
                    source = path
                }
                log = "正在创建任务…"
                let options: [String: Any] = [
                    "pitch": Int(pitch),
                    "f0Method": f0Method,
                    "indexRatio": indexRatio,
                    "preStemmed": preStemmed,
                    "deEchoDeReverb": deEcho,
                    "outputFormat": outputFormat,
                ]
                let resp = try await api.post("create_song", [
                    "modelId": selectedModel,
                    "songUrlOrFilePath": source,
                    "options": options,
                ])
                if let jobId = resp["jobId"] as? String {
                    log = "✅ 已提交，任务号 \(jobId)\n请到「任务与产物」查看进度。"
                } else {
                    log = "服务器响应：\(resp)"
                }
            } catch {
                log = "❌ \(error.localizedDescription)"
            }
        }
    }
}
