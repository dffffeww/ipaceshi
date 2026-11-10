import Foundation

/// 后端 API 客户端（1:1 移植自安卓 ApiClient.java，async/await 版）。
/// 协议与安卓端完全一致：POST/GET {base}/api/{path}，Bearer token，JSON。
/// 401 先同步续登一次并原地重试；网络瞬断自动重试一次。
public final class ApiClient {

    /// 401 全局兜底回调：token 失效时由 App 清会话并引导重新登录
    public static var onUnauthorized: (() -> Void)?
    /// 401 同步续登钩子：App 注入；返回新 token（成功）或 nil（失败/无凭据）
    public static var reloginHook: (() -> String?)?

    public let base: String
    public private(set) var token: String = ""
    private var notifyAuthFail = true

    public init(address: String) throws {
        let s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.query == nil, url.fragment == nil
        else { throw ApiError.invalidAddress }
        // 去尾部斜杠
        var b = s
        while b.hasSuffix("/") { b.removeLast() }
        base = b
    }

    public enum ApiError: LocalizedError {
        case invalidAddress, emptyBody, tooLarge, http(Int, String?), network
        public var errorDescription: String? {
            switch self {
            case .invalidAddress: return "请输入有效的HTTP(S)服务地址"
            case .emptyBody: return "上传内容为空"
            case .tooLarge: return "上传超过4MB，请拆分轨迹"
            case .http(let code, let msg): return msg ?? "HTTP \(code)"
            case .network: return "网络连接失败，请检查网络后重试"
            }
        }
    }

    public func setToken(_ value: String?) { token = value ?? "" }
    public func setNotifyUnauthorized(_ v: Bool) { notifyAuthFail = v }

    private func handleUnauthorized() {
        if token.isEmpty { return } // 未带 token 的请求（如登录失败）不触发兜底
        token = ""
        if notifyAuthFail { ApiClient.onUnauthorized?() }
    }

    /// 401 时同步续登一次：成功则本实例换上新 token，调用方原地重试当前请求
    private func trySyncRelogin() -> Bool {
        if token.isEmpty { return false }
        guard let fresh = ApiClient.reloginHook?(), !fresh.isEmpty else { return false }
        token = fresh
        return true
    }

    /// JSON 请求（登录成功后自动保存 token）
    @discardableResult
    public func request(_ method: String, _ path: String, body: [String: Any]? = nil, retried: Bool = false) async throws -> [String: Any] {
        do {
            return try await requestOnce(method, path, body: body, retried: retried)
        } catch let e as URLError {
            // v7.60 逻辑：网络瞬断自动重试一次
            if !retried {
                try? await Task.sleep(nanoseconds: 700_000_000)
                return try await request(method, path, body: body, retried: true)
            }
            throw ApiError.network
        }
    }

    private func requestOnce(_ method: String, _ path: String, body: [String: Any]?, retried: Bool) async throws -> [String: Any] {
        guard let url = URL(string: base + "/api/" + path) else { throw ApiError.invalidAddress }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body = body {
            guard JSONSerialization.isValidJSONObject(body) else { throw ApiError.emptyBody }
            let data = try JSONSerialization.data(withJSONObject: body)
            if data.count > 4 * 1024 * 1024 { throw ApiError.tooLarge }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 500
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if status >= 400 { throw ApiError.http(status, nil) }
            throw ApiError.emptyBody
        }
        if status >= 400 {
            if status == 401 {
                // v7.55 逻辑：先尝试同步续登并原地重试一次；不行才走异步兜底
                if !retried && trySyncRelogin() {
                    return try await request(method, path, body: body, retried: true)
                }
                handleUnauthorized()
            }
            throw ApiError.http(status, json["error"] as? String)
        }
        if path == "login", let tk = json["token"] as? String { token = tk }
        return json
    }

    /// 原始二进制上传（视频等大文件）
    @discardableResult
    public func upload(_ path: String, data: Data, contentType: String) async throws -> [String: Any] {
        if data.isEmpty { throw ApiError.emptyBody }
        guard let url = URL(string: base + "/api/" + path) else { throw ApiError.invalidAddress }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            return try parse(respData, status: (resp as? HTTPURLResponse)?.statusCode ?? 500)
        } catch let e as ApiError { throw e }
        catch { throw ApiError.network }
    }

    private func parse(_ data: Data, status: Int) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if status >= 400 { throw ApiError.http(status, nil) }
            throw ApiError.emptyBody
        }
        if status >= 400 {
            if status == 401 { handleUnauthorized() }
            throw ApiError.http(status, json["error"] as? String)
        }
        return json
    }
}
