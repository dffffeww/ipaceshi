import SwiftUI
import UIKit
import AVFoundation
import PhotosUI

/// 社区（对应安卓 HomeFragment 社区列表 + PostDetailActivity + CreatePostActivity 精简版）：
/// 帖子列表（分类筛选/搜索/置顶）、帖子详情（点赞/评论/关注作者）、发帖（文本，图片/视频/结伴报名后续迭代）
struct CommunityScreen: View {
    @State private var posts: [CommunityClient.Post] = []
    @State private var category = "全部"
    @State private var keyword = ""
    @State private var loading = false
    @State private var err = ""
    @State private var showCreate = false
    @State private var announcement: (title: String, content: String)?
    @State private var city = ""
    @State private var showCityInput = false
    @State private var cityInput = ""

    static let categories = ["全部", "综合", "线路攻略", "徒步笔记", "结伴同行", "装备交流"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 分类横滑条
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.categories, id: \.self) { c in
                            Button {
                                category = c
                                Task { await load() }
                            } label: {
                                Text(c)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(category == c ? Color.green.opacity(0.18) : Color(.systemGray6),
                                                in: Capsule())
                                    .foregroundStyle(category == c ? Color.green : Color.primary)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                // 搜索条 + 城市筛选（对应安卓城市筛选：按发帖地点过滤）
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜帖子", text: $keyword)
                        .onSubmit { Task { await load() } }
                    if !keyword.isEmpty {
                        Button { keyword = ""; Task { await load() } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        showCityInput = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "location")
                            Text(city.isEmpty ? "城市" : city)
                        }
                        .font(.caption)
                        .foregroundStyle(city.isEmpty ? Color.secondary : Color.green)
                    }
                    if !city.isEmpty {
                        Button { city = ""; Task { await load() } } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)
                .padding(10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12).padding(.bottom, 6)

                // 官方公告（对应安卓 HomeFragment announcement 横幅）
                if let a = announcement {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2).foregroundStyle(.orange)
                            Text(a.title).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                        Text(a.content).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 12).padding(.bottom, 6)
                }

                if loading { ProgressView().padding(.vertical, 30) }
                else if !err.isEmpty {
                    emptyState("wifi.exclamationmark", "加载失败", err)
                } else if posts.isEmpty {
                    emptyState("leaf", "还没有帖子", "下拉刷新或发第一帖")
                } else {
                    List {
                        ForEach(posts) { p in
                            NavigationLink {
                                PostDetailView(post: p) { Task { await load() } }
                            } label: {
                                PostRow(p: p)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("社区")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showCreate = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .refreshable { await load() }
            .alert("按城市筛选", isPresented: $showCityInput) {
                TextField("如：深圳（发帖地点包含即可）", text: $cityInput)
                Button("筛选") {
                    city = cityInput.trimmingCharacters(in: .whitespaces)
                    Task { await load() }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("筛选发帖地点包含该城市的帖子")
            }
            .sheet(isPresented: $showCreate) {
                CreatePostView { Task { await load() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        err = ""
        do {
            posts = try await CommunityClient.shared.listPosts(category: category, keyword: keyword, city: city)
            announcement = try? await CommunityClient.shared.latestAnnouncement()
        } catch {
            err = error.localizedDescription
        }
        loading = false
    }

    /// iOS 16 兼容的空态视图（iOS 17 的 ContentUnavailableView 不适用于 16.0 目标）
    private func emptyState(_ icon: String, _ title: String, _ sub: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(sub).font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

/// 帖子行（对应安卓帖子卡片：置顶徽标 + 分类 + 标题 + 摘要 + 作者/时间/赞/评 + 首图缩略）
struct PostRow: View {
    let p: CommunityClient.Post

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AvatarView(src: p.avatar, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(p.author.isEmpty ? "山友" : p.author).font(.subheadline.bold())
                        if p.pinned {
                            Text("置顶").font(.caption2).foregroundStyle(.orange)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.orange.opacity(0.12), in: Capsule())
                        }
                        if p.companion {
                            Text("结伴").font(.caption2).foregroundStyle(.blue)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.blue.opacity(0.12), in: Capsule())
                        }
                    }
                    Text("\(p.category) · \(TimeFmt.post(p.time))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(p.place).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(p.title).font(.headline).lineLimit(2)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    if !p.content.isEmpty {
                        Text(p.content).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 14) {
                        Label("\(p.likes)", systemImage: "hand.thumbsup")
                        Label("\(p.comments)", systemImage: "text.bubble")
                        if p.track > 0 { Label("轨迹", systemImage: "figure.hiking") }
                        Spacer()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let first = p.images.first {
                    RemoteImg(src: first)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 帖子详情（对应安卓 PostDetailActivity：正文 + 点赞 + 关注作者 + 评论列表 + 发评论）
struct PostDetailView: View {
    @EnvironmentObject var session: Session
    @State var post: CommunityClient.Post
    var onChanged: (() -> Void)?

    @State private var comments: [CommunityClient.Comment] = []
    @State private var liked = false
    @State private var likeCount = 0
    @State private var following = false
    @State private var newComment = ""
    @State private var busy = false
    @State private var err = ""
    @State private var viewerIdx: ViewerIndex?
    @State private var showSignup = false
    @State private var showSignups = false
    @State private var signedUp = false
    @State private var askDeletePost = false
    @State private var downloadingTrack = false

    /// 是否本人发的帖（session.uid 存的是字符串 uid）
    private var isMine: Bool {
        guard post.uid > 0 else { return false }
        return session.uid == String(post.uid) || Int(session.uid) == Int(post.uid)
    }

    var body: some View {
        List {
            Section {
                postHeader
            }
            Section {
                supportSection
            } header: { Text("支持") }
            Section("\(comments.count) 条评论") {
                ForEach(comments) { c in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(c.name).font(.subheadline.bold())
                            Spacer()
                            Text(TimeFmt.post(c.time)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(c.text).font(.subheadline)
                    }
                    .padding(.vertical, 2)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        // 只能删自己的评论（与安卓 PostDetailActivity 一致）
                        if Int64(session.uid) == c.uid || session.uid == String(c.uid) {
                            Button(role: .destructive) {
                                Task { await delComment(c) }
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
                HStack {
                    TextField("友善评论，共赴山野", text: $newComment)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await sendComment() }
                    } label: {
                        if busy { ProgressView() } else { Image(systemName: "paperplane.fill") }
                    }
                    .disabled(busy || newComment.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("帖子")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 删除自己的帖子（对应安卓 PostDetailActivity 删除入口）
            if post.uid > 0, isMine {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) { askDeletePost = true } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .fullScreenCover(item: $viewerIdx) { i in
            ImageViewer(images: post.images, index: i.value)
        }
        .sheet(isPresented: $showSignup) {
            SignupForm(post: post) { Task { await refresh() } }
        }
        .sheet(isPresented: $showSignups) {
            SignupListView(pid: post.id)
        }
        .confirmationDialog("删除这条帖子？", isPresented: $askDeletePost, titleVisibility: .visible) {
            Button("删除", role: .destructive) { Task { await delPost() } }
            Button("取消", role: .cancel) {}
        }
        .task { await refresh() }
    }

    // MARK: - 正文头部（标题/作者/关注/图片/轨迹卡/结伴/审核状态）

    @ViewBuilder
    private var postHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(post.title).font(.title3.bold())
            HStack {
                Text(post.author).font(.subheadline.bold())
                Text("\(post.category) · \(TimeFmt.post(post.time))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await toggleFollow() }
                } label: {
                    Text(following ? "已关注" : "关注")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(following ? Color(.systemGray5) : Color.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(following ? Color.secondary : Color.green)
                }
                .disabled(post.uid <= 0)
            }
            if !post.place.isEmpty {
                Label(post.place, systemImage: "mappin.and.ellipse")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(post.content).font(.body)
            if !post.images.isEmpty {
                imageGrid
            }
            if post.track > 0 {
                trackCard
            }
            if post.companion {
                companionSection
            }
            if post.status == "pending" {
                Text("⏳ 审核中，仅自己可见").font(.caption).foregroundStyle(.orange)
            }
            if !post.reviewNote.isEmpty {
                Text("审核备注：\(post.reviewNote)").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    /// 点赞/私信区
    private var supportSection: some View {
        Group {
            Button {
                Task { await toggleLike() }
            } label: {
                Label(liked ? "已赞 \(likeCount)" : "点赞 \(likeCount)",
                      systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
            }
            .buttonStyle(.bordered)
            if post.uid > 0 {
                NavigationLink {
                    ChatScreen(peer: ConversationsScreen.Conv(
                        uid: Int(post.uid), username: "", nickname: post.author,
                        lastText: "", lastKind: "text", lastCreated: 0, unread: 0))
                } label: {
                    Label("发私信", systemImage: "ellipsis.message.fill")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// 关联轨迹卡（点击下载到本地轨迹库，对应安卓帖子轨迹卡 TrackThumb 下载）
    private var trackCard: some View {
        Button {
            Task { await downloadPostTrack() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.hiking")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.green, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("轨迹：\(post.trackName.isEmpty ? "路线 #\(post.track)" : post.trackName)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("\(TrackMath.fmtDistance(post.trackDistance)) · \(TrackMath.fmtDuration(post.trackDur)) · 点击下载到轨迹库")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if downloadingTrack { ProgressView() }
                else { Image(systemName: "icloud.and.arrow.down").foregroundStyle(.green) }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 图片九宫格（3 列，点击全屏浏览）

    private var imageGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(Array(post.images.enumerated()), id: \.offset) { i, src in
                Button { viewerIdx = ViewerIndex(value: i) } label: {
                    RemoteImg(src: src)
                        .frame(height: 104)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 全屏查看器定位（Int 包装，满足 Identifiable）
    struct ViewerIndex: Identifiable { let value: Int; var id: Int { value } }

    // MARK: - 结伴报名区

    private var companionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("结伴同行 · 已报名 \(post.signups) 人", systemImage: "person.2.wave.2")
                    .font(.caption.weight(.semibold)).foregroundStyle(.blue)
                Spacer()
                Button("报名名单") { showSignups = true }
                    .font(.caption)
            }
            if !post.needGender.isEmpty {
                Text("限 \(post.needGender)报名").font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    showSignup = true
                } label: {
                    Text(signedUp ? "修改报名" : "我要报名")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.blue)
                }
                if signedUp {
                    Button {
                        Task { await cancelMySignup() }
                    } label: {
                        Text("取消报名")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 数据

    private func refresh() async {
        do {
            async let p = CommunityClient.shared.getPost(post.id)
            async let cs = CommunityClient.shared.listComments(pid: post.id)
            async let ls = CommunityClient.shared.likeStatus(pid: post.id)
            if post.uid > 0 {
                following = (try? await CommunityClient.shared.followStatus(uid: post.uid)) ?? false
            }
            if let np = try? await p {
                post = np
                likeCount = np.likes
            }
            comments = (try? await cs) ?? []
            let l = try? await ls
            liked = l?.liked ?? false
            likeCount = l?.count ?? post.likes
            // 我是否已报名（对照名单里的 uid）
            if post.companion, let myUid = Int(session.uid) {
                let my = (try? await CommunityClient.shared.listSignups(pid: post.id)) ?? []
                signedUp = my.contains { Int($0.uid) == myUid }
            }
        } catch {
            err = error.localizedDescription
        }
    }

    private func delComment(_ c: CommunityClient.Comment) async {
        do {
            try await CommunityClient.shared.deleteComment(c.id)
            comments = try await CommunityClient.shared.listComments(pid: post.id)
            post.comments = comments.count
        } catch { err = error.localizedDescription }
    }

    /// 下载帖子关联轨迹到本地（对应安卓帖子轨迹卡下载：GET tracks/{id} 含 points）
    private func downloadPostTrack() async {
        guard !downloadingTrack else { return }
        downloadingTrack = true
        defer { downloadingTrack = false }
        do {
            let res = try await session.api.request("GET", "tracks/\(post.track)")
            var t = Track()
            t.name = (res["name"] as? String) ?? (post.trackName.isEmpty ? "路线 #\(post.track)" : post.trackName)
            t.start = (res["start"] as? NSNumber)?.int64Value ?? 0
            t.end = (res["end"] as? NSNumber)?.int64Value ?? 0
            t.dur = (res["dur"] as? NSNumber)?.int64Value ?? 0
            t.cloudId = post.track
            var pts: [TrackPt] = []
            if let arr = res["points"] as? [[String: Any]] {
                for p in arr {
                    let pt = TrackPt(
                        lat: (p["lat"] as? NSNumber)?.doubleValue ?? 0,
                        lng: (p["lng"] as? NSNumber)?.doubleValue ?? 0,
                        alt: (p["alt"] as? NSNumber)?.doubleValue ?? 0,
                        t: (p["t"] as? NSNumber)?.int64Value ?? 0)
                    if pt.isValid { pts.append(pt) }
                }
            }
            guard pts.count >= 2 else { err = "该轨迹云端暂无轨迹点"; return }
            var inserted = Db.shared.listTracks().first(where: { $0.cloudId == post.track })
            if inserted == nil {
                _ = Db.shared.insertTrack(&t, pts: pts)
            }
            err = ""
            await MainActor.run { post.trackName = t.name }
        } catch {
            err = "下载失败：\(error.localizedDescription)"
        }
    }

    private func delPost() async {
        do {
            try await CommunityClient.shared.deletePost(post.id)
            onChanged?()
        } catch { err = error.localizedDescription }
    }

    private func cancelMySignup() async {
        do {
            try await CommunityClient.shared.cancelSignup(pid: post.id)
            signedUp = false
            await refresh()
        } catch { err = error.localizedDescription }
    }

    private func toggleLike() async {
        do {
            try await CommunityClient.shared.setLike(pid: post.id, !liked)
            liked.toggle()
            likeCount += liked ? 1 : -1
        } catch { err = error.localizedDescription }
    }

    private func toggleFollow() async {
        do {
            try await CommunityClient.shared.setFollow(uid: post.uid, !following)
            following.toggle()
        } catch { err = error.localizedDescription }
    }

    private func sendComment() async {
        let text = newComment.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        busy = true; err = ""
        do {
            _ = try await CommunityClient.shared.addComment(pid: post.id, text: text)
            newComment = ""
            comments = try await CommunityClient.shared.listComments(pid: post.id)
            post.comments = comments.count
        } catch {
            err = error.localizedDescription
        }
        busy = false
    }
}

/// 报名表单（对应安卓 signup：性别/名字/手机号 + 帖子要求同城时填城市）
struct SignupForm: View {
    let post: CommunityClient.Post
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var gender = "男"
    @State private var name = ""
    @State private var phone = ""
    @State private var city = ""
    @State private var err = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("报名信息") {
                    Picker("性别", selection: $gender) {
                        ForEach(["男", "女"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("姓名/称呼", text: $name)
                    TextField("手机号（仅楼主可见）", text: $phone)
                        .keyboardType(.phonePad)
                    if post.needCity {
                        TextField("所在城市（本帖要求同城）", text: $city)
                    }
                }
                if post.needGender == "男" || post.needGender == "女生" || post.needGender == "男生" {
                    Text("本帖限 \(post.needGender)报名，请留意").font(.footnote).foregroundStyle(.orange)
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("提交报名").frame(maxWidth: .infinity).bold() }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || phone.trimmingCharacters(in: .whitespaces).count < 5)
                    if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red) }
                } footer: {
                    Text("手机号仅楼主和管理员可见，其他人看到的是打码号码")
                }
            }
            .navigationTitle("结伴报名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    private func submit() async {
        busy = true; err = ""
        do {
            _ = try await CommunityClient.shared.signup(
                pid: post.id, gender: gender,
                name: name.trimmingCharacters(in: .whitespaces),
                phone: phone.trimmingCharacters(in: .whitespaces),
                city: city.trimmingCharacters(in: .whitespaces))
            onDone?()
            dismiss()
        } catch {
            err = error.localizedDescription
        }
        busy = false
    }
}

/// 报名名单（对应安卓 listSignups）
struct SignupListView: View {
    let pid: Int64
    @State private var items: [CommunityClient.Signup] = []
    @State private var err = ""

    var body: some View {
        NavigationStack {
            List {
                if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red) }
                ForEach(items) { s in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(s.name).font(.subheadline.bold())
                            Text(s.gender).font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(s.gender == "女" ? Color.pink.opacity(0.12) : Color.blue.opacity(0.12), in: Capsule())
                                .foregroundStyle(s.gender == "女" ? .pink : .blue)
                            Spacer()
                            Text(TimeFmt.post(s.time)).font(.caption2).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(s.phone).font(.caption).foregroundStyle(.secondary)
                            if !s.city.isEmpty { Text("· \(s.city)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                if items.isEmpty && err.isEmpty {
                    Text("还没有人报名").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("报名名单")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                do { items = try await CommunityClient.shared.listSignups(pid: pid) }
                catch { err = error.localizedDescription }
            }
        }
    }
}

/// 发帖（对应安卓 CreatePostActivity：标题/内容/地点/分类 + 图片≤4张 + 结伴报名条件）
struct CreatePostView: View {
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var content = ""
    @State private var place = ""
    @State private var category = "综合"
    @State private var picked: [UIImage] = []
    @State private var showPicker = false
    @State private var needCity = false
    @State private var needGender = "不限"
    @State private var res: String?
    @State private var busy = false

    static let categories = ["综合", "线路攻略", "徒步笔记", "结伴同行", "装备交流"]

    var body: some View {
        NavigationStack {
            Form {
                Section("分类") {
                    Picker("分类", selection: $category) {
                        ForEach(Self.categories, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("正文") {
                    TextField("标题", text: $title)
                    TextField("地点（如：武功山 / 不填）", text: $place)
                    TextEditor(text: $content)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("分享你的山野故事…")
                                    .foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                Section("图片（最多 4 张）") {
                    pickedImages
                    if picked.count < 4 {
                        Button {
                            showPicker = true
                        } label: {
                            Label("从相册选择", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                }
                if category == "结伴同行" {
                    Section("报名条件") {
                        Toggle("要求同城", isOn: $needCity)
                        Picker("性别限制", selection: $needGender) {
                            ForEach(["不限", "男生", "女生"], id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("发布").frame(maxWidth: .infinity).bold() }
                    }
                    .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty
                              || content.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let res { Text(res).font(.footnote).foregroundStyle(.orange) }
                } footer: {
                    Text(category == "结伴同行"
                         ? "结伴帖会展示报名入口，报名者手机号仅你可见"
                         : "帖子提交后进入审核，通过后所有人可见")
                }
            }
            .navigationTitle("发帖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                MultiPhotoPicker(maxCount: 4 - picked.count) { imgs in
                    picked.append(contentsOf: imgs.prefix(4 - picked.count))
                }
            }
        }
    }

    private var pickedImages: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(picked.enumerated()), id: \.offset) { i, img in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button {
                            picked.remove(at: i)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.white, .red)
                        }
                        .offset(x: 6, y: -6)
                    }
                }
                if picked.isEmpty {
                    Text("未选择图片").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func submit() async {
        busy = true
        do {
            // 压缩成 data URL（≤1.5MB，与安卓同规格）
            var imgs: [String] = []
            for img in picked {
                if let s = ImageUploadKit.dataURL(img) { imgs.append(s) }
            }
            let companion = category == "结伴同行"
            let r = try await CommunityClient.shared.createPost(
                title: title.trimmingCharacters(in: .whitespaces),
                content: content.trimmingCharacters(in: .whitespaces),
                place: place.trimmingCharacters(in: .whitespaces),
                category: category,
                images: imgs,
                companion: companion,
                needCity: needCity,
                needGender: needGender == "不限" ? "" : needGender)
            let status = r["status"] as? String ?? "approved"
            res = status == "approved" ? "发布成功！" : "已提交，等待人工审核"
            if status == "approved" {
                try? await Task.sleep(nanoseconds: 600_000_000)
                onDone?()
                dismiss()
            }
        } catch {
            res = error.localizedDescription
        }
        busy = false
    }
}

/// 多选照片（iOS 16 PhotosPicker 包装：返回 UIImage 数组）
struct MultiPhotoPicker: View {
    let maxCount: Int
    var onPicked: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            PhotosPicker(selection: $items, maxSelectionCount: max(1, maxCount), matching: .images) {
                Label("打开相册选择", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .padding()
            .navigationTitle("选择照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
            .onChange(of: items) { newItems in
                Task {
                    var imgs: [UIImage] = []
                    for it in newItems.prefix(max(1, maxCount)) {
                        if let d = try? await it.loadTransferable(type: Data.self),
                           let ui = UIImage(data: d) {
                            imgs.append(ui)
                        }
                    }
                    if !imgs.isEmpty { onPicked(imgs) }
                    dismiss()
                }
            }
            Text("最多还可选 \(max(0, maxCount)) 张").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
