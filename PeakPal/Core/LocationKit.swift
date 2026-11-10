import Foundation
import CoreLocation

/// 定位服务（对应安卓 TrackService + GcjLocationProvider 的定位部分）：
/// - 原始 WGS84 定位（GPS 硬件坐标），轨迹存储/算法一律用 WGS84
/// - 提供 GCJ02 转换出口（供地图显示对齐）
/// - 后台轨迹记录：walking 模式高精度，2 秒/点
public final class LocationKit: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = LocationKit()

    private let lm = CLLocationManager()
    /// 最近一次 WGS84 定位
    @Published public private(set) var lastLocation: CLLocation?
    /// 轨迹记录中
    @Published public private(set) var recording = false
    @Published public private(set) var currentTid: Int64 = 0

    private var pts: [TrackPt] = []
    private var trackStart: Int64 = 0
    private var lastSavedAt = 0.0

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

    // MARK: - 轨迹记录

    /// 开始记录轨迹
    public func startRecording() {
        guard !recording else { return }
        request()
        recording = true
        pts = []
        trackStart = Int64(Date().timeIntervalSince1970 * 1000)
        lastSavedAt = 0
        lm.allowsBackgroundLocationUpdates = true
        lm.startUpdatingLocation()
    }

    /// 停止记录并入库，返回轨迹 id
    public func stopRecording() -> Int64 {
        guard recording else { return 0 }
        recording = false
        lm.allowsBackgroundLocationUpdates = false
        lm.stopUpdatingLocation()
        let end = Int64(Date().timeIntervalSince1970 * 1000)
        var t = Track()
        t.name = Track.trackName(from: trackStart)
        t.start = trackStart
        t.end = end
        t.dur = end - trackStart
        guard pts.count >= 2 else { return 0 }
        let tid = Db.shared.insertTrack(&t, pts: pts)
        currentTid = tid
        return tid
    }

    // MARK: - CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastLocation = loc
        guard recording, loc.horizontalAccuracy > 0, loc.horizontalAccuracy < 50 else { return }
        let now = loc.timestamp.timeIntervalSince1970
        // 2 秒/点采样（与安卓端一致）
        guard now - lastSavedAt >= 2 else { return }
        lastSavedAt = now
        let p = TrackPt(
            lat: loc.coordinate.latitude,   // iOS 返回 WGS84，与存储一致
            lng: loc.coordinate.longitude,
            alt: loc.altitude,
            t: Int64(now * 1000))
        if p.isValid { pts.append(p) }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { }
}
