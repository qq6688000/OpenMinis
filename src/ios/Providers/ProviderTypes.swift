import Foundation
import Security

// MARK: - Provider Type

/// The LLM provider backend.
enum ProviderType: String, Codable, CaseIterable, Hashable, Sendable {
    case openAI
    case anthropic
    case gemini
    case antigravity
    case openRouter
    /// OpenAI Responses API — uses the /v1/responses endpoint format.
    /// Works with OpenAI directly or any Responses-API-compatible service.
    case openAIResponses
    /// xAI Grok (SuperGrok / X Premium+ OAuth). OpenAI-compatible API,
    /// flows through OpenAIProvider with custom base URL + OAuth bearer.
    case xAI
    /// Kimi Code / Coding Plan (Moonshot). RFC 8628 device-code OAuth,
    /// OpenAI-compatible coding upstream — flows through OpenAIProvider with
    /// custom base URL + OAuth bearer, like xAI.
    case kimiCode
    /// [T-copilot-provider] GitHub Copilot via an UNOFFICIAL reverse-engineered
    /// integration: RFC 8628 device-code sign-in to GitHub, then a short-lived
    /// Copilot session token. The chat surface is OpenAI-compatible, so it
    /// flows through OpenAIProvider like xAI/Kimi. Opt-in, warned about in the
    /// sign-in UI, and hideable via CopilotConstants.isEnabled.
    case githubCopilot
    /// WorkBuddy / WorkBuddy AI（腾讯 CodeBuddy 订阅）。官方 OpenAI 兼容
    /// 端点 `{endpoint}/v2/chat/completions`，账号用 access token + 自定义头
    /// `X-User-Id`/`X-Domain` 认证；登录走官方 web 页（state 轮询）。通过
    /// OpenAIProvider 的 oauthTokenProvider + extraHeaders 承载，站点由
    /// `ProviderInstance.workBuddySite` 指定（China / International）。
    case workBuddy
    /// Trae（字节跳动 IDE）。两个变体：国内版 `.traeCN` 和国际版 `.trae`。
    /// 聊天走官方 `llm_utils_chat` SSE 端点（非 OpenAI 格式，需自定义
    /// TraeProvider），登录走浏览器 + JWT。站点由 `ProviderInstance.traeSite`
    /// 指定（China / International）。
    case trae
    /// Trae 国际版（同 `.trae`，站点为 International）。见 `.trae` 注释。
    case traeIntl
    /// Raccoon（小浣熊）。官方 OpenAI 兼容端点
    /// `{apiBase}/api/web/llm/v2/chat/completions`，Bearer token +
    /// `X-Org-Code` 认证，登录走浏览器。走 OpenAIProvider。
    case raccoon
    /// Sentinel for a provider type this app build doesn't recognize — e.g. a
    /// NEWER build synced an instance whose `provider_type` string isn't a known
    /// case here. We DECODE to this instead of throwing/dropping, so the instance
    /// is preserved (shown as "Unsupported", unusable) and not silently rewritten
    /// to a wrong type on the next save. The original raw string is kept alongside
    /// (see ProviderInstance.unknownProviderTypeRaw) for faithful round-tripping.
    case unsupported

