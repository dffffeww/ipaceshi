import Foundation

/// 社区云端客户端（1:1 移植自安卓 CommunityClient.java 的帖子/评论/点赞/关注/资料部分）：
/// 封装后端 /api/posts /comments /likes /follows /users 接口，字段与安卓端完全一致。
public final class CommunityClient {

    public static let shared = CommunityClient()
    private init() { }

    /// 统一入口：已登录返回可用；未登录返回 nil（调用方提示登录）
    public static var available: Bool { Session.shared.loggedIn }

    private var api: ApiClient { Session.shared.api }

    // MARK: - 数据结构（字段与安卓 Post.java / Comment.java 一致）

    public struct Post: Identifiable {
        public var id: Int64
        public var uid: Int64
        public var author: String
        public var avatar: String          // 头像："/media/xx" 或 http 开头=图片，否则=表情字符
        public var title: String
        public var content: String
        public var place: String
        public var category: String
        public var time: Int64
        public var likes: Int
        public var comments: Int
        public var status: String          // approved / pending / rejected
        public var pinned: Bool
        public var reviewNote: String
        public var images: [String]        // 图片路径数组（如 /media/xx.jpg）
        public var track: Int64            // 关联云端轨迹 id（0=无）
        public var trackName: String
        public var trackDistance: Double
        public var trackDur: Int64
        public var trackAsc: Double
        public var companion: Bool         // 结伴同行帖
        public var needCity: Bool
        public var needGender: String
        public var signups: Int

        var avatarIsImage: Bool {
            let av = avatar.trimmingCharacters(in: .whitespaces)
            return av.hasPrefix("/") || av.hasPrefix("http")
        }
    }

    public struct Comment: Identifiable {
        public var id: Int64
        public var pid: Int64
        public var uid: Int64
        public var name: String
        public var text: String
        public var time: Int64
    }

    /// 结伴帖报名记录（对应安卓 listSignups：手机号仅楼主可见，他人返回打码号码）
    public struct Signup: Identifiable {
        public var uid: Int64
        public var name: String
        public var gender: String
        public var phone: String
        public var city: String
        public var time: Int64
        public var id: Int64 { uid }
    }

    // MARK: - 解析（对应安卓 CommunityClient.parsePost）

