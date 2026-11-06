import SwiftUI
import WeGitCore

struct SignatureRequest: Identifiable {
    let id = UUID()
    let session: RepositorySession
    let objectID: String
    let object: GitSignatureObject
    let title: String
}

struct SignatureSheet: View {
    @Environment(\.themeColors) private var colors
    @Environment(\.dismiss) private var dismiss
    let app: AppState
    let request: SignatureRequest
    @State private var report: GitSignatureReport?
    @State private var error: String?
    @State private var loading = true
    @State private var retry = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: L10n.text("验证签名"), symbol: "checkmark.seal")
            Text(request.title).font(.headline).lineLimit(3).textSelection(.enabled)
            Text(request.objectID).font(.caption.monospaced()).foregroundStyle(colors.secondaryText)
                .textSelection(.enabled).accessibilityIdentifier("signature-object")
            if loading { ProgressView(L10n.text("验证签名…")) }
            if let report {
                Label(report.state.title, systemImage: symbol(report.state))
                    .font(.title3.weight(.semibold)).foregroundStyle(tone(report.state))
                    .accessibilityElement(children: .ignore).accessibilityLabel(report.state.title)
                    .accessibilityIdentifier("signature-state")
                if let signer = report.signer { Text(signer).textSelection(.enabled) }
                if let fingerprint = report.fingerprint {
                    Text(fingerprint).font(.callout.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("signature-fingerprint")
                }
                if let format = report.format {
                    Text(format).font(.caption).foregroundStyle(colors.secondaryText)
                }
                if !report.details.isEmpty {
                    DisclosureGroup(L10n.text("验证详情")) {
                        ScrollView {
                            Text(report.details).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 230).padding(.top, 8)
                    }.accessibilityIdentifier("signature-details")
                }
            }
            if let error { Text(error).foregroundStyle(colors.negative).textSelection(.enabled) }
            HStack {
                if error != nil { Button(L10n.text("重试")) { retry = UUID() }.disabled(loading) }
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("signature-close")
            }.workbenchControlFamily()
        }.accessibilityElement(children: .contain).padding(24).frame(width: 570).task(id: retry) {
            await verify()
        }
        .onChange(of: app.session?.id) { _, _ in
            if app.session !== request.session { dismiss() }
        }
    }

    private func verify() async {
        loading = true
        error = nil
        report = nil
        do {
            let value = try await request.session.service.verifySignature(
                request.objectID, object: request.object)
            guard !Task.isCancelled, app.session === request.session else { return }
            report = value
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func symbol(_ state: GitSignatureState) -> String {
        switch state {
        case .verified: "checkmark.seal.fill"
        case .unsigned: "seal"
        case .untrusted: "exclamationmark.shield"
        case .invalid: "xmark.seal"
        case .missingPublicKey, .unverifiable: "questionmark.key.filled"
        }
    }
    private func tone(_ state: GitSignatureState) -> Color {
        switch state {
        case .verified: colors.positive
        case .invalid: colors.negative
        case .untrusted, .missingPublicKey, .unverifiable: colors.modified
        case .unsigned: colors.secondaryText
        }
    }
}
