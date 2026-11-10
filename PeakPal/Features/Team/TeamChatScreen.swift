import SwiftUI
import PhotosUI
import UIKit
import AVFoundation

/// 队伍聊天页（1:1 移植自安卓 TeamChatActivity 微信式聊天）：
/// - 气泡列表：先读本地历史（离线可用），监听 TeamChatSync.chatTick 增量刷新
/// - 发送：文本/图片（video/track 卡片后续迭代），统一 POST /api/chat {code,pid,name,kind,text,audio?}
/// - 电话模式：对讲分片（🎙对讲| 前缀）不进聊天框——本地历史一并过滤
/// - 媒体消息点击可看大图/回听语音
struct TeamChatScreen: View {
    @EnvironmentObject var team: TeamState
    @StateObject private var sync = TeamChatSync.shared
    @Environment(\.dismiss) private var dismiss

    @State private var msgs: [Db.TeamMsg] = []
    @State private var input = ""
    @State private var busy = false
    @State private var err = ""
    @State private var showPicker = false
    @State private var playingPath: String?

    var body: some View {
        VStack(spacing: 0) {
            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(msgs) { m in
                            ChatBubble(m: m, playingPath: $playingPath)
                                .id(m.id)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: sync.chatTick) { _ in
                    reload()
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        proxy.scrollTo(msgs.last?.id ?? 0, anchor: .bottom)
                    }
                }
                .onChange(of: msgs.count) { _ in
                    Task {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        proxy.scrollTo(msgs.last?.id ?? 0, anchor: .bottom)
                    }
                }
            }
            // 错误条
            if !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal).padding(.vertical, 4)
            }
            // 输入区
            HStack(spacing: 8) {
                Button { showPicker = true } label: {
                    Image(systemName: "photo").font(.title3)
                        .foregroundStyle(Color.green)
                }
                TextField("和队友聊聊…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { sendText() }
                Button {
                    sendText()
                } label: {
                    if busy { ProgressView() }
                    else {
                        Image(systemName: "paperplane.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.green, in: Circle())
                    }
                }
                .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial)
        }
        .navigationTitle("队伍聊天")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .sheet(isPresented: $showPicker) {
            // 选图完成回调直接发送（UIImage 非 Equatable，不能用 onChange(of:) 绑定）
            ImagePicker { img in
                sendImage(img)
            }
        }
    }

    // MARK: - 数据

    /// 本地历史（对讲分片过滤，与安卓一致）
    private func reload() {
        msgs = Db.shared.teamMsgs(code: team.code).filter {
            !($0.kind == "voice" && $0.text.hasPrefix("🎙对讲|"))
        }
    }

    // MARK: - 发送

    /// 统一发送（对应安卓 send(kind, label, b64, text)）
    private func send(_ kind: String, text: String, base64: String?) {
        busy = true; err = ""
        Task {
            do {
                var body: [String: Any] = [
                    "code": team.code,
                    "pid": team.pid,
                    "name": team.myName,
                    "kind": kind,
                    "text": text,
                ]
                if let b64 = base64 { body["audio"] = b64 }
                let res = try await Session.shared.api.request("POST", "chat", body: body)
                guard res["ok"] as? Bool == true else {
                    throw NSError(domain: "chat", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: res["error"] as? String ?? "服务器拒绝"])
                }
                // 与安卓一致：自己发的消息即时入库回显（服务器推送同 id 时 REPLACE 幂等覆盖）
                let mid = (res["id"] as? NSNumber)?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
                var file: String? = nil
                if kind == "image", let b64 = base64, let raw = Data(base64Encoded: b64) {
                    file = TeamChatSync.saveMedia(raw, id: mid, ext: "jpg")   // 自己发的图也落盘，气泡可回看
                }
                Db.shared.addTeamMsg(id: mid, code: team.code, pid: team.pid, name: team.myName,
                                     kind: kind, text: text, file: file, t: Int64(Date().timeIntervalSince1970 * 1000), mine: true)
                input = ""
                reload()
            } catch {
                err = error.localizedDescription
            }
            busy = false
        }
    }

    private func sendText() {
        let txt = input.trimmingCharacters(in: .whitespaces)
        guard !txt.isEmpty, !busy else { return }
        send("text", text: txt, base64: nil)
    }

    /// 图片消息：JPEG 压缩至 ≤1280px / 质量 0.7（与安卓 sendImage 体积策略相当）
    private func sendImage(_ image: UIImage) {
        let maxPx: CGFloat = 1280
        var img = image
        let maxSide = max(img.size.width, img.size.height)
        if maxSide > maxPx {
            let scale = maxPx / maxSide
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(size, true, 1)
            img.draw(in: CGRect(origin: .zero, size: size))
            let resized = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            if let resized { img = resized }
        }
        guard let data = img.jpegData(compressionQuality: 0.7) else {
            err = "图片编码失败"; return
        }
        send("image", text: "[图片]", base64: data.base64EncodedString())
    }

    private func sendImageAfterPick(_ image: UIImage) {
        sendImage(image)
    }
}
// MARK: - 气泡

