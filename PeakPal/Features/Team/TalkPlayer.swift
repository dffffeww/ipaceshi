import Foundation
import AVFoundation
import AudioToolbox

/// 流式对讲接收播放器（1:1 移植自安卓 TeamService.TalkPlayer v7.67+）：
/// - ADTS AAC 分片按「说话人会话」排队：同一人（seq 相同）无缝连播；
///   说完（收到 e 片或 2.5 秒无新片）才轮到下一个人，不混流
/// - 解码器跨片复用（AudioConverter 常驻，等价安卓 MediaCodec 复用优化）
/// - 解码输出 PCM Int16 16k 单声道，+3dB 增益（×1.41，与安卓 v7.73 一致）
/// - 播放走 AVAudioEngine + AVAudioPlayerNode 缓冲队列（等价 AudioTrack MODE_STREAM，
///   写入即排播，片与片零间隙）
/// - 消息 id 去重（同一分片绝不重复入队），会话按到达顺序排队
public final class TalkPlayer: ObservableObject {

    struct Chunk { let data: Data; let id: Int64; let from: String; let seq: String; let stat: String }
    final class TalkSess {
        var q: [Chunk] = []
        var lastArrival = Date()
        var ended = false        // 收到 e 片：该说话人本轮说完
    }

    public static let shared = TalkPlayer()

    static let speakerTimeout: TimeInterval = 2.5   // 无新片 2.5 秒视为说完（与安卓一致）
    static let seenMax = 400                        // 去重表上限（防长期常驻膨胀）

    // MARK: - UI 状态（顶部波纹胶囊：XX 正在对讲）
    @Published public private(set) var voiceFrom: String?
    @Published public private(set) var voiceIsTalk = true
    @Published public private(set) var playing = false

    private let lock = NSLock()
    private var order: [String] = []                // 说话人会话队列（到达顺序，等价 LinkedHashMap）
    private var sessMap: [String: TalkSess] = [:]
    private var seen = Set<Int64>()
    private var alive = true
    private var workerStarted = false

    // 播放链路
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var scheduledCount = 0                  // 已排播未播完的缓冲数（背压用）

    // 解码器（跨片复用，坏片时重建）
    private static var convLock = NSLock()
    private static var conv: AudioConverterRef?
    private static var convBroken = false

    private init() { }

    // MARK: - 入队

    /// 收到一片对讲（任意线程安全）
    func enqueue(data: Data, id: Int64, from: String, seq: String, stat: String) {
        lock.lock()
        guard alive else { lock.unlock(); return }
        if id > 0 && !seen.insert(id).inserted { lock.unlock(); return }  // 同一分片绝不重复入队
        if seen.count > Self.seenMax { seen.removeAll() }
        if sessMap[seq] == nil { order.append(seq); sessMap[seq] = TalkSess() }
        let s = sessMap[seq]!
        s.q.append(Chunk(data: data, id: id, from: from, seq: seq, stat: stat))
        s.lastArrival = Date()
        if stat.contains("e") { s.ended = true }
        let fromName = from
        lock.unlock()

        DispatchQueue.main.async {
            self.voiceFrom = fromName
            self.voiceIsTalk = true
            self.playing = true
        }
        startWorker()
    }

    /// 退出队伍/登出时关停（对应安卓 TalkPlayer.shutdown）
    func shutdown() {
        lock.lock()
        alive = false
        order.removeAll(); sessMap.removeAll(); seen.removeAll()
        lock.unlock()
        DispatchQueue.main.async {
            self.voiceFrom = nil
            self.playing = false
        }
        stopEngine()
    }

    // MARK: - 播放线程（对应安卓 talk-play 线程）

