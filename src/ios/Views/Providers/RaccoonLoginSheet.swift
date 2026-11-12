import AuthenticationServices
import SwiftUI

/// Browser sign-in sheet for Raccoon.
///
/// The authorisation page only accepts its own `office-raccoon://auth/callback`
/// scheme (a loopback `redirect` renders "授权链接无效"), so the URL comes back
/// through a custom scheme rather than a local socket. That makes
/// `ASWebAuthenticationSession` the right host: it hands back any URL matching
/// the callback scheme without the page having to leave the app.
struct RaccoonLoginSheet: View {
    let instanceId: String
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case starting
        case awaitingUser
        case success
        case failed(String)
    }

    @State private var phase: Phase = .starting
    @State private var loginTask: Task<Void, Never>?
    @State private var session: ASWebAuthenticationSession?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch phase {
                case .starting:
                    ProgressView()
                    Text(AppLocalized("Contacting Raccoon…"))
                        .foregroundStyle(.secondary)
                case .awaitingUser:
                    Text(AppLocalized("1. Tap “Open sign-in page”\n2. Sign in to Raccoon and confirm the authorisation"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        start()
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
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text(AppLocalized("Signed in to Raccoon"))
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
            .navigationTitle(AppLocalized("Raccoon Login"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { finish(false) }
                }
            }
        }
        .interactiveDismissDisabled(phase == .starting)
        .onAppear { if phase == .starting { phase = .awaitingUser } }
    }

    /// Kicks off the sign-in. The manager builds the page URL, opens it through
    /// `ASWebAuthenticationSession`, and resolves when the scheme callback lands.
    private func start() {
        loginTask?.cancel()
        let task = Task { @MainActor in
            do {
                try await RaccoonOAuthManager.shared.login(instanceId: instanceId) { url in
                    Task { @MainActor in
                        presentSession(url)
                    }
                }
                if Task.isCancelled { return }
                phase = .success
                try? await Task.sleep(nanoseconds: 700_000_000)
                finish(true)
            } catch {
                if Task.isCancelled { return }
                phase = .failed(error.localizedDescription)
            }
        }
        loginTask = task
    }

    @MainActor
    private func presentSession(_ url: URL) {
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "office-raccoon"
        ) { callbackURL, error in
            Task { @MainActor in
                if let callbackURL {
                    // Hand it to the broker the manager is awaiting.
                    RaccoonCallbackBroker.shared.deliver(callbackURL)
                    return
                }
                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    RaccoonCallbackBroker.shared.cancel()
                } else if let error {
                    RaccoonCallbackBroker.shared.deliver(URL(string: "office-raccoon://auth/callback?error=\(error.localizedDescription.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "auth_failed")")!)
                }
            }
        }
        session.presentationContextProvider = AnchorProvider.shared
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        session.start()
    }

    private func finish(_ success: Bool) {
        loginTask?.cancel()
        session?.cancel()
        session = nil
        onFinish(success)
        dismiss()
    }
}

/// Supplies the window `ASWebAuthenticationSession` anchors its sheet to.
final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AnchorProvider()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow })
            ?? scenes.flatMap(\.windows).first(where: { $0.isKeyWindow })
        return window ?? ASPresentationAnchor()
    }
}
