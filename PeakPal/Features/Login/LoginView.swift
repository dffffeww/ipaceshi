import SwiftUI

/// 登录页（对应安卓 AuthActivity 精简版）：
/// 服务器固定为云端生产服务器（与安卓同一套后端数据，页面上不显示地址）；
/// 记住账号密码（Keychain），token 失效自动续登
struct LoginView: View {
    @EnvironmentObject var session: Session

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
                Section("账号") {
                    TextField("用户名（2-20位中文/字母/数字）", text: $uid)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $pwd)
                }
                Section {
                    Button {
                        submit()
                    } label: {
                        if busy { ProgressView().frame(maxWidth: .infinity) }
                        else { Text(mode == .login ? "登录" : "注册并登录").frame(maxWidth: .infinity).bold() }
                    }
                    .disabled(busy || uid.isEmpty || pwd.isEmpty)
                }
                if !err.isEmpty {
                    Section { Text(err).foregroundStyle(.red).font(.footnote) }
                }
            }
            .frame(maxHeight: 300)
            .scrollContentBackground(.hidden)
        }
    }

    private func submit() {
        let name = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { err = "请输入用户名"; return }
        // 与服务器端一致：2-20位字母/数字/汉字/下划线/中划线
        if name.range(of: "^[\\p{L}\\p{N}_-]{2,20}$", options: .regularExpression) == nil {
            err = "用户名须为2-20位字母、数字、汉字、下划线或中划线"
            return
        }
        if mode == .register && pwd.count < 8 {
            err = "注册密码至少8字符"
            return
        }
        busy = true
        err = ""
        Task {
            do {
                // 字段名与安卓端完全一致：username / password（同一套后端）
                let body: [String: Any] = ["username": name, "password": pwd]
                if mode == .register {
                    _ = try await session.api.request("POST", "register", body: body)
                }
                let res = try await session.api.request("POST", "login", body: body)
                session.savePassword(pwd)
                session.saveLogin(res, server: session.server)
            } catch {
                err = error.localizedDescription
            }
            busy = false
        }
    }
}
