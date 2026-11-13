import Foundation
import zlib

/// 轨迹文件导入（1:1 移植自安卓 TrackImport.java）：
/// 支持 GPX / KML / KMZ / XMZ（zip 内含 .kml/.gpx），解析轨迹段 + 标注点并入库。
/// 限制与安卓一致：点数 30 万、容器 300MB、单 XML 120MB。
public enum TrackImport {

    public static let MAX_POINTS = 300_000
    public static let MAX_CONTAINER_BYTES: Int = 300 * 1024 * 1024
    public static let MAX_XML_BYTES: Int = 120 * 1024 * 1024
    public static let MAX_ENTRIES = 64

    /// 标注点（对应安卓 TrackImport.Wpt）
    public struct Wpt {
        public var lat: Double = 0
        public var lng: Double = 0
        public var alt: Double = 0
        public var name: String = ""
        public var desc: String = ""
    }

    public struct Result {
        public var name = "导入轨迹"
        public var segments: [[TrackPt]] = []
        public var pts: [TrackPt] = []
        public var wpts: [Wpt] = []
        public var skipped = 0

        mutating func finalize() {
            pts = segments.first ?? []
            if name.isEmpty { name = "导入轨迹" }
        }
    }

    public enum ImportError: LocalizedError {
        case emptyFile, unsupported, noTrack, allInvalid(Int), damaged
        public var errorDescription: String? {
            switch self {
            case .emptyFile: return "文件内容为空"
            case .unsupported: return "不支持的文件格式：仅支持 GPX / KML / KMZ / XMZ"
            case .noTrack: return "未解析到有效轨迹（只有独立的标注点，没有轨迹线）"
            case .allInvalid(let n): return "轨迹点全部无效（\(n) 个坐标无法解析），文件可能已损坏"
            case .damaged: return "这个压缩包里没有找到轨迹：KMZ/XMZ 应包含 .kml 或 .gpx 文件（只含照片或标注无效）"
            }
        }
    }

    // MARK: - 入口

    /// 解析文件（按扩展名分流 GPX/KML 直读，KMZ/XMZ 走 zip 解包）
    public static func parse(url: URL) throws -> Result {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        if data.isEmpty { throw ImportError.emptyFile }
        if data.count > MAX_CONTAINER_BYTES { throw ImportError.damaged }
        if ext == "kmz" || ext == "zip" || ext == "xmz" {
            return try parseZip(data)
        }
        if ext == "gpx" || ext == "kml" || ext == "xml" {
            return try parseXml(data)
        }
        // 无扩展名（内存临时文件）：嗅探首标签
        let head = String(data: data.prefix(512), encoding: .utf8) ?? ""
        if head.contains("<gpx") { return try parseXml(data) }
        if head.contains("<kml") { return try parseXml(data) }
        if head.contains("PK\u{03}\u{04}") { return try parseZip(data) }
        throw ImportError.unsupported
    }

    /// 解析 zip 容器（KMZ/XMZ）：只把 .kml/.gpx 条目解出来，其它条目（照片等）跳过
    static func parseZip(_ data: Data) throws -> Result {
        let entries = try MiniZip.list(data)
        var parts: [Result] = []
        for e in entries {
            let low = e.name.lowercased()
            guard low.hasSuffix(".kml") || low.hasSuffix(".gpx") else { continue }
            guard e.data.count <= MAX_XML_BYTES else { continue }
            if let r = try? parseXml(e.data) { parts.append(r) }
        }
        guard !parts.isEmpty else { throw ImportError.damaged }
        var out = parts[0]
        if parts.count > 1 {   // 多文件合并（与安卓 merge 同逻辑）
            for p in parts.dropFirst() {
                if out.name == "导入轨迹" && p.name != "导入轨迹" { out.name = p.name }
                out.segments += p.segments
                out.wpts += p.wpts
                out.skipped += p.skipped
            }
        }
        out.finalize()
        return out
    }

    // MARK: - XML 解析（XMLParser 移植安卓 XmlPullParser 状态机）

