import SwiftUI
import WeGitCore

struct AuthenticationView: View {
    @Environment(\.themeColors) private var colors
    @Bindable var controller: AuthenticationController
    var body: some View {
        if let request = controller.request {
            AuthenticationPromptView(request: request, answer: controller.answer).id(request.id)
        }
    }
}

private struct AuthenticationPromptView: View {
    @Environment(\.themeColors) private var colors
    let request: AuthenticationRequest
    let answer: (String?) -> Void
    @State private var value = ""
    @State private var verifiedHost = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(
                title: request.kind == .hostConfirmation ? L10n.text("核对 SSH 主机身份") : L10n.text("Git 需要认证"),
                symbol: "lock.shield")
            Text(L10n.text("操作：Git \(request.command)")).font(.callout)
            if let repository = request.repository {
                Text(repository.path).font(.caption).foregroundStyle(colors.secondaryText).lineLimit(2)
                    .textSelection(.enabled)
            }
            ScrollView {
                Text(request.prompt).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            if request.kind == .hostConfirmation {
                Text(L10n.text("请通过可信渠道核对上面的主机名和指纹。确认后，SSH 会按现有配置记录主机密钥。"))
                    .font(.callout)
                Toggle(L10n.text("我已核对主机指纹"), isOn: $verifiedHost).toggleStyle(.checkbox)
                    .accessibilityIdentifier("auth-verify-host")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.kind == .username ? L10n.text("用户名") : L10n.text("密码、Token 或密钥口令")).font(
                        .callout)
                    if request.kind == .username {
                        TextField(L10n.text("用户名"), text: $value).textFieldStyle(.roundedBorder)
                            .focused($inputFocused).accessibilityIdentifier("auth-username")
                    } else {
                        SecureField(L10n.text("密码、Token 或密钥口令"), text: $value).textFieldStyle(.roundedBorder)
                            .focused($inputFocused).accessibilityIdentifier("auth-secret")
                    }
                }
                Text(L10n.text("WeGit 只为本次操作传递输入。Git 凭证辅助程序仍按你的现有配置处理保存。"))
                    .font(.caption).foregroundStyle(colors.secondaryText)
            }
            HStack {
                Text(L10n.text("等待超过 2 分钟会自动取消")).font(.caption).foregroundStyle(colors.secondaryText)
                Spacer()
                Button(L10n.text("取消认证")) {
                    value = ""
                    answer(nil)
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("auth-cancel")
                if request.kind == .hostConfirmation {
                    Button(L10n.text("信任这个主机")) { answer("yes") }.disabled(!verifiedHost)
                        .accessibilityIdentifier("auth-trust-host")
                } else {
                    Button(L10n.text("继续")) {
                        let response = value
                        value = ""
                        answer(response)
                    }.workbenchPrimaryAction().tint(colors.primaryAction).keyboardShortcut(
                        .defaultAction
                    )
                    .disabled(value.isEmpty || value.contains("\n") || value.contains("\r"))
                    .accessibilityIdentifier("auth-submit")
                }
            }
        }.padding(24).frame(width: 520, height: 400).task { inputFocused = true }
    }
}
