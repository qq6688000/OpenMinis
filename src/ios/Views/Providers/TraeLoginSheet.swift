import SwiftUI
import WebKit

/// In-app browser sign-in sheet for Trae (both builds). Uses a WKWebView
/// instead of SFSafariViewController + loopback listener: the WebView shows
/// the authorization page inside the app, and its navigation delegate
/// intercepts the loopback callback URL before any real request is made.
struct TraeLoginSheet: View {
    let instanceId: String
    var initialSite: TraeSite = .china
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case starting
        case awaitingUser
        case exchanging
        case success
        case failed(String)
    }

    @State private var phase: Phase = .starting
    @State private var authContext: TraeOAuthClient.AuthContext?
    @State private var loginTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch phase {
                case .starting:
                    Spacer()
                    ProgressView()
                    Text(AppLocalized("Contacting Trae…"))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                case .awaitingUser:
                    if let ctx = authContext {
                        TraeWebView(url: ctx.authURL) { callbackURL in
                            handleCallback(callbackURL)
                        }
                    }
                case .exchanging:
                    Spacer()
                    ProgressView()
                    Text(AppLocalized("Completing sign-in…"))
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Spacer()
                case .success:
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text(AppLocalized("Signed in to \(initialSite.displayName)"))
                        .font(.headline)
                        .padding(.top, 8)
                    Spacer()
                case let .failed(message):
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    Button(AppLocalized("Try Again")) { start() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 12)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(AppLocalized("Trae Login"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { finish(false) }
                }
            }
        }
        .interactiveDismissDisabled(phase == .starting || phase == .exchanging)
        .onAppear { start() }
    }

    private func start() {
        loginTask?.cancel()
        phase = .starting
        authContext = nil
        loginTask = Task { @MainActor in
            do {
                let ctx = try await TraeOAuthClient.buildAuthURL(profile: TraeLoginProfile.of(initialSite))
                if Task.isCancelled { return }
                authContext = ctx
                phase = .awaitingUser
            } catch {
                if Task.isCancelled { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func handleCallback(_ url: URL) {
        guard let ctx = authContext else { return }
        loginTask?.cancel()
        phase = .exchanging
        loginTask = Task { @MainActor in
            do {
                let result = try await TraeOAuthClient.processCallback(url: url, context: ctx)
                if Task.isCancelled { return }
                let storage = TraeTokenStorage(
                    accessToken: result.access,
                    refreshToken: result.refresh,
                    expireDate: result.expireAt,
                    userID: result.userID,
                    machineID: result.machineID,
                    deviceID: result.deviceID,
                    oauthHost: result.origin,
                    accountName: result.userID.isEmpty ? "Trae" : result.userID,
                    site: initialSite.rawValue,
                    lastRefresh: Date()
                )
                ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
                phase = .success
                try? await Task.sleep(nanoseconds: 700_000_000)
                finish(true)
            } catch {
                if Task.isCancelled { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func finish(_ success: Bool) {
        loginTask?.cancel()
        onFinish(success)
        dismiss()
    }
}

/// WKWebView wrapper that intercepts the `traecb://` callback URL via a
/// WKURLSchemeHandler. Custom schemes never touch the network stack, so iOS
/// cannot route them away from decidePolicyFor — the callback is always caught.
struct TraeWebView: UIViewRepresentable {
    let url: URL
    let onCallback: (URL) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator, forURLScheme: "traecb")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCallback: onCallback)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKURLSchemeHandler {
        let onCallback: (URL) -> Void
        private var handled = false

        init(onCallback: @escaping (URL) -> Void) {
            self.onCallback = onCallback
        }

        private func isCallback(_ url: URL) -> Bool {
            guard url.scheme == "traecb" else { return false }
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return true }
            return items.contains { ["authCodeInfo", "code", "refreshToken", "error"].contains($0.name) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, !handled, isCallback(url) {
                handled = true
                onCallback(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: - WKURLSchemeHandler

        func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            guard !handled else { urlSchemeTask.didFailWithError(NSError(domain: "traecb", code: -1)) ; return }
            handled = true
            onCallback(urlSchemeTask.request.url ?? urlSchemeTask.request.url!)
            let response = URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html", expectedContentLength: 0, textEncodingName: nil)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
    }
}
