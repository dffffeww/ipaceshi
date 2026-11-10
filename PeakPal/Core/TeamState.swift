import Foundation

/// 队伍实时状态（1:1 移植自安卓 TeamState.java + TeamService.java 的网络协议部分）：
/// - 队伍码 code、设备身份 pid、我的昵称 myName（持久化）
/// - 成员快照 members：每轮同步整体替换（UI 零复制遍历安全）
/// - 离线判定：超过 15 分钟未上报（服务器最多保留 2 小时快照，离线成员仍显示并标注）
/// - 协议与安卓端逐字段一致（同一后端互通）：
///     join  = POST /api/team/join  { pid, code, uid?, myName? }
///     leave = POST /api/team/leave { code, pid }
///     pos   = POST /api/team/pos   { code, pid, myName, uid?, lat, lng, alt } → 返回 members
///     pull  = GET  /api/team/get?code=…（冷启动无定位/上报失败时的兜底）
///     chat  = POST /api/chat       { code, pid, name, kind, text, audio }
public final class TeamState: ObservableObject {
    public static let shared = TeamState()

    private let d = UserDefaults.standard
    private var timer: Timer?

    /// 队友（含自己，由服务器返回；渲染端按 pid 过滤自己，避免重名误判）
    public struct Member: Identifiable, Equatable {
        public var pid: String            // 设备身份ID（与本地 pid 相等 = 自己）
        public var name: String
        public var lat: Double            // WGS84（显示层需 wgs2gcj 纠偏）
        public var lng: Double
        public var alt: Double
        public var t: Int64               // 上报时间（秒）
        public var uid: Int64             // 云端账号 ID（0=未登录）
        public var avatar: String         // 云端头像路径（空=无）
        public var gender: String
        public var age: Int
        public var id: String { pid }

        public var hasCoord: Bool { !lat.isNaN && !lng.isNaN && lat != 0 && lng != 0 }
        /// 是否离线：超过 15 分钟未上报位置（与安卓 TeamState.offline 一致）
        public var offline: Bool {
            Int64(Date().timeIntervalSince1970) - t > 15 * 60
        }
    }

    @Published public var code: String { didSet { d.set(code, forKey: "team_code") } }
    @Published public var pid: String { didSet { d.set(pid, forKey: "team_pid") } }
    @Published public var myName: String { didSet { d.set(myName, forKey: "team_name") } }
    /// 随身定位（把我的 GPS 上报给队友），默认开启；关闭=隐身看队（不上报自己坐标）
    @Published public var shareLoc: Bool {
        didSet { d.set(shareLoc, forKey: "team_share_loc") }
    }
    /// 队伍名（服务器 join/pos 返回）
    @Published public var teamName: String { didSet { d.set(teamName, forKey: "team_tname") } }
    /// 队友位置只读快照（每轮同步后整体替换）
    @Published public private(set) var members: [Member] = []
    /// 同步自增标记（地图/导航页监听它重绘队友图层）
    @Published public private(set) var membersTick = 0

    public var inTeam: Bool { !code.isEmpty }

    private var posFail = false            // 最近一轮上报是否失败（驱动 3 秒快速重试，防队友端同屏卡断）

    /// 云端账号 uid（0=未登录；Session 里存的是字符串，转数值与安卓协议对齐）
    private var myUid: Int64 { Int64(Session.shared.uid) ?? 0 }

    private init() {
        code = d.string(forKey: "team_code") ?? ""
        pid = d.string(forKey: "team_pid") ?? ""
        myName = d.string(forKey: "team_name") ?? ""
        teamName = d.string(forKey: "team_tname") ?? ""
        shareLoc = d.object(forKey: "team_share_loc") as? Bool ?? true
        // 冷启动恢复：安卓端 TeamService 是常驻前台服务（自动续命），
        // iOS 端对应地在启动时恢复位置上报 + 聊天/对讲接收通道
        if inTeam {
            startReport()
            TeamChatSync.shared.start()
        }
    }

    // MARK: - 加入/退出

