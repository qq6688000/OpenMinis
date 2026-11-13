import Foundation
import os.log

private let qoderWireLogger = AppLogger(category: "QoderWire")

// [T-qoder] QoderProvider — Qoder IDE (CN) 的聊天实现。
//
// Qoder 与 Trae 同源：chat 端点同为 `POST {origin}/api/agent/v3/llm_utils_chat`
// 的专用 SSE 协议（`output` / `token_usage` / `done` / `error` 帧），鉴权同为
// `Authorization: Cloud-IDE-JWT <token>`。区别只在 host（gateway.qoder.com.cn）
// 与必须携带的 `machineId` 头。因此这里直接复用 `TraeProvider` 的静态 SSE
// 解析器（同协议），只重写请求构造部分。
final class QoderProvider: LLMProvider, TraeWireProvider {
    let name: String
    var model: LLMModel
    let site: QoderSite
    let instanceId: String

    typealias ChatEvent = TraeProvider.ChatEvent

    init(model: LLMModel, site: QoderSite, instanceId: String) {
        self.name = site.displayName
        self.model = model
        self.site = site
        self.instanceId = instanceId
    }

    // MARK: - LLMProvider

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        var text = ""
        var usage: LLMUsage?
        var stopReason: String?
        let stream = try await streamMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
        for try await chunk in stream {
            switch chunk {
            case .text(let t): text += t
            case .usage(let u): usage = u
            case .finished(let r): stopReason = r
            default: break
            }
        }
        return LLMResponse(text: text, stopReason: stopReason, usage: usage)
    }

    func streamChat(
        messages: [[String: Any]],
        systemPrompt: String?,
        toolSchemas: [[String: Any]]?
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let token = try await QoderOAuthManager.shared.validAccessToken(instanceId: instanceId)
        let url = try chatURL()
        let body = Self.buildAgentBody(
            messages: messages,
            systemPrompt: systemPrompt,
            model: model.id,
            appID: site.appID,
            tools: toolSchemas
        )
        let request = try await makeRequest(url: url, token: token, body: body)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                        throw LLMError.providerError(message: "Qoder \(status): \(msg.prefix(240))")
                    }
                    try TraeProvider.parseChatSSE(data: data) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    if let urlError = error as? URLError, !Task.isCancelled {
                        continuation.finish(throwing: LLMError.networkError(underlying: urlError))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let token = try await QoderOAuthManager.shared.validAccessToken(instanceId: instanceId)
        let url = try chatURL()
        let body = Self.buildBody(
            messages: messages, systemPrompt: systemPrompt,
            model: model.id, appID: site.appID,
            maxTokens: maxTokens, temperature: temperature)
        let request = try await makeRequest(url: url, token: token, body: body)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                        throw LLMError.providerError(message: "Qoder \(status): \(msg.prefix(240))")
                    }
                    try TraeProvider.parseSSE(data: data) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    if let urlError = error as? URLError, !Task.isCancelled {
                        continuation.finish(throwing: LLMError.networkError(underlying: urlError))
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    func chatURL() throws -> URL {
        guard let url = URL(string: site.gatewayBase + "/api/agent/v3/llm_utils_chat") else {
            throw LLMError.providerError(message: "Qoder: invalid chat URL")
        }
        return url
    }

    private func makeRequest(url: URL, token: String, body: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Cloud-IDE-JWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(site.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(site.ideVersion, forHTTPHeaderField: "x-ide-version")
        request.setValue(site.ideVersionCode, forHTTPHeaderField: "x-ide-version-code")
        if let uid = QoderOAuthManager.shared.userID(instanceId: instanceId) {
            request.setValue(uid, forHTTPHeaderField: "X-Uid")
        }
        // Qoder 必需：设备指纹，否则拒答 ("missing account machine id")。
        if let mid = QoderOAuthManager.shared.machineID(instanceId: instanceId) {
            request.setValue(mid, forHTTPHeaderField: "X-Machine-Id")
            request.setValue(mid, forHTTPHeaderField: "machineId")
        }
        return request
    }

    /// Plain-text body (LLMProvider path).
    static func buildBody(
        messages: [LLMMessage],
        systemPrompt: String?,
        model: String,
        appID: String,
        maxTokens: Int,
        temperature: Double?
    ) -> [String: Any] {
        var msgs: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            msgs.append(["role": "system", "content": [["type": "text", "text": systemPrompt]]])
        }
        for message in messages {
            switch message.role {
            case .user:
                msgs.append(["role": "user", "content": [["type": "text", "text": message.content]]])
            case .assistant:
                msgs.append(["role": "assistant", "content": [["type": "text", "text": message.content]]])
            }
        }
        return [
            "app_id": appID,
            "app_version_code": 20260820,
            "function": "solo_work_remote",
            "model": model,
            "config_name": model,
            "stream": true,
            "messages": msgs,
        ]
    }

    /// Agent body with tool schemas (OpenAI-ish dict messages from the loop).
    static func buildAgentBody(
        messages: [[String: Any]],
        systemPrompt: String?,
        model: String,
        appID: String,
        tools: [[String: Any]]?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "app_id": appID,
            "app_version_code": 20260820,
            "function": "solo_work_remote",
            "model": model,
            "config_name": model,
            "stream": true,
            "messages": messages,
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        if let systemPrompt, !systemPrompt.isEmpty {
            body["system_prompt"] = systemPrompt
        }
        return body
    }
}
