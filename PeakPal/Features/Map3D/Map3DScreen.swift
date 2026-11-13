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
/// - 标注点系统（对应安卓 Poi：长按地图添加 途经点/水源/营地/山峰/危险，点选查看/删除）
/// - 海拔探针、地形夸张调节、回中
struct Map3DScreen: View {
    @StateObject private var vm = Map3DViewModel()
    @State private var showExagPicker = false
    @State private var showSos = false
    @State private var showTeamChat = false

    var body: some View {
        ZStack {
            Map3DContainer(vm: vm).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    MapLocCard(vm: vm)          // 左上：定位/坐标系/比例尺信息卡
                    Spacer()
                    rightButtons                // 右侧：SOS/标注/功能/地图/热力/队伍/3D/定位
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Spacer()
                HStack(alignment: .bottom) {
                    zoomControls                // 左下：缩放 ±
                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.bottom, 8)
                bottomCards                     // 标注管理卡 / 底部信息条
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
        // 长按地图添加标注点（对应安卓 MapFragment 长按 → POI 五类型表单）
        .sheet(item: $vm.poiDraft) { draft in
            MapPoiForm(draft: draft) {
                vm.loadPois()
            }
        }
        .sheet(isPresented: $showSos) { GuardScreen() }
        .sheet(isPresented: $showTeamChat) { TeamChatScreen() }
        .onAppear { vm.activate() }
        .onDisappear { vm.deactivate() }
    }

    // MARK: - 右侧按钮组（对齐安卓地图页右列：SOS/标注/功能/地图/队伍/对讲/定位/回中）

    private var rightButtons: some View {
        VStack(spacing: 10) {
            Button { showSos = true } label: {
                Text("SOS").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(12).background(Color.red, in: Circle())
            }
            Button { vm.togglePois() } label: {
                Image(systemName: vm.poisOn ? "mappin.circle.fill" : "mappin.circle").mapBtn()
            }
            Button { showExagPicker = true } label: {
                Image(systemName: "mountain.2.fill").mapBtn()
            }
            Button { vm.cycleBasemap() } label: {
                Image(systemName: "square.3.layers.3d").mapBtn()
            }
            Button { vm.toggleHeat() } label: {
                Image(systemName: vm.heatOn ? "flame.fill" : "flame").mapBtn()
            }
            Button { vm.toggleTrack() } label: {
                Image(systemName: vm.trackOn ? "line.diagonal.fill" : "line.diagonal").mapBtn()
            }
            if TeamState.shared.inTeam {
                Button { vm.toggleTeam() } label: {
                    Image(systemName: vm.teamOn ? "person.3.fill" : "person.3").mapBtn()
                }
                Button { showTeamChat = true } label: {
                    Image(systemName: "message.fill").mapBtn()
                }
            }
            // 3D/2D 视角切换（对应安卓 2D/3D 模式）
            Button { vm.toggle3D() } label: {
                Image(systemName: vm.is3D ? "cube.transparent.fill" : "square.split.2x1").mapBtn()
            }
            Button { vm.recenter() } label: {
                Image(systemName: "location.fill").mapBtn()
            }
        }
    }

    // MARK: - 左下缩放控件（对应安卓 ±16.0）

    private var zoomControls: some View {
        VStack(spacing: 8) {
            Button { vm.zoom(by: 1) } label: { Text("+").mapTextBtn() }
            Text(String(format: "%.1f", vm.locInfo.zoom))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 36, minHeight: 20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            Button { vm.zoom(by: -1) } label: { Text("−").mapTextBtn() }
        }
    }

    // MARK: - 底部卡片（选中标注管理 / 信息条）

    @ViewBuilder
    private var bottomCards: some View {
        // 选中标注点管理卡（点标记弹出，可删除）
        if let sel = vm.selectedPoi {
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Poi.typeName(sel.type)) · \(sel.name.isEmpty ? "未命名" : sel.name)")
                        .font(.subheadline.weight(.semibold))
                    if !sel.note.isEmpty {
                        Text(sel.note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    Db.shared.deletePoi(id: sel.id)
                    vm.selectedPoi = nil
                    vm.loadPois()
                } label: {
                    Image(systemName: "trash")
                }
                Button { vm.selectedPoi = nil } label: {
                    Image(systemName: "xmark")
                }
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        // 底部信息条：海拔探针 / 队友点选信息条 / 底图名（6 秒保持）
        if vm.selectedPoi == nil, !vm.probeText.isEmpty {
            Text(vm.probeText)
                .font(.footnote.monospacedDigit())
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 24)
        }
    }
}

/// 左上定位信息卡（对齐安卓地图页定位卡：坐标系/精度/速度/比例尺/队伍/标注/轨迹）
struct MapLocCard: View {
    @ObservedObject var vm: Map3DViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(vm.locInfo.line1).font(.system(size: 11, weight: .semibold))
            Text(vm.locInfo.line2).font(.system(size: 10).monospacedDigit())
            Text(vm.locInfo.line3).font(.system(size: 10).monospacedDigit())
            Text(vm.locInfo.line4).font(.system(size: 10).monospacedDigit())
            Text(vm.locInfo.line5).font(.system(size: 10).monospacedDigit())
        }
        .foregroundStyle(Color.green)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 280, alignment: .leading)
    }
}