    /// Decode a raw provider-type string, never throwing: an unrecognized value
    /// maps to `.unsupported` (forward-compat with newer builds).
    static func decoded(_ raw: String) -> ProviderType {
        ProviderType(rawValue: raw) ?? .unsupported
    }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openAI: return "OpenAI"
        case .antigravity: return "Antigravity"
        case .openRouter: return "OpenRouter"
        case .openAIResponses: return "Responses API (v3)"
        case .xAI: return "xAI (Grok)"
        case .kimiCode: return "Kimi Code"
        case .githubCopilot: return "GitHub Copilot"
        case .workBuddy: return "WorkBuddy"
        case .trae: return "Trae"
        case .traeIntl: return "Trae (Intl)"
        case .raccoon: return "Raccoon"
        case .unsupported: return "Unsupported"
        }
    }

    /// Whether an OAuth instance of this provider can discover its model list
    /// from the network, rather than only reporting a compiled-in catalog.
    ///
    /// [T-provider-oauth-model-discovery] This drives the one-shot refresh
    /// `ProviderConfigStore.addInstance` fires after a provider is added, so a
    /// freshly-authenticated account shows the vendor's CURRENT models instead
    /// of whatever this build happened to ship with (GH#265: xAI OAuth seeded a
    /// static catalog with no grok-4.6, and only a manual Settings → Models →
    /// Refresh fixed it).
    ///
    /// Deliberately a property of the TYPE rather than a check at the call
    /// site: the same question is asked of every provider, and the answer is a
    /// fact about how that provider's OAuth branch in
    /// `fetchModelsForInstance` is implemented. Keeping it here means adding a
    /// provider means answering it, instead of silently inheriting "no".
    ///
    /// `false` for the two whose OAuth branch returns a static list without a
    /// request — refreshing them would spend a network round-trip to arrive
    /// back at the catalog already seeded.
    var oauthSupportsModelDiscovery: Bool {
        switch self {
        case .anthropic, .gemini, .antigravity, .openRouter, .xAI, .kimiCode, .githubCopilot:
            // These OAuth branches all reach a real /models endpoint.
            return true
        case .workBuddy:
            // WorkBuddy 登录后可从 /v2/plugin/... 拉取真实目录；暂回退内置。
            return false
        case .trae, .traeIntl:
            // Trae 目录来自 `get_detail_param`（按 function 拉取）。
            return true
        case .raccoon:
            // Raccoon 目录来自 `model_catalog`。
            return true
        case .openAI:
            // OpenAIModelsAPI.fetchModelsOAuth() is a compiled-in list.
            return false
        case .openAIResponses:
            // Responses-API instances are API-key only; the OAuth branch
            // returns builtInModels.
            return false
        case .unsupported:
            // Synced from a newer build — nothing to fetch with.
            return false
        }
    }

    /// Built-in models for this provider type.
    var builtInModels: [LLMModel] {
        switch self {
        case .anthropic: return LLMModel.allAnthropic
        case .gemini: return LLMModel.allGemini
        case .openAI: return LLMModel.allOpenAI
        case .antigravity: return LLMModel.allAntigravity
        case .openRouter: return LLMModel.allOpenRouter
        case .openAIResponses: return LLMModel.allOpenAI
        case .xAI: return XAIModelsAPI.allModels
        case .kimiCode: return KimiModelsAPI.allModels
        case .workBuddy: return WorkBuddyModelsAPI.allModels
        case .trae, .traeIntl: return TraeModelsAPI.allModels
        case .raccoon: return RaccoonModelsAPI.allModels
        // Deliberately empty: the task requires the list come from the server
        // (`model_picker_enabled`), never a compiled-in guess that would go
        // stale and offer models the account cannot use.
        case .githubCopilot: return []
        case .unsupported: return []
        }
    }

    /// Short description shown under the provider name in the Add Provider
    /// picker — what kinds of services this protocol supports, rather than a
    /// raw built-in model count. Localized; English key, translations in
    /// Localizable.xcstrings.
    var pickerSubtitle: String {
        switch self {
        case .openAI, .openAIResponses:
            return AppLocalized("Works with Codex, DeepSeek, Moonshot, Groq and other compatible vendors")
        case .anthropic:
            return AppLocalized("Works with Claude and Anthropic-protocol-compatible services")
        case .gemini:
            return AppLocalized("Works with the Gemini series and Google AI Studio")
        case .openRouter:
            return AppLocalized("Aggregates GPT, Claude, Gemini, Llama and other mainstream models")
        case .xAI:
            return AppLocalized("Works with the Grok series of models")
        case .kimiCode:
            return AppLocalized("Sign in with your Kimi Code / Coding Plan subscription")
        case .githubCopilot:
            return AppLocalized("Sign in with GitHub — unofficial, use at your own risk")
        case .workBuddy:
            return AppLocalized("Sign in with your WorkBuddy / WorkBuddy AI subscription")
        case .trae:
            return AppLocalized("Sign in with your Trae CN account in the browser.")
        case .traeIntl:
            return AppLocalized("Sign in with your Trae account in the browser.")
        case .raccoon:
            return AppLocalized("Sign in with your Raccoon account in the browser.")
        case .antigravity:
            return AppLocalized("\(builtInModels.count) built-in models")
        case .unsupported:
            return AppLocalized("\(builtInModels.count) built-in models")
        }
    }

    /// Default modality assumed for custom models added to this provider.
    var defaultModality: ModelModality {
        switch self {
        case .anthropic: return .vision
        case .gemini:    return .fullMultimodal
        case .openAI:    return .vision
        case .antigravity: return .fullMultimodal
        case .openRouter: return .vision
        case .openAIResponses: return .vision
        case .xAI: return .vision
        case .kimiCode: return .vision
        case .githubCopilot: return .vision
        case .workBuddy: return .vision
        case .trae, .traeIntl: return .vision
        case .raccoon: return .vision
        case .unsupported: return .vision
        }
    }

    /// True when this build can't actually use the provider (synced from a newer app).
    var isUnsupported: Bool { self == .unsupported }
}

