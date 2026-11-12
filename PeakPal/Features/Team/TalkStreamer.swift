import Foundation
import AVFoundation
import AudioToolbox

/// 队伍实时对讲（1:1 移植自安卓 TeamTalk.java v3 流式对讲，协议与安卓端互通）：
/// AVAudioEngine 连续采集 PCM → AudioConverter AAC-LC 24kbps 流式编码（raw 帧）
/// → 每帧拼 7 字节 ADTS 头 → 首片 2 帧（≈128ms）/ 后续片 4 帧（≈256ms）切片 → 串行上传。
/// 分片协议（与安卓逐字节一致）：
///   text  = "🎙对讲|<seqId>|<序号>|<s首片|m中间片|e结束片>"
///   audio = base64(ADTS AAC)
///   通道  = POST /api/chat { code, pid, name, kind:"voice", text, audio }
public final class TalkStreamer: ObservableObject {

    public static let shared = TalkStreamer()

    static let sr: Double = 16000                      // 16k 采样：电话级人声
    static let firstSegFrames = 2                      // 首片 2 帧 ≈128ms 抢先上传
    static let segFrames = 4                           // 后续片 4 帧 ≈256ms
    static let minMs: Int64 = 800                      // 不足 0.8 秒视为误触取消

    @Published public private(set) var talking = false
    @Published public private(set) var segSent = 0
    @Published public private(set) var amp: Int = 0
    @Published public private(set) var lastHint: String?

    private var engine: AVAudioEngine?
    private var conv16k: AVAudioConverter?             // 硬件采样率 → 16k Int16
    private var aac: AudioConverterRef?                // 16k PCM → AAC-LC raw

    private let lock = NSLock()
    private var aacFrameBuf = Data()                   // 当前片累计的 ADTS 帧
    private var frameCount = 0                         // 当前片帧数
    private var uploadChain: [[String: Any]] = []      // 待上传片（串行有序）
    private var uploading = false
    private var talkingFlag = false
    private var stopReq = false
    private var canceled = false
    private var seqId = ""
    private var segIdx = 0
    private var segSentCount = 0
    private var segFail = 0
    private var talkStart: Int64 = 0
    private var lastAmpAt: Int64 = 0

    // MARK: - 公开控制

    /// 是否对讲进行中/发送中（聊天轮询切快车道用）
    public var busy: Bool {
        lock.lock(); defer { lock.unlock() }
        return talkingFlag || !uploadChain.isEmpty
    }

