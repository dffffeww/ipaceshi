import SwiftUI
import AVFoundation

/// 我的页扩展三件套（对应安卓 MeFragment 菜单项）：
/// - MediaGalleryScreen：视频与照片（徒步作品）= 我的帖子里的图片媒体墙
/// - OfflineMapScreen：离线地图说明页
/// - SoundSettingsScreen：声音设置（播报音色/语速，对应安卓 TtsKit 设置）

// MARK: - 视频与照片（我的帖子媒体墙）

struct MediaGalleryScreen: View {
    @State private var items: [(pid: Int64, title: String, src: String)] = []
    @State private var busy = true
    @State private var viewer: ViewerIndex?

    struct ViewerIndex: Identifiable {
        let list: [String]
        let start: Int
        var id: Int { start }
    }

    private let cols = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        Group {
            if busy {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有徒步作品").font(.subheadline).foregroundStyle(.secondary)
                    Text("发帖时添加图片，作品会自动收录到这里").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                            Button { viewer = ViewerIndex(list: items.map(\.src), start: i) } label: {
                                RemoteImg(src: it.src)
                                    .frame(height: 110)
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                }
            }
        }
        .navigationTitle("视频与照片")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewer) { v in
            ImageViewer(images: v.list, index: v.start)
        }
        .task { await load() }
    }

    /// 拉我的帖子 → 收集全部图片（对应安卓「视频与照片」入口）
    private func load() async {
        busy = true
        defer { busy = false }
        do {
            let posts = try await CommunityClient.shared.listMine()
            var out: [(Int64, String, String)] = []
            for p in posts where !p.images.isEmpty {
                for img in p.images {
                    out.append((p.id, p.title, img))
                }
            }
            await MainActor.run { items = out }
        } catch { }
    }
}

// MARK: - 离线地图说明页

struct OfflineMapScreen: View {
    var body: some View {
        List {
            Section("离线地图说明") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("iOS 版地图采用 MapLibre 引擎 + 在线瓦片直连（与安卓 osmdroid 同源）：")
                        .font(.subheadline)
                    Label("卫星影像（Esri / 天地图）", systemImage: "globe.asia.australia.fill")
                    Label("高德标准图 / 高德卫星+路网", systemImage: "car.fill")
                    Label("OpenStreetMap", systemImage: "mappin.and.ellipse")
                    Label("AWS 地形高程（山体阴影 + 3D 地形）", systemImage: "mountain.2.fill")
                    .padding(.bottom, 4)
                }
                .font(.footnote)
            }
            Section("省流建议") {
                Text("• 高德系瓦片为 GCJ-02 直连国内 CDN，信号覆盖好、加载快，日常徒步流量占用极小（每屏约 100-300KB）。\n• 野外建议提前在有信号的路段滑动地图预加载区域，MapLibre 会缓存已浏览的瓦片。\n• 地形 DEM 瓦片按需加载，山顶视角下的 3D 地形在首次进入后会缓存。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("整包离线瓦片") {
                Text("完整离线瓦片包（按区域打包）体积大、需要后台批量下载，iOS 版会在后续版本提供；当前版本已内置瓦片浏览缓存 + 轨迹点抽稀，弱网下轨迹导航不受影响。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("离线地图")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 声音设置（播报音色/语速，对应安卓 TtsKit 设置）

struct SoundSettingsScreen: View {
    @State private var enabled = TtsPrefs.enabled()
    @State private var voiceId = TtsPrefs.voiceId()
    @State private var rate = TtsPrefs.rate()
    @State private var voices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        Form {
            Section("语音播报") {
                Toggle("开启语音播报", isOn: $enabled)
                    .onChange(of: enabled) { on in
                        TtsPrefs.setEnabled(on)
                    }
                Text("记录每公里 / 循迹导航播报共用此开关")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("播报音色") {
                Picker("音色", selection: $voiceId) {
                    Text("系统默认（普通话）").tag("")
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name)（\(v.language)）").tag(v.identifier)
                    }
                }
                .onChange(of: voiceId) { id in
                    TtsPrefs.setVoiceId(id)
                }
                Text("列出设备可用的中文语音（跟随系统设置里下载的语音包）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("语速") {
                VStack(alignment: .leading) {
                    Slider(value: $rate, in: 0.1...0.7, step: 0.05) {
                        Text("语速")
                    }
                    .onChange(of: rate) { r in
                        TtsPrefs.setRate(r)
                    }
                    HStack {
                        Text("慢").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f", rate)).font(.caption.monospacedDigit())
                        Spacer()
                        Text("快").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button {
                    TtsKit.speak("语音设置已保存，已走一公里，累计爬升一百二十米，加油！")
                } label: {
                    Label("试听播报", systemImage: "play.circle")
                }
            }
        }
        .navigationTitle("声音设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { voices = TtsPrefs.voices() }
    }
}
