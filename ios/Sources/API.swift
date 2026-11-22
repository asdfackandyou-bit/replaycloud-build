import Foundation
import Combine

final class ServerSettings: ObservableObject {
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "token") }
    }

    init() {
        self.baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? ""
        self.token = UserDefaults.standard.string(forKey: "token") ?? ""
    }

    var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty }

    var api: APIClient? {
        guard isConfigured, let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        return APIClient(baseURL: url, token: token)
    }
}

enum APIError: LocalizedError {
    case badURL
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址无效"
        case .http(let code, let msg): return "服务器返回 \(code)：\(msg)"
        case .decode(let msg): return "数据解析失败：\(msg)"
        }
    }
}

struct APIClient {
    let baseURL: URL
    let token: String

    private func makeRequest(_ path: String, method: String) -> URLRequest {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func validate(_ data: Data, _ resp: URLResponse) throws -> Data {
        guard let http = resp as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, String(msg.prefix(500)))
        }
        return data
    }

    func get(_ path: String) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: makeRequest(path, method: "GET"))
        let valid = try validate(data, resp)
        let obj = try JSONSerialization.jsonObject(with: valid)
        guard let dict = obj as? [String: Any] else { throw APIError.decode("非字典") }
        return dict
    }

    func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var req = makeRequest(path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let valid = try validate(data, resp)
        if valid.isEmpty { return [:] }
        let obj = try JSONSerialization.jsonObject(with: valid)
        return (obj as? [String: Any]) ?? [:]
    }

    func upload(_ path: String, fileURL: URL, field: String = "file", filename: String) async throws -> [String: Any] {
        var req = makeRequest(path, method: "POST")
        let boundary = "ReplayCloud-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        let valid = try validate(data, resp)
        let obj = try JSONSerialization.jsonObject(with: valid)
        return (obj as? [String: Any]) ?? [:]
    }

    /// 供 AVPlayer 使用，令牌放 query（播放器不方便带 Header）
    func mediaURL(path: String) -> URL? {
        var comps = URLComponents(url: baseURL.appendingPathComponent("file"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "token", value: token),
        ]
        return comps?.url
    }

    func download(path: String) async throws -> URL {
        guard let url = mediaURL(path: path) else { throw APIError.badURL }
        let (data, resp) = try await URLSession.shared.data(from: url)
        _ = try validate(data, resp)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        try data.write(to: tmp)
        return tmp
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
}

// MARK: - 模型

struct RVCModel: Identifiable, Hashable {
    let id: String
    let name: String
    let hasIndex: Bool
    let size: Int64

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
        self.id = id
        self.name = name
        self.hasIndex = (dict["hasIndex"] as? Bool) ?? false
        if let s = dict["size"] as? Int { self.size = Int64(s) }
        else if let s = dict["size"] as? Double { self.size = Int64(s) }
        else { self.size = 0 }
    }

    var sizeText: String {
        if size <= 0 { return "" }
        return String(format: "%.0f MB", Double(size) / 1_000_000)
    }
}

struct SongJob: Identifiable, Hashable {
    let id: String
    let status: String
    let percent: Double?
    let message: String?
    let error: String?
    let outputPath: String?
    let trackName: String?
    let modelName: String?

    init?(dict: [String: Any]) {
        guard let id = dict["jobId"] as? String else { return nil }
        self.id = id
        self.status = (dict["status"] as? String) ?? "unknown"
        self.percent = dict["percent"] as? Double
        self.message = dict["message"] as? String
        self.error = dict["error"] as? String
        self.outputPath = dict["outputFilepath"] as? String
        self.trackName = dict["trackName"] as? String
        if let md = dict["modelData"] as? [[String: Any]] {
            self.modelName = md.compactMap { $0["modelId"] as? String }.joined(separator: ", ")
        } else {
            self.modelName = nil
        }
    }

    var isDone: Bool { status == "completed" }
    var isFailed: Bool { status == "errored" || status == "stopped" }
    var statusText: String {
        switch status {
        case "queued": return "排队中"
        case "processing": return "生成中"
        case "completed": return "已完成"
        case "errored": return "失败"
        case "stopped": return "已停止"
        default: return status
        }
    }
}
