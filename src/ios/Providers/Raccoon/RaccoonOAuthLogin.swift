// [T-raccoon] Raccoon browser sign-in: loopback + authorization-code exchange.
// Ported from Apelin's RaccoonOAuth.
import Foundation

enum RaccoonOAuthLogin {
    static let origin = "https://xiaohuanxiong.com"
    static let authorizePath = "/code/authorize"
    static let authBase = "https://xiaohuanxiong.com/api/web/auth/v1"
    static let loginSource = "desktop"
    static let appName = "办公小浣熊客户端"
    static let callbackPath = "/auth/callback"

    static func login(
        present: @escaping (URL) -> Void,
    ) async throws -> (access: String, refresh: String, expireAt: Date?, orgCode: String, orgName: String, orgRole: String) {
        let state = try randomState()
        // The page redirects to `office-raccoon://auth/callback?code=…&state=…`
        // once the account confirms. AppDelegate forwards that URL into
        // `RaccoonOAuthManager`, which resolves the continuation created here.
        try await RaccoonCallbackBroker.shared.begin(expectedState: state)
        defer { RaccoonCallbackBroker.shared.cancel() }

        let page = try authorizeURL(state: state)
        present(page)

        let parameters = try await RaccoonCallbackBroker.shared.waitForCallback()
        try checkCallbackError(parameters)
        let code = try callbackCode(parameters, expectedState: state)
        let exchanged = try await exchange(authCode: code)
        return (exchanged.access, exchanged.refresh, exchanged.expires, exchanged.officeIdentity, exchanged.officeOrgName, exchanged.officeOrgRole)
    }

    /// The page's own scheme; the desktop client registers it and the page
    /// hands the one-time code back through it.
    static let callbackScheme = "office-raccoon"
    static let callbackHost = "auth"

    /// Builds the authorisation page URL.
    ///
    /// Only `login_source`, `appname` and `state` are sent. The page is
    /// server-rendered and validates these: adding `redirect` +
    /// `desktop_callback=loopback` makes it render `context: null`, i.e.
    /// "授权链接无效，请从客户端重新发起登录。" — it accepts no loopback
    /// address at all in the current build. The code comes back through the
    /// registered `office-raccoon://auth/callback` scheme instead.
    static func authorizeURL(state: String) throws -> URL {
        var components = URLComponents(string: origin + authorizePath)
        components?.queryItems = [
            URLQueryItem(name: "login_source", value: loginSource),
            URLQueryItem(name: "appname", value: appName),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else {
            throw RaccoonLoginError("The Raccoon sign-in address could not be built.")
        }
        return url
    }

    static func callbackCode(_ parameters: [String: String], expectedState: String) throws -> String {
        let code = (parameters["code"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw RaccoonLoginError("The Raccoon page did not return a sign-in code. Sign in again.")
        }
        if let state = parameters["state"], !state.isEmpty, state != expectedState {
            throw RaccoonLoginError("The Raccoon page returned another sign-in's code. Sign in again.")
        }
        return code
    }

    struct Exchanged: Sendable {
        var access: String
        var refresh: String
        var officeIdentity: String
        var officeOrgName: String
        var officeOrgRole: String
        var expires: Date?
    }

    static func exchange(authCode: String) async throws -> Exchanged {
        guard let url = URL(string: authBase + "/login_with_authorization_code") else {
            throw RaccoonLoginError("The Raccoon token address could not be read.")
        }
        let body: [String: Any] = ["authorization_code": authCode]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw RaccoonLoginError("The Raccoon sign-in request could not be built.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (answer, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard answer.count <= 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
        else {
            throw RaccoonLoginError("The Raccoon sign-in answer could not be read (HTTP \(status)).")
        }
        if let failure = envelopeError(root) {
            throw RaccoonLoginError(failure == "200035"
                ? "This Raccoon sign-in code was already used. Sign in again."
                : "The Raccoon sign-in was refused: \(failure)")
        }
        guard status == 200 else {
            throw RaccoonLoginError("The Raccoon sign-in failed (HTTP \(status)).")
        }
        let result = (root["data"] ?? root["Data"]) as? [String: Any] ?? root
        guard let access = firstString(result, ["access_token", "accessToken"]), !access.isEmpty else {
            throw RaccoonLoginError("The Raccoon sign-in returned no token. Sign in again.")
        }
        return Exchanged(
            access: access,
            refresh: firstString(result, ["refresh_token", "refreshToken"]) ?? "",
            officeIdentity: firstString(result, ["office_identity", "officeIdentity"]) ?? "",
            officeOrgName: firstString(result, ["office_org_name", "officeOrgName"]) ?? "",
            officeOrgRole: firstString(result, ["office_org_role", "officeOrgRole"]) ?? "",
            expires: expiry(result["expires_at"] ?? result["expiresAt"]),
        )
    }

    static func randomState() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func envelopeError(_ root: [String: Any]) -> String? {
        for key in ["Message", "message", "Error", "error"] {
            if let v = root[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let v = object[key] as? String, !v.isEmpty { return v }
        }
        for key in keys {
            if let v = object[key] as? NSNumber { return v.stringValue }
        }
        return nil
    }

    static func expiry(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let n = raw as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        if let s = raw as? String, let v = Double(s) { return Date(timeIntervalSince1970: v) }
        return nil
    }

    static func checkCallbackError(_ parameters: [String: String]) throws {
        if let error = parameters["error"], !error.isEmpty {
            throw RaccoonLoginError("Raccoon sign-in failed: \(error)")
        }
    }
}

struct RaccoonLoginError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
