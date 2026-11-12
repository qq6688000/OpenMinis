// [T-trae] Trae browser sign-in, ported from Apelin's TraeOAuth.
//
// Trae's sign-in is a PKCE loopback flow: build the authorization URL on the
// build's sign-in page, open it in the browser, bind a local listener on the
// `/authorize` callback, exchange the returned `authCodeInfo` for a token via
// `ExchangeToken`, then store the credentials.
import CryptoKit
import Foundation
import Network

/// The two Trae builds: mainland-China and international.
enum TraeLoginProfile {
    static let china = Profile(
        site: .china,
        fixedLoginHost: "https://www.trae.cn",
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
        exchangeOrigins: ["https://api.trae.cn"],
    )

    static let international = Profile(
        site: .international,
        fixedLoginHost: nil,
        guidanceURLs: [
            "https://api.marscode.com/cloudide/api/v3/trae/GetLoginGuidance",
            "https://api.trae.ai/cloudide/api/v3/trae/GetLoginGuidance",
            "https://www.trae.ai/cloudide/api/v3/trae/GetLoginGuidance",
        ],
        pluginVersion: "local",
        appVersion: "3.5.54",
        appType: "stable",
        deviceBrand: "unknown",
        osInfo: "unknown",
        osVersion: "unknown",
        channelName: nil,
        deviceIdentity: .uuid,
        fixedDeviceID: "0",
        exchangeOrigins: [
            "https://grow-normal.trae.ai",
            "https://growsg-normal.trae.ai",
            "https://grow-normal.traeapi.us",
            "https://api.marscode.com",
            "https://api.trae.ai",
            "https://www.trae.ai",
        ],
    )

    static func of(_ site: TraeSite) -> Profile {
        site == .china ? TraeLoginProfile.china : TraeLoginProfile.international
    }

    struct Profile: Sendable {
        var site: TraeSite
        var fixedLoginHost: String?
        var guidanceURLs: [String]
        var pluginVersion: String
        var appVersion: String
        var appType: String
        var deviceBrand: String
        var osInfo: String
        var osVersion: String
        var channelName: String?
        var deviceIdentity: DeviceIdentity
        var fixedDeviceID: String?
        var exchangeOrigins: [String]
    }

    enum DeviceIdentity: Sendable {
        case uuid
        case hex64
    }
}