    static func parsePost(_ o: [String: Any]) -> Post {
        let av = (o["avatar"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        return Post(
            id: (o["id"] as? NSNumber)?.int64Value ?? 0,
            uid: (o["uid"] as? NSNumber)?.int64Value ?? 0,
            author: o["author"] as? String ?? "",
            avatar: av.isEmpty ? "🥾" : av,
            title: o["title"] as? String ?? "",
            content: o["content"] as? String ?? "",
            place: o["place"] as? String ?? "",
            category: o["category"] as? String ?? "综合",
            time: (o["createdAt"] as? NSNumber)?.int64Value ?? 0,
            likes: (o["likes"] as? NSNumber)?.intValue ?? 0,
            comments: (o["comments"] as? NSNumber)?.intValue ?? 0,
            status: o["status"] as? String ?? "approved",
            pinned: o["pinned"] as? Bool ?? false,
            reviewNote: o["reviewNote"] as? String ?? "",
            images: o["images"] as? [String] ?? [],
            track: (o["track"] as? NSNumber)?.int64Value ?? 0,
            trackName: o["trackName"] as? String ?? "",
            trackDistance: (o["trackDistance"] as? NSNumber)?.doubleValue ?? 0,
            trackDur: (o["trackDur"] as? NSNumber)?.int64Value ?? 0,
            trackAsc: (o["trackAsc"] as? NSNumber)?.doubleValue ?? 0,
            companion: (o["companion"] as? NSNumber)?.intValue == 1 || (o["companion"] as? Bool == true),
            needCity: o["needCity"] as? Bool ?? false,
            needGender: o["needGender"] as? String ?? "",
            signups: (o["signups"] as? NSNumber)?.intValue ?? 0)
    }

    static func parseComment(_ o: [String: Any]) -> Comment {
        Comment(
            id: (o["id"] as? NSNumber)?.int64Value ?? 0,
            pid: (o["pid"] as? NSNumber)?.int64Value ?? 0,
            uid: (o["uid"] as? NSNumber)?.int64Value ?? 0,
            name: o["author"] as? String ?? "山友",
            text: o["text"] as? String ?? "",
            time: (o["createdAt"] as? NSNumber)?.int64Value ?? 0)
    }

    // MARK: - 帖子

    /// 帖子列表（category 传 nil/空 = 全部；keyword 模糊搜索；city=按地点筛选）
    public func listPosts(category: String?, keyword: String?, city: String? = nil) async throws -> [Post] {
        var qs: [String] = []
        if let c = category, !c.isEmpty, c != "全部" {
            qs.append("category=\(enc(c))")
        }
        if let city = city?.trimmingCharacters(in: .whitespaces), !city.isEmpty, city != "全部" {
            qs.append("city=\(enc(city))")
        }
        if let k = keyword?.trimmingCharacters(in: .whitespaces), !k.isEmpty {
            qs.append("q=\(enc(k))")
        }
        let path = qs.isEmpty ? "posts" : "posts?" + qs.joined(separator: "&")
        let res = try await api.request("GET", path)
        guard let items = res["items"] as? [[String: Any]] else { return [] }
        return items.map(Self.parsePost)
    }

    /// 帖子详情
    public func getPost(_ id: Int64) async throws -> Post {
        return Self.parsePost(try await api.request("GET", "posts/\(id)"))
    }

    /// 我的帖子（含全部审核状态）
    public func listMine() async throws -> [Post] {
        let res = try await api.request("GET", "posts?mine=1")
        guard let items = res["items"] as? [[String: Any]] else { return [] }
        return items.map(Self.parsePost)
    }

    /// 创建帖子；返回完整响应（status：approved=直接公开 / pending=待人工审核）
    /// companion=true 创建结伴同行帖，可带报名条件 needCity/needGender（与安卓 createCompanionPost 一致）
    @discardableResult
    public func createPost(title: String, content: String, place: String, category: String,
                           images: [String] = [], trackId: Int64 = 0,
                           companion: Bool = false, needCity: Bool = false, needGender: String = "") async throws -> [String: Any] {
        var body: [String: Any] = [
            "title": title, "content": content,
            "place": place, "category": companion ? "结伴同行" : category,
        ]
        if companion { body["companion"] = true; body["needCity"] = needCity }
        if !needGender.isEmpty { body["needGender"] = needGender }
        if !images.isEmpty { body["images"] = images }
        if trackId > 0 { body["track"] = trackId }
        return try await api.request("POST", "posts", body: body)
    }

    /// 删除帖子（本人）
    public func deletePost(_ id: Int64) async throws {
        _ = try await api.request("DELETE", "posts/\(id)")
    }

    // MARK: - 评论

    public func listComments(pid: Int64) async throws -> [Comment] {
        let res = try await api.request("GET", "comments/byPost?pid=\(pid)")
        guard let items = res["items"] as? [[String: Any]] else { return [] }
        return items.map(Self.parseComment)
    }

    public func addComment(pid: Int64, text: String) async throws -> Int64 {
        let res = try await api.request("POST", "comments", body: ["pid": pid, "text": text])
        return (res["id"] as? NSNumber)?.int64Value ?? -1
    }

    public func deleteComment(_ id: Int64) async throws {
        _ = try await api.request("DELETE", "comments/\(id)")
    }

    // MARK: - 点赞

    /// 点赞状态（liked=我是否已赞 count=总赞数），toggle 语义与安卓一致
    public func likeStatus(pid: Int64) async throws -> (liked: Bool, count: Int) {
        let res = try await api.request("GET", "likes/status?pid=\(pid)")
        return ((res["liked"] as? Bool) ?? false, (res["count"] as? NSNumber)?.intValue ?? 0)
    }

    public func setLike(pid: Int64, _ on: Bool) async throws {
        if on { _ = try await api.request("POST", "likes", body: ["pid": pid]) }
        else { _ = try await api.request("DELETE", "likes/\(pid)") }
    }

    // MARK: - 关注

    public func followStatus(uid: Int64) async throws -> Bool {
        let res = try await api.request("GET", "follows/status?uid=\(uid)")
        return (res["following"] as? Bool) ?? false
    }

    /// 显式关注/取关（与按钮目标状态一致，不依赖 toggle 语义——与安卓 v7.x 修复一致）
    public func setFollow(uid: Int64, _ on: Bool) async throws {
        let cur = try await followStatus(uid: uid)
        guard cur != on else { return }
        if on { _ = try await api.request("POST", "follows", body: ["uid": uid]) }
        else { _ = try await api.request("DELETE", "follows/\(uid)") }
    }

    /// 我关注的人 / 关注我的人（mutual=互相关注）
    public func followList() async throws -> [[String: Any]] {
        let res = try await api.request("GET", "follows/list")
        return res["items"] as? [[String: Any]] ?? []
    }

    public func fansList() async throws -> [[String: Any]] {
        let res = try await api.request("GET", "follows/fans")
        return res["items"] as? [[String: Any]] ?? []
    }

    // MARK: - 结伴报名（对应安卓 CommunityClient.signup / cancelSignup / listSignups）

    /// 报名结伴帖（必须：性别/名字/手机号；帖子要求同城时还需城市）
    @discardableResult
    public func signup(pid: Int64, gender: String, name: String, phone: String, city: String) async throws -> [String: Any] {
        var body: [String: Any] = ["gender": gender, "name": name, "phone": phone]
        if !city.isEmpty { body["city"] = city }
        return try await api.request("POST", "posts/\(pid)/signup", body: body)
    }

    /// 取消报名
    public func cancelSignup(pid: Int64) async throws {
        _ = try await api.request("DELETE", "posts/\(pid)/signup")
    }

    /// 报名名单
    public func listSignups(pid: Int64) async throws -> [Signup] {
        let res = try await api.request("GET", "posts/\(pid)/signups")
        guard let items = res["items"] as? [[String: Any]] else { return [] }
        return items.map {
            Signup(uid: ($0["uid"] as? NSNumber)?.int64Value ?? 0,
                   name: $0["name"] as? String ?? "",
                   gender: $0["gender"] as? String ?? "",
                   phone: $0["phone"] as? String ?? "",
                   city: $0["city"] as? String ?? "",
                   time: ($0["created"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: - 资料（对应安卓 userProfile / updateProfileFull）

    /// 用户公开资料：id/username/nickname/avatar/bio/location
    public func userProfile(_ uid: Int64) async throws -> [String: Any] {
        return try await api.request("GET", "users/\(uid)")
    }

    /// 更新自己资料；avatar 为 base64 data URL（nil=不改）；location=常驻城市
    @discardableResult
    public func updateProfile(nickname: String?, bio: String?, avatar: String?, location: String?) async throws -> [String: Any] {
        var body: [String: Any] = [:]
        if let n = nickname { body["nickname"] = n }
        if let b = bio { body["bio"] = b }
        if let a = avatar, !a.isEmpty { body["avatar"] = a }
        if let l = location { body["location"] = l }
        return try await api.request("PUT", "profile", body: body)
    }

    /// 修改密码（成功后服务端所有会话失效，需重新登录）
    public func changePassword(old: String, new: String) async throws {
        _ = try await api.request("POST", "password", body: ["old": old, "new": new])
    }

    // MARK: - 公告 / 客服（对应安卓 latestAnnouncement / supportAccount）

    /// 最新一条后台公告（无公告返回 nil）
    public func latestAnnouncement() async throws -> (title: String, content: String)? {
        let res = try await api.request("GET", "announcements?page=1&size=1")
        guard let items = res["items"] as? [[String: Any]], let f = items.first else { return nil }
        return (f["title"] as? String ?? "", f["content"] as? String ?? "")
    }

    /// 官方客服账号（管理员）；无客服抛错由调用方处理
    public func supportAccount() async throws -> (uid: Int, nickname: String) {
        let res = try await api.request("GET", "support")
        let u = (res["id"] as? NSNumber)?.intValue ?? 0
        let nick = res["nickname"] as? String ?? ""
        return (u, nick.isEmpty ? (res["username"] as? String ?? "官方客服") : nick)
    }

    // MARK: - 我的云端统计（tracks/posts/followers/following）

    public func myStats() async throws -> [String: Any] {
        return try await api.request("GET", "users/me/stats")
    }

    private func enc(_ s: String) -> String {
        return s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}

// MARK: - 时间格式化（对应安卓 TimeFmt：今天 HH:mm / 昨天 HH:mm / MM-dd / yyyy-MM-dd）

public enum TimeFmt {
    public static func post(_ ts: Int64) -> String {
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(ts) / (ts > 10_000_000_000 ? 1000.0 : 1.0))
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let now = Date()
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) {
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }
        if let yd = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yd) {
            f.dateFormat = "'昨天' HH:mm"
            return f.string(from: date)
        }
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            f.dateFormat = "MM-dd"
        } else {
            f.dateFormat = "yyyy-MM-dd"
        }
        return f.string(from: date)
    }
}
