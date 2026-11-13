import Foundation
import Security

/// 登录会话与服务器配置（对应安卓 Session + App 的偏好存储）
public final class Session: ObservableObject {
    public static let shared = Session()

    /// 云端服务器默认地址（与安卓 Session.DEFAULT_SERVER 一致：生产服务器，安卓 iOS 用户互通）
    public static let defaultServer = "http://111.170.49.138:8765"

    private let d = UserDefaults.standard

    @Published public var server: String {
        didSet { d.set(server, forKey: "server") }
    }
    @Published public var token: String {
        didSet {
            Keychain.set(token, for: "token")
            api.setToken(token)
        }
    }
    @Published public var uid: String { didSet { d.set(uid, forKey: "uid") } }
    @Published public var name: String { didSet { d.set(name, forKey: "name") } }
    @Published public var loggedIn: Bool { didSet { d.set(loggedIn, forKey: "loggedIn") } }

    public private(set) var api: ApiClient

    private init() {
        // 默认指向安卓同款生产服务器：首次打开即可直接登录，与安卓用户互通（队伍/聊天/社区同一套接口）
        // 注意：api 尚未初始化前不能读 self.server，先用局部变量接住
        let svr = d.string(forKey: "server") ?? Session.defaultServer
        server = svr
        token = Keychain.get("token") ?? ""
        uid = d.string(forKey: "uid") ?? ""
        name = d.string(forKey: "name") ?? ""
        loggedIn = d.bool(forKey: "loggedIn")
        api = (try? ApiClient(address: svr)) ?? (try! ApiClient(address: "https://example.com"))
        api.setToken(token)
    }

    /// 更换服务器地址
    public func reconnect(_ address: String) -> Bool {
        guard let client = try? ApiClient(address: address) else { return false }
        api = client
        api.setToken(token)
        server = address
        return true
    }

    /// 登录成功：保存会话并注入 token
    public func saveLogin(_ res: [String: Any], server addr: String) {
        token = res["token"] as? String ?? ""
        uid = res["uid"] as? String ?? ""
        name = res["name"] as? String ?? ""
        server = addr
        loggedIn = true
        api.setToken(token)
    }

    /// 登出
    public func logout() {
        token = ""
        loggedIn = false
        TeamState.shared.leaveLocal()
    }

    /// 401 同步续登：用保存的凭据重新登录（对应安卓 v7.55 ReloginHook）
    public func relogin() -> String? {
        guard let pwd = Keychain.get("pwd"), !uid.isEmpty else { return nil }
        guard let client = try? ApiClient(address: server) else { return nil }
        var res: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        Task {
            res = try? await client.request("POST", "login", body: ["uid": uid, "pwd": pwd])
            sem.signal()
        }
        sem.wait()
        guard let r = res, let tk = r["token"] as? String, !tk.isEmpty else { return nil }
        token = tk
        return tk
    }

    public func savePassword(_ pwd: String) { Keychain.set(pwd, for: "pwd") }
}

/// Keychain 轻量封装（token/密码存 Keychain，比 UserDefaults 安全）
enum Keychain {
    static func set(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "cn.peakpal.\(key)",
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "cn.peakpal.\(key)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
