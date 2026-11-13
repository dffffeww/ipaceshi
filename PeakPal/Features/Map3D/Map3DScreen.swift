import SwiftUI
import MapLibre
import Combine
import UIKit

/// 3D 地图页（对应安卓 MapFragment 的 3D 部分 + 2D 功能对齐）：
/// - 底图切换：卫星影像 / 高德标准图 / 高德卫星图(+路网) / OSM（对应安卓 LAYER_NAMES 循环）
/// - GCJ-02 纠偏：高德系底图时轨迹/队友/我的位置全部 wgs2gcj（对应安卓 GcjLocationProvider + Coord.wgs2gcj）
/// - 轨迹线叠加 + 记录中实时线（对应安卓 TrackOverlay + LiveOverlay）
/// - 队友实时位置图层（TeamOverlay 移植：绿点+名字胶囊+呼吸光晕，自己不画）
/// - 轨迹沿线卫生间（对应安卓 fetchToilets：GET /api/toilets/along）
/// - 海拔探针、地形夸张调节、回中
struct Map3DScreen: View {
    @StateObject private var vm = Map3DViewModel()
    @State private var showExagPicker = false

    var body: some View {
        ZStack {
            Map3DContainer(vm: vm).ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Button { vm.recenter() } label: {
                            Image(systemName: "location.fill").mapBtn()
                        }
                        // 底图切换（对应安卓 map_layer：循环 影像→高德标准→高德卫星→OSM）
                        Button { vm.cycleBasemap() } label: {
                            Image(systemName: "square.3.layers.3d").mapBtn()
                        }
                        Button { showExagPicker = true } label: {
                            Image(systemName: "mountain.2.fill").mapBtn()
                        }
                        Button { vm.toggleTrack() } label: {
                            Image(systemName: vm.trackOn ? "line.diagonal.fill" : "line.diagonal")
                                .mapBtn()
                        }
                        // 队友实时位置图层开关（对应安卓 TeamOverlay）
                        if TeamState.shared.inTeam {
                            Button { vm.toggleTeam() } label: {
                                Image(systemName: vm.teamOn ? "person.3.fill" : "person.3")
                                    .mapBtn()
                            }
                        }
                    }
                    .padding(.trailing, 12)
                }
                Spacer()
                // 底部信息条：海拔探针 / 队友点选信息 / 底图名（6 秒保持）
                if !vm.probeText.isEmpty {
                    Text(vm.probeText)
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
            }
        }
        .confirmationDialog("地形夸张", isPresented: $showExagPicker, titleVisibility: .visible) {
            ForEach(Map3DStyle.exagOpts, id: \.self) { e in
                Button(e == Map3DStyle.exag() ? "✓ \(e)x" : "\(e)x") {
                    Map3DStyle.setExag(e)
                    vm.reloadStyle()
                }
            }
        }
        .onAppear { vm.activate() }
        .onDisappear { vm.deactivate() }
    }
}

extension Image {
    func mapBtn() -> some View {
        resizable().scaledToFit().frame(width: 20, height: 20)
            .foregroundStyle(.white)
            .padding(12).background(.thinMaterial, in: Circle())
    }
}

// MARK: - ViewModel

@MainActor
final class Map3DViewModel: NSObject, ObservableObject {
    @Published var probeText = ""
    @Published var trackOn = false
    @Published var teamOn = true        // 队友图层默认开（在队伍中时）

    weak var mapView: MLNMapView?
    var probeHoldUntil = Date.distantPast    // Coordinator 需要读写（队友点选信息条保持 6 秒）
    private var teamSub: AnyCancellable?
    private var locSub: AnyCancellable?
    private var ptsSub: AnyCancellable?

