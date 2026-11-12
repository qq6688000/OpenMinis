import Foundation
import os.log

private let logger = AppLogger(category: "RaccoonOAuth")

/// Bridges the `office-raccoon://` URL the system delivers to the app with the
/// async sign-in that is waiting for it.
///
/// Raccoon's authorisation page only accepts its own scheme as the callback —
/// a loopback `redirect` renders `context: null` ("授权链接无效"). So the flow
/// can't listen on a socket; it registers the scheme in Info.plist, and
/// `AppDelegate` hands the incoming URL here.
final class RaccoonCallbackBroker: @unchecked Sendable {
    static let shared = RaccoonCallbackBroker()
    private init() {}

    private let lock = NSLock()
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var expectedState: String?
    private var delivered: Result<[String: String], Error>?

    /// True when the URL belongs to this flow.
    static func handles(_ url: URL) -> Bool {
        url.scheme?.lowercased() == RaccoonOAuthLogin.callbackScheme
    }

    /// Arms the broker for one sign-in attempt.
    func begin(expectedState: String) {
        lock.withLock {
            self.expectedState = expectedState
            delivered = nil
        }
    }

    func cancel() {
        let continuation: CheckedContinuation<[String: String], Error>? = lock.withLock {
            let c = waiter
            waiter = nil
            expectedState = nil
            return c
        }
        continuation?.resume(throwing: CancellationError())
    }

    func waitForCallback() async throws -> [String: String] {
        if let delivered = lock.withLock({ self.delivered }) {
            return try delivered.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            let already: Result<[String: String], Error>? = lock.withLock {
                if let delivered { return delivered }
                waiter = continuation
                return nil
            }
            if let already { continuation.resume(with: already) }
        }
    }

    /// Called from the app's URL handler. Parses the query and wakes the waiter.
    @discardableResult
    func deliver(_ url: URL) -> Bool {
        guard Self.handles(url) else { return false }
        var parameters: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }
        let result: Result<[String: String], Error>
        if parameters.isEmpty {
            result = .failure(RaccoonLoginError("The Raccoon callback carried no parameters."))
        } else {
            result = .success(parameters)
        }
        let continuation: CheckedContinuation<[String: String], Error>? = lock.withLock {
            guard waiter != nil else {
                delivered = result
                return nil
            }
            let c = waiter
            waiter = nil
            return c
        }
        logger.info("[RaccoonOAuth] callback received (keys: \(parameters.keys.sorted()))")
        continuation?.resume(with: result)
        return true
    }
}