    private func startWorker() {
        lock.lock()
        if workerStarted { lock.unlock(); return }
        workerStarted = true
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.run() }
    }

    private func run() {
        while true {
            lock.lock()
            let isAlive = alive
            lock.unlock()
            if !isAlive { break }

            if let c = nextChunk() {
                play(c)
                continue
            }
            lock.lock()
            let empty = sessMap.isEmpty
            lock.unlock()
            if empty {
                // 全部播完：顶部胶囊滑出 + 释放引擎（对应安卓 endTrack + sendVoiceUI(false)）
                stopEngine()
                DispatchQueue.main.async {
                    if self.voiceIsTalk { self.voiceFrom = nil }
                    self.playing = false
                }
                lock.lock()
                workerStarted = false
                lock.unlock()
                return
            }
            Thread.sleep(forTimeInterval: 0.04)   // 等片间隙 40ms（与安卓 v7.94 一致）
        }
    }

    /// 取下一个应播的分片：同一说话人连续出队；说完（e/超时）自动切到下一位
    private func nextChunk() -> Chunk? {
        lock.lock()
        defer { lock.unlock() }
        while !order.isEmpty {
            let first = order[0]
            guard let s = sessMap[first] else { order.removeFirst(); continue }
            if let c = s.q.first {
                s.q.removeFirst()
                return c
            }
            if s.ended || Date().timeIntervalSince(s.lastArrival) > Self.speakerTimeout {
                order.removeFirst()               // 该说话人已收尾：轮到下一位
                sessMap.removeValue(forKey: first)
                continue
            }
            return nil                            // 当前说话人还有后续片在路上：短暂等待
        }
        return nil
    }

    // MARK: - 播放引擎

    /// 引擎惰性创建：16k 单声道 PCM 直连混音（等价 AudioTrack USAGE_MEDIA/SPEECH）
    private func ensureEngine() throws {
        guard engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            throw NSError(domain: "talkplay", code: 1)
        }
        e.connect(p, to: e.mainMixerNode, format: fmt)
        e.prepare()
        try e.start()
        p.play()
        engine = e
        player = p
        scheduledCount = 0
    }

    private func stopEngine() {
        if let p = player {
            p.stop()
            engine?.detach(p)
        }
        engine?.stop()
        engine = nil
        player = nil
        scheduledCount = 0
    }

    /// 播一片：ADTS 解析 → 复用 AAC 解码器 → PCM +3dB → 排入播放队列（写入即播，片间零间隙）
    private func play(_ c: Chunk) {
        do {
            try ensureEngine()
            var rawFrames = Self.parseADTS(c.data)
            guard !rawFrames.isEmpty else { return }          // 坏片跳过不断流
            var pcm = Data()
            guard let converter = Self.ensureConverter(),
                  Self.decode(converter: converter, frames: rawFrames, out: &pcm), !pcm.isEmpty else {
                Self.invalidateConverter()                     // 解码器状态不明：下次重建（对应安卓 releaseDecoder）
                return
            }
            rawFrames.removeAll()
            Self.applyGain(&pcm)                               // +3dB：户外听得清（与安卓一致）
            schedulePCM(pcm)
        } catch {
            Self.invalidateConverter()
            stopEngine()
        }
    }

    /// PCM 排播 + 背压：缓冲积压超过 ~2 秒（32 片×256ms）短暂等待，防止解码快于实时导致延迟越积越大
    private func schedulePCM(_ pcm: Data) {
        guard let player = player, let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else { return }
        // 背压等待（40ms 步进，等价安卓 AudioTrack 阻塞写的节奏控制）
        while scheduledCount > 32 {
            Thread.sleep(forTimeInterval: 0.04)
        }
        let samples = pcm.count / 2
        guard samples > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples)) else { return }
        buf.frameLength = AVAudioFrameCount(samples)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let dst = buf.int16ChannelData {
                dst.pointee.update(from: raw.baseAddress!.assumingMemoryBound(to: Int16.self), count: samples)
            }
        }
        scheduledCount += 1
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.scheduledCount = max(0, self.scheduledCount - 1)
            self.lock.unlock()
        }
    }

    // MARK: - ADTS 解析

    /// ADTS 流 → 裸 AAC 帧数组（与安卓端 ADTS 头格式逐字节对应）
    static func parseADTS(_ data: Data) -> [Data] {
        var out: [Data] = []
        let bytes = [UInt8](data)
        var i = 0
        while i + 7 <= bytes.count {
            guard bytes[i] == 0xFF, (bytes[i + 1] & 0xF0) == 0xF0 else { i += 1; continue }   // 同步字 0xFFF
            let len = (Int(bytes[i + 3] & 0x03) << 11) | (Int(bytes[i + 4]) << 3) | (Int(bytes[i + 5]) >> 5)
            if len < 7 { break }
            let end = i + len
            guard end <= bytes.count else { break }
            out.append(Data(bytes[(i + 7)..<end]))   // 去 7 字节头
            i = end
        }
        return out
    }

    // MARK: - AAC 解码（AudioConverter，magic cookie = ASC 0x14 0x08，与安卓 csd-0 一致）

    /// 解码器惰性创建 + 跨片复用（等价安卓 ensureDecoder 的复用优化）；失败返回 nil
    static func ensureConverter() -> AudioConverterRef? {
        convLock.lock()
        defer { convLock.unlock() }
        if let c = conv, !convBroken { return c }
        var pcmASBD = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var aacASBD = AudioStreamBasicDescription(
            mSampleRate: 16000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 1024, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var c: AudioConverterRef?
        guard AudioConverterNew(&aacASBD, &pcmASBD, &c) == noErr, let convRef = c else {
            convBroken = true
            return nil
        }
        // 关键修复（对应安卓 v7.71）：部分解码器没有 AudioSpecificConfig 会输出静音。
        // 参数固定 16k/mono/LC：profile=LC(2)=00010 freqIdx=16k(8)=1000 chanCfg=1=0001 → 0x14 0x08
        let cookie = Data([0x14, 0x08])
        cookie.withUnsafeBytes { raw in
            _ = AudioConverterSetProperty(convRef, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), UnsafeRawPointer(raw.baseAddress!))
        }
        conv = convRef
        convBroken = false
        return convRef
    }

    static func invalidateConverter() {
        convLock.lock()
        defer { convLock.unlock() }
        if let c = conv { AudioConverterDispose(c) }
        conv = nil
        convBroken = false
    }

    struct DecCtx { let frames: [Data]; var idx = 0 }

    /// 裸 AAC 帧 → PCM Int16（packet = 1 个 AAC 帧 = 1024 采样）
    static func decode(converter: AudioConverterRef, frames: [Data], out: inout Data) -> Bool {
        guard !frames.isEmpty else { return false }
        var ctx = DecCtx(frames: frames)
        let maxOut = frames.count * 1024 * 2 + 4096
        var outBuf = Data(count: maxOut)
        var packets: UInt32 = UInt32(frames.count + 8)
        var outDesc = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: frames.count + 8)
        let status = outBuf.withUnsafeMutableBytes { (obuf: UnsafeMutableRawBufferPointer) -> OSStatus in
            withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                AudioConverterFillComplexBuffer(
                    converter,
                    { _, ioPackets, ioData, outDescPtr, inUserData -> OSStatus in
                        let ctxPtr = inUserData!.assumingMemoryBound(to: DecCtx.self)
                        var filled: UInt32 = 0
                        var byteOff: UInt32 = 0
                        let bufCapacity = Int(ioData.pointee.mBuffers.mDataByteSize)
                        while filled < ioPackets.pointee && ctxPtr.pointee.idx < ctxPtr.pointee.frames.count {
                            let f = ctxPtr.pointee.frames[ctxPtr.pointee.idx]
                            let n = f.count
                            guard byteOff + n <= bufCapacity else { break }
                            f.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                                memcpy(ioData.pointee.mBuffers.mData! + Int(byteOff), raw.baseAddress!, n)
                            }
                            outDescPtr?[Int(filled)] = AudioStreamPacketDescription(
                                mStartOffset: byteOff, mVariableFramesInPacket: 0, mDataByteSize: UInt32(n))
                            byteOff += UInt32(n)
                            filled += 1
                            ctxPtr.pointee.idx += 1
                        }
                        ioData.pointee.mNumberBuffers = 1
                        ioData.pointee.mBuffers.mDataByteSize = byteOff
                        ioPackets.pointee = filled
                        return filled == 0 ? -1 /* 数据耗尽 */ : noErr
                    },
                    ctxPtr,
                    &packets,
                    obuf.baseAddress!.assumingMemoryBound(to: AudioBufferList.self),
                    &outDesc)
            }
        }
        guard status == noErr, packets > 0 else { return false }
        // 输出 packet 的总字节数（PCM 每 packet=2 字节）
        var total = 0
        for i in 0..<Int(packets) { total += Int(outDesc[i].mDataByteSize) }
        guard total > 0, total <= maxOut else { return false }
        out = outBuf.prefix(total)
        return true
    }

    /// +3dB 增益（×1.41）+ 削波（与安卓 v7.73 一致：原 +6dB 用户反馈太响）
    static func applyGain(_ pcm: inout Data) {
        pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.baseAddress!.assumingMemoryBound(to: Int16.self)
            let n = raw.count / 2
            for i in 0..<n {
                var s = Int(p[i]) * 141 / 100
                if s > 32767 { s = 32767 } else if s < -32768 { s = -32768 }
                p[i] = Int16(s)
            }
        }
    }
}