    /// 加入队伍（POST /api/team/join，协议与安卓 joinDialog 一致）
    @MainActor
    public func join(code c: String, name n: String) async throws {
        var body: [String: Any] = [
            "pid": pid.isEmpty ? newPid() : pid,
            "code": c,
        ]
        let myUid = self.myUid
        if myUid > 0 { body["uid"] = myUid }
        if !n.isEmpty { body["myName"] = n }
        let res = try await Session.shared.api.request("POST", "team/join", body: body)
        guard res["ok"] as? Bool == true else {
            throw NSError(domain: "team", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: errMsg(res, "加入失败")])
        }
        // await 后恢复主线程再写 @Published（join 由 @MainActor UI 调用，此处显式保证）
        code = c
        pid = res["pid"] as? String ?? pid
        myName = n
        let tname = res["name"] as? String ?? ""
        if !tname.isEmpty { teamName = tname }
        startReport()
        TeamChatSync.shared.start()   // 聊天/对讲接收通道（轮询+SSE），与安卓 TeamService 对应
    }

    /// 退出队伍（POST /api/team/leave）
    public func leave() async {
        if inTeam {
            _ = try? await Session.shared.api.request("POST", "team/leave", body: [
                "code": code, "pid": pid,
            ])
        }
        leaveLocal()
    }

    /// 仅清本地（登出时用）
    public func leaveLocal() {
        code = ""
        pid = ""
        members = []
        stopReport()
        TeamChatSync.shared.stop()
        TalkPlayer.shared.shutdown()
    }

    func newPid() -> String {
        return String(Int64(Date().timeIntervalSince1970 * 1000))
    }

    // MARK: - 位置上报循环（与安卓 TeamService.report 一致：5 秒常规 / 失败 3 秒快速重试）

    public func startReport() {
        stopReport()
        guard inTeam else { return }
        // 立即来一轮（对应安卓 handler.postDelayed(loop, 1000) 的首拍）
        reportOnce()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.reportOnce()
        }
    }

    public func stopReport() { timer?.invalidate(); timer = nil }

    /// 上报我的位置并拉取全队最新位置（一次请求带回）。
    /// 关键修复（与安卓一致）：冷启动/室内还没拿到 GPS 时，绝不发不带坐标的 pos——
    /// 服务器会拒绝（"坐标无效"），队友列表就永远空着；此时改为只 GET 拉取队友位置。
    func reportOnce() {
        guard inTeam else { return }
        let myUid = self.myUid
        Task { [weak self] in
            guard let self else { return }
            let share = self.shareLoc
            let loc = LocationKit.shared.lastLocation
            var body: [String: Any] = [
                "code": self.code,
                "pid": self.pid,
                "myName": self.myName,
            ]
            if myUid > 0 { body["uid"] = myUid }
            if share, let loc = loc {
                body["lat"] = loc.coordinate.latitude
                body["lng"] = loc.coordinate.longitude
                body["alt"] = loc.altitude
            }
            do {
                var res: [String: Any]
                if share && loc != nil {
                    res = try await Session.shared.api.request("POST", "team/pos", body: body)
                    guard res["ok"] as? Bool == true else {
                        throw NSError(domain: "team", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: errMsg(res, "同步失败")])
                    }
                    self.posFail = false
                } else {
                    // 隐身看队 / 尚无定位：只拉队友，不上报坐标
                    res = try await Session.shared.api.request(
                        "GET", "team/get?code=\(self.code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self.code)")
                    guard res["ok"] as? Bool == true else { return }
                }
                self.applyMembers(res)
            } catch {
                // pos 失败兜底：GET 拉取，队友仍要显示（与安卓 pullMembers 一致）
                if share && loc != nil {
                    self.posFail = true
                    if let r = try? await Session.shared.api.request(
                        "GET", "team/get?code=\(self.code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self.code)") {
                        self.applyMembers(r)
                    }
                }
            }
        }
    }

    /// 解析服务器返回的队伍数据 → 整体替换成员快照 → 通知 UI 重绘
    /// （@Published 必须主线程赋值：本方法由 reportOnce 的 Task 网络回调调用，需调度回主线程）
    private func applyMembers(_ res: [String: Any]) {
        var list: [Member] = []
        if let ms = res["members"] as? [[String: Any]] {
            for m in ms {
                let la = (m["lat"] as? NSNumber)?.doubleValue ?? Double.nan
                let ln = (m["lng"] as? NSNumber)?.doubleValue ?? Double.nan
                // 无坐标成员（刚进队/室内还没拿到 GPS）也必须保留——与安卓一致，渲染端容错
                list.append(Member(
                    pid: m["pid"] as? String ?? "",
                    name: m["name"] as? String ?? "队员",
                    lat: la, lng: ln,
                    alt: (m["alt"] as? NSNumber)?.doubleValue ?? 0,
                    t: (m["t"] as? NSNumber)?.int64Value ?? 0,
                    uid: (m["uid"] as? NSNumber)?.int64Value ?? 0,
                    avatar: m["avatar"] as? String ?? "",
                    gender: m["gender"] as? String ?? "",
                    age: (m["age"] as? NSNumber)?.intValue ?? 0))
            }
        }
        let tname = res["name"] as? String ?? ""
        DispatchQueue.main.async {
            self.members = list
            if !tname.isEmpty { self.teamName = tname }
            self.membersTick += 1
        }
    }

    // MARK: - 聊天/对讲发送（安卓 iOS 同一接口）

    /// 发送聊天/对讲消息
    @discardableResult
    public func chat(body: [String: Any]) async throws -> [String: Any] {
        let res = try await Session.shared.api.request("POST", "chat", body: body)
        guard res["ok"] as? Bool == true else {
            throw NSError(domain: "team", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: errMsg(res, "服务器拒绝")])
        }
        return res
    }

    public func errMsg(_ res: [String: Any], _ fallback: String) -> String {
        let m = res["error"] as? String ?? ""
        return m.isEmpty ? fallback : m
    }
}
