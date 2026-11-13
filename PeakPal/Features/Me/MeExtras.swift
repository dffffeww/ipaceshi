import SwiftUI
import PhotosUI

/// 「我的」页扩展（对应安卓 AccountSecurityActivity + MyPostsActivity + FollowListActivity）：
/// - ProfileEditScreen：编辑资料（头像上传/昵称/签名/常驻城市）
/// - MyPostsScreen：我的帖子（审核状态 + 删除）
/// - FollowListScreen：关注/粉丝双列表（互关标记 + 关注操作）

// MARK: - 编辑资料（对应安卓 updateProfileFull）

struct ProfileEditScreen: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    @State private var nickname = ""
    @State private var bio = ""
    @State private var location = ""
    @State private var avatarImg: UIImage?
    @State private var showPicker = false
    @State private var oldPwd = ""
    @State private var newPwd = ""
    @State private var msg = ""
    @State private var err = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("头像") {
                HStack {
                    Spacer()
                    if let img = avatarImg {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 84, height: 84)
                            .clipShape(Circle())
                    } else {
                        AvatarView(src: session.avatar, size: 84)
                    }
                    Spacer()
                }
                Button {
                    showPicker = true
                } label: {
                    Label("更换头像", systemImage: "photo.on.rectangle.angled")
                }
            }
            Section("资料") {
                TextField("昵称", text: $nickname)
                TextField("个性签名", text: $bio)
                TextField("常驻城市（如：深圳）", text: $location)
            }
            Section("修改密码（可选）") {
                SecureField("原密码", text: $oldPwd)
                SecureField("新密码（≥8 位）", text: $newPwd)
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("保存").frame(maxWidth: .infinity).bold() }
                }
                .disabled(busy || nickname.trimmingCharacters(in: .whitespaces).isEmpty)
                if !msg.isEmpty { Text(msg).font(.footnote).foregroundStyle(.green) }
                if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("修改密码成功后需要重新登录")
            }
        }
        .navigationTitle("编辑资料")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            MultiPhotoPicker(maxCount: 1) { imgs in
                avatarImg = imgs.first
            }
        }
        .task {
            // 预填当前资料
            if let myUid = Int(session.uid),
               let p = try? await CommunityClient.shared.userProfile(Int64(myUid)) {
                nickname = p["nickname"] as? String ?? session.name
                bio = p["bio"] as? String ?? ""
                location = p["location"] as? String ?? ""
            } else {
                nickname = session.name
            }
        }
    }

    private func save() async {
        busy = true; err = ""; msg = ""
        do {
            var avatarB64: String?
            if let img = avatarImg {
                guard let s = ImageUploadKit.dataURL(img) else {
                    err = "头像图片处理失败，请换一张"; busy = false; return
                }
                avatarB64 = s
            }
            _ = try await CommunityClient.shared.updateProfile(
                nickname: nickname.trimmingCharacters(in: .whitespaces),
                bio: bio.trimmingCharacters(in: .whitespaces),
                avatar: avatarB64,
                location: location.trimmingCharacters(in: .whitespaces))
            // 修改密码（填了才提交）
            let o = oldPwd.trimmingCharacters(in: .whitespaces)
            let n = newPwd.trimmingCharacters(in: .whitespaces)
            if !o.isEmpty && !n.isEmpty {
                try await CommunityClient.shared.changePassword(old: o, new: n)
            }
            // 本地同步昵称/头像
            if let myUid = Int(session.uid),
               let p = try? await CommunityClient.shared.userProfile(Int64(myUid)) {
                if let nick = p["nickname"] as? String, !nick.isEmpty { session.name = nick }
                if let av = p["avatar"] as? String { session.avatar = av }
            }
            if !o.isEmpty && !n.isEmpty {
                msg = "保存成功，密码已修改，请重新登录"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                session.logout()
            } else {
                msg = "保存成功"
                try? await Task.sleep(nanoseconds: 600_000_000)
                dismiss()
            }
        } catch {
            err = error.localizedDescription
        }
        busy = false
    }
}

// MARK: - 我的帖子（对应安卓 MyPostsActivity：审核状态 + 删除）

struct MyPostsScreen: View {
    @State private var posts: [CommunityClient.Post] = []
    @State private var loading = true
    @State private var err = ""

