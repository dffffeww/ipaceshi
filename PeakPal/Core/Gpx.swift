import Foundation

/// 轨迹文件导出：GPX / KML(轨迹) / KML(路径)（1:1 移植自安卓 Gpx.java）。
/// KMZ（zip 容器）iOS 无系统级 zip API，用第三方 ZipArchive 才能实现，暂以 KML 轨迹替代。
public enum Gpx {

    public enum Fmt: String, CaseIterable {
        case gpx = "GPX"
        case kmlTrack = "KML轨迹"
        case kmlPath = "KML路径"
    }

    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    /// 导出（返回文件字节与扩展名），调用方写入文件后用 UIActivityViewController 分享
    public static func export(_ t: Track, _ pts: [TrackPt], fmt: Fmt) -> (data: Data, ext: String, mime: String) {
        switch fmt {
        case .kmlTrack:
            return (Data(buildKml(t, pts, withTime: true).utf8), "kml", "application/vnd.google-earth.kml+xml")
        case .kmlPath:
            return (Data(buildKml(t, pts, withTime: false).utf8), "kml", "application/vnd.google-earth.kml+xml")
        case .gpx:
            return (Data(build(t, pts).utf8), "gpx", "application/gpx+xml")
        }
    }

    /// 文件名（与安卓一致：track_yyyyMMdd_HHmmss.ext）
    public static func fileName(_ t: Track, ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "track_\(f.string(from: t.startDate)).\(ext)"
    }

    /// 构建 GPX XML
    public static func build(_ t: Track, _ pts: [TrackPt]) -> String {
        var sb = ""
        sb += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        sb += "<gpx version=\"1.1\" creator=\"Lisa爱徒步\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        sb += "  <trk>\n    <name>\(esc(t.name))</name>\n    <trkseg>\n"
        for p in pts {
            let time = p.t > 0 ? "<time>\(iso.string(from: Date(timeIntervalSince1970: Double(p.t) / 1000)))</time>" : ""
            sb += String(format: "      <trkpt lat=\"%.6f\" lon=\"%.6f\"><ele>%.1f</ele>%@</trkpt>\n", p.lat, p.lng, p.alt, time)
        }
        sb += "    </trkseg>\n  </trk>\n</gpx>\n"
        return sb
    }

    /// 构建 KML：withTime=true 为「KML轨迹」（gx:Track 含时间，两步路/Google Earth 可回放），
    /// false 为「KML路径」（LineString，仅经纬高程，兼容大部分第三方软件）。
    /// 注意：KML 标准坐标是 WGS84，与 GPX 同源，直接输出原始坐标即可。
    public static func buildKml(_ t: Track, _ pts: [TrackPt], withTime: Bool) -> String {
        var sb = ""
        sb += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        sb += "<kml xmlns=\"http://www.opengis.net/kml/2.2\" xmlns:gx=\"http://www.google.com/kml/ext/2.2\">\n"
        sb += "  <Document><name>\(esc(t.name))</name>\n"
        sb += "    <Placemark><name>\(esc(t.name))</name>\n"
        if withTime {
            sb += "      <gx:Track>\n"
            for p in pts {
                if p.t > 0 { sb += "        <when>\(iso.string(from: Date(timeIntervalSince1970: Double(p.t) / 1000)))</when>\n" }
                sb += String(format: "        <gx:coord>%.6f %.6f %.1f</gx:coord>\n", p.lng, p.lat, p.alt)
            }
            sb += "      </gx:Track>\n"
        } else {
            sb += "      <LineString><tessellate>1</tessellate><coordinates>"
            for p in pts {
                sb += String(format: "%.6f,%.6f,%.1f ", p.lng, p.lat, p.alt)
            }
            sb += "</coordinates></LineString>\n"
        }
        sb += "    </Placemark>\n  </Document>\n</kml>\n"
        return sb
    }

    static func esc(_ s: String) -> String {
        return (s as NSString)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
