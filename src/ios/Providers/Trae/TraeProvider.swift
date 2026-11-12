import Foundation

// [T-trae] TraeProvider — implements LLMProvider for ByteDance's Trae IDE.
//
// Trae's chat surface is `POST {origin}/api/agent/v3/llm_utils_chat`, a
// non-OpenAI SSE wire: the request body takes `app_id`, `function`,
// `config_name` and messages as text blocks, and responses arrive as
// `event: output {response, reasoning_content, tool_calls}` /
// `token_usage` / `done {finish_reason}` / `error {code, message}` frames.
//
// This is a port of Apelin's `TraeWire` (translated + mending), adapted to
// OpenMinis' `LLMProvider` protocol. Authentication is `Authorization:
// Cloud-IDE-JWT <token>` supplied by `TraeOAuthManager`.
final class TraeProvider: LLMProvider {
    let name: String
    var model: LLMModel
    let site: TraeSite
    let instanceId: String

    init(model: LLMModel, site: TraeSite, instanceId: String) {
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
        // Trae only streams; gather the stream into a single response.
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

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let token = try await TraeOAuthManager.shared.validAccessToken(instanceId: instanceId)
        let url = try chatURL()
        let body = try Self.buildBody(messages: messages, systemPrompt: systemPrompt,
                                      model: model.id, maxTokens: maxTokens, temperature: temperature)
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Cloud-IDE-JWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Trae/0.1.61", forHTTPHeaderField: "User-Agent")
        // These three version values are one set: the gate matches its
        // configuration table against them together.
        request.setValue("0.1.61", forHTTPHeaderField: "x-ide-version")
        request.setValue("20260820", forHTTPHeaderField: "x-ide-version-code")
        if let uid = await TraeOAuthManager.shared.userID(instanceId: instanceId) {
            request.setValue(uid, forHTTPHeaderField: "X-Uid")
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        let msg = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                        throw LLMError.providerError(message: "Trae \(status): \(msg.prefix(240))")
                    }
                    try Self.parseSSE(data: data) { line in
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - URL / body

    func chatURL() throws -> URL {
        // `remoteBase` already ends in `/api/remote/v1`; the agent chat path
        // hangs off the bare origin, so strip the suffix before appending.
        var base = site.remoteBase
        if let range = base.range(of: "/api/remote/v1") {
            base = String(base[base.startIndex..<range.lowerBound])
        }
        guard let url = URL(string: base + "/api/agent/v3/llm_utils_chat") else {
            throw LLMError.providerError(message: "Trae: invalid chat URL")
        }
        return url
    }

    /// Trae's request body. Ported from Apelin's `TraeWire.mending`.
    static func buildBody(
        messages: [LLMMessage],
        systemPrompt: String?,
        model: String,
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
                // Trae takes assistant content as text blocks; empty content is
                // an empty block (upstream validator accepts it).
                msgs.append(["role": "assistant", "content": [["type": "text", "text": message.content]]])
            }
        }
        var body: [String: Any] = [
            "app_id": "6eefa01c-1036-4c7e-9ca5-d891f63bfcd8",
            "app_version_code": 20260820,
            // `solo_work_remote` carries every user-selectable model; asking
            // through `solo_work_lite` answers `4001 param is invalid` for
            // models like glm-5.3 that only the remote roster publishes.
            "function": "solo_work_remote",
            "model": model,
            "config_name": model,
            "stream": true,
            "messages": msgs,
        ]
        return body
    }

    // MARK: - SSE parsing

    /// Parse Trae's SSE stream, yielding OpenMinis chunks. Ported from Apelin's
    /// `TraeWire.translated`.
    static func parseSSE(data: Data, yield: @escaping (LLMStreamChunk) -> Void) throws {
        // SSE frames are separated by double newlines.
        let text = String(data: data, encoding: .utf8) ?? ""
        for frame in text.components(separatedBy: "\n\n") {
            var event = "output"
            var payload = ""
            for line in frame.components(separatedBy: "\n") {
                if line.hasPrefix("event:") {
                    event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    payload += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !payload.isEmpty,
                  let root = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
            else { continue }

            // A queue refusal arrives as a 200 frame carrying its own status.
            if let status = root["statusCodeValue"] as? Int, status != 200 {
                let bodyText = String(describing: root["body"] ?? "")
                throw LLMError.providerError(message: "Trae \(status): \(bodyText.prefix(240))")
            }

            switch event {
            case "error":
                let code = root["code"].map { String(describing: $0) } ?? ""
                let message = root["message"] as? String ?? "unknown"
                throw LLMError.providerError(message: "Trae \(code.isEmpty ? "error" : "code \(code)"): \(message)")
            case "token_usage":
                if let usage = usage(from: root) { yield(.usage(usage)) }
            case "done":
                yield(.finished(stopReason: finishReason(root["finish_reason"] as? String)))
            case "output":
                if let reasoning = root["reasoning_content"] as? String, !reasoning.isEmpty {
                    yield(.text(reasoning))  // surface reasoning as text (best-effort)
                }
                if let response = root["response"] as? String, !response.isEmpty {
                    yield(.text(response))
                }
                // tool_calls ignored for now (OpenMinis LLMProvider has no tool channel here)
            default:
                break
            }
        }
    }

    static func usage(from root: [String: Any]) -> LLMUsage? {
        let usage = root["usage"] as? [String: Any] ?? root
        let input = intValue(usage["input_tokens"] ?? usage["prompt_tokens"])
        let output = intValue(usage["output_tokens"] ?? usage["completion_tokens"])
        guard let input, let output else { return nil }
        return LLMUsage(inputTokens: input, outputTokens: output,
                        cacheCreationInputTokens: nil, cacheReadInputTokens: nil)
    }

    static func finishReason(_ raw: String?) -> String? {
        let reason = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        switch reason {
        case "", "stop", "end": return "stop"
        case "length", "max_tokens": return "length"
        case "tool_calls", "function_call": return "tool_calls"
        default: return reason.isEmpty ? nil : reason
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
