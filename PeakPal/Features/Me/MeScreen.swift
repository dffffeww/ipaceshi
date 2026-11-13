import SwiftUI

/// 我的页（对齐安卓 MeFragment 新版布局，见截图）：
/// 绿色渐变头部卡（头像/昵称/编辑资料）+ 统计 5 卡（轨迹/帖子/关注/粉丝/队伍）
/// + 菜单：发布新帖/我的帖子/视频与照片/关注与粉丝/队伍同屏/离线地图/声音设置等。
struct MeScreen: View {
    @EnvironmentObject var session: Session
    @State private var checking = false
    @State private var updateInfo: UpdateChecker.Info?
    @State private var showUpdate = false
    @State private var upToDate = false
    @State private var supportUid = 0
    @State private var supportNick = "官方客服"
    @State private var showCreate = false
    // 统计（云端 posts/followers/following/teams + 本地轨迹数）
    @State private var postsCount = 0
    @State private var followingCount = 0
    @State private var followersCount = 0
    @State private var teamsCount = 0
    @State private var trackCount = 0

    /// 手动检查更新：有新版弹更新框；已最新/无网络给行内提示
    private func checkUpdate() {
        checking = true
        Task {
            let info = await UpdateChecker.fetchLatest(session: session)
            await MainActor.run {
                checking = false
                if let info {
                    updateInfo = info
                    if UpdateChecker.newerAvailable(info) { showUpdate = true }
                    else { upToDate = true }
                } else {
                    upToDate = true
                }
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                headerSection
                statsSection
                menuSection
                moreSection
                versionSection
                Section {
                    Button(role: .destructive) {
                        session.logout()
                    } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }
            .refreshable { await refresh() }
            .sheet(isPresented: $showCreate) {
                CreatePostView { Task { await refresh() } }
            }
            .alert("发现新版本 \(updateInfo?.version ?? "")（build \(updateInfo?.code ?? 0)）",
                   isPresented: $showUpdate, presenting: updateInfo) { info in
                Button("复制下载链接") { _ = UpdateChecker.copyLink(info.url) }
                Button("打开下载页") { UpdateChecker.openDownload(info.url) }
                Button("以后再说", role: .cancel) {}
            } message: { info in
                Text("当前 build \(UpdateChecker.currentBuild)。请把链接粘到电脑浏览器下载新 ipa，再用爱思助手重新签名安装。\n\n\(info.notes)")
            }
            .alert("已是最新版本", isPresented: $upToDate) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(updateInfo == nil ? "暂时无法连接服务器，请稍后再试" : "当前已是服务器发布的最新版本")
            }
        }
    }

    // MARK: - 头部（绿色渐变卡：头像/昵称/编辑资料）

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                AvatarView(src: session.avatar, size: 62)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name.isEmpty ? session.uname : session.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                    Text("云端已连接 · UID \(session.uid)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                NavigationLink { ProfileEditScreen() } label: {
                    Text("编辑资料")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.white.opacity(0.22), in: Capsule())
                }
            }
            .padding(.vertical, 18).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Color(red: 0.13, green: 0.42, blue: 0.25),
                                        Color(red: 0.24, green: 0.55, blue: 0.32)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - 统计 5 卡（轨迹/帖子/关注/粉丝/队伍）

    private var statsSection: some View {
        Section {
            HStack(spacing: 0) {
                statCell("\(trackCount)", "轨迹")
                statCell("\(postsCount)", "帖子")
                statCell("\(followingCount)", "关注")
                statCell("\(followersCount)", "粉丝")
                statCell("\(teamsCount)", "队伍")
            }
            .padding(.vertical, 10)
        }
    }

    private func statCell(_ num: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(num).font(.title3.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 菜单（对齐安卓：发布新帖/我的帖子/视频与照片/关注与粉丝/队伍同屏/离线地图/声音设置）

    private var menuSection: some View {
        Section {
            Button { showCreate = true } label: {
                Label("发布新帖", systemImage: "pencil.line")
            }
            NavigationLink { MyPostsScreen() } label: {
                Label("我的帖子", systemImage: "doc.text")
            }
            NavigationLink { MediaGalleryScreen() } label: {
                Label("视频与照片（徒步作品）", systemImage: "photo.stack")
            }
            NavigationLink { FollowListScreen() } label: {
                Label("关注与粉丝", systemImage: "person.2")
            }
            NavigationLink { TeamScreen() } label: {
                Label("队伍同屏（组队实时共享位置）", systemImage: "figure.walk.arrival")
            }
            NavigationLink { OfflineMapScreen() } label: {
                Label("离线地图", systemImage: "map")
            }
            NavigationLink { SoundSettingsScreen() } label: {
                Label("声音设置（播报音色/语速）", systemImage: "speaker.wave.2")
            }
        }
    }

    // MARK: - 更多（勋章/守护/客服/检查更新）

    @ViewBuilder
    private var moreSection: some View {
        Section("更多") {
            NavigationLink { ExpMedalScreen() } label: {
                Label("等级与勋章", systemImage: "medal")
            }
            NavigationLink { GuardScreen() } label: {
                Label("安全守护与紧急求救", systemImage: "shield.lefthalf.filled")
            }
            if supportUid > 0 {
                NavigationLink {
                    ChatScreen(peer: ConversationsScreen.Conv(
                        uid: supportUid, username: "", nickname: supportNick,
                        lastText: "", lastKind: "text", lastCreated: 0, unread: 0))
                } label: {
                    Label("联系客服", systemImage: "headphones")
                }
            } else {
                Label("客服加载中…", systemImage: "headphones")
                    .foregroundStyle(.secondary)
                    .onAppear {
                        Task {
                            if let s = try? await CommunityClient.shared.supportAccount() {
                                supportUid = s.uid
                                supportNick = s.nickname
                            }
                        }
                    }
            }
            Button {
                checkUpdate()
            } label: {
                if checking { ProgressView().frame(maxWidth: .infinity) }
                else { Label("检查更新", systemImage: "arrow.triangle.2.circlepath") }
            }
            .disabled(checking)
        }
    }

    private var versionSection: some View {
        Section {
            HStack {
                Text("当前版本").foregroundStyle(.secondary)
                Spacer()
                Text("v\(UpdateChecker.currentVersion) (build \(UpdateChecker.currentBuild))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 数据刷新（本地轨迹数 + 云端统计）

    private func refresh() async {
        trackCount = Db.shared.listTracks().count
        do {
            let s = try await CommunityClient.shared.myStats()
            let pc = (s["posts"] as? NSNumber)?.intValue ?? 0
            let fc = (s["followers"] as? NSNumber)?.intValue ?? 0
            let fwc = (s["following"] as? NSNumber)?.intValue ?? 0
            let tc = (s["teams"] as? NSNumber)?.intValue ?? 0
            await MainActor.run {
                postsCount = pc; followersCount = fc; followingCount = fwc; teamsCount = tc
            }
        } catch { }
    }
}
