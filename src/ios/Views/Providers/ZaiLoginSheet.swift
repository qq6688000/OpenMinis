import SwiftUI
import SafariServices

/// Browser device-code sign-in sheet for Z.ai (GLM Coding Plan).
///
/// Z.ai uses a CLI-style `cli/init` → browser/QR authorize → `cli/poll` flow
/// (`KWWKAuth.ZaiOAuth`). The manager issues a `flowId` + authorize page URL,
/// this sheet opens that page (the user signs in / scans QR and confirms), and
/// `ZaiOAuthManager` polls `cli/poll/{flowId}` in the background until the
/// access token arrives. No local loopback server is needed — the token comes
/// back through the poll response, exactly like Kimi's device-code flow.
///
/// Usage:
///   .sheet(isPresented: $showZaiLogin) {
///       ZaiLoginSheet(instanceId: instance.id, initialSite: .china) { success in ... }
///   }
@available(iOS 16.0, *)
struct ZaiLoginSheet: View {
    let instanceId: String
    var initialSite: ZaiSite = .china
    /// Called on dismiss with whether authentication succeeded.
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case starting
        case awaitingUser(url: String)
        case success
        case failed(String)
    }

    @State private var phase: Phase = .starting
    @State private var loginTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch phase {
                case .starting:
                    ProgressView()
                    Text(AppLocalized("Contacting Z.ai…"))
                        .foregroundStyle(.secondary)

                case let .awaitingUser(url):
                    awaitingBody(url: url)

                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text(AppLocalized("Signed in to Z.ai"))
                        .font(.headline)

                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    Button(AppLocalized("Try Again")) { start() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .navigationTitle(AppLocalized("Z.ai Login"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { finish(false) }
                }
            }
        }
        .interactiveDismissDisabled(phase == .starting)
        .onAppear { start() }
        .onDisappear { }
    }

    @ViewBuilder
    private func awaitingBody(url: String) -> some View {
        Text(AppLocalized("1. Tap “Open sign-in page”\n2. Sign in to Z.ai and authorize Minis"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

        Button {
            if let u = URL(string: url) { presentSafari(u) }
        } label: {
            Label(AppLocalized("Open sign-in page"), systemImage: "safari")
        }
        .buttonStyle(.borderedProminent)

        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(AppLocalized("Waiting for sign-in…"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func start() {
        loginTask?.cancel()
        phase = .starting
        let site = initialSite
        loginTask = Task { @MainActor in
            do {
                try await ZaiOAuthManager.shared.login(instanceId: instanceId, site: site) { presentation in
                    Task { @MainActor in
                        phase = .awaitingUser(url: presentation.authURL.absoluteString)
                    }
                }
                if Task.isCancelled { return }
                phase = .success
                try? await Task.sleep(nanoseconds: 700_000_000)
                finish(true)
            } catch is CancellationError {
                // user cancelled — no error surface
            } catch {
                if Task.isCancelled { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func finish(_ success: Bool) {
        loginTask?.cancel()
        dismissPresentedSafari()
        onFinish(success)
        dismiss()
    }

    /// Dismiss the `SFSafariViewController` this sheet presented, if present.
    private func dismissPresentedSafari() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }
        var topVC = root
        while let presented = topVC.presentedViewController { topVC = presented }
        if topVC is SFSafariViewController {
            topVC.dismiss(animated: true)
        }
    }

    /// Open the authorize page in an in-app SFSafariViewController, stacking
    /// over this sheet (same pattern as Kimi/Claude/Codex/Gemini).
    private func presentSafari(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController { topVC = presented }
        topVC.present(SFSafariViewController(url: url), animated: true)
    }
}
