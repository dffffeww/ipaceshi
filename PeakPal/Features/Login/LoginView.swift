import SwiftUI

/// 登录页（对应安卓 AuthActivity 精简版）：
/// 首次使用填服务器地址；此后记住服务器 + 账号密码（Keychain）
struct LoginView: View {
    @EnvironmentObject var session: Session

    @State private var server = ""
    @State private var uid = ""
    @State private var pwd = ""
    @State private var mode: Mode = .login
    @State private var busy = false
    @State private var err = ""

    enum Mode: String, CaseIterable { case login = "登录", register = "注册" }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "mountain.2.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("爱徒步").font(.largeTitle.bold())
            Text("PeakPal · iOS").foregroundStyle(.secondary)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 28)

            Form {
                Section("服务器") {
                    TextField("https://你的服务器地址", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("账号") {
                    TextField("用户名", text: $uid).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $pwd)
                }
                Section {
                    Button {
                        submit()
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Text(mode == .login ? "登录" : "注册并登录").frame(maxWidth: .infinity).bold() }
                    }
                    .disabled(busy || server.isEmpty || uid.isEmpty || pwd.isEmpty)
                }
                if !err.isEmpty {
                    Section { Text(err).foregroundStyle(.red).font(.footnote) }
                }
            }
            .frame(maxHeight: 340)
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            server = session.server
        }
    }

    private func submit() {
        busy = true
        err = ""
        Task {
            do {
                // 换服务器（校验地址合法性）
                if !session.reconnect(server) {
                    err = "请输入有效的HTTP(S)服务地址"
                    busy = false
                    return
                }
                let body: [String: Any] = ["uid": uid, "pwd": pwd]
                if mode == .register {
                    _ = try await session.api.request("POST", "register", body: body)
                }
                let res = try await session.api.request("POST", "login", body: body)
                session.savePassword(pwd)
                session.saveLogin(res, server: server)
            } catch {
                err = error.localizedDescription
            }
            busy = false
        }
    }
}
