import Foundation
import UIKit

/// 3D 地图样式（1:1 移植自安卓 Map3DStyle.java）：
/// 影像 = 天地图 img_w（需 tk）无 tk 回退 Esri World Imagery；
/// 高程 = AWS Open Data terrarium DEM + 山体阴影。
/// MapKit 2D 与 MapLibre 3D 页共用「map3d」偏好（iOS 用 UserDefaults suite "map3d"），tk/影像源设置互通。
public enum Map3DStyle {

    static let esriImg = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
    static let awsDem = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"

    /// 地形夸张档位（0~n 倍山体起伏），默认 1.4
    public static let exagOpts: [Float] = [1.0, 1.4, 2.0, 3.0]

    static var prefs: UserDefaults { UserDefaults(suiteName: "map3d") ?? .standard }

    public static func exag() -> Float {
        let e = prefs.float(forKey: "exag")
        return (e >= 0.5 && e <= 4) ? e : 1.4
    }

    public static func setExag(_ v: Float) { prefs.set(v, forKey: "exag") }

    public static func tdtTk() -> String { prefs.string(forKey: "tdt_tk") ?? "" }
    public static func setTdtTk(_ tk: String) { prefs.set(tk, forKey: "tdt_tk") }
    public static func imgSrc() -> Int { prefs.integer(forKey: "src") }

    static var tdtReady: Bool {
        imgSrc() == 0 && !tdtTk().isEmpty
    }

    /// 天地图影像 t0..t7 子域负载均衡
    static func tilesJson() -> String {
        let tk = tdtTk()
        var arr: [String] = []
        for i in 0..<8 {
            arr.append("https://t\(i).tianditu.gov.cn/img_w/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=img&STYLE=default&TILEMATRIXSET=w&FORMAT=tiles&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&tk=\(tk)")
        }
        let jsonArr = arr.map { "\"\($0)\"" }.joined(separator: ",")
        return "[\(jsonArr)]"
    }

    /// 生成 MapLibre style JSON（与安卓端同一数据源、同一图层结构）
    public static func json() -> String {
        let imgMax = tdtReady ? "17" : "18"
        let img = tdtReady ? tilesJson() : "[\"\(esriImg)\"]"
        let ex = exag()
        return """
        {"version":8,
        "sources":{
        "img":{"type":"raster","tiles":\(img),"tileSize":256,"maxzoom":\(imgMax)},
        "dem":{"type":"raster-dem","tiles":["\(awsDem)"],"encoding":"terrarium","tileSize":256,"maxzoom":14}
        },
        "layers":[
        {"id":"bg","type":"background","paint":{"background-color":"#10160f"}},
        {"id":"img","type":"raster","source":"img"},
        {"id":"hillshade","type":"hillshade","source":"dem",
        "paint":{"hillshade-exaggeration":0.35,
        "hillshade-shadow-color":"#0b1a0e",
        "hillshade-highlight-color":"#ffffff",
        "hillshade-accent-color":"#14251a"}}
        ],
        "terrain":{"source":"dem","exaggeration":\(ex)}
        }
        """
    }

    /// style JSON → 可加载的 URL（写入 Caches 临时文件）
    public static func styleURL() -> URL {
        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("map3d_style.json")
        try? json().data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}
