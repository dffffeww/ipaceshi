import SwiftUI
import UIKit

/// iOS 更新检测：
/// iOS 系统不允许 App 静默自更新（无 App Store/TestFlight/企业证书时），
/// 故检测到服务器发布更高构建号时弹窗，引导用户下载新 ipa 后用爱思助手重签安装。
enum UpdateChecker {

    struct Info {
        let code: Int          // 服务器上的最新构建号
        let version: String    // 版本名，如 1.0.0
        let notes: String      // 更新说明
        let url: URL?          // ipa 直链（服务器 /apk/<file>）
    }

    /// 本机安装包的构建号（Info.plist CFBundleVersion）
    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 1
    }

    /// 本机版本名（CFBundleShortVersionString）
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// 查询服务器最新 iOS 构建（/api/ipa/latest 公开接口）；无发布或网络失败返回 nil
    static func fetchLatest(session: Session) async -> Info? {
        guard let res = try? await session.api.request("GET", "ipa/latest"),
              res["available"] as? Bool == true,
              let code = (res["code"] as? NSNumber)?.intValue,
              let file = res["file"] as? String, !file.isEmpty else { return nil }
        let ver = res["version"] as? String ?? "1.0.0"
        let notes = res["notes"] as? String ?? ""
        let url = URL(string: session.server + "/apk/" + file)
        return Info(code: code, version: ver, notes: notes, url: url)
    }

    /// 服务器构建号高于本机 → 有新版本
    static func newerAvailable(_ info: Info) -> Bool {
        info.code > currentBuild
    }

    /// 用 Safari 打开 ipa 直链（iPhone 上可复制链接转发到电脑；电脑浏览器直接下载）
    static func openDownload(_ url: URL?) {
        guard let url else { return }
        UIApplication.shared.open(url)
    }

    /// 复制下载链接到剪贴板（方便粘到电脑浏览器下载）
    static func copyLink(_ url: URL?) -> Bool {
        guard let url else { return false }
        UIPasteboard.general.string = url.absoluteString
        return true
    }
}
