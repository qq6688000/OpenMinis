import Foundation
import os.log

private let logger = AppLogger(category: "TraeAgent")

/// AgentProvider implementation that wraps TraeProvider for the unified agent loop.
///
/// Trae's wire protocol (`llm_utils_chat`) is a custom SSE dialect, not
/// OpenAI Chat Completions. TraeProvider speaks it and emits `LLMStreamChunk`;
/// this adapter carries tool definitions up and maps returned `tool_calls`
/// into the agent loop's `AgentStreamEvent`.
final class TraeAgentProvider: AgentProvider {

    let provider: TraeProvider

    var name: String { provider.name }
    var model: LLMModel { provider.model }
    var defaultMaxTokens: Int { 16_384 }

    init(provider: TraeProvider) {
        self.provider = provider
    }

    // MARK: - Message conversion

    /// Trae takes OpenAI-shaped messages: assistant turns may carry
    /// `tool_calls`, and tool output comes back as `role: "tool"`.
    private static func convertMessages(_ messages: [AgentMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for message in messages {
            var text = ""
            var calls: [[String: Any]] = []
            var results: [[String: Any]] = []

            for part in message.parts {
                switch part {
                case .text(let t):
                    text += t
                case .toolUse(let id, let name, let input, _):
                    let args = (try? JSONSerialization.data(withJSONObject: input))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    calls.append([
                        "id": id,
                        "type": "function",
                        "function": ["name": name, "arguments": args],
                    ])
                case .toolResult(let id, let name, let content, _, _, _, _, _, _):
                    results.append([
                        "role": "tool",
                        "tool_call_id": id,
                        "name": name,
                        "content": content,
                    ])
                default:
                    break
                }
            }

            // Tool results go first: they answer the previous assistant turn.
            out.append(contentsOf: results)

            if message.role == .user {
                if !text.isEmpty { out.append(["role": "user", "content": text]) }
            } else if !text.isEmpty || !calls.isEmpty {
                var entry: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty { entry["tool_calls"] = calls }
                out.append(entry)
            }
        }
        return out
    }

    /// OpenAI-shaped tool schemas; `TraeProvider.mendTools` renders the
    /// `parameters` string form this wire requires.
    private static func convertTools(_ tools: [AgentToolDefinition]) -> [[String: Any]] {
        tools.map { tool in
            var properties: [String: Any] = [:]
            for (name, param) in tool.parameters {
                if let schema = param.schema {
                    var prop = schema.jsonSchema(uppercaseTypes: false, bounds: false)
                    prop["description"] = param.description
                    properties[name] = prop
                    continue
                }
                var prop: [String: Any] = [
                    "type": param.type.rawValue,
                    "description": param.description,
                ]
                if let enumValues = param.enumValues { prop["enum"] = enumValues }
                properties[name] = prop
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": "object",
                        "properties": properties,
                        "required": tool.required,
                    ],
                ],
            ]
        }
    }

    // MARK: - Stream

    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let converted = Self.convertMessages(messages)
        let toolSchemas = tools.isEmpty ? nil : Self.convertTools(tools)

        let raw = try await provider.streamChat(
            messages: converted,
            systemPrompt: systemPrompt,
            toolSchemas: toolSchemas,
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedTextStart = false
                do {
                    for try await event in raw {
                        switch event {
                        case .text(let text):
                            if !emittedTextStart {
                                continuation.yield(.contentBlockStart(.text))
                                emittedTextStart = true
                            }
                            continuation.yield(.textDelta(text))
                        case .toolCall(let call):
                            let callId = call.id.isEmpty ? UUID().uuidString : call.id
                            continuation.yield(.contentBlockStart(.toolUse(id: callId, name: call.name)))
                            let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                            continuation.yield(.toolCallComplete(
                                id: callId,
                                name: call.name,
                                args: args,
                                metadata: nil
                            ))
                        case .usage(let u):
                            continuation.yield(.usage(u))
                        case .finished(let reason):
                            continuation.yield(.done(stopReason: reason))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
