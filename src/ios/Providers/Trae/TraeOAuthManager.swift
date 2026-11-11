import Foundation

// [T-trae] TraeOAuthManager — token management for Trae (both builds).
//
// The full browser-loopback sign-in flow will be added via the UI layer; this
// manager provides what the provider needs at runtime: reading the stored
// token, refreshing it when near expiry (single-flight), and exposing the
// user id for the `X-Uid` header.
@MainActor
final class TraeOAuthManager: ObservableObject {
    static let shared = TraeOAuthManager()
    private init() {}

    private let logger = AppLogger(category: "TraeOAuth")
    private let refreshBuffer: TimeInterval = 5 * 60
    static let userAgent = "Trae/0.1.61"

    private var inFlightRefresh: [String: Task<TraeTokenStorage, Error>] = [:]

    // MARK: - Status accessors

    func isAuthenticated(instanceId: String) -> Bool {
        ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: TraeTokenStorage.self)?.accessToken.isEmpty == false
    }

    func userID(instanceId: String) -> String? {
        let uid = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: TraeTokenStorage.self)?.userID
        guard let uid, !uid.isEmpty else { return nil }
        return uid
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: TraeTokenStorage.self)?.accessToken,
              token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    func accountName(instanceId: String) -> String? {
        let name = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: TraeTokenStorage.self)?.accountName
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    func logout(instanceId: String) {
        inFlightRefresh[instanceId]?.cancel()
        inFlightRefresh[instanceId] = nil
        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
    }

    // MARK: - Login (PKCE loopback)

    struct LoginPresentation {
        let authURL: URL
        let site: TraeSite
    }

    /// Runs the browser sign-in: builds the authorization URL, calls `present`
    /// so the UI can open the browser, waits for the loopback callback, then
    /// exchanges the code for a token and stores it.
    func login(
        instanceId: String,
        site: TraeSite,
        present: @escaping (LoginPresentation) -> Void
    ) async throws {
        let profile = TraeLoginProfile.of(site)
        let result = try await TraeOAuthClient.login(profile: profile) { url in
            present(LoginPresentation(authURL: url, site: site))
        }
        let storage = TraeTokenStorage(
            accessToken: result.access,
            refreshToken: result.refresh,
            expireDate: result.expireAt,
            userID: result.userID,
            machineID: result.machineID,
            deviceID: result.deviceID,
            oauthHost: result.origin,
            accountName: result.userID.isEmpty ? "Trae" : result.userID,
            site: site.rawValue,
            lastRefresh: Date()
        )
        ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
        logger.info("Trae login OK (instance: \(instanceId), site: \(site.rawValue), user: \(result.userID))")
    }

    // MARK: - Access token (single-flight refresh)

    func validAccessToken(instanceId: String) async throws -> String {
        guard let storage = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: TraeTokenStorage.self) else {
            throw LLMError.invalidAPIKey(detail: "Trae: no OAuth token for instance \(instanceId)")
        }
        let needsRefresh = !storage.refreshToken.isEmpty
            && (storage.expireDate.map { $0.timeIntervalSinceNow <= refreshBuffer } ?? false)
        guard needsRefresh else {
            guard !storage.accessToken.isEmpty else {
                throw LLMError.invalidAPIKey(detail: "Trae: access token empty for instance \(instanceId)")
            }
            return storage.accessToken
        }
        let refreshed = try await refreshSingleFlight(instanceId: instanceId, current: storage)
        return refreshed.accessToken
    }

    private func refreshSingleFlight(instanceId: String, current: TraeTokenStorage) async throws -> TraeTokenStorage {
        if let existing = inFlightRefresh[instanceId] {
            return try await existing.value
        }
        let task = Task<TraeTokenStorage, Error> { [weak self] in
            guard let self else { throw LLMError.cancelled }
            return try await self.performRefresh(instanceId: instanceId, current: current)
        }
        inFlightRefresh[instanceId] = task
        defer { inFlightRefresh[instanceId] = nil }
        return try await task.value
    }

    /// Refresh via `POST {gate}/cloudide/api/v3/trae/oauth/ExchangeToken`.
    /// Placeholder — the full exchange is wired once the sign-in flow lands.
    private func performRefresh(instanceId: String, current: TraeTokenStorage) async throws -> TraeTokenStorage {
        let site = TraeSite.fromRaw(current.site)
        let gate = current.oauthHost ?? site.oauthHost
        guard let url = URL(string: "\(gate)/cloudide/api/v3/trae/oauth/ExchangeToken") else {
            throw LLMError.providerError(message: "Trae: invalid refresh URL")
        }
        let body: [String: Any] = ["refresh_token": current.refreshToken]
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.providerError(message: "Trae refresh failed (HTTP \(status))")
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let payload = (root?["data"] as? [String: Any]) ?? root ?? [:]
        let access = (payload["access_token"] as? String) ?? (payload["accessToken"] as? String) ?? ""
        guard !access.isEmpty else {
            throw LLMError.providerError(message: "Trae refresh returned no token")
        }
        let renewed = (payload["refresh_token"] as? String) ?? (payload["refreshToken"] as? String) ?? current.refreshToken
        var updated = current
        updated.accessToken = access
        updated.refreshToken = renewed
        updated.lastRefresh = Date()
        if let exp = jwtExpiry(access) {
            updated.expireDate = exp
        }
        ProviderKeychainHelper.saveOAuthToken(updated, instanceId: instanceId)
        return updated
    }

    private func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64Encoded: base64Pad(String(parts[1]))) else { return nil }
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let exp = (payload?["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func base64Pad(_ segment: String) -> String {
        var value = segment
        while value.count % 4 != 0 { value += "=" }
        return value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    }
}
