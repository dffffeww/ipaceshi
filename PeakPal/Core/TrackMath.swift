import Foundation

/// 轨迹数学计算工具（1:1 移植自安卓 TrackMath.java）
public enum TrackMath {
    static let R = 6371000.0

    public static func haversine(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
            * sin(dLng / 2) * sin(dLng / 2)
        return 2 * R * atan2(sqrt(a), sqrt(1 - a))
    }

    /// 累计距离（米）
    public static func totalDistance(_ pts: [TrackPt]) -> Double {
        var d = 0.0
        for i in 1..<max(pts.count, 1) {
            d += haversine(lat1: pts[i - 1].lat, lng1: pts[i - 1].lng, lat2: pts[i].lat, lng2: pts[i].lng)
        }
        return d
    }

    /// 累计爬升（米）
    public static func totalAscent(_ pts: [TrackPt]) -> Double {
        var a = 0.0
        for i in 1..<max(pts.count, 1) {
            let d = pts[i].alt - pts[i - 1].alt
            if d > 0 { a += d }
        }
        return a
    }

    /// 累计下降（米）
    public static func totalDescent(_ pts: [TrackPt]) -> Double {
        var d = 0.0
        for i in 1..<max(pts.count, 1) {
            let x = pts[i - 1].alt - pts[i].alt
            if x > 0 { d += x }
        }
        return d
    }

    /// 投影结果
    public struct Proj {
        public var seg = -1        // 所在线段索引（p[i] -> p[i+1]）
        public var offM = 0.0      // 横向偏移距离（米）
        public var remainM = 0.0   // 从起点累计沿程距离（米）
        public var fraction = 0.0
        public var lat = 0.0, lng = 0.0  // 投影点
    }

    /// 位置 → 轨迹最近投影（WGS84 平面近似，轨迹点间距短，精度足够）。
    /// fromSeg 限制只在 [fromSeg, size-2] 范围搜索，避免回头路误匹配；传 0 全程搜索。
    public static func project(_ pts: [TrackPt], lat: Double, lng: Double, fromSeg: Int, toSeg: Int? = nil) -> Proj? {
        guard pts.count >= 2 else { return nil }
        let latRad = lat * .pi / 180
        let kx = cos(latRad) * 111320.0 // 米/度经度
        let ky = 110540.0               // 米/度纬度
        let px = lng * kx, py = lat * ky

        // 预计算累计距离
        var cum = [Double](repeating: 0, count: pts.count)
        for i in 1..<pts.count {
            cum[i] = cum[i - 1] + haversine(lat1: pts[i - 1].lat, lng1: pts[i - 1].lng, lat2: pts[i].lat, lng2: pts[i].lng)
        }

        var best = Double.greatestFiniteMagnitude
        var r = Proj()
        let start = max(0, fromSeg)
        let end = min(toSeg ?? pts.count - 2, pts.count - 2)
        guard end >= start else { return nil }
        for i in start...end {
            let ax = pts[i].lng * kx, ay = pts[i].lat * ky
            let bx = pts[i + 1].lng * kx, by = pts[i + 1].lat * ky
            let abx = bx - ax, aby = by - ay
            let ab2 = abx * abx + aby * aby
            var t = ab2 == 0 ? 0.0 : ((px - ax) * abx + (py - ay) * aby) / ab2
            t = max(0, min(1, t))
            let cx = ax + abx * t, cy = ay + aby * t
            let d = sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
            if d < best {
                best = d
                r.seg = i
                r.fraction = t
                r.offM = d
                r.remainM = cum[i] + (cum[i + 1] - cum[i]) * t
                r.lat = cy / ky
                r.lng = cx / kx
            }
        }
        return r.seg < 0 ? nil : r
    }

    /// 剩余距离沿后续轨迹的累计爬升（米），用于预计到达
    public static func remainAscent(_ pts: [TrackPt], seg: Int) -> Double {
        var a = 0.0
        for i in max(1, seg + 1)..<pts.count {
            let d = pts[i].alt - pts[i - 1].alt
            if d > 0 { a += d }
        }
        return a
    }

    /// 预计徒步耗时（分钟）：距离 km + 爬升，Tobler 简化式
    public static func estimateMinutes(distM: Double, ascM: Double) -> Double {
        let km = distM / 1000.0
        return km * 12 + ascM / 10.0 // 平路均速 5km/h + 每爬 100m 加 10 分钟
    }

    /// 难度星级 1-5：距离 + 爬升综合
    public static func difficulty(distM: Double, ascM: Double) -> Int {
        let score = distM / 1000.0 / 5.0 + ascM / 300.0 // 5km 或 300m 各算 1 分
        if score <= 1.5 { return 1 }
        if score <= 3 { return 2 }
        if score <= 5 { return 3 }
        if score <= 7.5 { return 4 }
        return 5
    }

    /// 难度星文本
    public static func stars(_ n: Int) -> String {
        return String(repeating: "★", count: n) + String(repeating: "☆", count: 5 - n)
    }

    /// 格式化时长 mm:ss / hh:mm:ss（入参毫秒）
    public static func fmtDuration(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        if s < 3600 { return String(format: "%02d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// 格式化时长为「x 小时 y 分」（入参分钟）
    public static func fmtEtaMin(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if m < 60 { return "\(m) 分钟" }
        return "\(m / 60) 小时 \(m % 60) 分"
    }

    /// 格式化距离
    public static func fmtDistance(_ m: Double) -> String {
        if m < 1000 { return String(format: "%.0f m", m) }
        return String(format: "%.2f km", m / 1000)
    }

    /// 均速 km/h（距离米、时长毫秒），无效时返回 "--"
    public static func fmtSpeed(_ meters: Double, _ ms: Int64) -> String {
        if ms < 30_000 || meters < 10 { return "--" }
        let kmh = meters / 1000.0 / (Double(ms) / 3600000.0)
        return String(format: "%.1f km/h", kmh)
    }
}
