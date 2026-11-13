import SwiftUI
import MapLibre
import AVFoundation
import UIKit

/// 循迹导航（1:1 移植自安卓 NavigateActivity 核心算法）：
/// - 轨迹投影吸附（TrackMath.project，fromSeg 局部搜索 + 80m 防锁死重搜 + 10m 迟滞）
/// - 偏航三级判定：可靠偏移（偏离-GPS精度）>30m 轻微 / >80m 严重，连续 3 次确认才切状态
/// - 语音：偏离播报（限次 2 次）、前方坡度（400m 内坡量≥25m）、路口转弯（六向判定，40m 播报）
/// - 实际行走方向投票：累计净位移 5 米认定一次方向（反向走时坡度语音按真实方向）
/// - 剩余距离/累计升/降、Tobler 预计到达、已走段虚点渲染
/// - 同步记录：距离用 distanceFix 30 秒窗累计，爬升按 5 米基线增量（与安卓一致）
public final class NavigateEngine: NSObject, ObservableObject {

    // MARK: - 导航状态（Published 供 UI 展示）

    @Published public private(set) var navStarted = false
    @Published public private(set) var reversed = false
    @Published public private(set) var remainingM: Double = 0       // 剩余距离
    @Published public private(set) var offM: Double = 0             // 横向偏离
    @Published public private(set) var navState = 0                 // 0 正常 / 1 轻微偏离 / 2 严重偏离
    @Published public private(set) var ascRemain: Double = 0        // 剩余爬升
    @Published public private(set) var descRemain: Double = 0       // 剩余下降
    @Published public private(set) var distance: Double = 0         // 本次已走
    @Published public private(set) var ascent: Double = 0           // 本次累计升
    @Published public private(set) var descent: Double = 0          // 本次累计降
    @Published public private(set) var turnArrow = "▲"              // ◀ ▲ ▶ ⮌
    @Published public private(set) var turnText = "沿轨迹直行"
    @Published public private(set) var banner: String?              // 偏航横幅（nil=不显示）
    @Published public private(set) var walked: [TrackPt] = []       // 已走段（渲染虚点）
    @Published public private(set) var gpsAlt: Double = 0
    @Published public private(set) var etaText = "--"

    // MARK: - 内部（与安卓字段一一对应）

    public let track: [TrackPt]
    public let trackId: Int64
    private var total: Double = 0
    private var cum: [Double] = []
    private var turns: [(node: Int, diff: Double)] = []
    private var curSeg = -1
    private var candidate = -1
    private var confirmations = 0
    private var lastProjM: Double = -1
    private var projDelta: Double = 0
    private var moveDir = 1
    private var moveDirVotes = 0
    private var lastHillKey = ""
    private var lastHillAt: TimeInterval = 0
    private var lastSpeak: TimeInterval = 0
    private var offAlerts = 0
    private var lastTurnFar = -1
    private var lastTurnSpoken = -1
    private var lastTurnDist: Double = -1

    // 同步记录
    private var distanceFix: CLLocation?
    private var altitudeBase: Double?
    private var lastLocation: CLLocation?

    public init(track: Track, pts: [TrackPt]) {
        self.trackId = track.id
        self.track = pts
        super.init()
        buildNavData()
    }

    public var totalM: Double { total }
    /// 转角类型给通知/UI 用：L / S / R
    public var turnCode = "S"

    // MARK: - 预计算（对应安卓 buildNavData / bearingOf）

    /// 累计沿程 cum[] + 显著路口 turns[]（|转角|≥35°，转角>0=右转）
    private func buildNavData() {
        let n = track.count
        total = 0
        cum = [Double](repeating: 0, count: n)
        for i in 1..<n {
            cum[i] = cum[i - 1] + TrackMath.haversine(lat1: track[i - 1].lat, lng1: track[i - 1].lng,
                                                      lat2: track[i].lat, lng2: track[i].lng)
        }
        total = n > 0 ? cum[n - 1] : 0
        turns = []
        for j in 1..<(n - 1) where n >= 3 {
            let b1 = Self.bearingOf(track[j - 1], track[j])
            let b2 = Self.bearingOf(track[j], track[j + 1])
            var d = b2 - b1
            while d > 180 { d -= 360 }
            while d < -180 { d += 360 }
            if abs(d) >= 35 { turns.append((j, d)) }
        }
    }