// MARK: - Credential Type

/// How a provider instance authenticates.
enum ProviderCredential: String, Codable, Hashable, Sendable {
    case apiKey
    case oauth
}

// MARK: - WorkBuddy (merged; ProviderTypes is already in the Xcode project)

/// WorkBuddy / WorkBuddy AI 站点。
///
/// China（腾讯 CodeBuddy，copilot.tencent.com）与 International
/// （www.workbuddy.ai）是两条独立订阅，端点、登录、模型互不相通。
/// 模型跑在 `{endpoint}/v2/chat/completions`（OpenAI 兼容），账号用
/// access token（JWT）认证，请求还要带 `X-User-Id` / `X-Domain`
/// （企业账号加 `X-Enterprise-Id` / `X-Tenant-Id`）。
enum WorkBuddySite: String, Codable, CaseIterable, Hashable, Sendable {
    case china = "china"
    case international = "international"

    var displayName: String {
        switch self {
        case .china: return "WorkBuddy"
        case .international: return "WorkBuddy AI"
        }
    }

    var endpoint: String {
        switch self {
        case .china: return "https://copilot.tencent.com"
        case .international: return "https://www.workbuddy.ai"
        }
    }

    var platform: String {
        switch self {
        case .china: return "workbuddy"
        case .international: return "workbuddy-ai"
        }
    }

    /// 聊天 API 根：`{endpoint}/v2`。OpenAIProvider 的 customBaseURL 用它，
    /// appendV1Suffix=false（`/v2/chat/completions` 直接落在 `/v2` 下）。
    var chatBaseURL: String { endpoint + "/v2" }

    var host: String { URL(string: endpoint)?.host ?? "" }

    /// 解析持久化的站点字符串；未知/空回退到 China。
    static func fromRaw(_ raw: String?) -> WorkBuddySite {
        raw.flatMap(WorkBuddySite.init(rawValue:)) ?? .china
    }
}

/// [T-trae] Trae 站点（字节跳动 IDE）。
enum TraeSite: String, Codable, CaseIterable, Hashable, Sendable {
    case china = "china"
    case international = "international"

    var displayName: String {
        switch self {
        case .china: return "Trae CN"
        case .international: return "Trae"
        }
    }

    /// 远程会话门（agent/IDE 端点挂在其 origin 下，非 `/api/remote/v1`）。
    var remoteBase: String {
        switch self {
        case .china: return "https://trae-api-cn.mchost.guru/api/remote/v1"
        case .international: return "https://core-normal.trae.ai/api/remote/v1"
        }
    }

    /// 登录 ExchangeToken 的 host（国际版可能由账号指定其它 host）。
    var oauthHost: String {
        switch self {
        case .china: return "https://api.trae.cn"
        case .international: return "https://core-normal.trae.ai"
        }
    }

    var host: String { URL(string: remoteBase)?.host ?? "" }

    static func fromRaw(_ raw: String?) -> TraeSite {
        raw.flatMap(TraeSite.init(rawValue:)) ?? .china
    }
}

/// [T-raccoon] Raccoon 站点。
enum RaccoonSite: String, Codable, CaseIterable, Hashable, Sendable {
    case work = "work"

    var displayName: String { "Raccoon" }

    var apiBase: String { "https://xiaohuanxiong.com" }
    var llmPrefix: String { "/api/web/llm/v2" }
    var authPrefix: String { "/api/web/auth/v1" }
    var clientPlatform: String { "desktop-windows" }

    /// 聊天 API：`{apiBase}/api/web/llm/v2/chat/completions`（OpenAI 兼容）。
    var chatBaseURL: String { apiBase + llmPrefix }

    var host: String { URL(string: apiBase)?.host ?? "" }

    static func fromRaw(_ raw: String?) -> RaccoonSite {
        raw.flatMap(RaccoonSite.init(rawValue:)) ?? .work
    }
}

