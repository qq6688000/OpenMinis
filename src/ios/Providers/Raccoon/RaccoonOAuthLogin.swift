// [T-raccoon] Raccoon browser sign-in: loopback + authorization-code exchange.
// Ported from Apelin's RaccoonOAuth.
import Foundation
import Network

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
        let listener = RaccoonLoopback()
        try await listener.listen()
        defer { listener.stop() }
        let page = try authorizeURL(state: state, redirect: listener.redirectURI)
        present(page)
        let parameters = try await listener.waitForCallback()
        try checkCallbackError(parameters)
        let code = try callbackCode(parameters, expectedState: state)
        let exchanged = try await exchange(authCode: code)
        return (exchanged.access, exchanged.refresh, exchanged.expires, exchanged.officeIdentity, exchanged.officeOrgName, exchanged.officeOrgRole)
    }

    static func authorizeURL(state: String, redirect: String) throws -> URL {
        var components = URLComponents(string: origin + authorizePath)
        components?.queryItems = [
            URLQueryItem(name: "login_source", value: loginSource),
            URLQueryItem(name: "appname", value: appName),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect", value: redirect),
            URLQueryItem(name: "desktop_callback", value: "loopback"),
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

/// Loopback listener for the Raccoon `/auth/callback` redirect.
final class RaccoonLoopback: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var listeningContinuation: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var answered: Result<[String: String], Error>?
    private var stopped = false

    var redirectURI: String {
        "http://127.0.0.1:\(lock.withLock { boundPort ?? 0 })\(RaccoonOAuthLogin.callbackPath)"
    }

    func listen() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw RaccoonLoginError("The Raccoon sign-in could not open its local address.")
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
                    self.resolveListening(port: nil, error: RaccoonLoginError("The Raccoon sign-in could not open its local address."))
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
                if stopped { return true }
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

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "raccoon-signin"))
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
        guard path == RaccoonOAuthLogin.callbackPath else {
            write(connection, status: "404 Not Found", body: "Not found")
            return
        }
        guard parameters["code"] != nil || parameters["error"] != nil else {
            write(connection, status: "400 Bad Request", body: "No sign-in payload")
            return
        }
        write(connection, status: "200 OK", body: "<html><body><h3>Signed in to Raccoon</h3><p>You can close this tab.</p></body></html>")
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
