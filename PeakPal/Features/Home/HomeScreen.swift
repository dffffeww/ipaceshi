import SwiftUI

/// 首页（对应安卓 HomeFragment 聚合页）：
/// - 头部：头像/昵称/问候 + 消息铃铛（未读角标 = 私信 + 通知，对应安卓 badge_msg）
/// - 队伍状态卡（在队时常驻，点击进队伍页 —— 新版布局把「队伍」Tab 降级为首页入口）
/// - 今日/累计统计卡（本地轨迹库口径，与安卓 buildMagazineHeader 一致）
/// - 快捷入口：轨迹库 / 社区 / 队伍 / 发帖
/// - 社区精选（GET /api/posts 前 5 条，点击进帖子详情）
struct HomeScreen: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var team: TeamState
    @EnvironmentObject var loc: LocationKit

    @State private var dmUnread = 0
    @State private var notifyUnread = 0
    @State private var posts: [CommunityClient.Post] = []
    @State private var trackCount = 0
    @State private var totalDist: Double = 0
    @State private var cloudStats: [String: Any] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    teamCard
                    statsRow
                    quickEntries
                    postsSection
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("爱徒步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarBell }
        }
        .onAppear {
            refreshLocal()
            Task { await loadAll() }
        }
        .onReceive(loc.$tick) { _ in refreshLocal() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(red: 0.28, green: 0.62, blue: 0.36).opacity(0.15))
                .frame(width: 42, height: 42)
                .overlay(Text(String(session.name.prefix(1)).isEmpty ? "徒" : String(session.name.prefix(1)))
                    .font(.headline).foregroundStyle(Color(red: 0.28, green: 0.62, blue: 0.36)))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name.isEmpty ? "徒步者" : session.name)
                    .font(.subheadline.weight(.semibold))
                Text(greeting).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        if h < 6 { return "夜爬注意安全" }
        if h < 11 { return "早上好，今天走哪条线？" }
        if h < 14 { return "中午好，午后适合拉练" }
        if h < 19 { return "下午好，记得带够水" }
        return "晚上好，规划好明天的线路了吗"
    }

    // MARK: - 消息铃铛（导航栏右侧，未读角标）

    @ToolbarContentBuilder
    private var toolbarBell: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                MessagesRootScreen()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 16))
                    if dmUnread + notifyUnread > 0 {
                        Text(unreadText)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.red, in: Capsule())
                            .offset(x: 8, y: -7)
                    }
                }
            }
        }
    }

    private var unreadText: String {
        let n = dmUnread + notifyUnread
        return n > 99 ? "99+" : "\(n)"
    }

    // MARK: - 队伍状态卡（新版：队伍不是 Tab，在队时首页常驻）

    @ViewBuilder
    private var teamCard: some View {
        if team.inTeam {
            NavigationLink {
                TeamScreen()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color(red: 0.28, green: 0.62, blue: 0.36), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("队伍 · \(team.teamName.isEmpty ? "我的队伍" : team.teamName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 0.03, green: 0.31, blue: 0.25))
                        let online = team.members.filter { !$0.offline }.count
                        Text("\(online) 人在线 · 正在共享位置")
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.28, green: 0.62, blue: 0.36))
                    }
                    Spacer()
                    Text("查看").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(red: 0.28, green: 0.62, blue: 0.36), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(12)
                .background(Color(red: 0.88, green: 0.96, blue: 0.93), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                TeamScreen()
            } label: {
                HStack {
                    Image(systemName: "person.3")
                    Text("创建或加入队伍，与队友实时共享位置")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    // MARK: - 统计卡（本地轨迹库口径 + 云端社区数据）

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard("\(trackCount)", "轨迹")
            statCard(TrackMath.fmtDistance(totalDist), "总里程")
            statCard("\(cloudStats["posts"] as? Int ?? 0)", "帖子")
            statCard("\(cloudStats["followers"] as? Int ?? 0)", "粉丝")
        }
    }

    private func statCard(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 快捷入口

    private var quickEntries: some View {
        HStack(spacing: 10) {
            quickBtn("figure.hiking", "轨迹库") { TracksScreen() }
            quickBtn("message.circle.fill", "社区") { CommunityScreen() }
            quickBtn("person.3.fill", "队伍") { TeamScreen() }
            quickBtn("square.and.pencil", "发帖") { CreatePostView() }
        }
    }

    private func quickBtn(_ icon: String, _ label: String, @ViewBuilder dest: @escaping () -> some View) -> some View {
        NavigationLink {
            dest()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Color(red: 0.28, green: 0.62, blue: 0.36))
                    .frame(width: 48, height: 48)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                Text(label).font(.caption2).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 社区精选

    @ViewBuilder
    private var postsSection: some View {
        if !posts.isEmpty {
            VStack(spacing: 8) {
                HStack {
                    Text("社区精选").font(.subheadline.weight(.semibold))
                    Spacer()
                    NavigationLink {
                        CommunityScreen()
                    } label: {
                        Text("更多 ›").font(.caption)
                            .foregroundStyle(Color(red: 0.28, green: 0.62, blue: 0.36))
                    }
                }
                ForEach(posts.prefix(5)) { p in
                    NavigationLink {
                        PostDetailView(post: p)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(String(p.author.prefix(1)))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Color.orange.opacity(0.8), in: Circle())
                                Text(p.author).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(CommunityClient.post(p.time)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(p.title).font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            HStack(spacing: 12) {
                                Text("赞 \(p.likes)").font(.caption2).foregroundStyle(.secondary)
                                Text("评 \(p.comments)").font(.caption2).foregroundStyle(.secondary)
                                if !p.place.isEmpty {
                                    Text(p.place).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 数据加载

    private func refreshLocal() {
        let tracks = Db.shared.listTracks()
        trackCount = tracks.count
        totalDist = tracks.reduce(0) { $0 + $1.distance }
    }

    private func loadAll() async {
        // 未读角标（对应安卓 MainActivity.fetchUnread：私信 unread_count + 通知 unread）
        async let dm: Void = loadDmUnread()
        async let nt: Void = loadNotifyUnread()
        async let st: Void = loadCloudStats()
        async let ps: Void = loadPosts()
        _ = await (dm, nt, st, ps)
    }

    private func loadDmUnread() async {
        do {
            let res = try await session.api.request("GET", "messages/unread_count")
            let c = (res["count"] as? NSNumber)?.intValue ?? 0
            await MainActor.run { dmUnread = c }
        } catch { }
    }

    private func loadNotifyUnread() async {
        do {
            let res = try await session.api.request("GET", "notifies")
            let c = (res["unread"] as? NSNumber)?.intValue ?? 0
            await MainActor.run { notifyUnread = c }
        } catch { }
    }

    private func loadCloudStats() async {
        guard CommunityClient.available else { return }
        do {
            let s = try await CommunityClient.shared.myStats()
            await MainActor.run { cloudStats = s }
        } catch { }
    }

    private func loadPosts() async {
        do {
            let list = try await CommunityClient.shared.listPosts(category: nil, keyword: nil)
            await MainActor.run { posts = list }
        } catch { }
    }
}