/// WorkBuddy 账号凭据，按实例存 Keychain（`ProviderKeychainHelper`）。
struct WorkBuddyTokenStorage: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expireDate: Date?
    var uid: String
    var domain: String
    var enterpriseId: String?
    var accountName: String
    var site: String
    var lastRefresh: Date
}


/// WorkBuddy 内置模型目录（来自 kwwk 的 workbuddy-models.json）。
///
/// WorkBuddy 的模型服务是 OpenAI 兼容的，通过 `OpenAIProvider` + 自定义头
/// 调用。这里只做**内置回退**——登录后 `fetchModels` 会从真实
/// `/v2/plugin/.../models`（或等效端点）拉取账号实际目录覆盖。
enum WorkBuddyModelsAPI {
    /// 默认选择（首个/旗舰）。
    static let defaultModelId = "auto"

    static let allModels: [LLMModel] = [
        LLMModel(id: "auto", displayName: "Auto", provider: "WorkBuddy"),
        LLMModel(id: "hy4-preview-f", displayName: "Hy4 preview", provider: "WorkBuddy"),
        LLMModel(id: "hy3", displayName: "Hy3", provider: "WorkBuddy"),
        LLMModel(id: "hy3-x", displayName: "Hy3-X", provider: "WorkBuddy"),
        LLMModel(id: "deepseek-v4.1-flash", displayName: "Deepseek-V4.1-Flash", provider: "WorkBuddy"),
        LLMModel(id: "glm-5.3", displayName: "GLM-5.3", provider: "WorkBuddy"),
        LLMModel(id: "glm-5.3-flash", displayName: "GLM-5.3-Flash", provider: "WorkBuddy"),
        LLMModel(id: "glm-5.2", displayName: "GLM-5.2", provider: "WorkBuddy"),
        LLMModel(id: "glm-5.1", displayName: "GLM-5.1", provider: "WorkBuddy"),
        LLMModel(id: "glm-5v-turbo", displayName: "GLM-5v-Turbo", provider: "WorkBuddy"),
        LLMModel(id: "minimax-m3", displayName: "MiniMax-M3", provider: "WorkBuddy"),
        LLMModel(id: "kimi-k3-1", displayName: "Kimi-K3", provider: "WorkBuddy"),
        LLMModel(id: "kimi-k2.7", displayName: "Kimi-K2.7-Code", provider: "WorkBuddy"),
        LLMModel(id: "kimi-k2.6", displayName: "Kimi-K2.6", provider: "WorkBuddy"),
        LLMModel(id: "deepseek-v4-pro", displayName: "Deepseek-V4-Pro", provider: "WorkBuddy"),
    ]

    /// 登录后的真实目录。WorkBuddy 的模型端点随登录状态变化；在确认到
    /// 可用端点前，回退到内置清单。
    static func fetchModels(accessToken: String, site: WorkBuddySite) async -> [LLMModel] {
        // 未来可查 WorkBuddy 的模型目录；目前回退内置清单。
        allModels
    }
}

/// [T-trae] Trae 内置模型目录（回退；登录后从 `get_detail_param` 拉真实目录）。
enum TraeModelsAPI {
    static let defaultModelId = "glm-5.2"

    static let allModels: [LLMModel] = [
        LLMModel(id: "glm-5.3", displayName: "GLM 5.3", provider: "Trae"),
        LLMModel(id: "glm-5.2", displayName: "GLM 5.2", provider: "Trae"),
        LLMModel(id: "DeepSeek-V4-Pro-Official", displayName: "DeepSeek V4 Pro", provider: "Trae"),
        LLMModel(id: "DeepSeek-V4-Flash-Official", displayName: "DeepSeek V4 Flash", provider: "Trae"),
        LLMModel(id: "Doubao-Seed-2.1-Pro", displayName: "Doubao Seed 2.1 Pro", provider: "Trae"),
        LLMModel(id: "Doubao-Seed-2.1-Turbo", displayName: "Doubao Seed 2.1 Turbo", provider: "Trae"),
        LLMModel(id: "Doubao-Seed-Evolving", displayName: "Doubao Seed Evolving", provider: "Trae"),
        LLMModel(id: "kimi-k3", displayName: "Kimi K3", provider: "Trae"),
        LLMModel(id: "minimax-m3", displayName: "MiniMax M3", provider: "Trae"),
        LLMModel(id: "qwen-3.7-plus", displayName: "Qwen 3.7 Plus", provider: "Trae"),
        LLMModel(id: "qwen3.8-max", displayName: "Qwen 3.8 Max", provider: "Trae"),
    ]

