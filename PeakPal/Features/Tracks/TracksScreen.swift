import SwiftUI
import UniformTypeIdentifiers

/// 轨迹页（对应安卓 TracksFragment + TrackDetailActivity）：
/// 列表（本地 SQLite）+ 搜索（本地 + 平台路线库 pubtracks 直连，与安卓 v7.8/v7.69 同款）
/// + 文件导入（GPX/KML/KMZ）+ 详情统计 + 记录开关 + 云端上传 + GPX/KML 导出分享
struct TracksScreen: View {
    @StateObject private var loc = LocationKit.shared
    @State private var tracks: [Track] = []
    @State private var shareItem: (url: URL, name: String)?
    // 平台路线库搜索（v7.8 对齐：搜索框直连，需登录；失败静默不打扰本地搜索）
    @State private var query = ""
    @State private var pubItems: [PubLibrary.Item] = []
    @State private var pubBusy: Set<String> = []
    @State private var pubMsg = ""
    @State private var searchTask: Task<Void, Never>? = nil
    // 文件导入（对应安卓 TrackImport 入口）
    @State private var showImporter = false
    @State private var importMsg = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    recordCard
                }
                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索本地 + 平台路线库", text: $query)
                            .textFieldStyle(.plain)
                            .submitLabel(.search)
                        if !query.isEmpty {
                            Button {
                                query = ""; pubItems = []; pubMsg = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入轨迹文件（GPX / KML / KMZ）", systemImage: "square.and.arrow.down")
                    }
                    if !importMsg.isEmpty {
                        Text(importMsg).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(filtered) { t in
                    NavigationLink {
                        TrackDetailView(track: t) { load() }
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(t.name).font(.headline)
                                if t.done { Text("已完成").font(.caption2).padding(3).background(.green.opacity(0.15), in: Capsule()) }
                            }
                            HStack(spacing: 14) {
                                Label(TrackMath.fmtDistance(t.distance), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                                Label(TrackMath.fmtDuration(t.dur), systemImage: "clock")
                                Label(String(format: "%.0f m", t.asc), systemImage: "arrow.up")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                if !pubItems.isEmpty {
                    Section("平台路线（点击下载导入）") {
                        ForEach(pubItems) { item in
                            Button { download(item) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.label).font(.subheadline).foregroundStyle(.primary)
                                        Text(item.src == "kmz" ? "两步路 KMZ · 平台路线库" : "GPX · 平台路线库")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if pubBusy.contains(item.id) {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "arrow.down.circle").foregroundStyle(.green)
                                    }
                                }
                            }
                            .disabled(pubBusy.contains(item.id))
                        }
                    }
                }
                if !pubMsg.isEmpty {
                    Section { Text(pubMsg).font(.footnote).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("轨迹")
            .refreshable { load() }
            .onAppear { load() }
            .onChange(of: query) { q in onSearch(q) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { res in
                handleImport(res)
            }
        }
    }

    /// 记录卡片：开始/停止（对应安卓 RecordFragment）
    private var recordCard: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "record.circle").font(.title2).foregroundStyle(loc.recording ? .red : .green)
                Text(loc.recording ? "正在记录轨迹…" : "轨迹记录")
                    .font(.headline)
                Spacer()
                if loc.recording, let l = loc.lastLocation {
                    Text(String(format: "%.5f, %.5f", l.coordinate.latitude, l.coordinate.longitude))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Button(loc.recording ? "停止并保存" : "开始记录") {
                if loc.recording {
                    let tid = loc.stopRecording()
                    if tid > 0 { _ = tid }
                } else {
                    loc.startRecording()
                }
                load()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!loc.authorized && !loc.recording)
        }
        .padding(.vertical, 4)
    }

    private func load() {
        tracks = Db.shared.listTracks()
    }

    /// 本地过滤（平台路线结果由 onSearch 异步填充）
    private var filtered: [Track] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return tracks }
        return tracks.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// 搜索防抖 400ms（与安卓 pubPending 同节奏）：平台路线库后台搜索，失败静默返回空
    private func onSearch(_ q: String) {
        searchTask?.cancel()
        let kw = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { pubItems = []; return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            pubItems = await PubLibrary.search(kw)
        }
    }

    /// 下载平台路线 → 解析入库 → 刷新列表（与安卓 downloadPub 同流程）
    private func download(_ item: PubLibrary.Item) {
        guard !pubBusy.contains(item.id) else { return }
        pubBusy.insert(item.id)
        pubMsg = ""
        Task { @MainActor in
            do {
                _ = try await PubLibrary.download(item)
                load()
                pubMsg = "已下载「\(item.label)」，可在列表中打开"
            } catch {
                pubMsg = "下载失败：\(error.localizedDescription)"
            }
            pubBusy.remove(item.id)
        }
    }

    /// 文件导入（fileImporter 给的是沙盒外安全 URL，先 copy 进沙盒再解析）
    private func handleImport(_ res: Result<[URL], Error>) {
        switch res {
        case .success(let urls):
            guard let url = urls.first else { return }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tmp)
            do {
                try FileManager.default.copyItem(at: url, to: tmp)
                let r = try TrackImport.parse(url: tmp)
                let id = TrackImport.save(r)
                try? FileManager.default.removeItem(at: tmp)
                if id > 0 {
                    load()
                    importMsg = "已导入「\(r.name)」（标注点 \(r.wpts.count) 个）"
                } else {
                    importMsg = "导入失败：未解析到有效轨迹"
                }
            } catch {
                importMsg = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let e):
            importMsg = "导入失败：\(e.localizedDescription)"
        }
    }
}

