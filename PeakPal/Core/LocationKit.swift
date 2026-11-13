import Foundation
import CoreLocation

/// 定位服务（对应安卓 TrackService + GcjLocationProvider 的定位部分）：
/// - 原始 WGS84 定位（GPS 硬件坐标），轨迹存储/算法一律用 WGS84
/// - 提供 GCJ02 转换出口（供地图显示对齐）
/// - 后台轨迹记录：walking 模式高精度，2 秒/点
/// - 记录状态机：开始/暂停/继续/结束（对应安卓 TrackService.ACTION_PAUSE），
///   暂停期间不计用时、不采点；实时指标（里程/爬升/用时）增量维护
public final class LocationKit: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = LocationKit()

    private let lm = CLLocationManager()
    /// 最近一次 WGS84 定位
    @Published public private(set) var lastLocation: CLLocation?
    /// 轨迹记录中
    @Published public private(set) var recording = false
    /// 暂停中（对应安卓 TrackService paused）
    @Published public private(set) var paused = false
    @Published public private(set) var currentTid: Int64 = 0
    /// 每秒刷新 tick（记录页实时指标用）
    @Published public private(set) var tick = 0
    /// 新轨迹点 tick（地图实时线用）
    @Published public private(set) var ptsTick = 0

    private var pts: [TrackPt] = []
    private var trackStart: Int64 = 0
    private var trackName: String = ""
    private var lastSavedAt = 0.0
    // 实时指标（增量维护，避免每次全量重算）
    private var cumDist: Double = 0      // 米
    private var cumAsc: Double = 0       // 米
    private var lastAlt: Double = 0
    private var totalPauseMs: Int64 = 0  // 已结束的暂停累计
    private var pauseStart: Int64 = 0    // 当前暂停开始时刻
    private var tickTimer: Timer?

    override private init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.pausesLocationUpdatesAutomatically = false
        lm.activityType = .fitness
    }

    // MARK: - 权限

    public var authorized: Bool {
        lm.authorizationStatus == .authorizedWhenInUse || lm.authorizationStatus == .authorizedAlways
    }

    public func request() {
        switch lm.authorizationStatus {
        case .notDetermined:
            lm.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            lm.requestAlwaysAuthorization() // 轨迹记录需要后台定位
        default: break
        }
        lm.startUpdatingLocation()
    }

    // MARK: - 轨迹记录（开始/暂停/继续/结束，对应安卓 RecordFragment 状态机）

    /// 开始记录轨迹（name 可自定义，空=按开始时间命名，与安卓一致）
    public func startRecording(name: String = "") {
        guard !recording else { return }
        request()
        recording = true
        paused = false
        pts = []
        trackStart = Int64(Date().timeIntervalSince1970 * 1000)
        trackName = name.trimmingCharacters(in: .whitespaces)
        lastSavedAt = 0
        cumDist = 0
        cumAsc = 0
        lastAlt = 0
        totalPauseMs = 0
        pauseStart = 0
        currentTid = 0
        lm.allowsBackgroundLocationUpdates = true
        lm.startUpdatingLocation()
        // 1 秒心跳：记录页实时指标刷新（对应安卓 refreshState 的 1s tick）
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.recording else { return }
            self.tick += 1
        }
    }

    /// 暂停记录：休息时间不计入用时、不采点（对应安卓 TrackService.ACTION_PAUSE）
    public func pauseRecording() {
        guard recording, !paused else { return }
        paused = true
        pauseStart = Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// 继续记录（对应安卓继续按钮）
    public func resumeRecording() {
        guard recording, paused else { return }
        totalPauseMs += Int64(Date().timeIntervalSince1970 * 1000) - pauseStart
        paused = false
        lastSavedAt = 0   // 恢复后允许立即落下一个点
    }

    /// 停止记录并入库，返回轨迹 id（对应安卓 TrackService.onDestroy 自动保存）
    public func stopRecording() -> Int64 {
        guard recording else { return 0 }
        if paused { totalPauseMs += Int64(Date().timeIntervalSince1970 * 1000) - pauseStart }
        recording = false
        paused = false
        tickTimer?.invalidate(); tickTimer = nil
        lm.allowsBackgroundLocationUpdates = false
        lm.stopUpdatingLocation()
        let end = Int64(Date().timeIntervalSince1970 * 1000)
        guard pts.count >= 2 else { ptsTick += 1; return 0 }
        var t = Track()
        t.name = trackName.isEmpty ? Track.trackName(from: trackStart) : trackName
        t.start = trackStart
        t.end = end
        t.dur = elapsedMs()   // 净运动用时（不含暂停），与安卓 sessionElapsed 口径一致
        t.distance = cumDist
        t.asc = cumAsc
        t.maxalt = pts.map(\.alt).max() ?? 0
        let tid = Db.shared.insertTrack(&t, pts: pts)
        currentTid = tid
        ptsTick += 1
        return tid
    }

    /// 丢弃当前记录（对应安卓 EXTRA_SAVE=false）
    public func discardRecording() {
        guard recording else { return }
        recording = false
        paused = false
        pts = []
        tickTimer?.invalidate(); tickTimer = nil
        lm.allowsBackgroundLocationUpdates = false
        lm.stopUpdatingLocation()
        ptsTick += 1
    }

    // MARK: - 实时指标（对应安卓 TrackService.snapshot 系列）

    /// 记录中的实时轨迹点（地图画实时线用）
    public var livePts: [TrackPt] { pts }
    /// 实时里程（米）
    public var liveDistance: Double { cumDist }
    /// 实时累计爬升（米）
    public var liveAscent: Double { cumAsc }
    /// 净运动用时（毫秒，不含暂停）
    public func elapsedMs() -> Int64 {
        guard recording else { return 0 }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let curPause = paused ? now - pauseStart : 0
        return max(0, now - trackStart - totalPauseMs - curPause)
    }
    /// 实时均速（米/秒；暂停时 0，显示层转 --）
    public var liveSpeed: Double {
        let ms = elapsedMs()
        return ms > 5000 ? cumDist / (Double(ms) / 1000) : 0
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastLocation = loc
        guard recording, !paused, loc.horizontalAccuracy > 0, loc.horizontalAccuracy < 30 else { return }
        let now = loc.timestamp.timeIntervalSince1970
        // 2 秒/点采样（与安卓端一致）
        guard now - lastSavedAt >= 2 else { return }
        let p = TrackPt(
            lat: loc.coordinate.latitude,   // iOS 返回 WGS84，与存储一致
            lng: loc.coordinate.longitude,
            alt: loc.altitude,
            t: Int64(now * 1000))
        guard p.isValid else { return }
        // 过滤链（对应安卓 TrackService 采样过滤：漂移/跳变/原地）
        if let last = pts.last {
            let d = TrackMath.haversine(lat1: last.lat, lng1: last.lng, lat2: p.lat, lng2: p.lng)
            let dt = max(1, Double(p.t - last.t) / 1000)
            if d < 3 { return }                                  // 原地不动
            if d / dt > 10 { return }                            // >36km/h 判漂移
            if d < loc.horizontalAccuracy * 0.8 && d / dt < 1 { return }  // 静止漂移
            cumDist += d
            if lastAlt != 0 {
                let dAlt = p.alt - lastAlt
                if dAlt > 2 { cumAsc += dAlt }                   // 爬升基线 2 米（去抖）
            }
        }
        lastAlt = p.alt
        pts.append(p)
        lastSavedAt = now
        ptsTick += 1
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }
}