/// 微信式气泡（对应安卓 ChatUi）：自己=绿底右侧，队友=白底左侧；媒体消息带图标
struct ChatBubble: View {
    let m: Db.TeamMsg
    @Binding var playingPath: String?

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if m.mine { Spacer(minLength: 60) }
            if !m.mine {
                // 队友首字头像
                ZStack {
                    Circle().fill(Color.blue.opacity(0.75)).frame(width: 34, height: 34)
                    Text(String((m.name.isEmpty ? "队" : m.name).prefix(1)))
                        .font(.headline).foregroundStyle(.white)
                }
            }
            VStack(alignment: m.mine ? .trailing : .leading, spacing: 3) {
                if !m.mine {
                    Text(m.name).font(.caption2).foregroundStyle(.secondary)
                }
                bubbleContent
                Text(TimeFmt.post(m.t)).font(.caption2).foregroundStyle(.secondary)
            }
            if !m.mine { Spacer(minLength: 60) }
            if m.mine {
                ZStack {
                    Circle().fill(Color.green).frame(width: 34, height: 34)
                    Text(String((team_myName()).isEmpty ? "我" : String(team_myName().prefix(1))))
                        .font(.headline).foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 10)
    }

    /// 从 TeamState 拿我的昵称（避免直接持有 EnvironmentObject）
    private func team_myName() -> String { TeamState.shared.myName }

    @ViewBuilder
    private var bubbleContent: some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        if m.kind == "image", let file = m.file, let img = UIImage(contentsOfFile: file) {
            // 图片消息：缩略图，点击看大图
            NavigationLink {
                ZoomImageSheet(image: img)
            } label: {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(maxWidth: 180, maxHeight: 180)
                    .clipped()
                    .clipShape(shape)
            }
            .buttonStyle(.plain)
        } else if m.kind == "video", let file = m.file {
            Label("视频消息（点按播放后续迭代）", systemImage: "video.fill")
                .font(.subheadline)
                .padding(10).background(Color(.systemGray5), in: shape)
        } else if m.kind == "voice", let file = m.file {
            // 语音消息：点击回听（对讲分片已被上层过滤，不会出现在这里）
            Button {
                playVoice(file)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: playingPath == file ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                    Text(m.text.isEmpty ? "语音" : m.text)
                }
                .font(.subheadline)
                .foregroundStyle(m.mine ? .white : .primary)
                .padding(10)
                .background(m.mine ? Color.green : Color(.systemGray5), in: shape)
            }
        } else {
            Text(m.text)
                .font(.subheadline)
                .foregroundStyle(m.mine ? .white : .primary)
                .padding(10)
                .background(m.mine ? Color.green : Color(.systemGray5), in: shape)
        }
    }

    private func playVoice(_ path: String) {
        if playingPath == path { playingPath = nil; VoicePreview.shared.stop(); return }
        do {
            try VoicePreview.shared.play(path)
            playingPath = path
            VoicePreview.shared.onFinish = {
                self.playingPath = nil
            }
        } catch { }
    }
}

// MARK: - 语音试听（轻量单例）

final class VoicePreview: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePreview()
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    func play(_ path: String) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        stop()
        let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        player = p
        p.delegate = self
        p.play()
    }

    func stop() {
        player?.stop(); player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.onFinish?(); self.onFinish = nil }
    }
}

// MARK: - 图片选择与大图查看

/// 回调式图片选择器（UIImage 非 Equatable，不能用 onChange(of:)，改用完成回调）
struct ImagePicker: UIViewControllerRepresentable {
    var onPicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = 1
        let v = PHPickerViewController(configuration: cfg)
        v.delegate = context.coordinator
        return v
    }
    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        init(_ p: ImagePicker) { parent = p }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let item = results.first else { return }
            item.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] obj, _ in
                DispatchQueue.main.async {
                    if let img = obj as? UIImage { self?.parent.onPicked(img) }
                }
            }
        }
    }
}

/// 大图查看
struct ZoomImageSheet: View {
    let image: UIImage
    var body: some View {
        Image(uiImage: image)
            .resizable().scaledToFit()
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
    }
}
