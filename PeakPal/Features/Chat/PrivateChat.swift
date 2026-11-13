import SwiftUI
import PhotosUI
import UIKit
import AVFoundation

/// 私信模块（1:1 对接安卓 ConversationsFragment + ChatActivity + NotifyActivity）：
/// - 会话列表：GET /api/conversations
/// - 私信聊天：GET /api/messages?peer=&before=&limit= 拉取（拉取即已读），
///             POST /api/messages {to, kind, text, audio?} 发送（text/image/voice）
/// - 系统通知：GET /api/notifies 列表 + POST 已读
/// 协议字段与安卓端逐字段一致（同一后端互通）。
struct ConversationsScreen: View {
    @EnvironmentObject var session: Session
    @State private var items: [Conv] = []
    @State private var err = ""

    struct Conv: Identifiable {
        let uid: Int
        let username: String
        let nickname: String
        let lastText: String
        let lastKind: String
        let lastCreated: Int64
        let unread: Int
        var id: Int { uid }
        var displayName: String { nickname.isEmpty ? username : nickname }
        var lastPreview: String {
            switch lastKind {
            case "image": return "[图片]"
            case "voice": return "[语音]"
            case "video": return "[视频]"
            case "track": return "[轨迹]"
            default: return lastText
            }
        }
    }

