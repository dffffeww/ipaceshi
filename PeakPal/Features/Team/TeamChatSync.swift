import Foundation
import AVFoundation

/// 队伍聊天/对讲接收通道（1:1 移植自安卓 TeamService 的 chatLoop + SSE + handleMsgItem）：
/// - 轮询：2 秒常规节奏；对讲热聊期（刚收到语音 30 秒内 / 本机正在对讲）切 250ms 快车道
/// - SSE：/api/team/chat/stream 长连接实时推送（服务端 0.35 秒一查、50 秒一轮回），
///   断线 1 秒自动重连；与轮询并存，轮询按消息 id 游标幂等兜底
/// - 对讲分片（🎙对讲| 前缀）：只走实时播放通道（TalkPlayer），绝不写入聊天记录——
///   电话模式，说完即逝
/// - 其他消息：写本地库 team_msg（表结构同安卓）；队友语音消息自动播放且保留文件可回听
public final class TeamChatSync: ObservableObject {

    public static let shared = TeamChatSync()

    public struct VoiceCapsule: Equatable { public let from: String; public let talk: Bool }

    /// 顶部波纹胶囊（对应安卓 VoiceTopBar）：有人对讲/发语音时滑入
    @Published public private(set) var capsule: VoiceCapsule?
    /// 聊天消息自增标记（聊天页监听它重读本地库）
    @Published public private(set) var chatTick = 0

    private var pollTask: Task<Void, Never>?
    private var sseTask: Task<Void, Never>?
    private var lastVoiceSeenAt: TimeInterval = 0
    private var dnd: Bool { UserDefaults.standard.bool(forKey: "team_msg_dnd") }

    // 队友语音消息（非对讲 m4a 文件）顺序自动播放（对应安卓 playNextTalk 队列）
    private var voicePlayer: AVAudioPlayer?
    private var voiceQueue: [(path: String, from: String)] = []
    private let voiceLock = NSLock()

    /// 消息处理互斥锁：pollLoop 与 sseLoop 两个 Task 并发到达，游标推进与去重必须串行
    /// （与安卓一致：Android 端 handleMsgItem 虽多线程调用但 id<=since 判断+REPLACE 入库天然幂等；
    ///  iOS 端 UserDefaults double 读改写非原子，需要显式锁）
    private let msgLock = NSLock()

    private init() { }

    var chatSince: Int64 {
        get { Int64(UserDefaults.standard.double(forKey: "team_chat_since")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "team_chat_since") }
    }

    // MARK: - 启动/停止（加入队伍 / 退出队伍时调用）

    public func start() {
        stop()
        // 注意：不要在这里访问 TeamState.shared（App 冷启动时本方法由 TeamState.init 调用，
        // 单例还在初始化中，再访问会重入死锁）；直接读持久化的队伍码判断
        let saved = UserDefaults.standard.string(forKey: "team_code") ?? ""
        guard !saved.isEmpty else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
        sseTask = Task { [weak self] in await self?.sseLoop() }
    }

    public func stop() {
        pollTask?.cancel(); pollTask = nil
        sseTask?.cancel(); sseTask = nil
        voiceLock.lock()
        voiceQueue.removeAll()
        voiceLock.unlock()
        DispatchQueue.main.async { self.voicePlayer?.stop(); self.voicePlayer = nil }
        TalkPlayer.shared.shutdown()
    }

    /// 手动踢一脚立即拉一次（进入聊天页/队伍页时）
    public func kick() {
        Task { [weak self] in await self?.pollOnce() }
    }

