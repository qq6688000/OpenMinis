import SafariServices
import SwiftUI

/// Browser sign-in sheet for Trae (both builds). Mirrors WorkBuddyLoginSheet:
/// opens the authorization URL in Safari, waits for the PKCE loopback
/// callback, then lets TraeOAuthManager store the token.
struct TraeLoginSheet: View {
    let instanceId: String
    var initialSite: TraeSite = .china
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case starting
        case awaitingUser
        case success
        case failed(String)
    }

    @State private var phase: Phase = .starting
    @State private var site: TraeSite = .china
    @State private var loginTask: Task<Void, Never>?
    @State private var currentAuthURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch phase {
                case .starting:
                    ProgressView()
                    Text(AppLocalized("Contacting Trae…"))
                        .foregroundStyle(.secondary)
                case .awaitingUser:
                    awaitingBody
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text(AppLocalized("Signed in to \(site.displayName)"))
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
            .navigationTitle(AppLocalized("Trae Login"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { finish(false) }
                }
            }
        }
        .interactiveDismissDisabled(phase == .starting)
        .onAppear { site = initialSite; start() }
        .onDisappear { }
    }

    @ViewBuilder
    private var awaitingBody: some View {
        Text(AppLocalized("1. Tap “Open sign-in page”\n2. Sign in to \(site.displayName) in the browser"))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        Button {
            if let url = currentAuthURL { presentSafari(url) }
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
        currentAuthURL = nil
        loginTask = Task { @MainActor in
            do {
                try await TraeOAuthManager.shared.login(instanceId: instanceId, site: site) { presentation in
                    Task { @MainActor in
                        currentAuthURL = presentation.authURL
                        phase = .awaitingUser
                        presentSafari(presentation.authURL)
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
    }

    private func presentSafari(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController { topVC = presented }
        topVC.present(SFSafariViewController(url: url), animated: true)
    }

    private func finish(_ success: Bool) {
        loginTask?.cancel()
        dismissPresentedSafari()
        onFinish(success)
        dismiss()
    }

    private func dismissPresentedSafari() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var topVC = root
        while let presented = topVC.presentedViewController { topVC = presented }
        if topVC is SFSafariViewController { topVC.dismiss(animated: true) }
    }
}
