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

/// 主框架：地图 / 轨迹 / 队伍 / 社区 / 我的（对应安卓底部导航）
struct RootTabView: View {
    var body: some View {
        TabView {
            Map3DScreen()
                .tabItem { Label("地图", systemImage: "map.fill") }
            TracksScreen()
                .tabItem { Label("轨迹", systemImage: "figure.hiking") }
            TeamScreen()
                .tabItem { Label("队伍", systemImage: "person.3.fill") }
            CommunityScreen()
                .tabItem { Label("社区", systemImage: "message.circle.fill") }
            MeScreen()
                .tabItem { Label("我的", systemImage: "person.crop.circle.fill") }
        }
        .onAppear {
            // 上报上次崩溃日志（对应安卓 MainActivity 冷启动上报，网络不可用保留下次再试）
            CrashGuard.reportPending()
        }
    }
}