    /// 登录后从 Trae 目录拉取（`get_detail_param`）；失败回退内置。
    static func fetchModels(accessToken: String, site: TraeSite) async -> [LLMModel] {
        // 完整实现见 TraeModelsFetcher（后续）；目前回退内置清单。
        allModels
    }
}

/// [T-raccoon] Raccoon 内置模型目录（回退；登录后从 `model_catalog` 拉真实目录）。
enum RaccoonModelsAPI {
    static let defaultModelId = "auto"

    static let allModels: [LLMModel] = [
        LLMModel(id: "auto", displayName: "Auto", provider: "Raccoon"),
        LLMModel(id: "deepseek-v4.1-flash", displayName: "Deepseek V4.1 Flash", provider: "Raccoon"),
        LLMModel(id: "deepseek-v4-pro", displayName: "Deepseek V4 Pro", provider: "Raccoon"),
        LLMModel(id: "glm-5.3", displayName: "GLM 5.3", provider: "Raccoon"),
        LLMModel(id: "glm-5.2", displayName: "GLM 5.2", provider: "Raccoon"),
        LLMModel(id: "minimax-m3", displayName: "MiniMax M3", provider: "Raccoon"),
        LLMModel(id: "kimi-k3", displayName: "Kimi K3", provider: "Raccoon"),
        LLMModel(id: "qwen-3.7-plus", displayName: "Qwen 3.7 Plus", provider: "Raccoon"),
    ]

    /// 登录后从 Raccoon 目录拉取（`model_catalog`）；失败回退内置。
    static func fetchModels(accessToken: String, orgCode: String, site: RaccoonSite) async -> [LLMModel] {
        // 完整实现见 RaccoonModelsFetcher（后续）；目前回退内置清单。
        allModels
    }
}

/// [T-raccoon] Raccoon 账号凭据，按实例存 Keychain。
struct RaccoonTokenStorage: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expireDate: Date?
    var orgCode: String
    var orgName: String
    var orgRole: String
    var accountName: String
    var site: String
    var lastRefresh: Date
}

/// [T-trae] Trae 账号凭据，按实例存 Keychain。
struct TraeTokenStorage: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expireDate: Date?
    var userID: String
    var machineID: String?
    var deviceID: String?
    var oauthHost: String?
    var accountName: String
    var site: String
    var lastRefresh: Date
}


/// WorkBuddy / WorkBuddy AI 官方订阅登录与 token 管理。
///
/// 复刻 kwwk 的 `WorkBuddyOAuth`：模型跑在 OpenAI 兼容端点
/// `{endpoint}/v2/chat/completions` 下，账号用 access token（JWT）认证，
/// 请求还要带 `X-User-Id` / `X-Domain`（企业加 `X-Enterprise-Id`）。
/// 登录走官方 web 页（无 OAuth client id，用 state 命名）：先
/// `POST /v2/plugin/auth/state` 拿登录页，UI 在浏览器打开，再每秒轮询
/// `token` 和 `account` 直到拿到凭据。不需要桌面 App / 网关。
///
/// 结构与 `KimiOAuthManager` 一致：按实例存 Keychain，访问 token 按需
/// 刷新（5 分钟缓冲 + 单飞去重），刷新失败走 `markOAuthNeedsReauth`。
@MainActor
final class WorkBuddyOAuthManager: ObservableObject {
    static let shared = WorkBuddyOAuthManager()
    private init() {}

    private let logger = AppLogger(category: "WorkBuddyOAuth")

    /// 刷新缓冲：提前这么多秒换新 token（与 Kimi/Claude 一致）。
    private let refreshBuffer: TimeInterval = 5 * 60

    /// WorkBuddy 桌面版本，请求以它发出；copilot.tencent.com 对不认识
    /// 的 User-Agent 会答业务码 10085。
    static let userAgent = "WorkBuddy/5.5.6"
    /// "还没就绪"业务码：token 轮询 11217，account 轮询 12151。
    static let tokenPendingCode = 11217
    static let accountPendingCode = 12151
    /// 登录页最多等这么久。
    static let signInWindow: TimeInterval = 5 * 60
    /// access token 默认寿命一小时（端点没给时）。
    static let defaultLifetime: TimeInterval = 60 * 60