    static func parseXml(_ bytes: Data) throws -> Result {
        guard bytes.count <= MAX_XML_BYTES else { throw ImportError.damaged }
        let parser = XmlParser()
        let p = XMLParser(data: bytes)
        p.delegate = parser
        p.shouldProcessNamespaces = false
        if !p.parse(), parser.segments.isEmpty {
            // 与安卓一致：DOCTYPE 等轻微问题不拦，只有全无数据才报损坏
            if parser.root.isEmpty { throw ImportError.emptyFile }
        }
        guard !parser.segments.isEmpty else {
            if parser.skipped > 0 { throw ImportError.allInvalid(parser.skipped) }
            throw ImportError.noTrack
        }
        var r = Result()
        r.name = parser.name
        r.segments = parser.segments
        r.wpts = parser.wpts
        r.skipped = parser.skipped
        r.finalize()
        return r
    }

    static func number(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return 0 }
        return Double(t) ?? 0
    }

    /// KML description 常内嵌 HTML，剥掉标签只留可读文字（与安卓 stripHtml 同款）
    static func stripHtml(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        for (k, v) in ["&lt;": "<", "&gt;": ">", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 时间解析：ISO8601（含毫秒）为主，常见格式兜底；失败返回 0
    static func parseT(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return 0 }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return Int64(d.timeIntervalSince1970 * 1000) }
        let isoMs = ISO8601DateFormatter()
        isoMs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoMs.date(from: t) { return Int64(d.timeIntervalSince1970 * 1000) }
        for f in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = f
            if let d = df.date(from: t) { return Int64(d.timeIntervalSince1970 * 1000) }
        }
        return 0
    }

    /// 入库（与安卓 save 同逻辑）：多段坐标相同接缝去重拼接 → 建轨迹 → 标注点入 poi
    @discardableResult
    public static func save(_ r: Result) -> Int64 {
        var merged: [TrackPt] = []
        for seg in r.segments {
            if let a = merged.last, let b = seg.first,
               abs(a.lat - b.lat) < 1e-9 && abs(a.lng - b.lng) < 1e-9 {
                merged += seg.dropFirst()
            } else {
                merged += seg
            }
        }
        if merged.count < 2 { merged = r.pts }
        guard merged.count >= 2 else { return 0 }
        var t = Track()
        t.name = r.name
        t.start = merged.first?.t ?? 0
        t.end = merged.last?.t ?? 0
        if t.start == 0 {   // 无时间戳的路线（平台下载）：用当前时间命名排序
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            t.start = now; t.end = now
        }
        let id = Db.shared.insertTrack(&t, pts: merged)
        guard id > 0 else { return 0 }
        // 标注点入库：时间戳按序递增保证编号顺序与文件一致（与安卓同款）
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        for (i, w) in r.wpts.enumerated() {
            var poi = Poi()
            poi.name = w.name.isEmpty ? "标注点\(i + 1)" : w.name
            poi.note = w.desc
            poi.lat = w.lat; poi.lng = w.lng; poi.alt = w.alt
            poi.t = base + Int64(i)
            poi.type = "waypoint"
            poi.tid = id
            _ = Db.shared.insertPoi(poi, tid: id)
        }
        return id
    }

    final class XmlParser: NSObject, XMLParserDelegate {
        var name = "导入轨迹"
        var segments: [[TrackPt]] = []
        var wpts: [Wpt] = []
        var skipped = 0
        var root = ""

        private var stack: [String] = []
        private var owner = ""            // gpx: trk/rte；kml: LineString/Track
        private var ownerDepth = -1
        private var seg: [TrackPt] = []
        private var times: [Int64] = []
        private var segDepth = -1
        private var curWpt: Wpt? = nil
        private var wptDepth = -1
        private var inPt = false          // 正在读 trkpt/rtept 子元素
        private var ptLat = 0.0, ptLng = 0.0, ptAlt = 0.0
        private var ptTime: Int64 = 0
        // KML Placemark 状态
        private var pmDepth = -1, pointDepth = -1
        private var pmName = "", pmDesc = ""
        private var pmLat = 0.0, pmLng = 0.0, pmAlt = 0.0
        private var pmHasCoord = false
        // 文本捕获
        private var cap = ""              // 空=不捕获；ele/time/name/desc/cmt/coordinates/coord/when
        private var capBuf = ""

        private var depth: Int { stack.count }

        func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
            let tag = localName(el)
            stack.append(el)
            if root.isEmpty { root = tag; return }   // 根元素只登记，不做分支
            let d = depth

            if root == "gpx" {
                if (tag == "trk" || tag == "rte") && d == 2 {
                    owner = tag; ownerDepth = d
                    if tag == "rte" { seg = []; times = []; segDepth = d }
                } else if tag == "trkseg" && owner == "trk" && d == ownerDepth + 1 {
                    seg = []; times = []; segDepth = d
                } else if tag == "name" && d == ownerDepth + 1 && curWpt == nil && name == "导入轨迹" {
                    cap = "name"; capBuf = ""
                } else if !seg.isEmpty, d == segDepth + 1,
                          (tag == "trkpt" && owner == "trk") || (tag == "rtept" && owner == "rte") {
                    ptLat = number(attrs["lat"] ?? "")
                    ptLng = number(attrs["lon"] ?? "")
                    ptAlt = 0; ptTime = 0; inPt = true
                } else if inPt && d == segDepth + 2 && tag == "ele" {
                    cap = "ele"; capBuf = ""
                } else if inPt && d == segDepth + 2 && tag == "time" {
                    cap = "time"; capBuf = ""
                } else if tag == "wpt" && d == 2 {
                    curWpt = Wpt()
                    curWpt?.lat = number(attrs["lat"] ?? "")
                    curWpt?.lng = number(attrs["lon"] ?? "")
                    wptDepth = d
                } else if curWpt != nil && d == wptDepth + 1 && (tag == "ele" || tag == "name" || tag == "desc" || tag == "cmt") {
                    cap = tag; capBuf = ""
                }
            } else if root == "kml" {
                if tag == "Placemark" {
                    pmDepth = d; pointDepth = -1
                    pmName = ""; pmDesc = ""; pmLat = 0; pmLng = 0; pmAlt = 0; pmHasCoord = false
                } else if tag == "name" && pmDepth > 0 && d == pmDepth + 1 {
                    cap = "pmname"; capBuf = ""
                    if seg.isEmpty && name == "导入轨迹" { /* 名字在结束时统一处理 */ }
                } else if tag == "name" && pmDepth < 0 && seg.isEmpty && name == "导入轨迹" {
                    cap = "docname"; capBuf = ""
                } else if tag == "description" && pmDepth > 0 && d == pmDepth + 1 {
                    cap = "pmdesc"; capBuf = ""
                } else if tag == "Point" && pmDepth > 0 && d > pmDepth {
                    pointDepth = d
                } else if tag == "LineString" || tag == "Track" {
                    // gx:Track（MultiTrack 多段）；普通 KML 少见裸 <Track>，宽松匹配更稳
                    seg = []; times = []; segDepth = d; owner = tag
                } else if segDepth > 0 && d == segDepth + 1 {
                    if tag == "coordinates" && owner == "LineString" {
                        cap = "linestring"; capBuf = ""
                    } else if tag == "coord" && owner == "Track" {
                        cap = "coord"; capBuf = ""
                    } else if tag == "when" && owner == "Track" {
                        cap = "when"; capBuf = ""
                    }
                } else if tag == "coordinates" && pointDepth > 0 && d > pointDepth {
                    cap = "pmcoord"; capBuf = ""
                }
            }
        }

        func parser(_ p: XMLParser, foundCharacters string: String) {
            if !cap.isEmpty { capBuf += string }
        }

        func parser(_ p: XMLParser, foundCDATA CDATABlock: Data) {
            if !cap.isEmpty, let s = String(data: CDATABlock, encoding: .utf8) { capBuf += s }
        }

        func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let tag = localName(el)
            let d = depth   // 结束时元素自身还在栈顶，与安卓 END_TAG depth 一致
            defer { if !stack.isEmpty { stack.removeLast() } }

            // 结束捕获
            if !cap.isEmpty {
                let text = capBuf
                switch cap {
                case "ele": ptAlt = number(text)
                case "time": ptTime = parseT(text)
                case "name": if name == "导入轨迹" { let n = text.trimmingCharacters(in: .whitespacesAndNewlines); if !n.isEmpty { name = n } }
                case "docname": let n = text.trimmingCharacters(in: .whitespacesAndNewlines); if !n.isEmpty { name = n }
                case "pmname": pmName = text.trimmingCharacters(in: .whitespacesAndNewlines)
                case "pmdesc": pmDesc = stripHtml(text)
                case "cmt", "desc":
                    if curWpt != nil && (tag == "desc" || tag == "cmt") { curWpt?.desc = stripHtml(text) }
                case "linestring":
                    for tuple in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }) {
                        let a = tuple.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                        if a.count < 2 { skipped += 1; continue }
                        let al = a.count >= 3 && !a[2].isEmpty ? number(a[2]) : 0
                        addPoint(number(a[1]), number(a[0]), al, 0)
                    }
                case "coord":
                    let a = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).map(String.init)
                    if a.count != 3 { skipped += 1 }
                    else { addPoint(number(a[1]), number(a[0]), number(a[2]), 0) }
                case "when": times.append(parseT(text))
                case "pmcoord":
                    let a = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
                    if a.count >= 2 {
                        pmLat = number(a[1]); pmLng = number(a[0])
                        pmAlt = a.count >= 3 && !a[2].isEmpty ? number(a[2]) : 0
                        pmHasCoord = true
                    }
                default: break
                }
                cap = ""; capBuf = ""
            }

            if root == "gpx" {
                if inPt && (tag == "trkpt" || tag == "rtept") && d == segDepth + 1 {
                    addPoint(ptLat, ptLng, ptAlt, ptTime)
                    inPt = false
                }
                if tag == "wpt" && curWpt != nil && d == wptDepth {
                    if curWpt!.lat >= -90 && curWpt!.lat <= 90 && curWpt!.lng >= -180 && curWpt!.lng <= 180
                        && !(curWpt!.lat == 0 && curWpt!.lng == 0) {
                        wpts.append(curWpt!)
                    }
                    curWpt = nil; wptDepth = -1
                }
            } else if root == "kml" {
                if tag == "Placemark" && d == pmDepth {
                    if pmHasCoord {
                        var w = Wpt()
                        w.name = pmName; w.desc = pmDesc
                        w.lat = pmLat; w.lng = pmLng; w.alt = pmAlt
                        if w.lat >= -90 && w.lat <= 90 && w.lng >= -180 && w.lng <= 180 && !(w.lat == 0 && w.lng == 0) {
                            wpts.append(w)
                        }
                    }
                    pmDepth = -1; pointDepth = -1; pmName = ""; pmDesc = ""; pmHasCoord = false
                }
            }

            // 段结束：提交（gpx trkseg/trk/rte 与 kml LineString/Track 通用）
            if segDepth > 0 && d == segDepth && (tag == "trkseg" || tag == "trk" || tag == "rte"
                        || tag == "LineString" || tag == "Track") {
                if owner == "Track" && times.count != seg.count {
                    let n = min(times.count, seg.count)
                    for i in 0..<n { seg[i].t = times[i] }
                }
                if seg.count >= 2 { segments.append(seg) }
                seg = []; times = []; segDepth = -1
            }
            if ownerDepth > 0 && d == ownerDepth && (tag == "trk" || tag == "rte") {
                owner = ""; ownerDepth = -1
            }
        }

        private func addPoint(_ lat: Double, _ lng: Double, _ alt: Double, _ t: Int64) {
            if lat.isNaN || lng.isNaN || lat < -90 || lat > 90 || lng < -180 || lng > 180 {
                skipped += 1; return
            }
            if segmentsAllowed && seg.count < MAX_POINTS {
                seg.append(TrackPt(lat: lat, lng: lng, alt: alt.isNaN ? 0 : alt, t: t))
            }
        }

        private var segmentsAllowed: Bool {
            segments.reduce(0) { $0 + $1.count } + seg.count < MAX_POINTS
        }

        private func localName(_ el: String) -> String {
            if let i = el.firstIndex(of: ":") { return String(el[el.index(after: i)...]) }
            return el
        }
    }
}