/// The loopback listener the Trae page calls back to.
final class TraeLoopback: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var listeningContinuation: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var answered: Result<[String: String], Error>?
    private var stopped = false

    static let callbackPath = "/authorize"

    var redirectURI: String {
        "http://127.0.0.1:\(lock.withLock { boundPort ?? 0 })\(TraeLoopback.callbackPath)"
    }

    func listen() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw TraeLoginError("The Trae sign-in could not open its local address.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let refused: Bool = lock.withLock {
                if stopped { return true }
                listeningContinuation = continuation
                self.listener = listener
                return false
            }
            if refused {
                continuation.resume(throwing: CancellationError())
                return
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.resolveListening(port: listener.port?.rawValue, error: nil)
                case .failed:
                    self.resolveListening(port: nil, error: TraeLoginError("The Trae sign-in could not open its local address."))
                case .cancelled:
                    self.resolveListening(port: nil, error: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    func waitForCallback() async throws -> [String: String] {
        if let answered = lock.withLock({ self.answered }) {
            return try answered.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            let refused: Bool = lock.withLock {
                if stopped {
                    return true
                }
                waiter = continuation
                return false
            }
            if refused {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            listener?.cancel()
            listener = nil
        }
    }

    private func resolveListening(port: UInt16?, error: Error?) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            if error != nil {
                let c = listeningContinuation
                listeningContinuation = nil
                return c
            }
            boundPort = port
            let c = listeningContinuation
            listeningContinuation = nil
            return c
        }
        if let error {
            c?.resume(throwing: error)
        } else {
            c?.resume()
        }
    }

    // MARK: - Requests

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "trae-signin"))
        receive(connection, collected: Data())
    }

    private func receive(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
            guard let self else {
                connection.cancel()
                return
            }
            var collected = collected
            if let data { collected.append(data) }
            if let separator = collected.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: collected[..<separator.lowerBound], as: UTF8.self)
                self.respond(connection, to: head)
                return
            }
            if ended || error != nil || collected.count > 65536 {
                connection.cancel()
                return
            }
            self.receive(connection, collected: collected)
        }
    }

    private func respond(_ connection: NWConnection, to head: String) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.first ?? ""
        let target = parts.count > 1 ? parts[1] : "/"
        let components = URLComponents(string: "http://127.0.0.1" + target)
        let path = components?.path ?? ""
        var parameters: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }
        if method == "OPTIONS" {
            write(connection, status: "204 No Content", body: "")
            return
        }
        guard path == TraeLoopback.callbackPath else {
            write(connection, status: "404 Not Found", body: "Not found")
            return
        }
        guard parameters["authCodeInfo"] != nil || parameters["refreshToken"] != nil
            || parameters["code"] != nil || parameters["error"] != nil
        else {
            write(connection, status: "400 Bad Request", body: "No sign-in payload")
            return
        }
        write(connection, status: "200 OK", body: "<html><body><h3>Signed in to Trae</h3><p>You can close this tab.</p></body></html>")
        resolve(.success(parameters))
    }

    private func write(_ connection: NWConnection, status: String, body: String) {
        let bytes = Array(body.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bytes.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Access-Control-Allow-Methods: GET,POST,OPTIONS\r\n"
            + "Access-Control-Allow-Headers: content-type\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(Data(bytes))
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func resolve(_ result: Result<[String: String], Error>) {
        let continuation: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard answered == nil else { return nil }
            answered = result
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

struct TraeLoginError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}


// MARK: - PKCE

enum TraePKCE {
    static func random() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64URL(Data(bytes))
        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URL(Data(hash))
        return (verifier, challenge)
    }

    static func randomHex(bytes: Int) -> String {
        var data = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &data)
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - OAuth client

enum TraeOAuthClient {
    static let authorizationPath = "/authorization"
    static let authExchangePath = "/trae/api/v3/oauth/ExchangeToken"
    static let clientID = "ono9krqynydwx5"
    static let loginRedirect = "0"

    static func login(
        profile: TraeLoginProfile.Profile,
        present: @escaping (URL) -> Void,
    ) async throws -> (access: String, refresh: String, expireAt: Date?, userID: String, machineID: String, deviceID: String, origin: String) {
        let listener = TraeLoopback()
        try await listener.listen()
        defer { listener.stop() }

        let pkce = TraePKCE.random()
        let machineID = profile.deviceIdentity == .uuid
            ? UUID().uuidString
            : TraePKCE.randomHex(bytes: 32)
        let deviceID = profile.fixedDeviceID ?? randomDeviceID()
        let loginTraceID = UUID().uuidString

        let loginHost = try await signInHost(profile: profile, loginTraceID: loginTraceID)
        let page = try loginURL(
            loginHost: loginHost,
            redirect: listener.redirectURI,
            machineID: machineID,
            deviceID: deviceID,
            loginTraceID: loginTraceID,
            pkce: pkce,
            profile: profile,
        )
        present(page)
        let parameters = try await listener.waitForCallback()
        try checkCallbackError(parameters)
        let payload = try callbackPayload(parameters)

        let exchanged = try await exchange(
            authCode: payload.authCode,
            codeVerifier: pkce.verifier,
            machineID: machineID,
            deviceID: deviceID,
            profile: profile,
        )
        let userID = payload.userID.isEmpty ? jwtUserID(exchanged.access) : payload.userID
        return (exchanged.access, exchanged.refresh, exchanged.expires, userID, machineID, deviceID, exchanged.origin)
    }

    // MARK: - WKWebView flow (no loopback listener, no Safari jump)

    struct AuthContext: Sendable {
        let profile: TraeLoginProfile.Profile
        let pkceVerifier: String
        let machineID: String
        let deviceID: String
        let authURL: URL
    }

    /// Builds the authorization URL for an in-app WebView. The redirect points
    /// at a dummy loopback address — the WebView's navigation delegate
    /// intercepts it before any real request is made.
    static func buildAuthURL(profile: TraeLoginProfile.Profile) async throws -> AuthContext {
        let pkce = TraePKCE.random()
        let machineID = profile.deviceIdentity == .uuid
            ? UUID().uuidString
            : TraePKCE.randomHex(bytes: 32)
        let deviceID = profile.fixedDeviceID ?? randomDeviceID()
        let loginTraceID = UUID().uuidString
        let loginHost = try await signInHost(profile: profile, loginTraceID: loginTraceID)
        let redirect = "http://127.0.0.1:1" + TraeLoopback.callbackPath
        let page = try loginURL(
            loginHost: loginHost,
            redirect: redirect,
            machineID: machineID,
            deviceID: deviceID,
            loginTraceID: loginTraceID,
            pkce: pkce,
            profile: profile,
        )
        return AuthContext(profile: profile, pkceVerifier: pkce.verifier, machineID: machineID, deviceID: deviceID, authURL: page)
    }

    /// Processes the callback URL intercepted by the WebView: extracts the
    /// auth code, exchanges it for a token, and returns the credentials.
    static func processCallback(url: URL, context: AuthContext) async throws -> (access: String, refresh: String, expireAt: Date?, userID: String, machineID: String, deviceID: String, origin: String) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var parameters: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }
        try checkCallbackError(parameters)
        let payload = try callbackPayload(parameters)
        let exchanged = try await exchange(
            authCode: payload.authCode,
            codeVerifier: context.pkceVerifier,
            machineID: context.machineID,
            deviceID: context.deviceID,
            profile: context.profile,
        )
        let userID = payload.userID.isEmpty ? jwtUserID(exchanged.access) : payload.userID
        return (exchanged.access, exchanged.refresh, exchanged.expires, userID, context.machineID, context.deviceID, exchanged.origin)
    }

    static func signInHost(profile: TraeLoginProfile.Profile, loginTraceID: String) async throws -> String {
        if let fixed = profile.fixedLoginHost { return fixed }
        var failures: [String] = []
        for address in profile.guidanceURLs {
            guard let url = URL(string: address) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "loginTraceID": loginTraceID,
                    "login_trace_id": loginTraceID,
                ])
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, data.count <= 1024 * 1024,
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let host = guidanceHost(root), !host.isEmpty
                else {
                    failures.append("\(address): no sign-in host")
                    continue
                }
                return host
            } catch {
                failures.append("\(address): \(error.localizedDescription)")
            }
        }
        throw TraeLoginError("The Trae sign-in page could not be found. \(failures.joined(separator: " · "))")
    }

    static func guidanceHost(_ root: [String: Any]) -> String? {
        for key in ["Result", "result", "data"] {
            if let layer = root[key] as? [String: Any],
               let host = firstString(layer, ["LoginHost", "loginHost", "LoginURL", "loginUrl"]) {
                return host
            }
        }
        return firstString(root, ["LoginHost", "loginHost", "loginUrl"])
    }

    static func loginURL(
        loginHost: String,
        redirect: String,
        machineID: String,
        deviceID: String,
        loginTraceID: String,
        pkce: (verifier: String, challenge: String),
        profile: TraeLoginProfile.Profile,
    ) throws -> URL {
        guard let origin = origin(of: loginHost) else {
            throw TraeLoginError("The Trae sign-in page address could not be read.")
        }
        var components = URLComponents(string: origin + authorizationPath)
        var items = [
            URLQueryItem(name: "login_version", value: "1"),
            URLQueryItem(name: "auth_from", value: "trae"),
            URLQueryItem(name: "login_channel", value: "native_ide"),
            URLQueryItem(name: "plugin_version", value: profile.pluginVersion),
            URLQueryItem(name: "auth_type", value: "local"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect", value: loginRedirect),
            URLQueryItem(name: "login_trace_id", value: loginTraceID),
            URLQueryItem(name: "auth_callback_url", value: redirect),
            URLQueryItem(name: "machine_id", value: machineID),
            URLQueryItem(name: "device_id", value: deviceID),
            URLQueryItem(name: "x_device_id", value: deviceID),
            URLQueryItem(name: "x_machine_id", value: machineID),
            URLQueryItem(name: "x_device_brand", value: profile.deviceBrand),
            URLQueryItem(name: "x_device_type", value: profile.osInfo),
            URLQueryItem(name: "x_os_version", value: profile.osVersion),
            URLQueryItem(name: "x_env", value: ""),
            URLQueryItem(name: "x_app_version", value: profile.appVersion),
            URLQueryItem(name: "x_app_type", value: profile.appType),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let channelName = profile.channelName {
            items.append(URLQueryItem(name: "channel_name", value: channelName))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw TraeLoginError("The Trae sign-in address could not be built.")
        }
        return url
    }

    struct Callback: Sendable {
        var authCode: String
        var userID: String
        var loginTraceID: String
        var loginHost: String
    }

    static func callbackPayload(_ parameters: [String: String]) throws -> Callback {
        guard let raw = parameters["authCodeInfo"], !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw TraeLoginError("The Trae sign-in callback did not carry an auth code.")
        }
        let code = firstString(root, ["AuthCode", "authCode", "Code", "code"]) ?? ""
        guard !code.isEmpty else {
            throw TraeLoginError("The Trae sign-in callback did not carry an auth code.")
        }
        let userInfo = root["userInfo"] as? [String: Any] ?? root
        return Callback(
            authCode: code,
            userID: firstString(userInfo, ["UserID", "userId", "UID", "uid"]) ?? "",
            loginTraceID: parameters["loginTraceID"] ?? parameters["login_trace_id"] ?? "",
            loginHost: parameters["loginHost"] ?? parameters["LoginHost"] ?? ""
        )
    }

    struct Exchanged: Sendable {
        var access: String
        var refresh: String
        var boundDeviceID: String
        var expires: Date?
        var origin: String
    }

    static func exchange(
        authCode: String,
        codeVerifier: String,
        machineID: String,
        deviceID: String,
        profile: TraeLoginProfile.Profile,
    ) async throws -> Exchanged {
        let body: [String: Any] = [
            "ClientID": clientID,
            "AuthCode": authCode,
            "CodeVerifier": codeVerifier,
            "DeviceInfo": deviceInfo(machineID: machineID, deviceID: deviceID, profile: profile),
            "IDEVersion": profile.appVersion,
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw TraeLoginError("The Trae sign-in request could not be built.")
        }
        var failures: [String] = []
        for origin in profile.exchangeOrigins {
            guard let url = URL(string: origin + authExchangePath) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("", forHTTPHeaderField: "x-cloudide-token")
                request.timeoutInterval = 8
                request.httpBody = payload
                let (answer, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard answer.count <= 1024 * 1024,
                      let root = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
                else {
                    failures.append("\(origin): unreadable answer (HTTP \(status))")
                    continue
                }
                if let failure = envelopeError(root) {
                    failures.append("\(origin): \(failure)")
                    continue
                }
                guard status == 200 else {
                    failures.append("\(origin): HTTP \(status)")
                    continue
                }
                let result = (root["Result"] ?? root["result"]) as? [String: Any] ?? root
                guard let access = firstString(result, ["Token", "token", "AccessToken", "accessToken", "access_token"]),
                      !access.isEmpty
                else {
                    failures.append("\(origin): no token")
                    continue
                }
                return Exchanged(
                    access: access,
                    refresh: firstString(result, ["RefreshToken", "refreshToken", "refresh_token"]) ?? "",
                    boundDeviceID: firstString(result, ["BoundDeviceID", "BoundDeviceId", "boundDeviceId"]) ?? "",
                    expires: expiry(result["TokenExpireAt"] ?? result["tokenExpireAt"] ?? result["ExpiresAt"] ?? result["expiresAt"]),
                    origin: origin
                )
            } catch {
                failures.append("\(origin): \(error.localizedDescription)")
            }
        }
        throw TraeLoginError("The Trae sign-in could not be completed. \(failures.joined(separator: " · "))")
    }

    static func deviceInfo(machineID: String, deviceID: String, profile: TraeLoginProfile.Profile) -> [String: Any] {
        [
            "DeviceID": deviceID,
            "MachineID": machineID,
            "PlatformCode": "IDE_PC",
            "DeviceType": "1",
            "DeviceName": "iPhone",
            "DeviceModel": profile.deviceBrand.isEmpty ? "Apple" : profile.deviceBrand,
            "ClientVersion": profile.appVersion,
            "DevicePublicKey": P256.Signing.PrivateKey().publicKey.pemRepresentation,
            "DeviceBrand": profile.deviceBrand.isEmpty ? "Apple" : profile.deviceBrand,
            "DeviceCPU": "",
            "OSInfo": profile.osInfo,
            "OSVersion": profile.osVersion,
        ]
    }

    static func randomDeviceID() -> String {
        TraePKCE.randomHex(bytes: 16)
    }

    static func origin(of address: String) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)"
    }

    static func jwtUserID(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return "" }
        let padded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - padded.count % 4) % 4
        let b64 = padded + String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "" }
        return firstString(obj, ["userId", "UserID", "uid", "UID"]) ?? ""
    }

    static func expiry(_ raw: Any?) -> Date? {
        guard let raw else { return nil }
        if let n = raw as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        if let s = raw as? String, let v = Double(s) { return Date(timeIntervalSince1970: v) }
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

    static func envelopeError(_ root: [String: Any]) -> String? {
        // AWS-style envelope: { ResponseMetadata: { Error: { Code, Message } } }
        if let meta = root["ResponseMetadata"] as? [String: Any],
           let err = meta["Error"] as? [String: Any] {
            let code = (err["Code"] as? NSNumber)?.intValue
                ?? Int(err["Code"] as? String ?? "")
            if code != nil, code != 0 || (err["Message"] as? String)?.isEmpty == false {
                return (err["Message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (code.map { "code \($0)" })
            }
        }
        // flat envelope
        for key in ["Code", "code", "ErrCode", "errCode"] {
            guard let value = root[key] else { continue }
            let code: Int? = if let number = value as? NSNumber {
                number.intValue
            } else if let text = value as? String {
                Int(text)
            } else {
                nil
            }
            guard let code, code != 0 else { continue }
            let message = firstString(root, ["Message", "message", "Msg", "msg", "ErrMsg", "errMsg"])
            return message ?? "code \(code)"
        }
        if let error = root["Error"] as? String ?? root["error"] as? String, !error.isEmpty {
            return error
        }
        for key in ["Message", "message"] {
            if let v = root[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    static func checkCallbackError(_ parameters: [String: String]) throws {
        if let error = parameters["error"], !error.isEmpty {
            throw TraeLoginError("Trae sign-in failed: \(error)")
        }
    }
}