extension Text {
    func mapTextBtn() -> some View {
        font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(.thinMaterial, in: Circle())
    }
}

/// 添加标注点表单（类型 + 名称 + 备注；坐标取长按点，WGS84 存储）
struct MapPoiForm: View {
    let draft: Map3DViewModel.PoiDraft
    var onSaved: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var type = "waypoint"
    @State private var name = ""
    @State private var note = ""

    static let types: [(key: String, icon: String)] = [
        ("waypoint", "mappin"), ("water", "drop.fill"), ("camp", "tent.fill"),
        ("peak", "mountain.2.fill"), ("danger", "exclamationmark.triangle.fill"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("位置") {
                    Text(String(format: "%.5f, %.5f（WGS84）", draft.lat, draft.lng))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Section("类型") {
                    Picker("类型", selection: $type) {
                        ForEach(Self.types, id: \.key) { t in
                            Label(Poi.typeName(t.key), systemImage: t.icon).tag(t.key)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("信息") {
                    TextField("名称（如：水源点 / 三岔路口）", text: $name)
                    TextField("备注（选填）", text: $note)
                }
                Section {
                    Button {
                        var p = Poi()
                        p.name = name.trimmingCharacters(in: .whitespaces)
                        p.note = note.trimmingCharacters(in: .whitespaces)
                        p.lat = draft.lat; p.lng = draft.lng
                        p.type = type
                        p.t = Int64(Date().timeIntervalSince1970 * 1000)
                        _ = Db.shared.insertPoi(p, tid: 0)   // 全局兴趣点（地图页）
                        onSaved?()
                        dismiss()
                    } label: {
                        Text("保存标注点").frame(maxWidth: .infinity).bold()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("添加标注点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
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
    @Published var poisOn = true        // 标注点图层默认开
    @Published var selectedPoi: Poi?    // 点选的标注点（底部管理卡）
    @Published var poiDraft: PoiDraft?  // 非空时弹添加表单
    @Published var is3D: Bool           // 3D/2D 视角（记忆）
    @Published var heatOn: Bool         // 足迹热力图（记忆）
    @Published var locInfo = LocInfo()  // 左上定位信息卡

    /// 定位信息卡（对齐安卓地图页定位卡字段）
    struct LocInfo {
        var source = "定位中"
        var acc: Double = -1
        var wgs: (Double, Double) = (0, 0)
        var gcj: (Double, Double) = (0, 0)
        var alt = 0.0
        var speed = 0.0
        var zoom: Double = 0
        var mpp = 0.0
        var teamTotal = 0
        var teamOnline = 0
        var poiCount = 0
        var trackCount = 0
        var syncedAt = ""

        var line1: String {
            let s = acc >= 0 ? String(format: "精度±%.0fm", acc) : "等待定位"
            return "\(source) · \(s) · \(syncedAt)"
        }
        var line2: String {
            String(format: "WGS84 %.6f, %.6f", wgs.0, wgs.1)
        }
        var line3: String {
            String(format: "GCJ02 %.6f, %.6f", gcj.0, gcj.1)
        }
        var line4: String {
            String(format: "海拔%.0fm · 速度%.1fm/s · 缩放%.1f · 1px=%.1fm", alt, speed, zoom, mpp)
        }
        var line5: String {
            let t = teamTotal > 0 ? " · 队伍\(teamTotal)人(在线\(teamOnline))" : ""
            return "标注\(poiCount)个\(t) · 轨迹\(trackCount)条 · 长按加点"
        }
    }

    /// 长按落点（WGS84），作为 Identifiable 供 sheet(item:)
    struct PoiDraft: Identifiable {
        let lat: Double
        let lng: Double
        var id: String { "\(lat),\(lng)" }
    }

    weak var mapView: MLNMapView?
    var probeHoldUntil = Date.distantPast    // Coordinator 需要读写（队友点选信息条保持 6 秒）
    private var teamSub: AnyCancellable?
    private var locSub: AnyCancellable?
    private var ptsSub: AnyCancellable?
    private var cardTimer: Timer?            // 信息卡 1s 刷新（缩放/比例尺随地图变化）
    private var cardTick = 0

    override init() {
        is3D = UserDefaults(suiteName: "map3d")?.object(forKey: "is3d") as? Bool ?? true
        heatOn = Map3DStyle.heat()
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
        // 信息卡每秒刷新（重量级统计每 5 秒一次，避免每秒扫库）
        cardTimer?.invalidate()
        cardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateCard(heavy: false) }
        }
        updateCard(heavy: true)
    }
    func deactivate() {
        cardTimer?.invalidate()
        cardTimer = nil
    }

    // MARK: - 3D/2D 视角切换 + 缩放

    /// 3D↔2D：保持中心/朝向，俯仰 55°↔0°（记忆）
    func toggle3D() {
        guard let map = mapView else { return }
        is3D.toggle()
        UserDefaults(suiteName: "map3d")?.set(is3D, forKey: "is3d")
        map.camera = MLNMapCamera(lookingAtCenter: map.centerCoordinate,
                                  fromDistance: map.camera.altitude,
                                  pitch: is3D ? 55 : 0,
                                  heading: map.camera.heading)
        probeText = is3D ? "3D 视角（双指拖动调整俯仰）" : "2D 平面视角"
        probeHoldUntil = Date().addingTimeInterval(3)
    }

    /// 缩放 ±1（飞行动画；对应安卓 ± 按钮）
    func zoom(by delta: Int) {
        guard let map = mapView else { return }
        let cam = MLNMapCamera(lookingAtCenter: map.centerCoordinate,
                               fromDistance: map.camera.altitude * (delta > 0 ? 0.5 : 2.0),
                               pitch: map.camera.pitch, heading: map.camera.heading)
        map.fly(to: cam, withDuration: 0.3)
        updateCard(heavy: false)
    }

    // MARK: - 足迹热力图（对应安卓足迹热力）

    func toggleHeat() {
        heatOn.toggle()
        Map3DStyle.setHeat(heatOn)
        reloadStyle()
        probeText = heatOn ? "足迹热力图：开（全部本地轨迹）" : "足迹热力图：关"
        probeHoldUntil = Date().addingTimeInterval(3)
    }

    // MARK: - 定位信息卡

    /// heavy=false 只刷新坐标/缩放等轻量字段；heavy=true 加队伍/标注/轨迹统计（扫库）
    func updateCard(heavy: Bool) {
        guard let map = mapView else { return }
        var li = locInfo
        li.zoom = map.zoomLevel
        li.mpp = 40075016.686 * cos(map.centerCoordinate.latitude * .pi / 180) / (256 * pow(2, map.zoomLevel))
        if let loc = LocationKit.shared.lastLocation {
            let c = loc.coordinate
            li.source = loc.horizontalAccuracy <= 30 ? "定位：GPS" : "定位：网络"
            li.acc = loc.horizontalAccuracy
            li.wgs = (c.latitude, c.longitude)
            li.gcj = Coord.wgs2gcj(lat: c.latitude, lng: c.longitude)
            li.alt = loc.altitude
            li.speed = max(0, loc.speed)
            li.syncedAt = TimeFmt.clock(Date())
        }
        if heavy {
            let ms = TeamState.shared.members
            li.teamTotal = TeamState.shared.inTeam ? ms.count : 0
            li.teamOnline = ms.filter { !$0.offline }.count
            li.poiCount = Db.shared.allPois().count
            li.trackCount = Db.shared.listTracks().count
        } else {
            li.teamTotal = locInfo.teamTotal
            li.teamOnline = locInfo.teamOnline
            li.poiCount = locInfo.poiCount
            li.trackCount = locInfo.trackCount
        }
        locInfo = li
    }

    func togglePois() {
        poisOn.toggle()
        if poisOn { loadPois() } else { clearPois() }
    }

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
        loadPois()
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

    // MARK: - 标注点图层（对应安卓 MapFragment POI：全局 + 轨迹绑定，彩色胶囊）

    func loadPois() {
        guard let map = mapView else { return }
        clearPois()
        guard poisOn else { return }
        for p in Db.shared.allPois() {
            let a = MapPoiAnnotation()
            a.poi = p
            // 库里存 WGS84，按底图坐标系纠偏显示
            a.coordinate = disp(p.lat, p.lng)
            map.addAnnotation(a)
        }
    }

    func clearPois() {
        guard let map = mapView else { return }
        for a in (map.annotations ?? []) where a is MapPoiAnnotation { map.removeAnnotation(a) }
    }

    /// 长按地图：取点（还原 WGS84）后弹添加表单
    func requestPoi(at coord: CLLocationCoordinate2D) {
        let wgs: (Double, Double)
        if Map3DStyle.needsGcj() {
            wgs = Coord.gcj2wgs(lat: coord.latitude, lng: coord.longitude)
        } else {
            wgs = (coord.latitude, coord.longitude)
        }
        poiDraft = PoiDraft(lat: wgs.0, lng: wgs.1)
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
        // 默认视角：3D 记忆状态（is3D 开→俯仰 55°，关→2D 平面）
        map.camera = MLNMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 30.0, longitude: 102.0),
                                  fromDistance: 8000, pitch: vm.is3D ? 55 : 0, heading: 0)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onTap(_:)))
        tap.delegate = context.coordinator
        map.addGestureRecognizer(tap)
        // 长按添加标注点（对应安卓 MapFragment 长按 → POI 表单）
        let long = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onLongPress(_:)))
        long.minimumPressDuration = 0.5
        long.delegate = context.coordinator
        map.addGestureRecognizer(long)
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

        @objc func onLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MLNMapView else { return }
            let coord = map.convert(g.location(in: map), toCoordinateFrom: map)
            Task { @MainActor in vm.requestPoi(at: coord) }
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
            if let pa = annotation as? MapPoiAnnotation, let p = pa.poi {
                let id = "poi-\(p.type)"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MLNAnnotationView(annotation: annotation, reuseIdentifier: id)
                // 配色与安卓 Poi.java 一致：途经点绿 / 水源蓝 / 营地紫 / 山峰棕 / 危险红
                let (icon, color): (String, UIColor) = {
                    switch p.type {
                    case "water": return ("💧", UIColor(red: 0.13, green: 0.59, blue: 0.95, alpha: 1))
                    case "camp": return ("⛺", UIColor(red: 0.56, green: 0.14, blue: 0.67, alpha: 1))
                    case "peak": return ("⛰", UIColor(red: 0.43, green: 0.30, blue: 0.26, alpha: 1))
                    case "danger": return ("⚠️", UIColor(red: 0.83, green: 0.18, blue: 0.18, alpha: 1))
                    default: return ("📍", UIColor(red: 0.11, green: 0.48, blue: 0.26, alpha: 1))
                    }
                }()
                var n = p.name.isEmpty ? Poi.typeName(p.type) : p.name
                if n.count > 6 { n = String(n.prefix(6)) + "…" }
                let label = UILabel(frame: CGRect(x: 0, y: 0, width: 66, height: 20))
                label.text = "\(icon)\(n)"
                label.font = .systemFont(ofSize: 10, weight: .medium)
                label.textColor = .white
                label.backgroundColor = color.withAlphaComponent(0.92)
                label.textAlignment = .center
                label.layer.cornerRadius = 6
                label.layer.masksToBounds = true
                v.annotation = annotation
                for sub in v.subviews { sub.removeFromSuperview() }
                v.addSubview(label)
                v.bounds = CGRect(x: 0, y: 0, width: 66, height: 20)
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
            if let a = annotation as? MapPoiAnnotation, let p = a.poi {
                mapView.deselectAnnotation(a, animated: false)
                Task { @MainActor [weak vm] in
                    vm?.selectedPoi = p
                }
                return
            }
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

/// 我的位置点（高德系底图时替代原生蓝点）
final class SelfDotAnnotation: MLNPointAnnotation {}

/// 轨迹沿线卫生间
final class ToiletAnnotation: MLNPointAnnotation {
    var name = ""
}

/// 地图标注点（途经点/水源/营地/山峰/危险，对应安卓 Poi overlay）
final class MapPoiAnnotation: MLNPointAnnotation {
    var poi: Poi?
}

/// 记录中的实时轨迹线（与历史轨迹线类型区分，便于独立清理）
final class LiveLineAnnotation: MLNPolyline {}