    override init() {
        super.init()
        // 成员快照每轮同步 → 自动重绘队友图层（对应安卓 TeamService 广播 ACTION_MEMBERS）
        teamSub = TeamState.shared.$membersTick
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTeamLayer() }
        // 记录中每秒刷新我的位置点 + 实时线（对应安卓 LiveOverlay 收 ACTION_POINT）
        locSub = LocationKit.shared.$lastLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSelfDot() }
        ptsSub = LocationKit.shared.$ptsTick
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLiveLine() }
    }

    func activate() {
        probeText = ""
        // 新版底图记忆恢复后重绘覆盖物（GCJ 状态可能变化）
        redrawOverlays()
    }
    func deactivate() {}

    // MARK: - 坐标纠偏（高德系底图为 GCJ-02，需 wgs2gcj；影像/OSM 直投 WGS84）

    private func disp(_ lat: Double, _ lng: Double) -> CLLocationCoordinate2D {
        if Map3DStyle.needsGcj() {
            let g = Coord.wgs2gcj(lat: lat, lng: lng)
            return CLLocationCoordinate2D(latitude: g.0, longitude: g.1)
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    // MARK: - 底图切换（对应安卓 map_layer 循环）

    func cycleBasemap() {
        let next = (Map3DStyle.basemap() + 1) % Map3DStyle.basemapNames.count
        Map3DStyle.setBasemap(next)
        reloadStyle()
        probeText = "底图：\(Map3DStyle.basemapNames[next])"
        probeHoldUntil = Date().addingTimeInterval(3)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Date() >= (self?.probeHoldUntil ?? .distantFuture) { self?.probeText = "" }
        }
    }

    func reloadStyle() {
        mapView?.styleURL = Map3DStyle.styleURL()
        // 底图切换后 GCJ 状态可能翻转：原生蓝点开关 + 全部覆盖物按新坐标系重绘
        mapView?.showsUserLocation = !Map3DStyle.needsGcj()
        redrawOverlays()
    }

    private func redrawOverlays() {
        clearLiveLine()
        clearSelfDot()
        clearToilets()
        if trackOn { drawLocalTrack(showToilets: true) }
        if LocationKit.shared.recording { updateLiveLine() }
        updateTeamLayer()
        updateSelfDot()
    }

    func recenter() {
        LocationKit.shared.request()
        if let loc = LocationKit.shared.lastLocation {
            mapView?.setCenter(disp(loc.coordinate.latitude, loc.coordinate.longitude), zoomLevel: 15, animated: true)
        }
    }

    func toggleTrack() {
        trackOn.toggle()
        clearToilets()
        if trackOn { drawLocalTrack(showToilets: true) } else { clearTrack() }
    }

    func toggleTeam() {
        teamOn.toggle()
        updateTeamLayer()
    }

    /// 画出最近一条本地轨迹（按当前底图坐标系纠偏；对应安卓 TrackOverlay）
    func drawLocalTrack(showToilets: Bool = false) {
        guard let map = mapView, let latest = Db.shared.listTracks().first else { return }
        var pts = Db.shared.loadPts(tid: latest.id)
        guard pts.count >= 2 else { return }
        if showToilets { fetchToilets(pts: pts) }
        if Map3DStyle.needsGcj() {
            // 抽稀后再逐点纠偏（>1000 点先每 N 取 1，避免逐点转换卡顿）
            if pts.count > 1000 {
                let step = pts.count / 1000 + 1
                pts = pts.enumerated().compactMap { $0.offset % step == 0 || $0.offset == pts.count - 1 ? $0.element : nil }
            }
        }
        let coords = pts.map { disp($0.lat, $0.lng) }
        let line = MLNPolyline(coordinates: coords, count: UInt(coords.count))
        map.addAnnotation(line)
        let pad = UIEdgeInsets(top: 80, left: 40, bottom: 80, right: 40)
        map.setVisibleCoordinates(coords, count: UInt(coords.count), edgePadding: pad, animated: true)
    }

    func clearTrack() {
        guard let map = mapView else { return }
        for a in (map.annotations ?? []) where a is MLNPolyline && !(a is LiveLineAnnotation) { map.removeAnnotation(a) }
        clearToilets()
    }

    // MARK: - 记录实时线（对应安卓 LiveOverlay：收 ACTION_POINT 逐点追加）

    private final class LiveLineAnnotation: MLNPolyline {}
    private final class SelfDotAnnotation: MLNPointAnnotation {}
    private final class ToiletAnnotation: MLNPointAnnotation {
        var name = ""
    }

    func updateLiveLine() {
        guard let map = mapView else { return }
        clearLiveLine()
        guard LocationKit.shared.recording else { return }
        let pts = LocationKit.shared.livePts
        guard pts.count >= 2 else { return }
        let coords = pts.map { disp($0.lat, $0.lng) }
        let line = LiveLineAnnotation(coordinates: coords, count: UInt(coords.count))
        map.addAnnotation(line)
        // 跟随最新点（仅记录中；避免打扰手动浏览：每 10 个点跟一次）
        if pts.count % 10 == 0 {
            map.setCenter(coords.last!, animated: true)
        }
    }

    func clearLiveLine() {
        guard let map = mapView else { return }
        for a in (map.annotations ?? []) where a is LiveLineAnnotation { map.removeAnnotation(a) }
    }

    // MARK: - 我的位置点（高德系底图时原生蓝点关闭，改画纠偏后的位置点）

    func updateSelfDot() {
        guard let map = mapView else { return }
        clearSelfDot()
        guard Map3DStyle.needsGcj(), let loc = LocationKit.shared.lastLocation else { return }
        let a = SelfDotAnnotation()
        a.coordinate = disp(loc.coordinate.latitude, loc.coordinate.longitude)
        a.title = "我的位置"
        map.addAnnotation(a)
    }

    func clearSelfDot() {
        guard let map = mapView else { return }
        for a in (map.annotations ?? []) where a is SelfDotAnnotation { map.removeAnnotation(a) }
    }

    // MARK: - 轨迹沿线卫生间（对应安卓 fetchToilets：GET /api/toilets/along?pts=GCJ 坐标串）

    func fetchToilets(pts: [TrackPt]) {
        // 服务端协议：pts 为 GCJ02 坐标串 "lat,lng;lat,lng;…"（安卓端发送前已纠偏），只标 2km 内
        let step = max(1, pts.count / 120)   // 最多 120 个采样点
        var sample: [TrackPt] = []
        for (i, p) in pts.enumerated() where i % step == 0 { sample.append(p) }
        let gcj = sample.map { Coord.wgs2gcj(lat: $0.lat, lng: $0.lng) }
        let ptsStr = gcj.map { String(format: "%.5f,%.5f", $0.0, $0.1) }.joined(separator: ";")
        Task { @MainActor [weak self] in
            do {
                let res = try await Session.shared.api.request(
                    "GET", "toilets/along?pts=\(ptsStr.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ptsStr)")
                guard res["configured"] as? Bool == true,
                      let spots = res["spots"] as? [[String: Any]] else { return }
                var list: [ToiletAnnotation] = []
                for s in spots {
                    let la = (s["lat"] as? NSNumber)?.doubleValue ?? 0
                    let ln = (s["lng"] as? NSNumber)?.doubleValue ?? 0
                    guard la != 0, ln != 0 else { continue }
                    let a = ToiletAnnotation()
                    a.name = s["name"] as? String ?? "公共卫生间"
                    a.title = a.name
                    // 服务端返回 GCJ02：高德底图直投；影像底图需 gcj2wgs 还原
                    if Map3DStyle.needsGcj() {
                        a.coordinate = CLLocationCoordinate2D(latitude: la, longitude: ln)
                    } else {
                        let w = Coord.gcj2wgs(lat: la, lng: ln)
                        a.coordinate = CLLocationCoordinate2D(latitude: w.0, longitude: w.1)
                    }
                    list.append(a)
                }
                guard let self, let map = self.mapView, self.trackOn else { return }
                for a in list { map.addAnnotation(a) }
                if !list.isEmpty {
                    self.probeText = "沿线找到 \(list.count) 个卫生间"
                    self.probeHoldUntil = Date().addingTimeInterval(4)
                }
            } catch { }
        }
    }

    func clearToilets() {
        guard let map = mapView else { return }
        for a in (map.annotations ?? []) where a is ToiletAnnotation { map.removeAnnotation(a) }
    }

    // MARK: - 队友实时位置图层（1:1 移植安卓 TeamOverlay 视觉：绿点+名字胶囊，自己不画）

    func updateTeamLayer() {
        guard let map = mapView else { return }
        // 清旧的队友标记（保留轨迹线）
        for a in (map.annotations ?? []) where a is TeamMemberAnnotation {
            map.removeAnnotation(a)
        }
        guard teamOn, TeamState.shared.inTeam else { return }
        let myPid = TeamState.shared.pid
        for m in TeamState.shared.members {
            guard m.hasCoord else { continue }      // 无坐标成员跳过（列表页仍显示）
            if m.pid == myPid { continue }          // v7.49：地图上不显示自己，只看队友
            // 队友上报 WGS84 原始值（与安卓 TeamService 一致），按当前底图坐标系纠偏
            let a = TeamMemberAnnotation()
            a.coordinate = disp(m.lat, m.lng)
            a.member = m
            map.addAnnotation(a)
        }
    }

    /// 点击地图取海拔/坐标（高德系底图点击为 GCJ02，需还原 WGS84；影像/OSM 直投）
    func onTap(at coord: CLLocationCoordinate2D) {
        probeHoldUntil = Date().addingTimeInterval(6)
        let wgs: (Double, Double)
        if Map3DStyle.needsGcj() {
            wgs = Coord.gcj2wgs(lat: coord.latitude, lng: coord.longitude)
        } else {
            wgs = (coord.latitude, coord.longitude)
        }
        let lat = wgs.0, lng = wgs.1
        Task {
            await MainActor.run {
                probeText = String(format: "%.5f, %.5f（WGS84）", lat, lng)
            }
        }
    }
}