    var body: some View {
        List {
            if items.isEmpty && err.isEmpty {
                Text("还没有私信。\n在社区里点队友头像/资料卡即可发起私信。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red) }
            ForEach(items) { c in
                NavigationLink {
                    ChatScreen(peer: c)
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color(red: 0.24, green: 0.42, blue: 0.78)).frame(width: 42, height: 42)
                            Text(String(c.displayName.prefix(1))).font(.headline).foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(c.displayName).font(.subheadline.bold())
                                Spacer()
                                Text(TimeFmt.post(c.lastCreated)).font(.caption2).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(c.lastPreview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if c.unread > 0 {
                                    Text("\(c.unread)").font(.caption2.bold()).foregroundStyle(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.red, in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("私信")
        .refreshable { await load() }
        .onAppear { Task { await load() } }
    }

    private func load() async {
        do {
            let res = try await session.api.request("GET", "conversations")
            var list: [Conv] = []
            for o in (res["items"] as? [[String: Any]]) ?? [] {
                list.append(Conv(
                    uid: (o["uid"] as? NSNumber)?.intValue ?? 0,
                    username: o["username"] as? String ?? "",
                    nickname: o["nickname"] as? String ?? "",
                    lastText: o["lastText"] as? String ?? "",
                    lastKind: o["lastKind"] as? String ?? "text",
                    lastCreated: (o["lastCreated"] as? NSNumber)?.int64Value ?? 0,
                    unread: (o["unread"] as? NSNumber)?.intValue ?? 0))
            }
            await MainActor.run { items = list; err = "" }
        } catch {
            await MainActor.run { err = "加载失败：\(error.localizedDescription)" }
        }
    }
}

/// 私信聊天页（对应安卓 ChatActivity 微信式气泡；拉取即已读）
struct ChatScreen: View {
    @EnvironmentObject var session: Session
    let peer: ConversationsScreen.Conv

    struct Msg: Identifiable {
        let id: Int
        let sender: Int
        let kind: String
        let text: String
        let image: String
        let audio: String
        let created: Int64
        let mine: Bool

        init(o: [String: Any], myUid: String) {
            id = (o["id"] as? NSNumber)?.intValue ?? 0
            sender = (o["sender"] as? NSNumber)?.intValue ?? 0
            kind = o["kind"] as? String ?? "text"
            text = o["text"] as? String ?? ""
            image = o["image"] as? String ?? ""
            audio = o["audio"] as? String ?? ""
            created = (o["created"] as? NSNumber)?.int64Value ?? 0
            mine = sender == (Int(myUid) ?? 0)
        }
    }

    @State private var msgs: [Msg] = []
    @State private var input = ""
    @State private var busy = false
    @State private var err = ""
    @State private var showPicker = false
    @State private var recorder: AVAudioRecorder?
    @State private var micRecording = false
    @State private var recStartAt = Date()
    @State private var peerName = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(msgs) { m in
                            PrivateBubble(m: m, peerName: peerName)
                                .id(m.id)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: msgs.count) { _ in
                    Task {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        proxy.scrollTo(msgs.last?.id ?? 0, anchor: .bottom)
                    }
                }
            }
            if !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal).padding(.vertical, 4)
            }
            HStack(spacing: 8) {
                Button { toggleMic() } label: {
                    Image(systemName: micRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.title3)
                        .foregroundStyle(micRecording ? Color.red : Color.green)
                }
                Button { showPicker = true } label: {
                    Image(systemName: "photo").font(.title3).foregroundStyle(Color.green)
                }
                TextField("发消息…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .onSubmit { sendText() }
                Button { sendText() } label: {
                    if busy { ProgressView() }
                    else {
                        Image(systemName: "paperplane.fill").font(.title3)
                            .foregroundStyle(.white).padding(8)
                            .background(Color.green, in: Circle())
                    }
                }
                .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial)
        }
        .navigationTitle(peerName.isEmpty ? peer.displayName : peerName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            pollTask = Task {
                await load(initial: true)
                await pollLoop()
            }
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
        }
        .sheet(isPresented: $showPicker) {
            ImagePicker { img in sendImage(img) }
        }
    }

    @State private var pollTask: Task<Void, Never>?

    /// 2 秒轮询新消息（页面在前台时；离线由会话列表红点兜底）
    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { break }
            await load(initial: false)
        }
    }

    private func load(initial: Bool) async {
        do {
            let res = try await session.api.request(
                "GET", "messages?peer=\(peer.uid)&limit=50")
            var list: [Msg] = []
            for o in (res["items"] as? [[String: Any]]) ?? [] {
                list.append(Msg(o: o, myUid: session.uid))
            }
            if let p = res["peer"] as? [String: Any] {
                let nk = p["nickname"] as? String ?? ""
                let un = p["username"] as? String ?? ""
                let name = nk.isEmpty ? un : nk
                if !name.isEmpty { peerName = name }
            }
            await MainActor.run { msgs = list; err = "" }
        } catch {
            await MainActor.run { err = "加载失败：\(error.localizedDescription)" }
        }
    }

    private func sendText() {
        let txt = input.trimmingCharacters(in: .whitespaces)
        guard !txt.isEmpty, !busy else { return }
        send(kind: "text", text: txt, audio: nil, image: nil)
    }

    private func sendImage(_ image: UIImage) {
        var img = image
        let maxSide = max(img.size.width, img.size.height)
        if maxSide > 1280 {
            let scale = 1280 / maxSide
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(size, true, 1)
            img.draw(in: CGRect(origin: .zero, size: size))
            if let r = UIGraphicsGetImageFromCurrentImageContext() { img = r }
            UIGraphicsEndImageContext()
        }
        guard let data = img.jpegData(compressionQuality: 0.7) else { err = "图片编码失败"; return }
        let b64 = data.base64EncodedString()
        guard b64.count <= 1_200_000 else { err = "图片过大"; return }
        send(kind: "image", text: "[图片]", audio: b64, image: nil)
    }

    /// 统一发送（POST /api/messages，协议同安卓 ChatClient）
    private func send(kind: String, text: String, audio: String?, image: String?) {
        busy = true; err = ""
        Task {
            do {
                var body: [String: Any] = ["to": peer.uid, "kind": kind, "text": text]
                if let a = audio { body["audio"] = a }
                if let i = image { body["image"] = i }
                let res = try await session.api.request("POST", "messages", body: body)
                guard res["ok"] as? Bool == true else {
                    throw NSError(domain: "msg", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: res["error"] as? String ?? "发送失败"])
                }
                if kind == "text" { input = "" }
                await load(initial: false)
            } catch {
                await MainActor.run { err = error.localizedDescription }
            }
            busy = false
        }
    }

    // MARK: - 语音消息（与队伍聊天同款：AAC m4a ≤30 秒）

