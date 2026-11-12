import Foundation

/// 平台路线库（1:1 对接安卓 TracksFragment/HomeFragment v7.8/v7.69 的 pubtracks 接入）：
/// GET /api/pubtracks?q= 搜索（AI 轨迹 + 用户上传 + 三批两步路 KMZ，服务器 v153 新仓库）
/// GET /pub/gpx?src=&name= 下载（Bearer token，不在 /api 前缀下，走原始 URLSession）
public enum PubLibrary {

    public struct Item: Identifiable {
        public let name: String       // 原始文件名（含扩展名，下载参数用）
        public let src: String        // ai / user / kmz
        public let loc: String        // 所在城市（GPX 首点就近匹配 / KMZ 文件名尾段）
        public let size: Int
        public let mtime: Int
        public var id: String { src + "/" + name }
        /// 展示名：loc + " - " + 清洗后的路线名（与安卓 pubLabel+label 同款）
        public var label: String {
            let clean = PubLibrary.pubLabel(fname: name, loc: loc, src: src)
            return loc.isEmpty ? clean : loc + " - " + clean
        }
    }

    /// 平台路线展示名：去扩展名；KMZ 再去「序号_」前缀与尾部重复城市段
    /// （001_三峰大觉寺环线_北京 → 三峰大觉寺环线，配上 loc=北京）
    public static func pubLabel(fname: String, loc: String, src: String) -> String {
        var s = fname
        if let r = s.range(of: "\\.(gpx|kmz)$", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<r.lowerBound])
        }
        if src == "kmz" {
            if let r = s.range(of: "^\\d+_", options: .regularExpression) {
                s = String(s[r.upperBound...])
            }
            if !loc.isEmpty && s.hasSuffix("_" + loc) {
                s = String(s.dropLast(loc.count + 1))
            }
        }
        return s
    }

    /// 搜索平台路线（需登录；失败静默返回空，不干扰本地搜索体验——与安卓同策略）
    public static func search(_ query: String) async -> [Item] {
        let token = Session.shared.token
        guard !token.isEmpty else { return [] }
        do {
            let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let res = try await Session.shared.api.request("GET", "pubtracks?q=" + q)
            guard let arr = res["items"] as? [[String: Any]] else { return [] }
            return arr.map { o in
                Item(name: o["name"] as? String ?? "",
                     src: o["src"] as? String ?? "ai",
                     loc: o["loc"] as? String ?? "",
                     size: o["size"] as? Int ?? 0,
                     mtime: o["mtime"] as? Int ?? 0)
            }
        } catch {
            return []
        }
    }

    /// 下载平台路线 → 解析入库，返回新轨迹 id（失败抛错；与安卓 downloadPub 同流程）
    @discardableResult
    public static func download(_ item: Item) async throws -> Int64 {
        guard let url = URL(string: Session.shared.server + "/pub/gpx?src=" + item.src
                + "&name=" + (item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) else {
            throw ApiClient.ApiError.invalidAddress
        }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("Bearer " + Session.shared.token, forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw ApiClient.ApiError.http((resp as? HTTPURLResponse)?.statusCode ?? 500, nil)
        }
        guard data.count <= TrackImport.MAX_CONTAINER_BYTES else {
            throw TrackImport.ImportError.damaged
        }
        // 落盘临时文件再解析（TrackImport 按扩展名分流 GPX/KMZ）
        let ext = item.name.lowercased().hasSuffix(".kmz") ? "kmz" : "gpx"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pub_\(UUID().uuidString).\(ext)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try TrackImport.parse(url: tmp)
        let id = TrackImport.save(r)
        guard id > 0 else { throw TrackImport.ImportError.noTrack }
        return id
    }
}

/// 轨迹云端仓库（1:1 对接安卓 TracksFragment 云上传：POST tracks + GPX 同步到平台路线库）
public enum CloudTracks {

    public struct UploadOutcome {
        public let cloudId: Int64
        public let libSynced: Bool   // 平台路线库同步是否成功（失败不影响云端）
    }

    /// 上传轨迹到云端仓库，并同步 GPX 到平台路线库（待审核）
    /// 与安卓字段一致：{name,start,end,distance,dur,asc,maxalt,points:[{lat,lng,alt,t}]}
    public static func upload(_ t: Track, pts: [TrackPt]) async throws -> UploadOutcome {
        guard pts.count >= 2 else { throw ApiClient.ApiError.emptyBody }
        let points: [[String: Any]] = pts.map {
            ["lat": $0.lat, "lng": $0.lng, "alt": $0.alt, "t": $0.t]
        }
        let data: [String: Any] = [
            "name": t.name, "start": t.start, "end": t.end,
            "distance": t.distance, "dur": t.dur, "asc": t.asc,
            "maxalt": t.maxalt, "points": points,
        ]
        let res = try await Session.shared.api.request("POST", "tracks", body: data)
        let cloudId = (res["id"] as? NSNumber)?.int64Value ?? 0
        guard cloudId > 0 else { throw ApiClient.ApiError.http(500, "服务器未返回轨迹 id") }
        // 同步 GPX 到平台路线库（服务器用户上传轨迹文件夹，待审核）；失败不影响云端上传
        var libSynced = false
        if let gpx = Gpx.build(t, pts).data(using: .utf8) {
            let fname = t.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t.name
            do {
                _ = try await Session.shared.api.upload("upload/track?name=" + fname + ".gpx",
                                                        data: gpx, contentType: "application/gpx+xml")
                libSynced = true
            } catch { libSynced = false }
        }
        return UploadOutcome(cloudId: cloudId, libSynced: libSynced)
    }
}
