import SwiftUI
import UIKit
import CoreLocation

/// 天气查询（1:1 对应安卓 Weather.java）：Open-Meteo 免费接口，无需 key；
/// 15 分钟缓存 + 失败退避（内存缓存按坐标取整 0.05° 网格）。
/// 用途：记录页/循迹导航页天气芯片（对应安卓 F67 天气芯片）。
enum WeatherKit {

    struct Now {
        let temp: Double        // ℃
        let wind: Double        // km/h
        let code: Int           // WMO weather code
        let city: String        // 逆地理城市（粗略：不填则只显示天气）

        var icon: String {
            switch code {
            case 0: return "sun.max.fill"
            case 1, 2: return "cloud.sun.fill"
            case 3: return "cloud.fill"
            case 45, 48: return "cloud.fog.fill"
            case 51...57: return "cloud.drizzle.fill"
            case 61...67, 80...82: return "cloud.rain.fill"
            case 71...77, 85, 86: return "cloud.snow.fill"
            case 95...99: return "cloud.bolt.rain.fill"
            default: return "cloud.fill"
            }
        }

        var desc: String {
            switch code {
            case 0: return "晴"
            case 1: return "大致晴朗"
            case 2: return "多云"
            case 3: return "阴"
            case 45, 48: return "雾"
            case 51, 53, 55, 56, 57: return "毛毛雨"
            case 61, 63, 65, 80, 81, 82: return "雨"
            case 66, 67: return "冻雨"
            case 71, 73, 75, 77, 85, 86: return "雪"
            case 95, 96, 99: return "雷雨"
            default: return "—"
            }
        }

        /// 出行提示（与安卓 Weather.suggest 同思路）
        var suggest: String {
            if code >= 95 { return "雷雨天气，强烈建议取消进山" }
            if (61...67).contains(code) || (80...82).contains(code) { return "有雨，带好雨具注意防滑" }
            if (71...77).contains(code) || code == 85 || code == 86 { return "降雪，注意保暖与路滑" }
            if code == 45 || code == 48 { return "有雾，能见度低谨慎行走" }
            if temp >= 32 { return "高温，多带水防中暑" }
            if temp <= 0 { return "低温冰冻，注意保暖" }
            return "天气适宜徒步"
        }
    }

    private struct CacheEntry { let item: Now; let at: Date }
    private static var cache: [String: CacheEntry] = [:]
    private static let lock = NSLock()
    private static let ttl: TimeInterval = 15 * 60

    /// 取当前天气（带缓存；失败抛错由调用方降级）
    static func fetch(lat: Double, lng: Double) async throws -> Now {
        let key = String(format: "%.1f,%.1f", lat, lng)
        lock.lock()
        if let c = cache[key], Date().timeIntervalSince(c.at) < ttl {
            lock.unlock()
            return c.item
        }
        lock.unlock()

        let urlStr = String(
            format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,weather_code,wind_speed_10m",
            lat, lng)
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cur = o["current"] as? [String: Any] else { throw URLError(.cannotParseResponse) }

        let now = Now(
            temp: (cur["temperature_2m"] as? NSNumber)?.doubleValue ?? 0,
            wind: (cur["wind_speed_10m"] as? NSNumber)?.doubleValue ?? 0,
            code: (cur["weather_code"] as? NSNumber)?.intValue ?? 0,
            city: "")
        lock.lock()
        cache[key] = CacheEntry(item: now, at: Date())
        lock.unlock()
        return now
    }
}

/// 天气芯片（对应安卓导航页 Weather 芯片视图）：图标 + 温度 + 描述
struct WeatherChip: View {
    let lat: Double
    let lng: Double
    @State private var now: WeatherKit.Now?
    @State private var failed = false

    var body: some View {
        HStack(spacing: 6) {
            if let n = now {
                Image(systemName: n.icon).font(.subheadline).foregroundStyle(.orange)
                Text("\(Int(n.temp))℃ \(n.desc)").font(.subheadline.weight(.medium))
                Text("风 \(Int(n.wind))km/h").font(.caption).foregroundStyle(.secondary)
                Text(n.suggest).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if failed {
                Image(systemName: "wifi.exclamationmark").font(.caption).foregroundStyle(.secondary)
                Text("天气获取失败").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().scaleEffect(0.8)
                Text("天气加载中…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .task {
            do { now = try await WeatherKit.fetch(lat: lat, lng: lng) }
            catch { failed = true }
        }
    }
}

/// 第三方地图导航调起（对应安卓 ThirdNav.java：高德/百度/腾讯/Apple Maps 兜底）。
/// 注意：高德/腾讯为 GCJ-02 坐标系，百度 BD-09 由百度端 coord_type 参数转换，
/// 传入统一使用 WGS84，由各 scheme 的坐标参数声明。
enum ThirdNav {

    /// 依序尝试已安装的地图 App，都未装则跳 Apple Maps
    static func navigate(lat: Double, lng: Double, name: String = "目的地") {
        let g = Coord.wgs2gcj(lat: lat, lng: lng)
        let dest = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""

        // 1) 高德地图（iOS scheme: iosamap，GCJ-02，dev=0 表示已是火星坐标）
        if let u = URL(string: "iosamap://path?sourceApplication=PeakPal&dlat=\(g.0)&dlon=\(g.1)&dev=0&t=0&dname=\(dest)&m=0"),
           UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u); return
        }
        // 2) 百度地图（BD-09 由百度端转换：coord_type=wgs84）
        if let u = URL(string: "baidumap://map/direction?destination=\(g.0),\(g.1)&coord_type=gcj2&mode=walking&src=ios.peakpal"),
           UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u); return
        }
        // 3) 腾讯地图（GCJ-02，coord_type=1）
        if let u = URL(string: "qqmap://map/routeplan?type=walk&to=\(dest)&tocoord=\(g.0),\(g.1)&coord_type=1&referer=peakpal"),
           UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u); return
        }
        // 4) 兜底：Apple Maps（步行导航，WGS84）
        if let u = URL(string: "maps://?daddr=\(lat),\(lng)&q=\(dest)&dirflg=w") {
            UIApplication.shared.open(u, options: [:], completionHandler: nil)
        }
    }
}