/// 极简 zip 读取器（KMZ/XMZ）：解析中央目录 + zlib raw inflate，
/// 只解出需要的文本条目（.kml/.gpx），照片等大条目直接跳过不占内存。
enum MiniZip {

    struct Entry { var name: String; var data: Data }

    static func list(_ data: Data) throws -> [Entry] {
        // 1. 从尾部找 EOCD（0x06054b50），注释最长 65535+22
        let tail = data.suffix(min(data.count, 66_000))
        var eocdOff = -1
        if tail.count >= 22 {
            let arr = [UInt8](tail)
            var i = arr.count - 22
            while i >= 0 {
                if arr[i] == 0x50 && arr[i + 1] == 0x4B && arr[i + 2] == 0x05 && arr[i + 3] == 0x06 {
                    eocdOff = i; break
                }
                i -= 1
            }
        }
        guard eocdOff >= 0 else { throw TrackImport.ImportError.damaged }
        let base = data.count - tail.count
        let u16 = { (off: Int) -> Int in
            let o = base + off
            guard o + 2 <= data.count else { return 0 }
            return Int(data[o]) | (Int(data[o + 1]) << 8)
        }
        let u32 = { (off: Int) -> Int in
            let o = base + off
            guard o + 4 <= data.count else { return 0 }
            return Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
        }
        let total = u16(eocdOff + 10)
        let cdSize = u32(eocdOff + 12)
        var cdOff = u32(eocdOff + 16)
        guard cdOff >= 0, cdSize > 0, cdOff + cdSize <= data.count, total > 0, total <= 4096 else {
            throw TrackImport.ImportError.damaged
        }

        // 2. 遍历中央目录条目（0x02014b50）
        var out: [Entry] = []
        var pos = cdOff
        for _ in 0..<total {
            guard pos + 46 <= data.count,
                  data[pos] == 0x50 && data[pos + 1] == 0x4B && data[pos + 2] == 0x01 && data[pos + 3] == 0x02 else { break }
            let method = u16(pos + 10)
            let csize = u32(pos + 20)
            let usize = u32(pos + 24)
            let nlen = u16(pos + 28)
            let elen = u16(pos + 30)
            let clen = u16(pos + 32)
            let lho = u32(pos + 42)
            guard nlen > 0, pos + 46 + nlen <= data.count else { break }
            let nameData = data.subdata(in: (pos + 46)..<(pos + 46 + nlen))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .ascii) ?? ""
            let low = name.lowercased()
            let isWanted = low.hasSuffix(".kml") || low.hasSuffix(".gpx")
            if isWanted, usize > 0, usize <= TrackImport.MAX_XML_BYTES,
               lho > 0, lho + 30 + nlen <= data.count {
                // 本地头：30 字节定长 + nlen + elen 后是数据（csize 以中央目录为准，兼容 data-descriptor）
                let lnlen = u16(lho + 26), lelen = u16(lho + 28)
                let dataOff = lho + 30 + lnlen + lelen
                if method == 0 {   // stored
                    if dataOff + csize <= data.count {
                        out.append(Entry(name: name, data: data.subdata(in: dataOff..<(dataOff + csize))))
                    }
                } else if method == 8, dataOff + csize <= data.count {   // deflate
                    let comp = data.subdata(in: dataOff..<(dataOff + csize))
                    if let raw = inflateRaw(comp, maxOut: Int(usize)) {
                        out.append(Entry(name: name, data: raw))
                    }
                }
            }
            if out.count >= TrackImport.MAX_ENTRIES { break }
            pos += 46 + nlen + elen + clen
        }
        return out
    }

    /// zlib raw deflate 解压（KMZ 条目是 -15 windowBits 的裸流）。
    /// 输出缓冲按中央目录 usize 精确分配（zip 记录的是解压后真实大小），成功即整段返回。
    static func inflateRaw(_ src: Data, maxOut: Int) -> Data? {
        guard !src.isEmpty, maxOut > 0 else { return nil }
        var out = Data(count: maxOut)
        var written = 0
        let ok = out.withUnsafeMutableBytes { obuf -> Bool in
            src.withUnsafeBytes { sbuf -> Bool in
                guard let ip = sbuf.bindMemory(to: Bytef.self).baseAddress,
                      let op = obuf.bindMemory(to: Bytef.self).baseAddress else { return false }
                var stream = z_stream()
                inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
                defer { inflateEnd(&stream) }
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: ip)
                stream.avail_in = uInt(src.count)
                stream.next_out = op
                stream.avail_out = uInt(maxOut)
                let rc = inflate(&stream, Z_FINISH)
                written = maxOut - Int(stream.avail_out)
                return rc == Z_STREAM_END || rc == Z_OK || rc == Z_BUF_ERROR
            }
        }
        guard ok, written > 0 else { return nil }
        return out.prefix(written)
    }
}
