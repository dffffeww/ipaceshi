import Foundation

/// WGS84 → GCJ02 火星坐标转换（中国境内纠偏）
/// 1:1 移植自安卓端 Coord.java，算法与精度完全一致
public enum Coord {

    static func outOfChina(lat: Double, lng: Double) -> Bool {
        return lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271
    }

    static func transLat(_ x: Double, _ y: Double) -> Double {
        var r = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        r += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2.0 / 3.0
        r += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2.0 / 3.0
        r += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2.0 / 3.0
        return r
    }

    static func transLng(_ x: Double, _ y: Double) -> Double {
        var r = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        r += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2.0 / 3.0
        r += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2.0 / 3.0
        r += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2.0 / 3.0
        return r
    }

    /// WGS84 转 GCJ02；境外原样返回。返回 (lat, lng)
    public static func wgs2gcj(lat: Double, lng: Double) -> (Double, Double) {
        if outOfChina(lat: lat, lng: lng) { return (lat, lng) }
        var dLat = transLat(lng - 105, lat - 35)
        var dLng = transLng(lng - 105, lat - 35)
        let rad = lat / 180 * .pi
        var magic = sin(rad)
        magic = 1 - 0.00669342162296594323 * magic * magic
        let sq = sqrt(magic)
        dLat = (dLat * 180) / ((6378245 * (1 - 0.00669342162296594323)) / (magic * sq) * .pi)
        dLng = (dLng * 180) / (6378245 / sq * cos(rad) * .pi)
        return (lat + dLat, lng + dLng)
    }

    /// GCJ02 转 WGS84（迭代反算，精度优于 1e-7 度）。
    /// 用于把底图上的点击坐标还原成 WGS84 存储，保证与 GPS 定位一致。返回 (lat, lng)
    public static func gcj2wgs(lat: Double, lng: Double) -> (Double, Double) {
        if outOfChina(lat: lat, lng: lng) { return (lat, lng) }
        var wLat = lat, wLng = lng
        for _ in 0..<6 {
            let g = wgs2gcj(lat: wLat, lng: wLng)
            let dLat = g.0 - lat, dLng = g.1 - lng
            if abs(dLat) < 1e-9 && abs(dLng) < 1e-9 { break }
            wLat -= dLat
            wLng -= dLng
        }
        return (wLat, wLng)
    }
}
