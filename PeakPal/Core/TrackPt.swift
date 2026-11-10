import Foundation

/// 轨迹点（1:1 对应安卓 TrackPt）
public struct TrackPt: Codable, Identifiable {
    public var id: Int { seq }
    public var seq: Int = 0
    public var lat: Double
    public var lng: Double
    public var alt: Double
    public var t: Int64   // Unix 毫秒

    public init(lat: Double, lng: Double, alt: Double, t: Int64) {
        self.lat = lat; self.lng = lng; self.alt = alt; self.t = t
    }

    public var isValid: Bool {
        return !lat.isNaN && !lat.isInfinite && lat >= -90 && lat <= 90
            && !lng.isNaN && !lng.isInfinite && lng >= -180 && lng <= 180
            && !alt.isNaN && !alt.isInfinite
    }
}

/// 轨迹元数据（1:1 对应安卓 Track，字段与 SQLite 表结构一致）
public struct Track: Codable, Identifiable {
    public var id: Int64 = 0
    public var start: Int64 = 0     // Unix 毫秒
    public var end: Int64 = 0
    public var dur: Int64 = 0
    public var name: String = ""
    public var distance: Double = 0 // 米
    public var asc: Double = 0      // 累计爬升米
    public var maxalt: Double = 0
    /// 云端轨迹仓库 id（上传成功后回写，0=未上传），发帖插轨迹时避免重复上传
    public var cloudId: Int64 = 0
    /// 是否已完成（循迹走完全程、达成目标）
    public var done: Bool = false

    public var idValue: Int64 { id }
    public var startDate: Date { Date(timeIntervalSince1970: Double(start) / 1000) }

    public static func trackName(from start: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm 徒步"
        return f.string(from: Date(timeIntervalSince1970: Double(start) / 1000))
    }
}

/// 标注点/兴趣点（1:1 对应安卓 Poi，字段与 SQLite poi 表一致）
/// tid=0 为全局兴趣点（首页地图），tid=轨迹id 为导入轨迹绑定的标注点
public struct Poi: Codable, Identifiable {
    public var id: Int64 = 0
    public var name: String = ""
    public var note: String = ""     // 导入时解析的备注（KMZ/GPX 描述）
    public var lat: Double = 0
    public var lng: Double = 0
    public var alt: Double = 0
    public var t: Int64 = 0          // Unix 毫秒
    public var type: String = "waypoint"  // waypoint/water/camp/peak/danger
    public var tid: Int64 = 0        // 绑定轨迹 id（0=全局）

    public var isValid: Bool {
        return !lat.isNaN && !lat.isInfinite && lat >= -90 && lat <= 90
            && !lng.isNaN && !lng.isInfinite && lng >= -180 && lng <= 180
    }

    /// 类型显示名（与安卓 TrackDetailActivity.POI_TYPES 一致）
    public static func typeName(_ key: String) -> String {
        switch key {
        case "water": return "水源"
        case "camp": return "营地"
        case "peak": return "山峰"
        case "danger": return "危险"
        default: return "途经点"
        }
    }
}