    /// 两点间真北方位角（0~360，0=正北顺时针）
    static func bearingOf(_ a: TrackPt, _ b: TrackPt) -> Double {
        let la1 = a.lat * .pi / 180, la2 = b.lat * .pi / 180
        let dLon = (b.lng - a.lng) * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - 控制

    public func start() {
        navStarted = true
        banner = nil
        speak(navStarted ? "循迹导航开始，请沿轨迹前行" : "")
        LocationKit.shared.request()
    }

    public func stop() {
        navStarted = false
        navState = 0
        banner = nil
    }

    public func toggleReverse() {
        reversed.toggle()
        curSeg = -1
        lastProjM = -1
        projDelta = 0
        speak(reversed ? "已切换反向导航" : "已切换正向导航")
    }

    /// 位置驱动入口：LocationKit.lastLocation 变化时由 UI 层调用
    public func onLocation(_ loc: CLLocation) {
        lastLocation = loc
        // 精度过滤（GPS 30m / 网络 100m → iOS 统一 30m，过老的定位丢弃）
        guard loc.horizontalAccuracy > 0, loc.horizontalAccuracy <= 30 else { candidate = -1; confirmations = 0; return }
        guard abs(Date().timeIntervalSince(loc.timestamp)) < 15 else { candidate = -1; confirmations = 0; return }

        // 同步记录：距离 30 秒窗 + 3 米步进（对应安卓 distanceFix 逻辑）
        if distanceFix == nil || Date().timeIntervalSince(distanceFix!.timestamp) > 30 {
            distanceFix = loc
        } else if let f = distanceFix {
            let d = f.distance(from: loc)
            if d >= max(3, (loc.horizontalAccuracy + f.horizontalAccuracy) / 2) {
                distance += d
                distanceFix = loc
            }
        }
        // 爬升：5 米基线增量（对应安卓 altitudeBase 逻辑，过滤气压/GPS 海拔抖动）
        // iOS: verticalAccuracy <= 0 表示无垂直精度（安卓 hasVerticalAccuracy=false），照常接受
        let vAcc = loc.verticalAccuracy
        let altOk = vAcc <= 0 || vAcc <= 20
        if altOk {
            if let base = altitudeBase {
                let delta = loc.altitude - base
                if abs(delta) >= 5 {
                    if delta > 0 { ascent += delta } else { descent -= delta }
                    altitudeBase = loc.altitude
                }
            } else {
                altitudeBase = loc.altitude
            }
        }
        gpsAlt = loc.altitude
        update(loc: loc)
    }

    // MARK: - 核心更新（对应安卓 update()）

    private func update(loc: CLLocation) {
        guard track.count >= 2 else { return }
        // 投影吸附：局部搜索（防回头路误匹配）→ 远偏离时全局重搜（防锁死）
        var p: TrackMath.Proj?
        if curSeg < 0 {
            p = TrackMath.project(track, lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, fromSeg: 0)
        } else {
            let from = reversed ? 0 : max(0, curSeg - 2)
            let to: Int? = reversed ? min(track.count - 2, curSeg + 2) : nil
            p = TrackMath.project(track, lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, fromSeg: from, toSeg: to)
        }
        guard var proj = p, proj.seg >= 0 else { return }
        // 防锁死：偏离 >80m 时全局重搜，新结果明显更优（10m 迟滞）才采纳
        if proj.offM > 80 {
            if let p2 = TrackMath.project(track, lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, fromSeg: 0),
               p2.offM + 10 < proj.offM { proj = p2 }
        }
        curSeg = proj.seg
        let remaining = max(0, reversed ? proj.remainM : total - proj.remainM)
        remainingM = remaining
        offM = proj.offM

        // 实际移动方向投票（净位移 5 米认定一次，滤 GPS 抖动）
        if lastProjM >= 0 {
            projDelta += proj.remainM - lastProjM
            if abs(projDelta) > 5 {
                let d = projDelta > 0 ? 1 : -1
                projDelta = 0
                if d != moveDir { moveDir = d; moveDirVotes = 0 }
                moveDirVotes += 1
                if moveDirVotes == 3 { lastHillKey = "" }   // 方向稳定后清语音节流
            }
        }
        lastProjM = proj.remainM
        let effRev = moveDirVotes >= 3 ? moveDir < 0 : reversed

        // 剩余累计升/降（含当前段的分数权重）
        var ascR = 0.0, descR = 0.0
        for i in 0..<(track.count - 1) {
            let ahead = reversed ? i <= proj.seg : i >= proj.seg
            guard ahead else { continue }
            let w = i == proj.seg ? (reversed ? proj.fraction : 1 - proj.fraction) : 1.0
            let delta = reversed ? track[i].alt - track[i + 1].alt : track[i + 1].alt - track[i].alt
            let ad = delta * w
            if ad > 0 { ascR += ad } else { descR += -ad }
        }
        ascRemain = ascR
        descRemain = descR
        etaText = TrackMath.fmtEtaMin(TrackMath.estimateMinutes(distM: remaining, ascM: ascR))

        // 已走段（正向=起点→当前段；反向=终点→当前段）
        let from = reversed ? proj.seg + 1 : 0
        let to = reversed ? track.count : min(track.count, proj.seg + 1)
        walked = (to - from >= 2) ? Array(track[from..<to]) : []

        // 前方坡度语音
        let hill = findHill(proj, effRev: effRev)
        if navStarted { speakHill(hill) }

        // 路口转弯指引
        updateTurnHint(proj, remaining: remaining)

        // 偏航三级判定（连续 3 次确认，防 GPS 噪声误报）
        let reliableOff = max(0, proj.offM - loc.horizontalAccuracy)
        let target = reliableOff > 80 ? 2 : (reliableOff > 30 ? 1 : 0)
        if navStarted {
            if candidate != target { candidate = target; confirmations = 1 } else { confirmations += 1 }
            if confirmations >= 3 && target != navState {
                navState = target
                speak(navState == 2 ? "走错轨迹！请停步确认路线，建议原路返回"
                                    : navState == 1 ? "已偏离轨迹，请注意方向" : "已回到轨迹")
                if navState == 2 {
                    vibrate()
                    offAlerts = 0
                }
            }
            if navState != 2 { offAlerts = 0 }
            // 偏航重复提醒限次：追加 2 次（共 3 次），不无限循环
            if navState == 2 && offAlerts < 2 && Date().timeIntervalSince1970 - lastSpeak > 20 {
                offAlerts += 1
                speak("仍走错轨迹，请停步确认路线，避免迷路")
            }
        }
        banner = !navStarted ? nil
            : (navState == 0 ? nil
               : (navState == 2 ? "严重偏离，请停步确认路线" : "轻微偏离，请注意方向")
                  + (reversed ? " · 反向" : " · 正向"))
    }

    // MARK: - 路口转弯指引（对应安卓 updateTurnHint：高德式六向判定）

    private func updateTurnHint(_ p: TrackMath.Proj, remaining: Double) {
        guard track.count >= 2 else { return }
        let along = p.remainM
        var next: (node: Int, diff: Double)?
        for t in turns {
            let ahead = reversed ? cum[t.node] < along - 15 : cum[t.node] > along + 15
            if ahead { next = t; break }
        }
        let dist = next == nil ? Double.greatestFiniteMagnitude : abs(cum[next!.node] - along)
        if next == nil || dist > 800 {
            turnArrow = "▲"; turnText = "沿轨迹直行"
            turnCode = "S"
            lastTurnDist = -1; lastTurnFar = -1; lastTurnSpoken = -1
        } else {
            let a = next!.diff
            let absA = abs(a)
            let right = a > 0
            let node = next!.node
            if absA >= 150 {
                turnArrow = "⮌"; turnText = "掉头 \(TrackMath.fmtDistance(dist))"
                turnCode = right ? "R" : "L"
                if dist <= 120 && lastTurnFar != node {
                    lastTurnFar = node
                    speak("前方路口掉头，请调转方向")
                } else if dist <= 30 && lastTurnSpoken != node {
                    lastTurnSpoken = node
                    speak("马上掉头")
                }
            } else if absA >= 70 {
                let sharp = absA >= 110
                turnArrow = right ? "▶" : "◀"
                turnText = "\(sharp ? "急" : "")\(right ? "右" : "左")转 \(TrackMath.fmtDistance(dist))"
                turnCode = right ? "R" : "L"
                if dist <= 40 && lastTurnSpoken != node {
                    lastTurnSpoken = node
                    speak("前方\(sharp ? "急" : "")\(right ? "右" : "左")转")
                }
            } else {
                turnArrow = right ? "▶" : "◀"
                turnText = "\(right ? "右" : "左")前方 \(TrackMath.fmtDistance(dist))"
                turnCode = "S"
            }
            lastTurnDist = dist
        }
    }

    // MARK: - 前方坡段（对应安卓 findHill / speakHill）

    /// 扫描前方最近连续坡段：返回 {到坡起点距离米, 坡量, 1上/-1下}，无坡返回 nil
    private func findHill(_ p: TrackMath.Proj, effRev: Bool) -> (dist: Double, amount: Double, up: Int)? {
        var dist: Double = -1
        var amount = 0.0
        var up = 0
        for k in 0..<(track.count - 1) {
            let i = effRev ? p.seg - k : p.seg + 1 + k          // 段索引沿前进方向推进
            if i < 0 || i >= track.count - 1 { break }
            let dStart = effRev ? p.remainM - cum[i + 1] : cum[i] - p.remainM
            if dStart > 500 { break }
            // 反向时首段按剩余比例折算坡量，否则虚报爬升
            let delta: Double
            if effRev {
                delta = k == 0 ? (track[i].alt - track[i + 1].alt) * max(0, p.fraction)
                               : track[i].alt - track[i + 1].alt
            } else {
                delta = track[i + 1].alt - track[i].alt
            }
            if dist < 0 {
                if abs(delta) < 1 { continue }                  // 平段跳过
                dist = max(0, dStart)
                up = delta > 0 ? 1 : -1
                amount = abs(delta)
            } else {
                if delta * Double(up) < 0 && abs(delta) >= 1 { break }   // 反向坡 → 结束
                amount += abs(delta)
            }
            if amount >= 150 { break }
        }
        return dist < 0 ? nil : (dist, amount, up)
    }

    /// 坡度语音：前方 400 米内坡量 ≥25 米时播报（90 秒同向节流 / 8 秒全局节流）
    private func speakHill(_ hill: (dist: Double, amount: Double, up: Int)?) {
        guard let hill, hill.amount >= 25, hill.dist <= 400 else { return }
        let key = hill.up > 0 ? "U" : "D"
        let now = Date().timeIntervalSince1970
        if (key != lastHillKey || now - lastHillAt > 90) && now - lastSpeak > 8 {
            lastHillKey = key; lastHillAt = now
            speak(hill.up > 0
                  ? String(format: "前方 %.0f 米上坡，爬升 %.0f 米", hill.dist, hill.amount)
                  : String(format: "前方 %.0f 米下坡，下降 %.0f 米", hill.dist, hill.amount))
        }
    }

    // MARK: - 语音/振动

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        lastSpeak = Date().timeIntervalSince1970
        TtsKit.speak(text)   // 音色/语速走「声音设置」
    }

