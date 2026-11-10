import Foundation
import UIKit

/// 崩溃捕获与上报（对齐安卓 CrashGuard + MainActivity 上报链路）：
/// 1. NSSetUncaughtExceptionHandler + 致命信号 → 落盘 crash-*.txt（保留最近 5 份）
/// 2. 下次冷启动 reportPending() 自动 POST /api/crash/report（device/android/version/content，
///    字段名与安卓上报完全一致，服务器统一入库 crash_reports 表并落盘到 D:\爱徒步后台\日志）
public enum CrashGuard {

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crash", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// App 启动时安装（PeakPalApp.init 调用一次）
    public static func install() {
        NSSetUncaughtExceptionHandler { ex in
            let body = """
            time=\(Self.stamp())
            device=\(Self.device())
            thread=\(ex.name.rawValue)
            \(ex.reason ?? "")

            \(ex.callStackSymbols.joined(separator: "\n"))
            """
            Self.write(body)
        }
        // 致命信号：写一份带信号名的最小日志（进程即将死亡，尽量精简）
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP] {
            signal(sig) { s in
                let body = "time=\(Self.stamp())\ndevice=\(Self.device())\nsignal=\(s)\n\n致命信号崩溃（无堆栈）"
                Self.write(body)
                exit(128 + s)
            }
        }
    }

    /// 上报本地未发送的崩溃日志（登录页/主页 onAppear 调用；未登录也上报——服务器匿名收）
    public static func reportPending() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?.sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        guard !files.isEmpty else { return }
        Task.detached(priority: .utility) {
            for f in files.prefix(10) {
                guard let content = try? String(contentsOf: f, encoding: .utf8), !content.isEmpty else {
                    try? FileManager.default.removeItem(at: f); continue
                }
                let payload: [String: Any] = [
                    "device": device(),
                    "android": await osVersion(),          // 服务器字段名固定为 android，塞 iOS 版本
                    "version": appVersion(),
                    "content": String(content.prefix(20000)),
                ]
                guard let body = try? JSONSerialization.data(withJSONObject: payload) else { continue }
                guard let url = URL(string: Session.shared.server + "/api/crash/report") else { return }
                var req = URLRequest(url: url, timeoutInterval: 20)
                req.httpMethod = "POST"
                req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                if !Session.shared.token.isEmpty {
                    req.setValue("Bearer " + Session.shared.token, forHTTPHeaderField: "Authorization")
                }
                req.httpBody = body
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                        try? FileManager.default.removeItem(at: f)   // 成功即删，避免重复上报
                    }
                } catch { break }   // 网络不可用：保留文件下次再试
            }
        }
    }

    // MARK: - 内部

    static func write(_ content: String) {
        let f = dir.appendingPathComponent("crash-\(stamp()).txt")
        try? content.data(using: .utf8)?.write(to: f)
        // 只保留最近 5 份（与安卓 CrashGuard 一致）
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for old in all.dropFirst(5) { try? FileManager.default.removeItem(at: old) }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    static func device() -> String {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return machine.isEmpty ? "iOS" : machine
    }

    static func osVersion() async -> String {
        let v = await MainActor.run { UIDevice.current.systemVersion }
        return "iOS \(v)"
    }

    static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
