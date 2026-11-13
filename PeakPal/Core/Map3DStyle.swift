import Foundation
import UIKit

/// 3D 地图样式（1:1 移植自安卓 Map3DStyle.java + Tiles.java）：
/// 影像 = 天地图 img_w（需 tk）无 tk 回退 Esri World Imagery；
/// 底图可切换 = 影像(默认) / 高德标准图 / 高德卫星图(+路网) / OpenStreetMap
/// ——高德瓦片与安卓端 Tiles.AMAP/AMAP_SATELLITE/AMAP_ROADS 完全同源（osmdroid 直连同一 URL）。
/// 高程 = AWS Open Data terrarium DEM + 山体阴影。
/// 注意：高德瓦片为 GCJ-02，选高德底图时所有覆盖物需 wgs2gcj 纠偏（见 needsGcj）。
public enum Map3DStyle {

    static let esriImg = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
    static let awsDem = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"

    /// 地形夸张档位（0~n 倍山体起伏），默认 1.4
    public static let exagOpts: [Float] = [1.0, 1.4, 2.0, 3.0]

    /// 底图选项（对应安卓 LAYER_NAMES：影像 + 高德标准/卫星 + OSM）
    public static let basemapNames = ["卫星影像", "高德标准图", "高德卫星图", "OSM"]

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

    // MARK: - 底图切换（对应安卓 map_layer 循环切换）

    public static func basemap() -> Int {
        let v = prefs.integer(forKey: "basemap")
        return v >= 0 && v < basemapNames.count ? v : 0
    }

    public static func setBasemap(_ v: Int) { prefs.set(v, forKey: "basemap") }

    // MARK: - 足迹热力图（对应安卓足迹热力：所有本地轨迹点叠加热力渲染）

    public static func heat() -> Bool { prefs.bool(forKey: "heat") }
    public static func setHeat(_ on: Bool) { prefs.set(on, forKey: "heat") }

    /// 全部本地轨迹抽稀 → GeoJSON FeatureCollection（高德系底图时逐点 wgs2gcj）
    static func heatData() -> String {
        var pts: [(Double, Double)] = []
        let gcj = needsGcj()
        for t in Db.shared.listTracks().prefix(30) {
            var p = Db.shared.loadPts(tid: t.id)
            if p.count > 400 {
                let step = p.count / 400 + 1
                p = p.enumerated().compactMap { ($0.offset % step == 0 || $0.offset == p.count - 1) ? $0.element : nil }
            }
            for q in p {
                if gcj { let g = Coord.wgs2gcj(lat: q.lat, lng: q.lng); pts.append(g) }
                else { pts.append((q.lat, q.lng)) }
            }
        }
        guard !pts.isEmpty else { return "{\"type\":\"FeatureCollection\",\"features\":[]}" }
        let feats = pts.map {
            "{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[\($0.1),\($0.0)]}}"
        }
        return "{\"type\":\"FeatureCollection\",\"features\":[\(feats.joined(separator: ","))]}"
    }

    /// 当前底图是否为 GCJ-02（高德系）→ 覆盖物/定位需 wgs2gcj 纠偏
    public static func needsGcj() -> Bool {
        let v = basemap()
        return v == 1 || v == 2
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

    /// 高德瓦片（与安卓 Tiles.java 同一 URL 模板；MapLibre 占位符 {z}/{x}/{y}）
    static func amapTiles(style: String) -> String {
        var arr: [String] = []
        for i in 1...4 {
            arr.append("https://wprd0\(i).is.autonavi.com/appmaptile?x={x}&y={y}&z={z}&lang=zh_cn&size=1&scl=1&style=\(style)&ltype=7")
        }
        return "[" + arr.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    static func amapSatTiles(style: String) -> String {
        var arr: [String] = []
        for i in 1...4 {
            arr.append("https://webst0\(i).is.autonavi.com/appmaptile?x={x}&y={y}&z={z}&lang=zh_cn&size=1&style=\(style)")
        }
        return "[" + arr.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }

    /// 可见性快捷写法
    static func vis(_ on: Bool) -> String { on ? "visible" : "none" }

    /// 生成 MapLibre style JSON（与安卓端同一数据源、同一图层结构 + 底图切换 + 热力图）
    public static func json() -> String {
        let imgMax = tdtReady ? "17" : "18"
        let img = tdtReady ? tilesJson() : "[\"\(esriImg)\"]"
        let ex = exag()
        let bm = basemap()
        // 热力图层（足迹热力：开关打开且有本地轨迹点时才生成）
        var heatLayer = ""
        if heat() {
            let data = heatData()
            if !data.contains("\"features\":[]") {
                heatLayer = """
                ,"heat_src":{"type":"geojson","data":\(data)}
                ,"heat":{"type":"heatmap","source":"heat_src","paint":{
                "heatmap-weight":1,"heatmap-intensity":1,"heatmap-radius":18,"heatmap-opacity":0.72,
                "heatmap-color":["interpolate",["linear"],["heatmap-density"],0,"rgba(0,0,0,0)",
                0.2,"rgba(0,255,80,0.35)",0.4,"rgba(255,230,0,0.55)",0.6,"rgba(255,140,0,0.72)",
                0.8,"rgba(255,40,40,0.85)",1,"rgba(180,0,0,1)"]}}
                """
            }
        }
        return """
        {"version":8,
        "sources":{
        "img":{"type":"raster","tiles":\(img),"tileSize":256,"maxzoom":\(imgMax)},
        "amap":{"type":"raster","tiles":\(amapTiles(style: "7")),"tileSize":256,"maxzoom":18},
        "amapsat":{"type":"raster","tiles":\(amapSatTiles(style: "6")),"tileSize":256,"maxzoom":18},
        "amaproads":{"type":"raster","tiles":\(amapSatTiles(style: "8")),"tileSize":256,"maxzoom":18},
        "osm":{"type":"raster","tiles":["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],"tileSize":256,"maxzoom":19},
        "dem":{"type":"raster-dem","tiles":["\(awsDem)"],"encoding":"terrarium","tileSize":256,"maxzoom":14}
        \(heatLayer)},
        "layers":[
        {"id":"bg","type":"background","paint":{"background-color":"#10160f"}},
        {"id":"img","type":"raster","source":"img","layout":{"visibility":"\(vis(bm == 0))"}},
        {"id":"amap","type":"raster","source":"amap","layout":{"visibility":"\(vis(bm == 1))"}},
        {"id":"amapsat","type":"raster","source":"amapsat","layout":{"visibility":"\(vis(bm == 2))"}},
        {"id":"amaproads","type":"raster","source":"amaproads","layout":{"visibility":"\(vis(bm == 2))"}},
        {"id":"osm","type":"raster","source":"osm","layout":{"visibility":"\(vis(bm == 3))"}},
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