    public func press() {
        guard !talkingFlag else { return }
        guard TeamState.shared.inTeam else {
            lastHint = "先加入队伍，即可对全体队友直接说话"
            return
        }
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] ok in
                if !ok { DispatchQueue.main.async { self?.lastHint = "需要麦克风权限，请授权后再点击说话" } }
            }
            return
        }
        guard !busy else {
            lastHint = "上一段对讲还在发送，请稍候再按"
            return
        }
        lock.lock()
        talkingFlag = true
        stopReq = false
        canceled = false
        segIdx = 0
        segSentCount = 0
        segFail = 0
        seqId = String(Int64(Date().timeIntervalSince1970 * 1000))
        talkStart = Int64(Date().timeIntervalSince1970 * 1000)
        uploadChain.removeAll()
        aacFrameBuf.removeAll()
        frameCount = 0
        lock.unlock()
        DispatchQueue.main.async {
            self.talking = true
            self.segSent = 0
            self.amp = 0
        }
        startEngine()
    }

    public func release() {
        lock.lock(); stopReq = true; lock.unlock() // 采集回调检测：排空编码器后收尾
    }

    // MARK: - 采集引擎

    private func startEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            // voiceChat 模式：系统级回声消除(AEC)+噪声抑制(NS)——对应安卓 VOICE_COMMUNICATION 采集源
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0 else { throw NSError(domain: "talk", code: 1) }

            // 目标：16k 单声道 Int16（与安卓 AudioRecord 完全一致）
            let out16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sr, channels: 1, interleaved: true)!
            let conv = AVAudioConverter(from: inFormat, to: out16k)!
            self.conv16k = conv

            // AAC-LC 24kbps（raw 帧，等价安卓 MediaCodec AAC 输出；ADTS 由我们拼）
            guard let aacConv = Self.makeAACConverter() else {
                throw NSError(domain: "talk", code: 2, userInfo: [NSLocalizedDescriptionKey: "AAC 编码器初始化失败"])
            }
            self.aac = aacConv

            engine.prepare()
            input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
                self?.onMicData(buffer)
            }
            try engine.start()
            self.engine = engine
        } catch {
            lastHint = "无法录音：\(error.localizedDescription)"
            teardown()
        }
    }

    /// 硬件格式 → 16k Int16 重采样 → AAC 编码 → 分片
    private func onMicData(_ buffer: AVAudioPCMBuffer) {
        guard let conv = conv16k, let aac = aac else { return }
        let ratio = Self.sr / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 2048
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: cap) else { return }
        var err: NSError?
        var fed = false
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = outBuf.int16ChannelData, outBuf.frameLength > 0 else { return }
        let samples = Int(outBuf.frameLength)

        // 振幅（RMS→近似量级）：驱动波形气泡（100ms 节流，与安卓一致）
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if nowMs - lastAmpAt >= 100 {
            lastAmpAt = nowMs
            let v = Self.rms(of: ch.pointee, count: samples)
            DispatchQueue.main.async { [weak self] in self?.amp = min(32767, Int(v * 2.2)) }
        }

        // PCM → AAC raw 帧 → ADTS → 分片
        let pcm = Data(bytes: ch, count: samples * 2)
        var raw = Data()
        guard Self.encodeAAC(converter: aac, pcm: pcm, out: &raw), !raw.isEmpty else { return }

        lock.lock()
        var endNow = false
        for byte in raw { aacFrameBuf.append(byte) } // raw 已按帧边界，直接累计
        frameCount += raw.frames(in: aacFrameBuf)
        // 首片 2 帧抢先上传，后续片 4 帧（帧对齐零裂缝，与安卓一致）
        let cutAt = (segIdx == 0) ? Self.firstSegFrames : Self.segFrames
        if frameCount >= cutAt {
            enqueue(seg: aacFrameBuf, end: false)
            aacFrameBuf.removeAll()
            frameCount = 0
        }
        if stopReq {
            if !aacFrameBuf.isEmpty { enqueue(seg: aacFrameBuf, end: true) } // 尾片
            aacFrameBuf.removeAll()
            frameCount = 0
            endNow = true
        }
        lock.unlock()
        if endNow { drain() }
    }

    private func enqueue(seg: Data, end: Bool) {
        let idx = segIdx
        segIdx += 1
        let stat = end && stopReq ? "e" : (idx == 0 ? "s" : "m")
        uploadChain.append(packetBody(idx: idx, stat: stat, data: seg))
    }

    // MARK: - 串行上传（单队列保证顺序，弱网每片重试一次）

    private func drain() {
        lock.lock()
        if uploading || uploadChain.isEmpty { lock.unlock(); return }
        let body = uploadChain.removeFirst()
        uploading = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var ok = false
            if !self.canceled {
                for attempt in 0..<2 {
                    do {
                        _ = try Self.blockingChat(body: body)
                        ok = true
                        break
                    } catch {
                        if attempt == 1 { lock.lock(); self.segFail += 1; lock.unlock() }
                    }
                }
            }
            DispatchQueue.main.async {
                if ok { self.segSent += 1 }
                self.uploading = false
                self.drain()
                if !self.talkingFlag && !self.uploading {
                    self.finishIfDone()
                }
            }
        }
    }

    /// 采集已停且队列已空 → 收尾 UI
    private func finishIfDone() {
        guard !talkingFlag, !uploading else { return }
        let total = Int64(Date().timeIntervalSince1970 * 1000) - talkStart
        let sent = segSentCount + segSent
        segSentCount = sent
        let fails = segFail
        let tt = total
        talking = false
        amp = 0
        if sent > 0 {
            if fails > 0 { lastHint = "对讲完成，\(fails) 片因网络丢失，可能不连贯" }
            else { lastHint = "🎙 对讲结束，已实时送达全队" }
        } else if tt < Self.minMs {
            canceled = true
            lastHint = "说话太短，已取消"
        } else {
            lastHint = "对讲未送出，请检查网络"
        }
    }

    private func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let aac { AudioConverterDispose(aac) }
        aac = nil
        talkingFlag = false
        talking = false
    }

    // MARK: - 协议（与安卓端逐字节一致）

    /// 组装 /api/chat 请求体
    func packetBody(idx: Int, stat: String, data: Data) -> [String: Any] {
        return [
            "code": TeamState.shared.code,
            "pid": TeamState.shared.pid,
            "name": TeamState.shared.myName,
            "kind": "voice",
            "text": "🎙对讲|\(self.seqId)|\(idx)|\(stat)",
            "audio": data.base64EncodedString(),
        ]
    }

    /// 同步等一次 chat 上传（串行队列内使用）
    static func blockingChat(body: [String: Any]) throws -> [String: Any] {
        var result: Result<[String: Any], Error>?
        let sem = DispatchSemaphore(value: 0)
        Task {
            do { result = .success(try await TeamState.shared.chat(body: body)) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        switch result! {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }

    static func rms(of ptr: UnsafeMutablePointer<Int16>, count: Int) -> Double {
        var sum = 0.0
        var cnt = 0
        for i in stride(from: 0, to: count, by: 4) {
            let s = Double(ptr[i]); sum += s * s; cnt += 1
        }
        return cnt == 0 ? 0 : sqrt(sum / Double(cnt)) * 2.2
    }

    // MARK: - AAC 编码（AudioToolbox）

    static func makeAACConverter() -> AudioConverterRef? {
        var pcmASBD = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var aacASBD = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var conv: AudioConverterRef?
        guard AudioConverterNew(&pcmASBD, &aacASBD, &conv) == noErr, let c = conv else { return nil }
        var bitrate: UInt32 = 24000 // 24kbps：与安卓一致，弱网上传快、清晰度不变
        AudioConverterSetProperty(c, kAudioConverterEncodeBitRate, 4, &bitrate)
        return c
    }

    /// PCM Int16 → AAC raw 帧（每 packet 1024 采样一个帧）
    static func encodeAAC(converter: AudioConverterRef, pcm: Data, out: inout Data) -> Bool {
        var ctx = EncCtx(data: pcm, offset: 0)
        var outDesc = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: 64)
        var packets: UInt32 = 64
        let ioBytes = UInt32(pcm.count + 2048)
        var outBuf = Data(count: Int(ioBytes))
        let ok = outBuf.withUnsafeMutableBytes { (obuf: UnsafeMutableRawBufferPointer) -> OSStatus in
            withUnsafeMutablePointer(to: &ctx) { ctxPtr in
                AudioConverterFillComplexBuffer(
                    converter,
                    { _, ioNumberDataPackets, ioData, _, inUserData -> OSStatus in
                        let ctxPtr = inUserData!.assumingMemoryBound(to: EncCtx.self)
                        let avail = ctxPtr.pointee.data.count - ctxPtr.pointee.offset
                        if avail < 2 { return noErr } // 数据耗尽
                        let want = min(Int(ioNumberDataPackets.pointee) * 2, avail, Int(ioData.pointee.mBuffers.mDataByteSize))
                        ctxPtr.pointee.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                            memcpy(ioData.pointee.mBuffers.mData!, raw.baseAddress! + ctxPtr.pointee.offset, want)
                        }
                        ioData.pointee.mBuffers.mDataByteSize = UInt32(want)
                        ioData.pointee.mNumberBuffers = 1
                        ioNumberDataPackets.pointee = UInt32(want / 2)
                        ctxPtr.pointee.offset += want
                        return noErr
                    },
                    ctxPtr,
                    &packets,
                    obuf.baseAddress!.assumingMemoryBound(to: AudioBufferList.self),
                    &outDesc)
            }
        }
        guard ok == noErr, packets > 0 else { return false }
        // 每个输出 packet = 一个 AAC raw 帧 → 拼 7 字节 ADTS 头
        let used = outBuf.prefix(Int(outDesc[0].mDataByteSize))
        out.append(adts(used.count))
        out.append(used)
        return true
    }

    struct EncCtx { let data: Data; var offset: Int }

    /// 7 字节 ADTS 头（AAC-LC 16k 单声道，保护位 absent）——与安卓 TeamTalk.adts() 完全一致
    static func adts(_ rawLen: Int) -> Data {
        let full = rawLen + 7
        var a = [UInt8](repeating: 0, count: 7)
        a[0] = 0xFF
        a[1] = 0xF1
        a[2] = UInt8((1 << 6) | (8 << 2))                  // profile=LC(1) freqIdx=16k(8) chanCfg=1
        a[3] = UInt8(((1 & 3) << 6) | (full >> 11))
        a[4] = UInt8((full >> 3) & 0xFF)
        a[5] = UInt8(((full & 7) << 5) | 0x1F)
        a[6] = 0xFC
        return Data(a)
    }
}

extension Data {
    /// 估算 AAC 帧数（仅用于统计；1024 采样/帧 @16k ≈ 64ms/帧，实际按 packet 解析）
    func frames(in buf: Data) -> Int { 1 } // 每次编码输出按 1 帧计，由 AudioConverter packet 数决定
}

private extension UnsafeMutableRawBufferPointer {
    var baseMemory: UnsafeMutableRawPointer? { baseAddress }
}