    // MARK: - 轮询循环

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            let hot = TalkStreamer.shared.busy || Date().timeIntervalSince1970 - lastVoiceSeenAt < 30
            try? await Task.sleep(nanoseconds: hot ? 250_000_000 : 2_000_000_000)
        }
    }

    private func pollOnce() async {
        guard let team = teamSnapshot() else { return }
        do {
            let res = try await Session.shared.api.request(
                "GET", "team/chat?code=\(urlEsc(team.code))&since=\(chatSince)")
            guard let items = res["items"] as? [[String: Any]] else { return }
            for o in items { handleMsgItem(o) }
        } catch { }   // 弱网静默，下轮重试
    }

    // MARK: - SSE 实时推送（对讲/聊天毫秒级到达，轮询作幂等兜底）

    private func sseLoop() async {
        while !Task.isCancelled {
            guard let team = teamSnapshot() else { return }
            do {
                guard let url = URL(string: Session.shared.api.base + "/api/team/chat/stream?code=\(urlEsc(team.code))&since=\(chatSince)") else { return }
                var req = URLRequest(url: url, timeoutInterval: 70)   // 服务端 50 秒一轮回
                req.setValue("Bearer " + Session.shared.api.token, forHTTPHeaderField: "Authorization")
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode ?? 500 < 400 else { throw URLError(.badServerResponse) }
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if let data = payload.data(using: .utf8),
                       let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        handleMsgItem(o)
                    }
                }
            } catch { }
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)   // 断线 1 秒自动重连（与安卓一致）
        }
    }

    // MARK: - 单条消息处理（轮询与 SSE 共用；msgLock 串行化：游标推进幂等、@Published 主线程更新）

    func handleMsgItem(_ o: [String: Any]) {
        msgLock.lock()
        let id = (o["id"] as? NSNumber)?.int64Value ?? 0
        guard id > 0, id > chatSince else { msgLock.unlock(); return }
        let team = teamSnapshot()
        guard let team else { msgLock.unlock(); return }
        let kind = o["kind"] as? String ?? "text"
        let pid2 = o["pid"] as? String ?? ""
        let text = o["text"] as? String ?? ""
        let name = o["name"] as? String ?? "队员"
        let mine = (pid2 == team.pid)
        let t = ((o["t"] as? NSNumber)?.doubleValue ?? 0) * 1000
        let isTalk = kind == "voice" && text.hasPrefix("🎙对讲|")

        if kind == "voice" || kind == "image" || kind == "video" {
            guard let b64 = o["audio"] as? String, let raw = Data(base64Encoded: b64), !raw.isEmpty else {
                advanceCursor(id); msgLock.unlock(); return
            }
            if isTalk {
                // 电话模式：对讲分片只走实时播放通道，绝不写入聊天记录
                if !mine && !dnd {
                    lastVoiceSeenAt = Date().timeIntervalSince1970
                    let tp = text.components(separatedBy: "|")
                    let seq = tp.count > 1 ? tp[1] : String(id)
                    let stat = tp.count > 3 ? tp[3] : "m"
                    TalkPlayer.shared.enqueue(data: raw, id: id, from: name, seq: seq, stat: stat)
                }
            } else {
                // 聊天媒体：落盘 Documents/teamchat/msg_<id>.<ext>（可回听）
                let ext = kind == "voice" ? "m4a" : (kind == "image" ? "jpg" : "mp4")
                let file = Self.saveMedia(raw, id: id, ext: ext)
                Db.shared.addTeamMsg(id: id, code: team.code, pid: pid2, name: name,
                                     kind: kind, text: text, file: file, t: Int64(t), mine: mine)
                if kind == "voice" && !mine && !dnd && file != nil {
                    lastVoiceSeenAt = Date().timeIntervalSince1970
                    enqueueVoiceFile(file!, from: name)   // 电话式自动播放（keep：文件保留可回听）
                }
            }
        } else {
            Db.shared.addTeamMsg(id: id, code: team.code, pid: pid2, name: name,
                                 kind: kind, text: text, file: nil, t: Int64(t), mine: mine)
        }
        advanceCursor(id)
        msgLock.unlock()
        // @Published 只能主线程写（pollLoop/SSE 均在后台 Task）
        DispatchQueue.main.async {
            self.chatTick += 1
            if !isTalk && !mine {
                self.capsule = VoiceCapsule(from: name, talk: false)
            }
        }
    }

    private func advanceCursor(_ id: Int64) {
        if id > chatSince { chatSince = id }
    }

    private func teamSnapshot() -> (code: String, pid: String)? {
        let team = TeamState.shared
        guard team.inTeam, !team.code.isEmpty else { return nil }
        return (team.code, team.pid)
    }

    private func urlEsc(_ s: String) -> String {
        return s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    /// 媒体落盘（对应安卓 teamchat/msg_<id>.<ext>）
    static func saveMedia(_ raw: Data, id: Int64, ext: String) -> String? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("teamchat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("msg_\(id).\(ext)")
        do { try raw.write(to: url); return url.path } catch { return nil }
    }

    // MARK: - 队友语音消息自动播放（对应安卓 playNextTalk：播完自动接下一片，坏片跳过）

    private func enqueueVoiceFile(_ path: String, from: String) {
        voiceLock.lock()
        if voiceQueue.count >= 30 { voiceQueue.removeFirst() }   // 队列硬上限（与安卓一致）
        voiceQueue.append((path, from))
        voiceLock.unlock()
        DispatchQueue.main.async {
            self.capsule = VoiceCapsule(from: from, talk: false)
            self.playNextVoiceFile()
        }
    }

    private func playNextVoiceFile() {
        guard voicePlayer == nil else { return }                 // 正在播：completion 回调会自动接上
        voiceLock.lock()
        let next = voiceQueue.isEmpty ? nil : voiceQueue.removeFirst()
        voiceLock.unlock()
        guard let item = next else {
            DispatchQueue.main.async { if self.capsule?.talk == false { self.capsule = nil } }
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: item.path))
            voicePlayer = p
            p.delegate = VoicePlayerDelegate.shared
            VoicePlayerDelegate.shared.onDone = { [weak self] in
                self?.voicePlayer = nil
                DispatchQueue.main.async { self?.playNextVoiceFile() }
            }
            p.volume = 1.4   // +3dB 响度增强（等价安卓 VoiceBoost，户外听得清）
            p.play()
        } catch {
            voicePlayer = nil
            DispatchQueue.main.async { self.playNextVoiceFile() }   // 跳过坏片继续
        }
    }
}

/// AVAudioPlayer 完播回调桥（delegate 必须长期持有，用单例防提前释放）
final class VoicePlayerDelegate: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayerDelegate()
    var onDone: (() -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onDone?() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onDone?() }
}
