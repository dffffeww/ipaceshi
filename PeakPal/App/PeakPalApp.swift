import SwiftUI

@main
struct PeakPalApp: App {
    @StateObject private var session = Session.shared
    @StateObject private var team = TeamState.shared
    @StateObject private var loc = LocationKit.shared

    init() {
        // 崩溃捕获：未捕获异常/致命信号落盘（对应安卓 CrashGuard.install）
        CrashGuard.install()
        // 401 全局兜底：token 失效 → 清会话并回登录页（对应安卓 App.java）
        ApiClient.onUnauthorized = {
            DispatchQueue.main.async { Session.shared.logout() }
        }
        // 401 同步续登钩子（对应安卓 v7.55 ReloginHook）
        ApiClient.reloginHook = { Session.shared.relogin() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.loggedIn {
                    RootTabView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(session)
            .environmentObject(team)
            .environmentObject(loc)
            .tint(Color(red: 0.28, green: 0.62, blue: 0.36)) // 徒步绿（与安卓主色一致）
        }
    }
}

/// 主框架（新版布局，对齐安卓 MainActivity：5 槽位 + 中央凸起记录键）
/// 首页 | 地图 | 记录(中央) | 发现 | 我的；消息从首页铃铛进入（与安卓 tab_msg 无槽位一致）
struct RootTabView: View {
    @State private var sel = 0
    @State private var updateInfo: UpdateChecker.Info?
    @State private var showUpdate = false
    @State private var linkCopied = false

    var body: some View {
        tabContent
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TabBarView(sel: $sel)
            }
        .onAppear {
            // 上报上次崩溃日志（对应安卓 MainActivity 冷启动上报，网络不可用保留下次再试）
            CrashGuard.reportPending()
            // 启动后 3 秒检查 iOS 新版本（不阻塞首屏；本机构建号低于服务器即提示）
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let info = await UpdateChecker.fetchLatest(session: Session.shared),
                   UpdateChecker.newerAvailable(info) {
                    await MainActor.run { updateInfo = info; showUpdate = true }
                }
            }
        }
        .alert("发现新版本 \(updateInfo?.version ?? "")（build \(updateInfo?.code ?? 0)）",
               isPresented: $showUpdate, presenting: updateInfo) { info in
            Button("复制下载链接") {
                linkCopied = UpdateChecker.copyLink(info.url)
            }
            Button("打开下载页") { UpdateChecker.openDownload(info.url) }
            Button("以后再说", role: .cancel) {}
        } message: { info in
            Text("当前 build \(UpdateChecker.currentBuild)。iOS 无法静默更新：请把链接粘到电脑浏览器下载新 ipa，再用爱思助手重新签名安装。\n\n\(info.notes)")
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch sel {
        case 0: HomeScreen()
        case 1: Map3DScreen()
        case 2: RecordScreen()
        case 3: DiscoverScreen()
        default: MeScreen()
        }
    }
}

/// 自定义底部 TabBar：首页/地图/[记录中央键]/发现/我的（对应安卓底部导航布局）
struct TabBarView: View {
    @Binding var sel: Int
    @EnvironmentObject var loc: LocationKit

    private let green = Color(red: 0.28, green: 0.62, blue: 0.36)

    var body: some View {
        ZStack(alignment: .top) {
            // 中央凸起记录键（对应安卓 tab_record 中央大按钮）
            Button {
                sel = 2
            } label: {
                VStack(spacing: 2) {
                    ZStack {
                        Circle()
                            .fill(sel == 2 ? green : Color(red: 0.16, green: 0.42, blue: 0.24))
                            .frame(width: 52, height: 52)
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                        Image(systemName: "figure.hiking")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text("记录").font(.system(size: 10, weight: sel == 2 ? .semibold : .regular))
                        .foregroundStyle(sel == 2 ? green : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .offset(y: -16)
            .accessibilityLabel("开始记录轨迹")

            HStack {
                tabItem(0, "house.fill", "house", "首页")
                tabItem(1, "map.fill", "map", "地图")
                Spacer().frame(width: 64)
                tabItem(3, "safari.fill", "safari", "发现")
                tabItem(4, "person.crop.circle.fill", "person.crop.circle", "我的")
            }
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(height: 58)
            .background(
                Rectangle()
                    .fill(Color(.systemBackground))
                    .overlay(Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5), alignment: .top)
                    .ignoresSafeArea()
            )
        }
        .frame(height: 58)
    }

    @ViewBuilder
    private func tabItem(_ tag: Int, _ activeIcon: String, _ inactiveIcon: String, _ label: String) -> some View {
        Button {
            sel = tag
        } label: {
            VStack(spacing: 2) {
                Image(systemName: sel == tag ? activeIcon : inactiveIcon)
                    .font(.system(size: 19, weight: sel == tag ? .semibold : .regular))
                Text(label).font(.system(size: 10, weight: sel == tag ? .semibold : .regular))
            }
            .foregroundStyle(sel == tag ? green : Color.secondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}
