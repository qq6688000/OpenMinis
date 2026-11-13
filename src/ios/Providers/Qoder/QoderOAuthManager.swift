import Foundation

// [T-qoder] QoderOAuthManager — token management for Qoder (CN build).
//
// Qoder 是与 Trae 孪生的 IDE，共用同一 `OAuthLogin` 基类逻辑（PKCE loopback
// + ExchangeToken）。这里直接复用 `TraeOAuthClient` 的整套机制，只换
// profile（host / clientID / 版本号），并把返回的 machineID 持久化
// （Qoder chat 必须带 machineId 头）。
@MainActor
final class QoderOAuthManager: ObservableObject {
    static let shared = QoderOAuthManager()
    private init() {}

    private let logger = AppLogger(category: "QoderOAuth")
    private let refreshBuffer: TimeInterval = 5 * 60

    private var inFlightRefresh: [String: Task<QoderTokenStorage, Error>] = [:]

    // MARK: - Status accessors

    func isAuthenticated(instanceId: String) -> Bool {
        ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: QoderTokenStorage.self)?.accessToken.isEmpty == false
    }

    func userID(instanceId: String) -> String? {
        let uid = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: QoderTokenStorage.self)?.userID
        guard let uid, !uid.isEmpty else { return nil }
        return uid
    }

    /// Qoder chat 必需的设备指纹（登录时生成并持久化）。
    func machineID(instanceId: String) -> String? {
        let mid = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: QoderTokenStorage.self)?.machineID
        guard let mid, !mid.isEmpty else { return nil }
        return mid
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: QoderTokenStorage.self)?.accessToken,
              token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    func accountName(instanceId: String) -> String? {
        let name = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: QoderTokenStorage.self)?.accountName
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    func logout(instanceId: String) {
        inFlightRefresh[instanceId]?.cancel()
        inFlightRefresh[instanceId] = nil
        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
    }

    // MARK: - Login (PKCE loopback, reuses TraeOAuthClient)

    struct LoginPresentation {
        let authURL: URL
        let site: QoderSite
    }

    func login(
        instanceId: String,
        site: QoderSite,
        present: @escaping (LoginPresentation) -> Void
    ) async throws {
        let profile = QoderLoginProfile.of(site)
        let result = try await TraeOAuthClient.login(profile: profile) { url in
            present(LoginPresentation(authURL: url, site: site))
        }
        let storage = QoderTokenStorage(
            accessToken: result.access,
            refreshToken: result.refresh,
            expireDate: result.expireAt,
            userID: result.userID,
            machineID: result.machineID,
            deviceID: result.deviceID,
            oauthHost: result.origin,
            accountName: result.userID.isEmpty ? "Qoder" : result.userID,
            site: site.rawValue,
            lastRefresh: Date()
        )
        ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
        logger.info("Qoder login OK (instance: \(instanceId), site: \(site.rawValue), user: \(result.userID))")
    }

    // MARK: - Access token (single-flight refresh)

    func validAccessToken(instanceId: String) async throws -> String {
        guard let storage = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: QoderTokenStorage.self) else {
            throw LLMError.invalidAPIKey(detail: "Qoder: no OAuth token for instance \(instanceId)")
        }
        let needsRefresh = !storage.refreshToken.isEmpty
            && (storage.expireDate.map { $0.timeIntervalSinceNow < refreshBuffer } ?? false)
        guard needsRefresh else { return storage.accessToken }
        let refreshed = try await refreshSingleFlight(instanceId: instanceId, current: storage)
        return refreshed.accessToken
    }

    private func refreshSingleFlight(instanceId: String, current: QoderTokenStorage) async throws -> QoderTokenStorage {
        if let existing = inFlightRefresh[instanceId] {
            return try await existing.value
        }
        let task = Task<QoderTokenStorage, Error> { [weak self] in
            guard let self else { throw LLMError.cancelled }
            defer { self.inFlightRefresh[instanceId] = nil }
            return try await self.performRefresh(instanceId: instanceId, current: current)
        }
        inFlightRefresh[instanceId] = task
        return try await task.value
    }

    private func performRefresh(instanceId: String, current: QoderTokenStorage) async throws -> QoderTokenStorage {
        let site = QoderSite.fromRaw(current.site)
        let gate = current.oauthHost ?? site.oauthHost
        guard let url = URL(string: "\(gate)/qoder/api/v3/oauth/ExchangeToken") else {
            throw LLMError.providerError(message: "Qoder: invalid refresh URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(site.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["refresh_token": current.refreshToken]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.providerError(message: "Qoder refresh failed: HTTP \(status)")
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let payload = (root?["data"] as? [String: Any]) ?? root ?? [:]
        let access = (payload["access_token"] as? String) ?? (payload["accessToken"] as? String) ?? ""
        guard !access.isEmpty else {
            throw LLMError.providerError(message: "Qoder refresh: empty access token")
        }
        let renewed = (payload["refresh_token"] as? String) ?? (payload["refreshToken"] as? String) ?? current.refreshToken
        var updated = current
        updated.accessToken = access
        updated.refreshToken = renewed
        updated.lastRefresh = Date()
        if let exp = jwtExpiry(access) { updated.expireDate = exp }
        ProviderKeychainHelper.saveOAuthToken(updated, instanceId: instanceId)
        return updated
    }

    private func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count > 1,
              let data = Data(base64Encoded: base64Pad(String(parts[1]))) else { return nil }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let exp = (payload?["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func base64Pad(_ segment: String) -> String {
        var s = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return s
    }
}

/// [T-qoder] Qoder 登录 profile。复用 `TraeLoginProfile.Profile` 结构，
/// 但 host / 版本号 / clientID 需要覆盖。
///
/// 注意：`TraeOAuthClient` 内部硬编码了 Trae 的 `clientID` 与
/// `ExchangeToken` 路径。Qoder 若走不同 client，需要在 `TraeOAuthClient`
/// 里读取 profile 上的覆盖值；当前 Qoder CN 沿用 Trae 同源 client
/// （同为字节系分发），【待实测】若 4001/401 再改。
enum QoderLoginProfile {
    static let china = TraeLoginProfile.Profile(
        site: .china,
        fixedLoginHost: "https://qoder.cn",
        guidanceURLs: [],
        pluginVersion: "2.3.83560",
        appVersion: "3.3.100",
        appType: "stable",
        deviceBrand: "",
        osInfo: "windows",
        osVersion: "Windows 10 Home",
        channelName: "common",
        deviceIdentity: .hex64,
        fixedDeviceID: nil,
        exchangeOrigins: ["https://gateway.qoder.com.cn"]
    )

    static func of(_ site: QoderSite) -> TraeLoginProfile.Profile {
        china
    }
}
