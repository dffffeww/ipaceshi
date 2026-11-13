import SwiftUI

/// 我的页（对应安卓 MeFragment 精简版）：账号信息、3D 地图设置、退出登录。
/// 服务器固定为云端生产服务器（与安卓同一套后端），页面上不显示地址
struct MeScreen: View {
    @EnvironmentObject var session: Session

    var body: some View {
        NavigationStack {
            List {
                Section("账号") {
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 44)).foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text(session.name.isEmpty ? session.uid : session.name).font(.headline)
                            Text("UID: \(session.uid)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("3D 地图") {
                    HStack {
                        Text("地形夸张").foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1fx", Map3DStyle.exag()))
                    }
                    Text("影像源：\(Map3DStyle.tdtReady ? "天地图影像" : "Esri World Imagery")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(role: .destructive) {
                        session.logout()
                    } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                }
            }
            .navigationTitle("我的")
        }
    }
}
