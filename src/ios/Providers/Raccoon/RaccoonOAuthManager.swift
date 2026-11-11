import Foundation

// [T-raccoon] RaccoonOAuthManager — token management for Raccoon.
//
// Raccoon's chat is OpenAI-compatible (`{apiBase}/api/web/llm/v2/chat/completions`)
// authenticated with `Authorization: Bearer <token>` plus `X-Org-Code`
// (office_identity). The full browser-loopback sign-in flow will be added via
// the UI layer; this manager provides token reading/refresh at runtime.
@MainActor
final class RaccoonOAuthManager: ObservableObject {
    static let shared = RaccoonOAuthManager()
    private init() {}

    private let logger = AppLogger(category: "RaccoonOAuth")
    private let refreshBuffer: TimeInterval = 5 * 60
    static let userAgent = "Raccoon Work/1.0.35 (Windows)"

    private var inFlightRefresh: [String: Task<RaccoonTokenStorage, Error>] = [:]

    // MARK: - Status accessors

    func isAuthenticated(instanceId: String) -> Bool {
        ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: RaccoonTokenStorage.self)?.accessToken.isEmpty == false
    }

    func maskedToken(instanceId: String) -> String? {
        guard let token = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: RaccoonTokenStorage.self)?.accessToken,
              token.count > 8 else { return nil }
        return "\(token.prefix(4))…\(token.suffix(4))"
    }

    func accountName(instanceId: String) -> String? {
        let name = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: RaccoonTokenStorage.self)?.accountName
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    func logout(instanceId: String) {
        inFlightRefresh[instanceId]?.cancel()
        inFlightRefresh[instanceId] = nil
        ProviderKeychainHelper.deleteOAuthToken(instanceId: instanceId)
    }

    // MARK: - Browser sign-in

    /// Runs the Raccoon browser-loopback sign-in and stores the tokens.
    func login(
        instanceId: String,
        present: @escaping (URL) -> Void
    ) async throws {
        let result = try await RaccoonOAuthLogin.login { url in
            present(url)
        }
        let storage = RaccoonTokenStorage(
            accessToken: result.access,
            refreshToken: result.refresh,
            expireDate: result.expireAt,
            orgCode: result.orgCode,
            orgName: result.orgName,
            orgRole: result.orgRole,
            accountName: result.orgName.isEmpty ? "Raccoon" : result.orgName,
            site: RaccoonSite.work.rawValue,
            lastRefresh: Date()
        )
        ProviderKeychainHelper.saveOAuthToken(storage, instanceId: instanceId)
        logger.info("Raccoon login OK (instance: \(instanceId), org: \(result.orgCode))")
    }

    // MARK: - Access token (single-flight refresh)

    func validAccessToken(instanceId: String) async throws -> String {
        guard let storage = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: RaccoonTokenStorage.self) else {
            throw LLMError.invalidAPIKey(detail: "Raccoon: no OAuth token for instance \(instanceId)")
        }
        let needsRefresh = !storage.refreshToken.isEmpty
            && (storage.expireDate.map { $0.timeIntervalSinceNow <= refreshBuffer } ?? false)
        guard needsRefresh else {
            guard !storage.accessToken.isEmpty else {
                throw LLMError.invalidAPIKey(detail: "Raccoon: access token empty for instance \(instanceId)")
            }
            return storage.accessToken
        }
        let refreshed = try await refreshSingleFlight(instanceId: instanceId, current: storage)
        return refreshed.accessToken
    }

    private func refreshSingleFlight(instanceId: String, current: RaccoonTokenStorage) async throws -> RaccoonTokenStorage {
        if let existing = inFlightRefresh[instanceId] {
            return try await existing.value
        }
        let task = Task<RaccoonTokenStorage, Error> { [weak self] in
            guard let self else { throw LLMError.cancelled }
            return try await self.performRefresh(instanceId: instanceId, current: current)
        }
        inFlightRefresh[instanceId] = task
        defer { inFlightRefresh[instanceId] = nil }
        return try await task.value
    }

    /// Refresh via `POST {apiBase}/api/web/auth/v1/refresh`.
    private func performRefresh(instanceId: String, current: RaccoonTokenStorage) async throws -> RaccoonTokenStorage {
        let site = RaccoonSite.fromRaw(current.site)
        guard let url = URL(string: site.apiBase + site.authPrefix + "/refresh") else {
            throw LLMError.providerError(message: "Raccoon: invalid refresh URL")
        }
        let body: [String: Any] = ["refresh_token": current.refreshToken]
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.providerError(message: "Raccoon refresh failed (HTTP \(status))")
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let result = (root?["data"] as? [String: Any]) ?? root ?? [:]
        let access = (result["access_token"] as? String) ?? (result["accessToken"] as? String) ?? ""
        guard !access.isEmpty else {
            throw LLMError.providerError(message: "Raccoon refresh returned no token")
        }
        let renewed = (result["refresh_token"] as? String) ?? (result["refreshToken"] as? String) ?? current.refreshToken
        var updated = current
        updated.accessToken = access
        updated.refreshToken = renewed
        updated.lastRefresh = Date()
        if let exp = expiry(result) {
            updated.expireDate = exp
        }
        ProviderKeychainHelper.saveOAuthToken(updated, instanceId: instanceId)
        return updated
    }

    private func expiry(_ result: [String: Any]) -> Date? {
        if let at = (result["expires_at"] ?? result["expiresAt"] ?? result["exp"]) as? NSNumber {
            let v = at.doubleValue
            // Unix ms vs seconds heuristic.
            let seconds = v > 10_000_000_000 ? v / 1000 : v
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
