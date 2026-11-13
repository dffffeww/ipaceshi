import SwiftUI

/// 记录页（对应安卓 RecordFragment，中央凸起记录键进入）：
/// - 未记录：轨迹名输入 + 大按钮开始（对应安卓 onToggle）
/// - 记录中：大字里程 + 用时/爬升/均速 + 暂停/继续/结束 + GPS 状态
/// - 暂停口径与安卓 TrackService 一致：休息时间不计用时、不采点
/// - 结束自动入库（不弹表单，与安卓一致），可在「发现-轨迹库」上传云端
struct RecordScreen: View {
    @EnvironmentObject var loc: LocationKit
    @State private var name = ""
    @State private var askStop = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loc.recording {
                    recordingBody
                } else {
                    idleBody
                }
            }
            .navigationTitle("记录")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 未记录：开始页

    private var idleBody: some View {
        VStack(spacing: 24) {
            Spacer()
            gpsStatus
            TextField("轨迹名（默认按时间命名）", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 40)
            Button {
                loc.startRecording(name: name)
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "figure.hiking")
                        .font(.system(size: 44, weight: .medium))
                    Text("开始记录").font(.headline)
                }
                .foregroundStyle(.white)
                .frame(width: 160, height: 160)
                .background(Color(red: 0.28, green: 0.62, blue: 0.36), in: Circle())
            }
            Text("记录中可随时暂停/继续，结束后自动保存到轨迹库")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - 记录中

    private var recordingBody: some View {
        VStack(spacing: 0) {
            gpsStatus.padding(.top, 8)

            VStack(spacing: 4) {
                Text("当前里程")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(loc.paused ? "--" : TrackMath.fmtDistance(loc.liveDistance))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if loc.paused {
                    Text("已暂停 · 休息时间不计入用时")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 24)

            HStack(spacing: 10) {
                metricCard("用时", TrackMath.fmtDuration(loc.elapsedMs()))
                metricCard("爬升", String(format: "%.0f m", loc.liveAscent))
                metricCard("均速", loc.paused ? "--" : TrackMath.fmtSpeed(loc.liveDistance, loc.elapsedMs()))
            }
            .padding(.horizontal, 20)

            HStack(spacing: 10) {
                metricCard("点数", "\(loc.livePts.count)")
                metricCard("海拔", loc.lastLocation.map { String(format: "%.0f m", $0.altitude) } ?? "--")
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            Spacer()

            HStack(spacing: 14) {
                Button {
                    if loc.paused { loc.resumeRecording() } else { loc.pauseRecording() }
                } label: {
                    Label(loc.paused ? "继续" : "暂停", systemImage: loc.paused ? "play.fill" : "pause.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(loc.paused ? Color.orange : Color.orange.opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                Button {
                    askStop = true
                } label: {
                    Label("结束", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 20)

            Text("已上传位置给队友 · 队友可在地图看到你的实时轨迹")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.vertical, 10)
        }
        .confirmationDialog("结束并保存这条轨迹？", isPresented: $askStop, titleVisibility: .visible) {
            Button("保存并结束") {
                _ = loc.stopRecording()
                saved = true
            }
            Button("丢弃不保存", role: .destructive) { loc.discardRecording() }
            Button("取消", role: .cancel) {}
        }
        .alert("已保存", isPresented: $saved) {
            Button("好") {}
        } message: {
            Text("轨迹已保存到「发现 - 轨迹库」，可在轨迹详情里上传云端/发帖分享")
        }
    }

    private var gpsStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(loc.authorized && loc.lastLocation != nil ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            if let loc0 = loc.lastLocation {
                Text(String(format: "GPS 信号良好 · 精度 %.0f 米", loc0.horizontalAccuracy))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("正在搜索 GPS 信号…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metricCard(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
