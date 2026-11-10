import SwiftUI

/// 队伍页（对应安卓 TeamActivity + TeamTalk）：
/// 加入/退出队伍 + 实时对讲按钮（与安卓队友互通）+ 位置自动上报
struct TeamScreen: View {
    @EnvironmentObject var team: TeamState
    @EnvironmentObject var loc: LocationKit
    @StateObject private var sync = TeamChatSync.shared
    @StateObject private var player = TalkPlayer.shared

    @State private var codeInput = ""
    @State private var nameInput = ""
    @State private var busy = false
    @State private var err = ""

    var body: some View {
        NavigationStack {
            List {
                if team.inTeam {
                    // 顶部波纹胶囊：XX 正在对讲 / 发来语音（对应安卓 VoiceTopBar）
                    if let cap = sync.capsule {
                        Section {
                            HStack(spacing: 10) {
                                Image(systemName: "waveform")
                                    .font(.title2)
                                    .foregroundStyle(cap.talk ? .orange : .green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cap.talk ? "\(cap.from) 正在对讲" : "\(cap.from) 发来语音")
                                        .font(.subheadline.bold())
                                    Text("实时接收中")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Section("当前队伍") {
                        HStack {
                            Text("队伍名").foregroundStyle(.secondary)
                            Spacer()
                            Text(team.teamName.isEmpty ? "我的队伍" : team.teamName)
                        }
                        HStack {
                            Text("队伍码").foregroundStyle(.secondary)
                            Spacer()
                            Text(team.code).font(.title3.bold().monospaced())
                        }
                        Toggle(isOn: $team.shareLoc) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("随身定位").font(.body)
                                Text(team.shareLoc ? "开启：每 5 秒向队友共享我的位置" : "关闭：隐身看队，不上报我的坐标")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Text("在线成员").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(team.members.count) 人").font(.caption.monospacedDigit())
                        }
                        Button(role: .destructive) {
                            Task {
                                await team.leave()
                                LocationKit.shared.stopRecording()
                            }
                        } label: { Label("退出队伍", systemImage: "rectangle.portrait.and.arrow.right") }
                    }

                    // 成员实时列表（对应安卓 TeamActivity 成员条目）
                    if !team.members.isEmpty {
                        Section("队友位置") {
                            ForEach(team.members) { m in
                                HStack(spacing: 10) {
                                    // 首字彩色圆头像（自己绿、队友蓝；离线灰）
                                    ZStack {
                                        Circle()
                                            .fill(m.offline ? Color(.systemGray3)
                                                  : (m.pid == team.pid ? Color(red: 0.18, green: 0.62, blue: 0.27)
                                                     : Color(red: 0.24, green: 0.42, blue: 0.78)))
                                            .frame(width: 34, height: 34)
                                        Text(String((m.name.isEmpty ? "队" : m.name).prefix(1)))
                                            .font(.headline).foregroundStyle(.white)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(m.name.isEmpty ? "队员" : m.name).font(.subheadline.bold())
                                            if m.offline {
                                                Text("离线").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                                    .background(.gray.opacity(0.2), in: Capsule())
                                            } else if m.pid == team.pid {
                                                Text("我").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                                    .background(.green.opacity(0.2), in: Capsule())
                                            }
                                        }
                                        Text(memberSubtitle(m)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if m.hasCoord {
                                        Image(systemName: "location.fill")
                                            .font(.caption).foregroundStyle(m.offline ? .gray : .green)
                                    }
                                }
                            }
                        }
                    }

                    Section("实时对讲") {
                        TalkButton()
                        if player.playing, let from = player.voiceFrom {
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.orange)
                                Text("\(from) 的对讲播放中").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("队友在安卓端按住对讲，本机会像电话一样自动播放；对讲碎片不进聊天记录")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    // 队伍聊天入口（对应安卓 TeamChatActivity）
                    Section {
                        NavigationLink {
                            TeamChatScreen()
                        } label: {
                            Label("队伍聊天", systemImage: "bubble.left.and.bubble.right.fill")
                        }
                    } footer: {
                        Text("文字/图片消息 · 记录存本机 · 对讲分片不出现在聊天记录")
                    }
                } else {
                    Section("加入队伍") {
                        TextField("队伍码", text: $codeInput)
                            .font(.title3.monospaced())
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        TextField("我的昵称", text: $nameInput)
                        if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red) }
                        Button {
                            join()
                        } label: {
                            if busy { ProgressView().frame(maxWidth: .infinity) }
                            else { Text("加入").frame(maxWidth: .infinity).bold() }
                        }
                        .disabled(busy || codeInput.isEmpty || nameInput.isEmpty)
                    }
                    Text("和安卓端队友输入同一队伍码即可互见位置、实时对讲")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("队伍")
        }
    }

    private func join() {
        busy = true
        err = ""
        Task {
            do {
                try await team.join(code: codeInput, name: nameInput)
            } catch {
                err = error.localizedDescription
            }
            busy = false
        }
    }

    /// 成员副标题：坐标/海拔/多久前上报（对应安卓成员列表条目信息）
    private func memberSubtitle(_ m: TeamState.Member) -> String {
        var parts: [String] = []
        if let my = loc.lastLocation, m.hasCoord, m.pid != team.pid {
            let d = TrackMath.haversine(lat1: my.coordinate.latitude, lng1: my.coordinate.longitude,
                                        lat2: m.lat, lng2: m.lng)
            parts.append(String(format: "距我 %.0f 米", d))
        }
        if m.hasCoord {
            if m.alt != 0 { parts.append(String(format: "海拔 %.0f 米", m.alt)) }
        } else {
            parts.append("暂无定位")
        }
        let ago = Int64(Date().timeIntervalSince1970) - m.t
        if ago > 0 && ago < 86400 {
            parts.append(ago < 60 ? "刚刚上报" : "\(ago / 60) 分钟前上报")
        }
        return parts.joined(separator: " · ")
    }
}

/// 对讲按钮（对应安卓 TeamTalk.bind 的按钮交互）：点击开讲 → 再点结束
struct TalkButton: View {
    @StateObject private var talk = TalkStreamer.shared

    var body: some View {
        VStack(spacing: 12) {
            Button {
                if talk.talking { talk.release() } else { talk.press() }
            } label: {
                ZStack {
                    Circle()
                        .fill(talk.talking ? Color.red : Color.green)
                        .frame(width: 84, height: 84)
                        .shadow(color: (talk.talking ? Color.red : Color.green).opacity(0.4), radius: talk.amp > 100 ? 14 : 6)
                    Image(systemName: talk.talking ? "waveform" : "mic.fill")
                        .font(.system(size: 32)).foregroundStyle(.white)
                }
            }
            Text(talk.talking ? "说话中… 点击结束（已发 \(talk.segSent) 片）" : "点击开始对讲")
                .font(.caption).foregroundStyle(.secondary)
            if let hint = talk.lastHint, !hint.isEmpty {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
