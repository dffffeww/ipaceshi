import SwiftUI
import UIKit
import AVFoundation

/// 社区（对应安卓 HomeFragment 社区列表 + PostDetailActivity + CreatePostActivity 精简版）：
/// 帖子列表（分类筛选/搜索/置顶）、帖子详情（点赞/评论/关注作者）、发帖（文本，图片/视频/结伴报名后续迭代）
struct CommunityScreen: View {
    @State private var posts: [CommunityClient.Post] = []
    @State private var category = "全部"
    @State private var keyword = ""
    @State private var loading = false
    @State private var err = ""
    @State private var showCreate = false

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
                // 搜索条
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜帖子", text: $keyword)
                        .onSubmit { Task { await load() } }
                    if !keyword.isEmpty {
                        Button { keyword = ""; Task { await load() } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)
                .padding(10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12).padding(.bottom, 6)

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
            posts = try await CommunityClient.shared.listPosts(category: category, keyword: keyword)
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

/// 帖子行（对应安卓帖子卡片：置顶徽标 + 分类 + 标题 + 摘要 + 作者/时间/赞/评）
struct PostRow: View {
    let p: CommunityClient.Post

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // 首字头像（表情字符或真图后续迭代）
                ZStack {
                    Circle().fill(Color.green.opacity(0.18)).frame(width: 34, height: 34)
                    Text(p.avatarIsImage ? "🥾" : p.avatar).font(.headline)
                }
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
        .padding(.vertical, 2)
    }
}

/// 帖子详情（对应安卓 PostDetailActivity：正文 + 点赞 + 关注作者 + 评论列表 + 发评论）
struct PostDetailView: View {
    @State var post: CommunityClient.Post
    var onChanged: (() -> Void)?

    @State private var comments: [CommunityClient.Comment] = []
    @State private var liked = false
    @State private var likeCount = 0
    @State private var following = false
    @State private var newComment = ""
    @State private var busy = false
    @State private var err = ""

    var body: some View {
        List {
            Section {
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
                        Text("📷 \(post.images.count) 张图片（图片浏览后续迭代）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if post.track > 0 {
                        Label("关联轨迹：\(post.trackName.isEmpty ? "点击下载" : post.trackName) · \(TrackMath.fmtDistance(post.trackDistance)) · \(TrackMath.fmtDuration(post.trackDur))",
                              systemImage: "figure.hiking")
                            .font(.caption).foregroundStyle(.green)
                    }
                    if post.companion {
                        Text("结伴同行 · 已报名 \(post.signups) 人（报名功能后续迭代）")
                            .font(.caption).foregroundStyle(.blue)
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
            Section {
                Button {
                    Task { await toggleLike() }
                } label: {
                    Label(liked ? "已赞 \(likeCount)" : "点赞 \(likeCount)",
                          systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
                .buttonStyle(.bordered)
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
        .task { await refresh() }
    }

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
        } catch {
            err = error.localizedDescription
        }
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

/// 发帖（对应安卓 CreatePostActivity：标题/内容/地点/分类）
struct CreatePostView: View {
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var content = ""
    @State private var place = ""
    @State private var category = "综合"
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
                    Text("图片/视频/关联轨迹发帖功能后续迭代；结伴同行帖请先在正文写明集合时间地点")
                }
            }
            .navigationTitle("发帖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func submit() async {
        busy = true
        do {
            let r = try await CommunityClient.shared.createPost(
                title: title.trimmingCharacters(in: .whitespaces),
                content: content.trimmingCharacters(in: .whitespaces),
                place: place.trimmingCharacters(in: .whitespaces),
                category: category)
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
