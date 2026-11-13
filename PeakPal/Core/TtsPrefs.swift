import AVFoundation

/// 语音播报设置（对应安卓 TtsKit + 声音设置页）：
/// - 开关、音色（系统 zh-CN 语音列表）、语速
/// - TtsKit.speak 统一播报入口：记录页每公里 / 导航播报共用，读同一套偏好
public enum TtsPrefs {

    static var d: UserDefaults { UserDefaults(suiteName: "tts") ?? .standard }

    /// 播报总开关（默认开）
    public static func enabled() -> Bool {
        let v = d.object(forKey: "enabled") as? Int
        return v == nil ? true : v == 1
    }
    public static func setEnabled(_ on: Bool) { d.set(on ? 1 : 0, forKey: "enabled") }

    /// 音色 identifier（空 = 系统默认 zh-CN）
    public static func voiceId() -> String { d.string(forKey: "voice") ?? "" }
    public static func setVoiceId(_ id: String) { d.set(id, forKey: "voice") }

    /// 语速 0.1(慢) ~ 0.7(快)，默认 0.5（AVSpeechUtteranceRate 适中值）
    public static func rate() -> Float {
        let r = d.float(forKey: "rate")
        return (r >= 0.1 && r <= 0.7) ? r : 0.5
    }
    public static func setRate(_ r: Float) { d.set(r, forKey: "rate") }

    /// 可选音色列表（zh-CN 全部 + 普通话台标声，去重）
    public static func voices() -> [AVSpeechSynthesisVoice] {
        let all = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
        return all.sorted { ($0.name, $0.language) < ($1.name, $1.language) }
    }

    /// 组装 utterance（读偏好）
    public static func utterance(_ text: String) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        let id = voiceId()
        if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        u.rate = rate()
        return u
    }
}

/// 统一播报入口（对应安卓 TtsKit.speak）：共用一个 synthesizer，读 TtsPrefs
public enum TtsKit {
    public static let synth = AVSpeechSynthesizer()

    /// 播报一句话（总开关关闭时静默；同一时刻只播最新一条，避免播报排队堆积）
    public static func speak(_ text: String) {
        guard TtsPrefs.enabled() else { return }
        synth.stopSpeaking(at: .word)
        synth.speak(TtsPrefs.utterance(text))
    }
}