    private func vibrate() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - SwiftUI 页面

/// 循迹导航页：地图 + 转弯横幅 + 偏航横幅 + 底部统计面板（两步路风格）
struct NavigateScreen: View {
    @StateObject private var engine: NavigateEngine
    @StateObject private var loc = LocationKit.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pois: [Poi] = []          // 本轨迹标注点（v7.108 iOS：与安卓导航页 v7.107 同款）
    @State private var tappedPoi: Poi?
    /// 轨迹起点坐标（天气芯片定位用，对应安卓导航页天气芯片）
    private let routeStart: TrackPt?

    init(track: Track, pts: [TrackPt]) {
        _engine = StateObject(wrappedValue: NavigateEngine(track: track, pts: pts))
        routeStart = pts.first
    }

    var body: some View {
        ZStack {
            NavMapContainer(engine: engine, pois: pois) { tappedPoi = $0 }.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                // 天气芯片（对应安卓导航页 Weather 芯片：Open-Meteo + 15min 缓存）
                if let s = routeStart {
                    HStack {
                        Spacer()
                        WeatherChip(lat: s.lat, lng: s.lng)
                            .padding(.bottom, 6)
                    }
                    .padding(.horizontal, 12)
                }
                // 路口转弯大横幅
                if engine.navStarted {
                    HStack(spacing: 14) {
                        Text(engine.turnArrow).font(.system(size: 40, weight: .bold))
                        Text(engine.turnText).font(.headline)
                        Spacer()
                    }
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 12)
                }
                // 偏航横幅
                if let banner = engine.banner {
                    Text(banner)
                        .font(.subheadline.bold())
                        .foregroundStyle(engine.navState == 2 ? Color(red: 0.78, green: 0.2, blue: 0.16)
                                                             : Color(red: 0.7, green: 0.42, blue: 0))
                        .padding(10).frame(maxWidth: .infinity)
                        .background((engine.navState == 2 ? Color(red: 1, green: 0.92, blue: 0.9)
                                                          : Color(red: 1, green: 0.96, blue: 0.85))
                                    .opacity(0.92))
                }
                navPanel
            }
        }
        .navigationTitle("循迹导航")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            LocationKit.shared.request()
            pois = Db.shared.poisForTrack(engine.trackId)   // 本轨迹标注点 + 全局兴趣点（与安卓 poisForTrack 同源）
        }
        .onReceive(loc.$lastLocation) { l in
            if let l { engine.onLocation(l) }
        }
        .alert(item: $tappedPoi) { poi in
            // 点击标注点详情（与安卓导航页/详情页同款：类型·海拔·WGS84·导入备注）
            Alert(
                title: Text(poi.name.isEmpty ? "标注点" : poi.name),
                message: Text(Self.poiDetail(poi)),
                dismissButton: .default(Text("确定"))
            )
        }
    }

    static func poiDetail(_ poi: Poi) -> String {
        var msg = "\(Poi.typeName(poi.type)) · 海拔 \(String(format: "%.0f m", poi.alt))"
        + "\nWGS84: \(String(format: "%.6f, %.6f", poi.lat, poi.lng))"
        if !poi.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            msg += "\n\n" + poi.note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return msg
    }

    /// 底部面板：剩余/预计 + 偏离/海拔 + 本次行程 + 控制（对应安卓双面板）
    private var navPanel: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.2f", engine.remainingM / 1000))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("km").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("剩余").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(engine.etaText).font(.subheadline.bold())
                    Text("预计还需").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(String(format: "已行 %.2f km · 偏离 %.0f m · GPS海拔 ≈%.0f m · 累计升/降 %.0f/%.0f m",
                        engine.distance / 1000, engine.offM, engine.gpsAlt, engine.ascent, engine.descent))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button {
                    engine.toggleReverse()
                } label: {
                    Label(engine.reversed ? "反向" : "正向", systemImage: "arrow.left.arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    if engine.navStarted { engine.stop() } else { engine.start() }
                } label: {
                    Label(engine.navStarted ? "停止导航" : "开始导航",
                          systemImage: engine.navStarted ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.navStarted ? .red : Color(red: 0.9, green: 0.5, blue: 0.1))
            }
        }
        .padding(14)
        .background(.thinMaterial)
    }
}