/// 轨迹详情：地图（轨迹+起终点+里程碑+标注点）+ 统计 + 导出（GPX / KML轨迹 / KML路径）
struct TrackDetailView: View {
    let track: Track
    var onChanged: (() -> Void)?

    @State private var pts: [TrackPt] = []
    @State private var pois: [Poi] = []
    @State private var shareUrl: URL?
    @State private var uploading = false
    @State private var uploadMsg = ""

    var body: some View {
        List {
            Section("轨迹地图") {
                if pts.count >= 2 {
                    DetailMapContainer(pts: pts, pois: pois)
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                } else {
                    Text("暂无轨迹点").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("概览") {
                statRow("距离", TrackMath.fmtDistance(track.distance))
                statRow("时长", TrackMath.fmtDuration(track.dur))
                statRow("累计爬升", String(format: "%.0f m", track.asc))
                statRow("最高海拔", String(format: "%.0f m", track.maxalt))
                statRow("均速", TrackMath.fmtSpeed(track.distance, track.dur))
                statRow("难度", TrackMath.stars(TrackMath.difficulty(distM: track.distance, ascM: track.asc)))
            }
            Section("循迹") {
                if pts.count >= 2 {
                    NavigationLink {
                        NavigateScreen(track: track, pts: pts)
                    } label: {
                        Label("循迹导航（语音偏航提醒 + 转弯指引）", systemImage: "arrow.triangle.turn.up.right.circle.fill")
                    }
                } else {
                    Text("轨迹点不足，无法导航").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("导出") {
                ForEach(Gpx.Fmt.allCases, id: \.self) { f in
                    Button {
                        export(f)
                    } label: {
                        Label("导出 \(f.rawValue)", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section("云端") {
                if track.cloudId > 0 {
                    Label("已上传云端（仓库 #\(track.cloudId)）", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                }
                Button {
                    uploadCloud()
                } label: {
                    HStack {
                        Label(track.cloudId > 0 ? "重新上传" : "上传到云端轨迹仓库", systemImage: "icloud.and.arrow.up")
                        Spacer()
                        if uploading { ProgressView() }
                    }
                }
                .disabled(uploading || pts.count < 2)
                if !uploadMsg.isEmpty {
                    Text(uploadMsg).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button(role: .destructive) {
                    Db.shared.deleteTrack(tid: track.id)
                    onChanged?()
                } label: { Label("删除轨迹", systemImage: "trash") }
            }
        }
        .navigationTitle(track.name)
        .onAppear {
            pts = Db.shared.loadPts(tid: track.id)
            pois = Db.shared.poisForTrack(track.id)   // 标注点：本轨迹绑定 + 全局兴趣点（与安卓同源）
        }
        .sheet(item: Binding(
            get: { shareUrl.map { ShareItem(url: $0) } },
            set: { shareUrl = $0?.url })) { item in
            ActivitySheet(url: item.url)
        }
    }

    struct ShareItem: Identifiable { let url: URL; var id: String { url.absoluteString } }

    private func statRow(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit() }
    }

    private func export(_ fmt: Gpx.Fmt) {
        let out = Gpx.export(track, pts, fmt: fmt)
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Gpx.fileName(track, ext: out.ext))
        try? out.data.write(to: url, options: .atomic)
        shareUrl = url
    }

    /// 云端上传（与安卓 TracksFragment uploadToCloud 同链路）：POST tracks 建云轨迹 +
    /// GPX 同步到平台路线库（待审核）；成功回写 cloud_id 避免重复上传
    private func uploadCloud() {
        uploading = true
        uploadMsg = ""
        Task { @MainActor in
            do {
                let out = try await CloudTracks.upload(track, pts: pts)
                Db.shared.setCloudId(tid: track.id, cloudId: out.cloudId)
                uploadMsg = out.libSynced
                    ? "已上传云端，并已收录到平台路线库（待审核）"
                    : "已上传云端（路线库同步失败，不影响云端）"
            } catch {
                uploadMsg = "上传失败：\(error.localizedDescription)"
            }
            uploading = false
        }
    }
}

/// 系统分享面板
struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// 轨迹详情地图容器：轨迹线 + 起终点徽章 + 里程碑 + 标注点（对应安卓 TrackDetailActivity，WGS84 直投）
struct DetailMapContainer: UIViewRepresentable {
    let pts: [TrackPt]
    let pois: [Poi]

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero)
        map.styleURL = Map3DStyle.styleURL()
        map.delegate = context.coordinator
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.render(map, pts: pts, pois: pois)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private var drawn = false
        private var poisRendered = -1

        func render(_ map: MLNMapView, pts: [TrackPt], pois: [Poi]) {
            if !drawn && pts.count >= 2 {
                drawn = true
                // 影像底图 WGS84，轨迹点 WGS84：直投（GCJ 纠偏反而偏移几百米）
                let coords = pts.map { p in CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng) }
                let line = MLNPolyline(coordinates: coords, count: UInt(coords.count))
                map.addAnnotation(line)
                map.addAnnotation(IconAnnotation(image: PoiBadge.glowLabel("起"), coordinate: coords[0]))
                map.addAnnotation(IconAnnotation(image: PoiBadge.glowLabel("终"), coordinate: coords[coords.count - 1]))
                // 里程碑：每满 1km 黑色数字徽章（与安卓 TrackOverlay.ensureMilestones 同算法）
                var d = 0.0
                var k = 1
                for i in 1..<pts.count {
                    d += TrackMath.haversine(lat1: pts[i - 1].lat, lng1: pts[i - 1].lng,
                                             lat2: pts[i].lat, lng2: pts[i].lng)
                    if d >= Double(k) * 1000 {
                        map.addAnnotation(KmAnnotation(num: k, coordinate: coords[i]))
                        k += 1
                    }
                }
                let pad = UIEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
                map.setVisibleCoordinates(coords, count: UInt(coords.count), edgePadding: pad, animated: false)
            }
            // 标注点（数量变化即刷新）
            if poisRendered != pois.count {
                poisRendered = pois.count
                for a in (map.annotations ?? []) where a is PoiAnnotation { map.removeAnnotation(a) }
                for (idx, poi) in pois.enumerated() where poi.isValid {
                    map.addAnnotation(PoiAnnotation(poi: poi, num: idx + 1))
                }
            }
        }

        public func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            func view(_ id: String, _ image: UIImage?, callout: Bool) -> MLNAnnotationView {
                let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MLNAnnotationView)
                    ?? MLNAnnotationView(annotation: annotation, reuseIdentifier: id)
                v.annotation = annotation
                // MapLibre 的 MLNAnnotationView 是纯 UIView：用 UIImageView 承载位图
                v.subviews.forEach { $0.removeFromSuperview() }
                if let img = image {
                    let iv = UIImageView(image: img)
                    iv.frame = CGRect(origin: .zero, size: img.size)
                    v.bounds = iv.frame
                    v.addSubview(iv)
                }
                v.isEnabled = true   // MapLibre 无 canShowCallout；气泡由选中态控制
                return v
            }
            if let poi = annotation as? PoiAnnotation {
                return view("det_poi", PoiBadge.glowDot(poi.num), callout: true)   // 默认气泡显示标题/类型
            }
            if let km = annotation as? KmAnnotation {
                return view("det_km", PoiBadge.kmBadge(km.num), callout: false)
            }
            if let ic = annotation as? IconAnnotation {
                return view("det_icon", ic.image, callout: false)
            }
            return nil
        }
    }
}