    private func toggleMic() {
        if micRecording {
            let durMs = Int64(Date().timeIntervalSince(recStartAt) * 1000)
            let path = recorder?.url.path
            recorder?.stop()
            recorder = nil
            micRecording = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            guard let path, durMs >= 1000 else { return }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
            let b64 = data.base64EncodedString()
            if b64.count > 700_000 {
                err = "语音太长，请控制在 30 秒内"
            } else {
                send(kind: "voice", text: "\(max(1, durMs / 1000))″", audio: b64, image: nil)
            }
            try? FileManager.default.removeItem(atPath: path)
        } else {
            do {
                let s = AVAudioSession.sharedInstance()
                try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
                try s.setActive(true)
                let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("chat", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("rec_\(Int(Date().timeIntervalSince1970 * 1000)).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder?.record()
                recStartAt = Date()
                micRecording = recorder != nil
            } catch {
                err = "麦克风不可用：\(error.localizedDescription)"
            }
        }
    }
}

/// 私信气泡（微信式：自己绿右，对方白左；图片/语音可点）
struct PrivateBubble: View {
    let m: ChatScreen.Msg
    let peerName: String
    @State private var img: UIImage?
    @State private var playing = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if m.mine { Spacer(minLength: 60) }
            if !m.mine {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.75)).frame(width: 34, height: 34)
                    Text(String((peerName.isEmpty ? "友" : peerName).prefix(1)))
                        .font(.headline).foregroundStyle(.white)
                }
            }
            VStack(alignment: m.mine ? .trailing : .leading, spacing: 3) {
                if !m.mine { Text(peerName).font(.caption2).foregroundStyle(.secondary) }
                content
                Text(TimeFmt.post(m.created)).font(.caption2).foregroundStyle(.secondary)
            }
            if !m.mine { Spacer(minLength: 60) }
            if m.mine {
                ZStack {
                    Circle().fill(Color.green).frame(width: 34, height: 34)
                    Text("我").font(.headline).foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 10)
        .onAppear {
            if m.kind == "image", !m.image.isEmpty, img == nil {
                let path = m.image
                let server = Session.shared.server
                Task.detached {
                    guard let url = URL(string: server + path),
                          let data = try? Data(contentsOf: url) else { return }
                    let image = UIImage(data: data)
                    await MainActor.run { img = image }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        if m.kind == "image" || (!m.image.isEmpty && m.kind == "text") {
            if let img {
                NavigationLink {
                    ZoomImageSheet(image: img)
                } label: {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(maxWidth: 180, maxHeight: 180).clipped().clipShape(shape)
                }
                .buttonStyle(.plain)
            } else {
                Text("[图片]").font(.subheadline).padding(10)
                    .background(Color(.systemGray5), in: shape)
            }
        } else if m.kind == "voice" {
            HStack(spacing: 6) {
                Image(systemName: playing ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                Text(m.text.isEmpty ? "语音" : m.text)
            }
            .font(.subheadline)
            .foregroundStyle(m.mine ? .white : .primary)
            .padding(10)
            .background(m.mine ? Color.green : Color(.systemGray5), in: shape)
        } else {
            Text(m.text).font(.subheadline)
                .foregroundStyle(m.mine ? .white : .primary)
                .padding(10)
                .background(m.mine ? Color.green : Color(.systemGray5), in: shape)
        }
    }
}

/// 系统通知页（对应安卓 NotifyActivity 重排版）：分类图标徽章（关注/审核/勋章/系统）
/// + 未读高亮侧条 + 卡片式列表 + 头部未读统计，进入即全部标记已读
struct NotifyScreen: View {
    @EnvironmentObject var session: Session
    @State private var items: [Item] = []
    @State private var unread = 0

    struct Item: Identifiable {
        let id: Int
        let kind: String
        let title: String
        let text: String
        let created: Int64
        let read: Int
    }

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bell.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("暂无消息").font(.subheadline).foregroundStyle(.secondary)
                    Text("关注、审核结果和获得的勋章都会出现在这里")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { n in
                            NotifyCard(item: n,
                                       icon: Self.kindIcon(n.kind, n.title),
                                       color: Self.kindColor(n.kind, n.title))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color(red: 0.965, green: 0.973, blue: 0.961))
        .navigationTitle("消息中心")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if unread > 0 {
                    Text("未读 \(unread)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.red, in: Capsule())
                }
            }
        }
        .onAppear {
            Task {
                do {
                    let res = try await session.api.request("GET", "notifies")
                    var list: [Item] = []
                    for o in (res["items"] as? [[String: Any]]) ?? [] {
                        list.append(Item(
                            id: (o["id"] as? NSNumber)?.intValue ?? 0,
                            kind: o["kind"] as? String ?? "",
                            title: o["title"] as? String ?? "",
                            text: o["text"] as? String ?? "",
                            created: (o["created"] as? NSNumber)?.int64Value ?? 0,
                            read: (o["read"] as? NSNumber)?.intValue ?? 0))
                    }
                    let u = (res["unread"] as? NSNumber)?.intValue ?? 0
                    await MainActor.run { items = list; unread = u }
                    _ = try? await session.api.request("POST", "notifies")   // 拉取即已读
                } catch { }
            }
        }
    }

    /// 分类 → 图标（对应后端 kind：follow/review/medal/系统默认；标题兜底判断与安卓一致）
    static func kindIcon(_ kind: String, _ title: String) -> String {
        let k = kind.lowercased()
        if k.contains("follow") || title.contains("关注") { return "👥" }
        if k.contains("review") || k.contains("audit") || title.contains("审核") { return "📋" }
        if k.contains("medal") || title.contains("勋章") { return "🏅" }
        if k.contains("system") || k.contains("announce") || title.contains("公告") || title.contains("系统") { return "📢" }
        return "🔔"
    }

    /// 分类 → 主题色（关注蓝 / 审核橙 / 勋章金 / 系统绿）
    static func kindColor(_ kind: String, _ title: String) -> Color {
        let k = kind.lowercased()
        if k.contains("follow") || title.contains("关注") { return Color(red: 0.12, green: 0.53, blue: 0.90) }
        if k.contains("review") || k.contains("audit") || title.contains("审核") { return Color(red: 0.98, green: 0.55, blue: 0.0) }
        if k.contains("medal") || title.contains("勋章") { return Color(red: 0.98, green: 0.66, blue: 0.15) }
        if k.contains("system") || k.contains("announce") || title.contains("公告") || title.contains("系统") { return Color(red: 0.18, green: 0.49, blue: 0.20) }
        return Color(red: 0.36, green: 0.54, blue: 0.40)
    }
}

/// 通知卡片：未读彩色侧条 + 图标徽章 + 标题/时间 + 正文（与安卓 NotifyActivity 同款视觉）
struct NotifyCard: View {
    let item: NotifyScreen.Item
    let icon: String
    let color: Color

    private var unread: Bool { item.read == 0 }

    /// 时间口径与安卓一致：今天 HH:mm / 昨天 HH:mm / MM-dd
    private var timeText: String {
        let d = Date(timeIntervalSince1970: Double(item.created) / 1000)
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        let md = DateFormatter(); md.dateFormat = "MM-dd"
        let cal = Calendar.current
        if cal.isDateInToday(d) { return hm.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天 " + hm.string(from: d) }
        return md.string(from: d)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if unread {
                Rectangle()
                    .fill(color)
                    .frame(width: 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(icon)
                        .font(.system(size: 17))
                        .frame(width: 38, height: 38)
                        .background(color.opacity(0.10), in: Circle())
                    Text(item.title)
                        .font(.subheadline.weight(unread ? .bold : .regular))
                        .foregroundStyle(unread ? Color(red: 0.09, green: 0.14, blue: 0.13)
                                               : Color(red: 0.36, green: 0.42, blue: 0.38))
                    Spacer()
                    Text(timeText).font(.caption2).foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(unread ? Color(red: 0.24, green: 0.29, blue: 0.26)
                                            : Color(red: 0.54, green: 0.59, blue: 0.55))
                    .lineLimit(3)
                    .padding(.leading, 48)
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .clipShape(RoundedRectangle(cornerRadius: 14))   // 未读侧条随卡片圆角裁切
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

/// 时间格式化已由 CommunityClient.TimeFmt 提供（post(ms) 兼容毫秒时间戳）

/// 消息 Tab 根页：私信会话 + 系统通知（对应安卓 ConversationsFragment + NotifyActivity）
/// 消息中心（对应安卓 ConversationsFragment「消息中心」四宫格升级为三段式）：
/// - 私信：GET /api/conversations（拉取即红点，进会话即已读）
/// - 队伍聊天：TeamChatScreen（未在队伍时引导去队伍页）
/// - 通知：GET /api/notifies + POST 已读
/// 与安卓端同一套服务器数据，实时互通
struct MessagesRootScreen: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var team: TeamState
    @State private var seg = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("消息", selection: $seg) {
                Text("私信").tag(0)
                Text("队伍聊天").tag(1)
                Text("通知").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if seg == 0 {
                ConversationsScreen()
            } else if seg == 1 {
                if team.inTeam {
                    TeamChatScreen()
                } else {
                    teamEmpty
                }
            } else {
                NotifyScreen()
            }
        }
        .navigationTitle("消息")
    }

    private var teamEmpty: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "person.3")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("还没有加入队伍")
                    .font(.subheadline.weight(.medium))
                Text("创建或加入队伍后，即可在这里和队友实时聊天、对讲")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                NavigationLink {
                    TeamScreen()
                } label: {
                    Text("去队伍页").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20).padding(.vertical, 9)
                        .background(Color(red: 0.28, green: 0.62, blue: 0.36), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(24)
        }
    }
}