/// 导航地图容器：轨迹线 + 已走段红色虚点 + 起终点徽章 + 里程碑 + 标注点（与安卓导航页同款）
struct NavMapContainer: UIViewRepresentable {
    @ObservedObject var engine: NavigateEngine
    var pois: [Poi]
    var onPoiTap: (Poi) -> Void

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero)
        map.styleURL = Map3DStyle.styleURL()
        map.showsUserLocation = true
        map.showsUserHeadingIndicator = true
        map.delegate = context.coordinator
        map.camera = MLNMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 30, longitude: 102),
                                  fromDistance: 8000, pitch: 50, heading: 0)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.pois = pois
        context.coordinator.onPoiTap = onPoiTap
        context.coordinator.render(map, engine: engine)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private var routeDrawn = false
        private var walkedCount = -1
        private var lastFollowAt = Date.distantPast
        var pois: [Poi]?                    // 标注点数据（数量变化触发重画）
        private var poisRendered = -1
        var onPoiTap: ((Poi) -> Void)?

    func render(_ map: MLNMapView, engine: NavigateEngine) {
        // 全轨迹蓝色线（一次）。注意：影像底图（天地图 img_w/Esri）为 WGS84，
        // 轨迹点同为 WGS84 —— 直投绘制，与安卓端一致；做 GCJ 纠偏反而会偏移几百米
        if !routeDrawn && engine.track.count >= 2 {
            routeDrawn = true
            let coords = engine.track.map { p in CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng) }
            let line = MLNPolyline(coordinates: coords, count: UInt(coords.count))
            map.addAnnotation(line)
            // 起终点发光徽章 + 里程碑徽章（与安卓轨迹详情页/导航页同款）
            addEndsAndKm(map, engine: engine)
            let padding = UIEdgeInsets(top: 120, left: 40, bottom: 220, right: 40)
            map.setVisibleCoordinates(coords, count: UInt(coords.count),
                                      edgePadding: padding,
                                      animated: false)
        }
        // 已走段红色虚点线（每轮重画，等价安卓 LiveOverlay.setWalkedPoints）
        if engine.walked.count != walkedCount {
            walkedCount = engine.walked.count
            for a in (map.annotations ?? []) where a is WalkedPolyline { map.removeAnnotation(a) }
            if engine.walked.count >= 2 {
                let coords = engine.walked.map { p in CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng) }
                map.addAnnotation(WalkedPolyline(coordinates: coords, count: UInt(coords.count)))
            }
        }
        // 标注点（后台查库晚于首帧：数量变化即刷新，等价安卓 addNavPois）
        let poiCount = pois?.count ?? -1
        if poisRendered != poiCount {
            poisRendered = poiCount
            for a in (map.annotations ?? []) where a is PoiAnnotation { map.removeAnnotation(a) }
            if let pois {
                for (idx, poi) in pois.enumerated() where poi.isValid {
                    map.addAnnotation(PoiAnnotation(poi: poi, num: idx + 1))
                }
            }
        }
        // 跟随：导航中每 3 秒居中一次（用户手势后不打断）
        if engine.navStarted, let loc = LocationKit.shared.lastLocation,
           Date().timeIntervalSince(lastFollowAt) > 3 {
            lastFollowAt = Date()
            map.setCenter(loc.coordinate, animated: true)
        }
    }

    /// 起终点徽章 + 里程碑（每满 1km 黑色数字徽章，与安卓 TrackOverlay.ensureMilestones 同算法）
    private func addEndsAndKm(_ map: MLNMapView, engine: NavigateEngine) {
        let pts = engine.track
        map.addAnnotation(IconAnnotation(image: PoiBadge.glowLabel("起"),
                                         coordinate: CLLocationCoordinate2D(latitude: pts[0].lat, longitude: pts[0].lng)))
        map.addAnnotation(IconAnnotation(image: PoiBadge.glowLabel("终"),
                                         coordinate: CLLocationCoordinate2D(latitude: pts[pts.count - 1].lat,
                                                                            longitude: pts[pts.count - 1].lng)))
        var d = 0.0
        var k = 1
        for i in 1..<pts.count {
            d += TrackMath.haversine(lat1: pts[i - 1].lat, lng1: pts[i - 1].lng,
                                     lat2: pts[i].lat, lng2: pts[i].lng)
            if d >= Double(k) * 1000 {
                map.addAnnotation(KmAnnotation(num: k,
                                               coordinate: CLLocationCoordinate2D(latitude: pts[i].lat, longitude: pts[i].lng)))
                k += 1
            }
        }
    }

        // MapLibre 无 renderer API：形状样式走这两个回调（v7.114 对齐官方 delegate 签名）
        public func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            if annotation is WalkedPolyline {
                return UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)   // 0xFFFF3B30 已走段红
            }
            return UIColor(red: 0.11, green: 0.48, blue: 0.26, alpha: 1)    // 循迹线深绿
        }

        public func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            return annotation is WalkedPolyline ? 7 : 5
        }

        // 标注点/里程碑/起终点徽章（位图图标，与安卓 glowDot/glowLabel/黑色公里徽章同款）
        public func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            func view(_ id: String, _ image: UIImage?) -> MLNAnnotationView {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MLNAnnotationView)
                    ?? MLNAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                // MapLibre 的 MLNAnnotationView 是纯 UIView（无 image 属性）：用 UIImageView 承载位图徽章
                v.subviews.forEach { $0.removeFromSuperview() }
                if let img = image {
                    let iv = UIImageView(image: img)
                    iv.frame = CGRect(origin: .zero, size: img.size)
                    v.bounds = iv.frame
                    v.addSubview(iv)
                }
                return v
            }
            if let poi = annotation as? PoiAnnotation {
                return view("nav_poi", PoiBadge.glowDot(poi.num))
            }
            if let km = annotation as? KmAnnotation {
                return view("nav_km", PoiBadge.kmBadge(km.num))
            }
            if let ic = annotation as? IconAnnotation {
                return view("nav_icon", ic.image)
            }
            return nil
        }

        public func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            if let a = annotation as? PoiAnnotation {
                onPoiTap?(a.poi)
                mapView.deselectAnnotation(a, animated: false)
            }
        }
    }

    final class WalkedPolyline: MLNPolyline { }
}

