import SwiftUI

/// 我的页（对应安卓 MeFragment 精简版）：账号信息、3D 地图设置、退出登录。
/// 服务器固定为云端生产服务器（与安卓同一套后端），页面上不显示地址
struct MeScreen: View {
    @EnvironmentObject var session: Session
    @State private var checking = false
    @State private var updateInfo: UpdateChecker.Info?
    @State private var showUpdate = false
    @State private var upToDate = false
    @State private var supportUid = 0
    @State private var supportNick = "官方客服"
    @State private var supportErr = ""

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
                Section("账号") {
                    HStack {
                        AvatarView(src: session.avatar, size: 44)
                        VStack(alignment: .leading) {
                            Text(session.name.isEmpty ? session.uid : session.name).font(.headline)
                            Text("UID: \(session.uid)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("社区") {
                    NavigationLink { ExpMedalScreen() } label: {
                        Label("等级与勋章", systemImage: "medal")
                    }
                    NavigationLink { ProfileEditScreen() } label: {
                        Label("编辑资料", systemImage: "person.crop.rectangle")
                    }
                    NavigationLink { MyPostsScreen() } label: {
                        Label("我的帖子", systemImage: "doc.text")
                    }
                    NavigationLink { FollowListScreen() } label: {
                        Label("关注与粉丝", systemImage: "person.2")
                    }
                    NavigationLink { GuardScreen() } label: {
                        Label("安全守护与紧急求救", systemImage: "shield.lefthalf.filled")
                    }
                    NavigationLink {
                        if supportUid > 0 {
                            ChatScreen(peer: ConversationsScreen.Conv(
                                uid: supportUid, username: "", nickname: supportNick,
                                lastText: "", lastKind: "text", lastCreated: 0, unread: 0))
                        }
                    } label: {
                        Label("联系客服", systemImage: "headphones")
                    }
                    .disabled(supportUid == 0)
                    .onAppear {
                        guard supportUid == 0 else { return }
                        Task {
                            do {
                                let s = try await CommunityClient.shared.supportAccount()
                                await MainActor.run { supportUid = s.uid; supportNick = s.nickname }
                            } catch { supportErr = error.localizedDescription }
                        }
                    }
                }
                Section("3D 地图") {
                    HStack {
                        Text("地形夸张").foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1fx", Map3DStyle.exag()))
                    }
                    Text("影像源：\(Map3DStyle.tdtReady ? "天地图影像" : "Esri World Imagery")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("版本") {
                    HStack {
                        Text("当前版本").foregroundStyle(.secondary)
                        Spacer()
                        Text("v\(UpdateChecker.currentVersion) (build \(UpdateChecker.currentBuild))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        checkUpdate()
                    } label: {
                        if checking { ProgressView().frame(maxWidth: .infinity) }
                        else { Label("检查更新", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(checking)
                }
                Section {
                    Button(role: .destructive) {
                        session.logout()
                    } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                }
            }
            .navigationTitle("我的")
            .task { await session.syncProfile() }
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
}