    var body: some View {
        Group {
            if loading {
                ProgressView().padding(.vertical, 40)
            } else if !err.isEmpty {
                Text(err).font(.footnote).foregroundStyle(.red)
            } else if posts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("还没有发过帖子").font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 40)
            } else {
                List {
                    ForEach(posts) { p in
                        NavigationLink {
                            PostDetailView(post: p) { Task { await load() } }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                HStack {
                                    statusBadge(p.status)
                                    Text("\(TimeFmt.post(p.time)) · 赞 \(p.likes) · 评 \(p.comments)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if p.status == "rejected" && !p.reviewNote.isEmpty {
                                    Text("驳回原因：\(p.reviewNote)").font(.caption2).foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("我的帖子")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func statusBadge(_ s: String) -> some View {
        let (text, color): (String, Color) = s == "approved" ? ("已通过", .green)
            : s == "pending" ? ("审核中", .orange) : ("已驳回", .red)
        Text(text).font(.caption2).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func load() async {
        loading = posts.isEmpty
        err = ""
        do { posts = try await CommunityClient.shared.listMine() }
        catch { err = error.localizedDescription }
        loading = false
    }
}

// MARK: - 关注 / 粉丝（对应安卓 FollowListActivity 双 Tab）

struct FollowListScreen: View {
    @EnvironmentObject var session: Session
    @State private var tab = 0
    @State private var follows: [FollowItem] = []
    @State private var fans: [FollowItem] = []
    @State private var loading = true
    @State private var err = ""

    struct FollowItem: Identifiable {
        let uid: Int
        let username: String
        let nickname: String
        let avatar: String
        var mutual: Bool
        var following: Bool
        var id: Int { uid }
        var display: String { nickname.isEmpty ? username : nickname }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("关注 \(follows.count)").tag(0)
                Text("粉丝 \(fans.count)").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(12)
            if loading {
                ProgressView().padding(.vertical, 40)
                Spacer()
            } else {
                List {
                    if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red) }
                    ForEach(tab == 0 ? follows : fans) { item in
                        row(item)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("关注与粉丝")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func row(_ item: FollowItem) -> some View {
        HStack(spacing: 10) {
            AvatarView(src: item.avatar, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.display).font(.subheadline.weight(.semibold))
                    if item.mutual {
                        Text("互关").font(.caption2).foregroundStyle(.green)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                }
                Text("@\(item.username)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if tab == 0 {
                Button {
                    Task { await setFollow(item, false) }
                } label: {
                    Text("已关注").font(.caption)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(.systemGray5), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            } else if item.following {
                NavigationLink {
                    ChatScreen(peer: ConversationsScreen.Conv(
                        uid: item.uid, username: item.username, nickname: item.nickname,
                        lastText: "", lastKind: "text", lastCreated: 0, unread: 0))
                } label: {
                    Text("发私信").font(.caption)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.green.opacity(0.14), in: Capsule())
                        .foregroundStyle(.green)
                }
            } else {
                Button {
                    Task { await setFollow(item, true) }
                } label: {
                    Text("回关注").font(.caption.bold())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.green, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        loading = follows.isEmpty && fans.isEmpty
        err = ""
        do {
            let f = try await CommunityClient.shared.followList()
            let g = try await CommunityClient.shared.fansList()
            await MainActor.run {
                follows = f.map(Self.parse($0, defaultFollowing: true))
                fans = g.map(Self.parse($0, defaultFollowing: false))
                loading = false
            }
        } catch {
            await MainActor.run { err = error.localizedDescription; loading = false }
        }
    }

    private static func parse(_ o: [String: Any], defaultFollowing: Bool) -> FollowItem {
        FollowItem(
            uid: (o["uid"] as? NSNumber)?.intValue ?? (o["id"] as? NSNumber)?.intValue ?? 0,
            username: o["username"] as? String ?? "",
            nickname: o["nickname"] as? String ?? "",
            avatar: o["avatar"] as? String ?? "",
            mutual: (o["mutual"] as? NSNumber)?.intValue == 1 || (o["mutual"] as? Bool == true),
            following: defaultFollowing)
    }

    private func setFollow(_ item: FollowItem, _ on: Bool) async {
        do {
            try await CommunityClient.shared.setFollow(uid: Int64(item.uid), on)
            if let i = follows.firstIndex(where: { $0.id == item.uid }) {
                follows.remove(at: i)
            }
        } catch { err = error.localizedDescription }
    }
}
