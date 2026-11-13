import SwiftUI
import WebKit

/// [T-meoo] WebView sign-in sheet for Meoo (秒悟).
///
/// Meoo 没有面向第三方账号的模型聊天 OAuth；网页聊天用同源
/// `/api/v1/agent/*` + 会话 Cookie。此 sheet 用 WKWebView 打开 `meoo.com`，
/// 用户手动登录（手机验证码 / 阿里云 SSO），登录成功后点「完成登录」：
/// 1) 从 `WKWebsiteDataStore` 读取 meoo.com 的 Cookie 字符串；
/// 2) 注入 JS `fetch('/api/v1/agent/models')` 拉模型列表（同源自动带 Cookie）；
/// 3) 把 Cookie 存到 Keychain（`MeooTokenStorage`）供 `MeooProvider` 使用。
struct MeooLoginSheet: View {
    let instanceId: String
    var initialSite: MeooSite = .cn
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case loading
        case ready
        case success
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var webView: WKWebView?
    @State private var statusMessage = ""
    @State private var modelCount = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                switch phase {
                case .loading:
                    ProgressView()
                    Text(AppLocalized("正在打开 Meoo 登录页…"))
                        .foregroundStyle(.secondary)
                case .ready:
                    WebViewContainer(webView: $webView, statusMessage: $statusMessage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text(AppLocalized("已登录 Meoo\(modelCount > 0 ? " · \(modelCount) 个模型" : "")"))
                        .font(.headline)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                }
                if phase == .ready {
                    Button(AppLocalized("我已登录，完成")) {
                        finishLogin()
                    }
                    .buttonStyle(.borderedProminent)
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                }
            }
            .navigationTitle(AppLocalized("Meoo Login"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("取消")) { onFinish(false); dismiss() }
                }
            }
            .onAppear {
                if webView == nil { startLoad() }
            }
        }
    }

    private func startLoad() {
        phase = .loading
        statusMessage = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let wk = WKWebView(frame: .zero, configuration: config)
            webView = wk
            if let url = URL(string: initialSite.webBase) {
                wk.load(URLRequest(url: url))
            }
            phase = .ready
        }
    }

    /// 用户点「我已登录」：读 Cookie、注入 JS 拉模型、存 Keychain。
    private func finishLogin() {
        statusMessage = AppLocalized("读取会话…")
        guard let wk = webView else { phase = .failed("WebView 未就绪"); return }
        // 1) 拉模型列表（同源 fetch，自动带 Cookie）。
        wk.callAsyncJavaScript(
            """
            try {
              const r = await fetch('/api/v1/agent/models', { credentials: 'include' });
              if (!r.ok) return { ok:false, status:r.status };
              const j = await r.json();
              return { ok:true, models:(j.models||[]).map(m=>({ id:m.value||m.id, name:m.key||m.display_name||m.value||m.id })) };
            } catch(e) { return { ok:false, error:String(e) }; }
            """,
            arguments: [:],
            in: nil,
            in: .page
        ) { result in
            let value: Any?
            switch result {
            case .failure(let error):
                statusMessage = AppLocalized("拉取模型失败：\(error.localizedDescription)")
                phase = .failed("模型列表拉取失败：\(error.localizedDescription)")
                return
            case .success(let v):
                value = v
            }
            guard let obj = value as? [String: Any] else {
                statusMessage = AppLocalized("模型列表解析失败")
                phase = .failed("模型列表解析失败")
                return
            }
            let models = (obj["models"] as? [[String: Any]]) ?? []
            modelCount = models.count

            // 2) 读 Cookie（HTTP-only 也在 WKWebsiteDataStore 里）。
            wk.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let meoo = cookies.filter { $0.domain.contains("meoo") }
                    .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                guard !meoo.isEmpty else {
                    statusMessage = AppLocalized("未读取到登录 Cookie，请确认已在页面内登录")
                    phase = .failed("未读取到登录 Cookie，请确认已在页面内登录")
                    return
                }
                let storage = MeooTokenStorage(cookie: meoo, accountName: nil, site: initialSite.rawValue, lastRefresh: Date())
                ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
                phase = .success
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    onFinish(true)
                    dismiss()
                }
            }
        }
    }
}

/// 包装 WKWebView 到 SwiftUI。
private struct WebViewContainer: UIViewRepresentable {
    @Binding var webView: WKWebView?
    @Binding var statusMessage: String

    func makeUIView(context: Context) -> WKWebView {
        let wk = webView ?? WKWebView()
        if webView == nil { webView = wk }
        wk.navigationDelegate = context.coordinator
        return wk
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewContainer
        init(parent: WebViewContainer) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.statusMessage = AppLocalized("请在页面内登录（手机验证码或阿里云），登录后点「我已登录，完成」")
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.statusMessage = AppLocalized("页面加载失败：\(error.localizedDescription)")
        }
    }
}
