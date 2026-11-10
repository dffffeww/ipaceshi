import SwiftUI
import MapLibre
import Combine
import UIKit

/// 3D 地图页（对应安卓 Map3DActivity）：
/// MapLibre iOS + 同一套样式数据源（天地图/Esri 影像 + AWS terrarium DEM + 山体阴影 + 地形夸张）。
/// 支持：轨迹线叠加、队友实时位置图层（TeamOverlay 移植）、倾斜/旋转手势、海拔探针、地形夸张调节。
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
                // 底部信息条：海拔探针读数（点击地图取点，6 秒保持）
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

    override init() {
        super.init()
        // 成员快照每轮同步 → 自动重绘队友图层（对应安卓 TeamService 广播 ACTION_MEMBERS）
        teamSub = TeamState.shared.$membersTick
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTeamLayer() }
    }

    func activate() {
        probeText = ""
    }
    func deactivate() {}

    func recenter() {
        LocationKit.shared.request()
        if let loc = LocationKit.shared.lastLocation {
            // 影像底图（天地图 img_w/Esri）为 WGS84，定位同为 WGS84：直投回中，不做 GCJ 纠偏
            mapView?.setCenter(loc.coordinate, zoomLevel: 15, animated: true)
        }
    }

    func toggleTrack() {
        trackOn.toggle()
        if trackOn { drawLocalTrack() } else { clearTrack() }
    }

    func toggleTeam() {
        teamOn.toggle()
        updateTeamLayer()
    }

    /// 画出最近一条本地轨迹（WGS84 直投，与 WGS84 影像底图对齐；GCJ 纠偏反而偏移几百米）
    func drawLocalTrack() {
        guard let map = mapView, let latest = Db.shared.listTracks().first else { return }
        let pts = Db.shared.loadPts(tid: latest.id)
        guard pts.count >= 2 else { return }
        let coords = pts.map { p in CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng) }
        let line = MLNPolyline(coordinates: coords, count: coords.count)
        map.addAnnotation(line)
        let pad = UIEdgeInsets(top: 80, left: 40, bottom: 80, right: 40)
        map.setVisibleCoordinates(coords, count: UInt(coords.count), edgePadding: pad, animated: true)
    }

    func clearTrack() {
        guard let map = mapView else { return }
        for a in map.annotations where a is MLNPolyline { map.removeAnnotation(a) }
    }

    // MARK: - 队友实时位置图层（1:1 移植安卓 TeamOverlay 视觉：绿点+名字胶囊，自己不画）

    func updateTeamLayer() {
        guard let map = mapView else { return }
        // 清旧的队友标记（保留轨迹线）
        for a in map.annotations where a is TeamMemberAnnotation {
            map.removeAnnotation(a)
        }
        guard teamOn, TeamState.shared.inTeam else { return }
        let myPid = TeamState.shared.pid
        for m in TeamState.shared.members {
            guard m.hasCoord else { continue }      // 无坐标成员跳过（列表页仍显示）
            if m.pid == myPid { continue }          // v7.49：地图上不显示自己，只看队友
            // 队友上报的是原始 WGS84（与安卓 TeamService 一致），影像底图同为 WGS84：直投
            let a = TeamMemberAnnotation()
            a.coordinate = CLLocationCoordinate2D(latitude: m.lat, longitude: m.lng)
            a.member = m
            map.addAnnotation(a)
        }
    }

    func reloadStyle() {
        mapView?.styleURL = Map3DStyle.styleURL()
    }

    /// 点击地图取海拔（terrarium DEM 经 queryTerrainElevation；iOS 端用本地解像素或地表渲染高程，骨架用相机高度近似）
    func onTap(at coord: CLLocationCoordinate2D) {
        probeHoldUntil = Date().addingTimeInterval(6)
        let lat = coord.latitude, lng = coord.longitude
        Task {
            // iOS MapLibre style terrain 高程查询：MLNMapCamera 高度近似，精确值待接 dem 源（见 README）
            let wgs = Coord.gcj2wgs(lat: lat, lng: lng)
            await MainActor.run {
                probeText = String(format: "%.5f, %.5f（WGS84）", wgs.0, wgs.1)
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
        map.showsUserLocation = true
        map.showsUserHeadingIndicator = true
        map.pitchEnabled = true
        map.compassView.isHidden = false
        map.delegate = context.coordinator
        // 默认视角：带俯仰的 3D 观感
        map.camera = MLNMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 30.0, longitude: 102.0),
                                  fromDistance: 8000, pitch: 55, heading: 0)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onTap(_:)))
        map.addGestureRecognizer(tap)
        vm.mapView = map
        return map
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        context.coordinator.syncToMap(uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(vm: vm) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let vm: Map3DViewModel
        init(vm: Map3DViewModel) { self.vm = vm }

        @objc func onTap(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MLNMapView else { return }
            let coord = map.convert(g.location(in: map), toCoordinateFrom: map)
            Task { @MainActor in vm.onTap(at: coord) }
        }

        /// 队友图层标注同步（主线程调 updateTeamLayer 后需重绘）
        func syncToMap(_ map: MLNMapView) {
            Task { @MainActor [weak vm] in
                guard let vm else { return }
                vm.updateTeamLayer()
            }
        }

        // MARK: - 队友标记渲染（绿点 + 名字胶囊，视觉对应安卓 TeamOverlay）

        public func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
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
