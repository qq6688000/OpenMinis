import SwiftUI
import AuthenticationServices

/// In-app Trae OAuth sign-in.
///
/// Uses `ASWebAuthenticationSession` (the system authentication browser) so the
/// Trae sign-in page runs in a real browser session with a clean network
/// environment — `WKWebView` embedded in the app surfaced a "network error"
/// from the page's own scripts. The callback is a custom scheme
/// (`traecb://authorize`) that the session intercepts without touching the
/// local network stack.
struct TraeLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .starting
    @State private var errorMessage: String?
    @State private var session: ASWebAuthenticationSession?

    let instanceId: String
    let initialSite: TraeLoginProfile.Profile
    let onDone: (Bool) -> Void

    enum Phase: Equatable {
        case starting
        case exchanging
        case done
        case failed
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                switch phase {
                case .starting:
                    ProgressView()
                    Text(AppLocalized("正在打开 Trae 登录页…"))
                        .foregroundStyle(.secondary)
                case .exchanging:
                    ProgressView()
                    Text(AppLocalized("正在验证身份…"))
                        .foregroundStyle(.secondary)
                case .done:
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.green)
                        Text(AppLocalized("Signed in to Trae"))
                            .font(.headline)
                    }
                case .failed:
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.red)
                        if let msg = errorMessage {
                            ScrollView {
                                Text(msg)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                            .frame(maxHeight: 160)
                        }
                    }
                }
            }
            .navigationTitle(AppLocalized("Trae Login"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("取消")) { dismiss() }
                }
            }
            .interactiveDismissDisabled(phase == .starting || phase == .exchanging)
        }
        .task { await start() }
    }

    @MainActor
    private func start() async {
        do {
            let ctx = try await TraeOAuthClient.buildAuthURL(profile: TraeLoginProfile.of(initialSite))
            let s = ASWebAuthenticationSession(
                url: ctx.authURL,
                callbackURLScheme: "traecb"
            ) { [self] callbackURL, error in
                if let error {
                    Task { @MainActor in
                        if case ASWebAuthenticationSessionError.canceledLogin = error as NSError {
                            dismiss()
                        } else {
                            phase = .failed
                            errorMessage = AppLocalized("登录被取消或失败：") + error.localizedDescription
                        }
                    }
                    return
                }
                guard let url = callbackURL else { return }
                Task { @MainActor in await handle(url, context: ctx) }
            }
            s.presentationContextProvider = PresentationAnchor()
            s.prefersEphemeralWebBrowserSession = false
            s.start()
            session = s
        } catch {
            phase = .failed
            errorMessage = AppLocalized("打开登录页失败：") + error.localizedDescription
        }
    }

    @MainActor
    private func handle(_ url: URL, context: TraeOAuthClient.AuthContext) async {
        phase = .exchanging
        do {
            let result = try await TraeOAuthClient.processCallback(url: url, context: context)
            let storage = TraeTokenStorage(
                accessToken: result.access,
                refreshToken: result.refresh,
                expireDate: result.expireAt,
                userID: result.userID,
                machineID: result.machineID,
                deviceID: result.deviceID,
                oauthHost: result.origin,
                accountName: result.userID,
                site: TraeLoginProfile.of(initialSite).site.rawValue,
                lastRefresh: Date()
            )
            ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
            phase = .done
            onDone(true)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            dismiss()
        } catch {
            phase = .failed
            errorMessage = AppLocalized("登录失败：") + error.localizedDescription
        }
    }

    private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            let scenes = UIApplication.shared.connectedScenes
            let window = (scenes.first(where: { $0.activationState == .foregroundActive })
                as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })
            return window ?? ASPresentationAnchor()
        }
    }
}