// MARK: - MapLibre 容器

struct Map3DContainer: UIViewRepresentable {
    @ObservedObject var vm: Map3DViewModel

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero)
        map.styleURL = Map3DStyle.styleURL()
        map.showsUserLocation = !Map3DStyle.needsGcj()
        map.showsUserHeadingIndicator = true
        map.isPitchEnabled = true
        map.compassView.isHidden = false
        map.delegate = context.coordinator
        // 默认视角：带俯仰的 3D 观感
        map.camera = MLNMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 30.0, longitude: 102.0),
                                  fromDistance: 8000, pitch: 55, heading: 0)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        vm.mapView = map
        return map
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        context.coordinator.syncToMap(uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(vm: vm) }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        let vm: Map3DViewModel
        init(vm: Map3DViewModel) { self.vm = vm }

        @objc func onTap(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MLNMapView else { return }
            let coord = map.convert(g.location(in: map), toCoordinateFrom: map)
            Task { @MainActor in vm.onTap(at: coord) }
        }

        /// 手势防冲突：点按不影响地图自带手势
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// 队友图层标注同步（主线程调 updateTeamLayer 后需重绘）
        func syncToMap(_ map: MLNMapView) {
            Task { @MainActor [weak vm] in
                guard let vm else { return }
                vm.updateTeamLayer()
            }
        }

        // MARK: - 标注渲染（队友绿点胶囊 / 我的位置点 / 卫生间）

        public func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if annotation is SelfDotAnnotation {
                let id = "selfdot"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MLNAnnotationView(annotation: annotation, reuseIdentifier: id)
                let wrap = UIView(frame: CGRect(x: 0, y: 0, width: 26, height: 26))
                let dot = UIView(frame: CGRect(x: 5, y: 5, width: 16, height: 16))
                dot.layer.cornerRadius = 8
                dot.backgroundColor = UIColor(red: 0.11, green: 0.48, blue: 0.26, alpha: 1)  // 徒步绿
                dot.layer.borderColor = UIColor.white.cgColor
                dot.layer.borderWidth = 2.5
                let ring = UIView(frame: CGRect(x: 0, y: 0, width: 26, height: 26))
                ring.layer.cornerRadius = 13
                ring.backgroundColor = UIColor(red: 0.11, green: 0.48, blue: 0.26, alpha: 0.22)
                wrap.addSubview(ring)
                wrap.addSubview(dot)
                v.annotation = annotation
                for sub in v.subviews { sub.removeFromSuperview() }
                v.addSubview(wrap)
                v.bounds = wrap.bounds
                v.centerOffset = .zero
                return v
            }
            if let ta = annotation as? ToiletAnnotation {
                let id = "toilet"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MLNAnnotationView(annotation: annotation, reuseIdentifier: id)
                let wrap = UIView(frame: CGRect(x: 0, y: 0, width: 46, height: 20))
                let label = UILabel(frame: CGRect(x: 0, y: 0, width: 46, height: 20))
                var n = ta.name
                if n.count > 4 { n = String(n.prefix(4)) }
                label.text = "🚻\(n)"
                label.font = .systemFont(ofSize: 10, weight: .medium)
                label.textColor = .white
                label.backgroundColor = UIColor(red: 0.18, green: 0.54, blue: 0.87, alpha: 0.9)
                label.textAlignment = .center
                label.layer.cornerRadius = 6
                label.layer.masksToBounds = true
                wrap.addSubview(label)
                v.annotation = annotation
                for sub in v.subviews { sub.removeFromSuperview() }
                v.addSubview(wrap)
                v.bounds = wrap.bounds
                v.centerOffset = CGVector(dx: 0, dy: -10)
                return v
            }
            guard annotation is TeamMemberAnnotation else { return nil }
            let id = "teammate"
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MLNAnnotationView(annotation: annotation, reuseIdentifier: id)
            let m = (annotation as? TeamMemberAnnotation)?.member
            let name = m?.name ?? "队员"
            let off = m?.offline ?? true
            // 名字胶囊（黑底白字，离线灰）
            let label = UILabel()
            var n = name.isEmpty ? "队员" : name
            if n.count > 6 { n = String(n.prefix(6)) + "…" }
            if off { n += "·离线" }
            label.text = n
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = off ? UIColor(white: 0.9, alpha: 0.72) : .white
            label.backgroundColor = off ? UIColor(red: 0.23, green: 0.27, blue: 0.25, alpha: 0.54)
                                        : UIColor.black.withAlphaComponent(0.65)
            label.textAlignment = .center
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            let capW = max(label.intrinsicContentSize.width + 14, 44)
            // 容器：胶囊在上、绿点在下
            let wrap = UIView(frame: CGRect(x: 0, y: 0, width: capW, height: 42))
            label.frame = CGRect(x: 0, y: 0, width: capW, height: 18)
            wrap.addSubview(label)
            let dot = UIView(frame: CGRect(x: capW / 2 - 6, y: 26, width: 12, height: 12))
            dot.layer.cornerRadius = 6
            dot.backgroundColor = off ? UIColor(red: 0.60, green: 0.65, blue: 0.61, alpha: 1)
                                      : UIColor(red: 0.24, green: 0.86, blue: 0.39, alpha: 1)   // 0xFF3EDC64
            dot.layer.borderColor = UIColor.white.withAlphaComponent(0.95).cgColor
            dot.layer.borderWidth = 1.6
            if !off {
                // 呼吸光晕脉冲（对应安卓 glow 呼吸）
                let glow = UIView(frame: CGRect(x: -5, y: -5, width: 22, height: 22))
                glow.layer.cornerRadius = 11
                glow.backgroundColor = UIColor(red: 0.24, green: 0.86, blue: 0.39, alpha: 0.28)
                dot.addSubview(glow)
                let anim = CABasicAnimation(keyPath: "transform.scale")
                anim.fromValue = 0.9
                anim.toValue = 1.5
                anim.duration = 1.2
                anim.repeatCount = .infinity
                anim.autoreverses = true
                glow.layer.add(anim, forKey: "pulse")
            }
            wrap.addSubview(dot)
            v.annotation = annotation
            for sub in v.subviews { sub.removeFromSuperview() }
            v.addSubview(wrap)
            v.bounds = wrap.bounds
            v.centerOffset = CGVector(dx: 0, dy: -21)   // 锚点对准绿点位置
            return v
        }

        public func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let a = annotation as? TeamMemberAnnotation, let m = a.member else { return }
            mapView.deselectAnnotation(a, animated: false)
            var info = m.name
            if m.offline { info += "（离线）" }
            if let my = LocationKit.shared.lastLocation, m.hasCoord {
                let d = TrackMath.haversine(lat1: my.coordinate.latitude, lng1: my.coordinate.longitude, lat2: m.lat, lng2: m.lng)
                info += String(format: " · 距我 %.0f 米", d)
            }
            if m.alt != 0 { info += String(format: " · 海拔 %.0f 米", m.alt) }
            let text = info
            Task { @MainActor [weak vm] in
                vm?.probeText = text
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if Date() >= (vm?.probeHoldUntil ?? .distantFuture) { vm?.probeText = "" }
            }
        }
    }
}

// MARK: - 队友标记

final class TeamMemberAnnotation: MLNPointAnnotation {
    var member: TeamState.Member?
}
