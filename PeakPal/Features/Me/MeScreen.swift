import SwiftUI

/// 我的页（对应安卓 MeFragment 精简版）：账号信息、服务器设置、退出登录
struct MeScreen: View {
    @EnvironmentObject var session: Session
    @State private var serverInput = ""
    @State private var err = ""

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
                Section("服务器") {
                    TextField("服务器地址", text: $serverInput)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("重新连接") {
                        err = session.reconnect(serverInput) ? "" : "请输入有效的HTTP(S)服务地址"
                    }
                    if !err.isEmpty { Text(err).font(.footnote).foregroundStyle(.red) }
                    Text(session.server).font(.caption).foregroundStyle(.secondary)
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
            .onAppear { serverInput = session.server }
        }
    }
}