    /// 单飞刷新去重。
    private var inFlightRefresh: [String: Task<WorkBuddyTokenStorage, Error>] = [:]

    // MARK: - Status accessors

    func isAuthenticated(instanceId: String) -> Bool {
        ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self)?.accessToken.isEmpty == false
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self)?.accessToken,
              token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    func logout(instanceId: String) {
        inFlightRefresh[instanceId]?.cancel()
        inFlightRefresh[instanceId] = nil
        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
    }

    func accountName(instanceId: String) -> String? {
        let name = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self)?.accountName
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    // MARK: - 浏览器登录

    /// 登录页交给 UI 打开（Safari）；`pollCredentials` 在后台轮询直到拿到
    /// 凭据，成功后存 Keychain。
    struct LoginPresentation {
        let authURL: URL
        let site: WorkBuddySite
    }

    func login(
        instanceId: String,
        site: WorkBuddySite,
        present: @escaping (LoginPresentation) -> Void
    ) async throws {
        logger.info("WorkBuddy login START (instance: \(instanceId), site: \(site.rawValue))")
        let state = try await requestState(site: site)
        present(.init(authURL: state.authURL, site: site))
        let creds = try await pollCredentials(site: site, state: state.state)
        let storage = WorkBuddyTokenStorage(
            accessToken: creds.access,
            refreshToken: creds.refresh,
            expireDate: creds.expiresAt,
            uid: creds.uid,
            domain: creds.domain,
            enterpriseId: creds.enterpriseId,
            accountName: creds.accountName,
            site: site.rawValue,
            lastRefresh: Date()
        )
        ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
        logger.info("WorkBuddy login complete (instance: \(instanceId))")
    }

    // MARK: - 按需 access token（单飞刷新）

    func validAccessToken(instanceId: String) async throws -> String {
        guard let storage = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self) else {
            throw LLMError.invalidAPIKey(detail: "WorkBuddy: no OAuth token found for instance \(instanceId)")
        }
        let needsRefresh = !storage.refreshToken.isEmpty
            && (storage.expireDate.map { $0.timeIntervalSinceNow <= refreshBuffer } ?? false)
        guard needsRefresh else {
            guard !storage.accessToken.isEmpty else {
                throw LLMError.invalidAPIKey(detail: "WorkBuddy: access token is empty for instance \(instanceId)")
            }
            return storage.accessToken
        }
        let refreshed = try await refreshSingleFlight(instanceId: instanceId, current: storage)
        return refreshed.accessToken
    }

    private func refreshSingleFlight(instanceId: String, current: WorkBuddyTokenStorage) async throws -> WorkBuddyTokenStorage {
        if let existing = inFlightRefresh[instanceId] {
            return try await existing.value
        }
        let task = Task<WorkBuddyTokenStorage, Error> { [weak self] in
            guard let self else { throw LLMError.cancelled }
            return try await self.performRefresh(instanceId: instanceId, current: current)
        }
        inFlightRefresh[instanceId] = task
        defer { inFlightRefresh[instanceId] = nil }
        return try await task.value
    }

    /// `POST /v2/plugin/auth/token/refresh`（`X-Refresh-Token` 头）。
    /// 刷新令牌过期时抛错并标记需重登；成功则写回 Keychain。
    private func performRefresh(instanceId: String, current: WorkBuddyTokenStorage) async throws -> WorkBuddyTokenStorage {
        let site = WorkBuddySite.fromRaw(current.site)
        var headers = Self.jsonHeaders
        headers["X-Refresh-Token"] = current.refreshToken
        headers["X-Auth-Refresh-Source"] = "plugin"
        headers["X-Domain"] = current.domain
        if let enterprise = current.enterpriseId {
            headers["X-Enterprise-Id"] = enterprise
            headers["X-Tenant-Id"] = enterprise
        }
        do {
            let data = try await call(site, method: "POST", path: "/v2/plugin/auth/token/refresh", headers: headers, body: Data("{}".utf8))
            guard let token = data as? [String: Any],
                  let access = token["accessToken"] as? String, !access.isEmpty else {
                throw LLMError.providerError(message: "WorkBuddy token refresh failed: no access token")
            }
            let refreshed = WorkBuddyTokenStorage(
                accessToken: access,
                refreshToken: (token["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? current.refreshToken,
                expireDate: Self.expiry(token, now: Date()),
                uid: current.uid,
                domain: current.domain,
                enterpriseId: current.enterpriseId,
                accountName: current.accountName,
                site: current.site,
                lastRefresh: Date()
            )
            ProviderKeychainHelper.saveOAuthToken(refreshed, instanceId: instanceId)
            return refreshed
        } catch {
            // 刷新令牌过期 → 标记需重登（保留凭据但不可用）。
            if let token = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: WorkBuddyTokenStorage.self) {
                ProviderKeychainHelper.markOAuthNeedsReauth(instanceId: instanceId)
                logger.info("WorkBuddy refresh failed; marked reauth (instance: \(instanceId))")
            }
            throw error
        }
    }

    // MARK: - 内部：登录协议

    private struct State { let state: String; let authURL: URL }
    private struct Credentials {
        let access: String
        let refresh: String
        let expiresAt: Date
        let uid: String
        let domain: String
        let enterpriseId: String?
        let accountName: String
    }

    /// `POST /v2/plugin/auth/state?platform=` → `{state, authUrl}`，再拼
    /// `version` + `loginSessionId`。登录页在浏览器打开后轮询拿凭据。
    private func requestState(site: WorkBuddySite) async throws -> State {
        let path = "/v2/plugin/auth/state?" + Self.form(["platform": site.platform])
        let headers = [
            "X-No-Authorization": "true",
            "X-No-User-Id": "true",
            "X-No-Enterprise-Id": "true",
            "X-No-Department-Info": "true",
        ]
        let data = try await call(site, method: "POST", path: path, headers: headers, body: Data("{}".utf8))
        guard let payload = data as? [String: Any],
              let state = payload["state"] as? String, !state.isEmpty,
              var page = (payload["authUrl"] as? String).flatMap(URLComponents.init(string:)),
              page.scheme == "https" else {
            throw LLMError.providerError(message: "\(site.displayName): no sign-in page")
        }
        var items = page.queryItems ?? []
        items.removeAll { $0.name == "version" || $0.name == "loginSessionId" }
        items.append(URLQueryItem(name: "version", value: "2.0.0"))
        items.append(URLQueryItem(name: "loginSessionId", value: Self.randomHex(32)))
        page.queryItems = items
        guard let authURL = page.url else { throw LLMError.providerError(message: "\(site.displayName): invalid sign-in page") }
        return State(state: state, authURL: authURL)
    }

    private func pollCredentials(site: WorkBuddySite, state: String) async throws -> Credentials {
        let deadline = Date().addingTimeInterval(Self.signInWindow)
        let query = Self.form(["state": state])
        let token = try await pollValue(site, path: "/v2/plugin/auth/token?" + query,
                                        pendingCode: Self.tokenPendingCode, deadline: deadline)
        guard let access = token["accessToken"] as? String, !access.isEmpty else {
            throw LLMError.providerError(message: "\(site.displayName): no token")
        }
        let refresh = (token["refreshToken"] as? String) ?? ""
        let expiresAt = Self.expiry(token, now: Date())
        var domain = ((token["domain"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if domain.isEmpty { domain = site.host }

        let accountHeaders = [
            "Authorization": "Bearer \(access)",
            "X-Domain": domain,
            "X-No-User-Id": "true",
            "X-No-Enterprise-Id": "true",
        ]
        let account = try await pollValue(site, path: "/v2/plugin/login/account?" + query,
                                          pendingCode: Self.accountPendingCode, deadline: deadline,
                                          headers: accountHeaders)
        guard let uid = account["uid"] as? String, !uid.isEmpty else {
            throw LLMError.providerError(message: "\(site.displayName): no account")
        }
        let names = [account["nickname"], account["phoneNumber"]].compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let accountName = names.first { !$0.isEmpty } ?? uid
        let enterprise = await enterpriseId(site, account: account, bearer: access, domain: domain)
        return Credentials(access: access, refresh: refresh, expiresAt: expiresAt, uid: uid,
                           domain: domain, enterpriseId: enterprise.isEmpty ? nil : enterprise,
                           accountName: accountName)
    }

    /// 轮询一个 `{code,msg,data}` 端点直到 `data` 非空；"还没就绪"码、408、
    /// 429 继续等，其余失败结束。
    private func pollValue(_ site: WorkBuddySite, path: String, pendingCode: Int,
                           deadline: Date, headers: [String: String] = [:]) async throws -> [String: Any] {
        var consecutiveErrors = 0
        while true {
            try Task.checkCancellation()
            if Date() > deadline { throw LLMError.providerError(message: "\(site.displayName): sign-in timed out") }
            do {
                let data = try await call(site, method: "GET", path: path, headers: headers)
                consecutiveErrors = 0
                if let answer = data as? [String: Any], !answer.isEmpty { return answer }
            } catch let failure as WorkBuddyAPI.Failure {
                consecutiveErrors = 0
                if failure.code == pendingCode || failure.status == 408 || failure.status == 429 {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                throw LLMError.providerError(message: "\(site.displayName): \(failure.message)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    throw LLMError.providerError(message: "\(site.displayName) polling failed: \(error.localizedDescription)")
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func enterpriseId(_ site: WorkBuddySite, account: [String: Any], bearer: String, domain: String) async -> String {
        let own = Self.trimmed(account["enterpriseId"])
        if !own.isEmpty { return own }
        let type = Self.trimmed(account["type"]).lowercased()
        if type.isEmpty || type == "personal" { return "" }
        let headers = ["Authorization": "Bearer \(bearer)", "X-Domain": domain, "X-User-Id": Self.trimmed(account["uid"])]
        guard let listed = try? await call(site, method: "GET", path: "/v2/plugin/accounts", headers: headers),
              let accounts = listed as? [String: Any] else { return "" }
        let mine = ((accounts["accounts"] as? [[String: Any]] ?? [])).filter {
            ($0["uid"] as? String) == (account["uid"] as? String) && !Self.trimmed($0["enterpriseId"]).isEmpty
        }
        let sameType = mine.filter { Self.trimmed($0["type"]).lowercased() == type }
        let pick = sameType.count == 1 ? sameType[0] : mine.first ?? [:]
        return Self.trimmed(pick["enterpriseId"])
    }

    // MARK: - 内部：网络

    /// WorkBuddy 的 JSON 请求头。
    private static let jsonHeaders = [
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": userAgent,
    ]

    private func call(_ site: WorkBuddySite, method: String, path: String,
                      headers: [String: String] = [:], body: Data? = nil) async throws -> Any? {
        guard let url = URL(string: site.endpoint + path) else {
            throw LLMError.providerError(message: "invalid URL")
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        var all = Self.jsonHeaders
        for (name, value) in headers { all[name] = value }
        request.allHTTPHeaderFields = all
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let envelope = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let code = (envelope["code"] as? Int) ?? ((envelope["code"] as? String).flatMap(Int.init)) ?? 0
        let message = envelope["msg"] as? String ?? ""
        if code != 0 {
            throw WorkBuddyAPI.Failure(code: code, status: status, message: message.isEmpty ? "error \(code)" : message)
        }
        guard (200..<300).contains(status) else {
            throw WorkBuddyAPI.Failure(code: 0, status: status, message: message.isEmpty ? "HTTP \(status)" : message)
        }
        let payload = envelope["data"]
        return (payload is NSNull) ? nil : payload
    }

    /// token 到期时间：`expiresAt`（毫秒）、`expiresIn`（秒）、JWT exp。
    private static func expiry(_ token: [String: Any], now: Date) -> Date {
        if let at = int64(token["expiresAt"]), at > 0 { return Date(timeIntervalSince1970: Double(at) / 1000) }
        if let inSeconds = int64(token["expiresIn"]), inSeconds > 0 { return now.addingTimeInterval(Double(inSeconds)) }
        if let access = token["accessToken"] as? String, let exp = jwtExpiry(access) { return exp }
        return now.addingTimeInterval(defaultLifetime)
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let data = Data(base64Encoded: base64Pad(String(parts[1]))) else { return nil }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let exp = int64(payload?["exp"]) else { return nil }
        return Date(timeIntervalSince1970: Double(exp))
    }

    private static func base64Pad(_ segment: String) -> String {
        var value = segment
        while value.count % 4 != 0 { value += "=" }
        return value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as Int: Int64(number)
        case let number as Int64: number
        case let number as Double: Int64(number)
        case let text as String: Int64(text)
        default: nil
        }
    }

    private static func trimmed(_ value: Any?) -> String {
        ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func form(_ fields: [String: String]) -> String {
        fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
    }

    private static func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count / 2)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// WorkBuddy 的 `{code,msg,data}` 信封错误。
enum WorkBuddyAPI {
    struct Failure: Error, LocalizedError, Equatable {
        let code: Int
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }
}