// MARK: - 地图徽章与注解（v7.108 iOS：与安卓导航页 v7.107/v7.108 同款观感）

/// 标注点注解（编号发光红点，点击弹详情；详情页气泡显示标题/类型）
final class PoiAnnotation: MLNPointAnnotation {
    let poi: Poi
    let num: Int
    init(poi: Poi, num: Int) {
        self.poi = poi
        self.num = num
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: poi.lat, longitude: poi.lng)
        title = "\(num) · \(poi.name.isEmpty ? "标注点" : poi.name)"
        subtitle = "\(Poi.typeName(poi.type)) · 海拔 \(String(format: "%.0f m", poi.alt))"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 里程碑注解（每满 1km 黑色数字徽章）
final class KmAnnotation: MLNPointAnnotation {
    let num: Int
    init(num: Int, coordinate: CLLocationCoordinate2D) {
        self.num = num
        super.init()
        self.coordinate = coordinate
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 固定图标注解（起终点发光徽章）
final class IconAnnotation: MLNPointAnnotation {
    let image: UIImage
    init(image: UIImage, coordinate: CLLocationCoordinate2D) {
        self.image = image
        super.init()
        self.coordinate = coordinate
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 徽章位图（1:1 移植安卓 TrackDetailActivity.glowDot/glowLabel + TrackOverlay.drawKmBadge）
enum PoiBadge {

    static func glowDot(_ num: Int) -> UIImage { badge(size: 44) { ctx, cx, cy, s in
        // 径向红色光晕
        let red = UIColor(red: 0.898, green: 0.224, blue: 0.208, alpha: 1)   // 0xFFE53935
        let colors = [red.withAlphaComponent(0.4).cgColor,
                      red.withAlphaComponent(0.13).cgColor,
                      red.withAlphaComponent(0).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
            ctx.cgContext.drawRadialGradient(grad, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                                             endCenter: CGPoint(x: cx, y: cy), endRadius: s / 2, options: [])
        }
        red.setFill()
        ctx.cgContext.fillEllipse(in: CGRect(x: cx - 10.5 * scale, y: cy - 10.5 * scale,
                                             width: 21 * scale, height: 21 * scale))
        drawCentered(String(num), cx: cx, cy: cy, size: 12.5, color: .white, in: ctx)
    } }

    static func glowLabel(_ ch: String) -> UIImage { badge(size: 46) { ctx, cx, cy, s in
        let red = UIColor(red: 0.898, green: 0.224, blue: 0.208, alpha: 1)   // 0xFFE53935
        let colors = [red.withAlphaComponent(0.53).cgColor,
                      red.withAlphaComponent(0.2).cgColor,
                      red.withAlphaComponent(0).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
            ctx.cgContext.drawRadialGradient(grad, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                                             endCenter: CGPoint(x: cx, y: cy), endRadius: s / 2, options: [])
        }
        red.setFill()
        ctx.cgContext.fillEllipse(in: CGRect(x: cx - 13.5 * scale, y: cy - 13.5 * scale,
                                             width: 27 * scale, height: 27 * scale))
        // 白描边提亮
        UIColor.white.setStroke()
        ctx.cgContext.strokeEllipse(in: CGRect(x: cx - 12.6 * scale, y: cy - 12.6 * scale,
                                               width: 25.2 * scale, height: 25.2 * scale))
        drawCentered(ch, cx: cx, cy: cy, size: 13, color: .white, in: ctx)
    } }

    /// 黑色实心圆 + 白色粗体编号，三位数自动加宽（与安卓 drawKmBadge 同款）
    static func kmBadge(_ num: Int) -> UIImage { badge(size: num >= 100 ? 25 : 21) { ctx, cx, cy, s in
        UIColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 0.9).setFill()   // 0xE6212121
        ctx.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: s - 2, height: s - 2))
        drawCentered(String(num), cx: cx, cy: cy, size: 11, color: .white, in: ctx)
    } }

    // MARK: 私有

    private static let scale = UIScreen.main.scale

    private static func badge(size dp: CGFloat, draw: (inout UIGraphicsImageRendererContext, _ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat) -> Void) -> UIImage {
        let s = dp * scale
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: s, height: s))
        return renderer.image { ctx in
            var ctx = ctx
            draw(&ctx, s / 2, s / 2, s)
        }
    }

    private static func drawCentered(_ text: String, cx: CGFloat, cy: CGFloat, size: CGFloat, color: UIColor, in ctx: UIGraphicsImageRendererContext) {
        let attr: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size * scale, weight: .bold),
            .foregroundColor: color,
        ]
        let str = NSAttributedString(string: text, attributes: attr)
        let sz = str.size()
        str.draw(at: CGPoint(x: cx - sz.width / 2, y: cy - sz.height / 2))
    }
}
