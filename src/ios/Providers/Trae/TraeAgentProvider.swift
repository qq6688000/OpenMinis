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

    /// Trae's reasoning models can think for a minute or more before the
    /// first token, which brushes against the 120s default watchdog. Allow
    /// more idle time so a slow-but-alive stream isn't cut off.
    var responseIdleTimeout: TimeInterval { 240 }

    init(provider: TraeProvider) {
        self.provider = provider
    }

    // MARK: - Message conversion

    /// Trae's `llm_utils_chat` takes `content` as an array of text blocks and
    /// calls as `function_call` (NOT OpenAI's `tool_calls`) — sending the
    /// OpenAI shape answers 400 `bad request: json: ...`.
    private static func textBlocks(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": text]]
    }

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
                        "content": textBlocks(content),
                    ])
                default:
                    break
                }
            }

            // Order matters: the assistant turn carrying `function_call` must
            // come FIRST, then its `tool` results. Reversing them leaves the
            // call unpaired and Trae silently stops responding.
            if message.role == .user {
                if !text.isEmpty {
                    out.append(["role": "user", "content": textBlocks(text)])
                }
            } else if !text.isEmpty || !calls.isEmpty {
                var entry: [String: Any] = ["role": "assistant", "content": textBlocks(text)]
                if !calls.isEmpty { entry["function_call"] = calls }
                out.append(entry)
            }
            out.append(contentsOf: results)
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
        logger.info("[TraeWire] request messages(\(converted.count)): \(String(describing: converted.map { ($0["role"] as? String) ?? "?" }))")
        if let last = converted.last {
            logger.info("[TraeWire] last message keys: \(String(describing: Array(last.keys)))")
        }

        let raw = try await provider.streamChat(
            messages: converted,
            systemPrompt: systemPrompt,
            toolSchemas: toolSchemas,
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedTextStart = false
                // Repetition guard on the ACCUMULATED answer. DeepSeek-V4
                // occasionally collapses on long arithmetic-heavy turns: it
                // restates the same paragraph verbatim (often after emitting a
                // stray token such as `</thread>`), burning the whole turn and
                // filling the context with duplicates. Sample a fixed-size
                // tail each time the answer grows past the next bucket; three
                // identical samples in a row means a loop.
                var accumulated = ""
                var repeats = 0
                var lastSample = ""
                var nextSampleAt = 400
                func checkRepeat(_ chunk: String) {
                    accumulated += chunk
                    guard accumulated.count >= nextSampleAt else { return }
                    nextSampleAt += 200
                    let tail = String(accumulated.suffix(200))
                    if tail == lastSample {
                        repeats += 1
                    } else {
                        repeats = 0
                        lastSample = tail
                    }
                }
                do {
                    for try await event in raw {
                        switch event {
                        case .reasoning(let text):
                            continuation.yield(.thinkingDelta(text))
                        case .text(let text):
                            checkRepeat(text)
                            if repeats >= 2 {
                                logger.warning("[TraeWire] repetition loop on accumulated text — aborting turn")
                                throw LLMError.providerError(
                                    message: "The model started repeating itself (stuck in a loop). Stopped this turn to save tokens — try asking it to compute step by step with a tool instead of in its head.")
                            }
                            if !emittedTextStart {
                                continuation.yield(.contentBlockStart(.text))
                                emittedTextStart = true
                            }
                            continuation.yield(.textDelta(text))
                        case .toolCall(let call):
                            let callId = call.id.isEmpty ? UUID().uuidString : call.id
                            continuation.yield(.contentBlockStart(.toolUse(id: callId, name: call.name)))
                            var args: [String: Any] = [:]
                            if let parsed = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] {
                                args = parsed
                            } else {
                                logger.info("[TraeWire] tool args unparsable(\(call.name)) raw=\(call.arguments.prefix(300))")
                                // Never hand the executor an empty object: fall
                                // back to the raw text so the failure names the
                                // real problem instead of "arguments empty".
                                args = ["_raw": call.arguments]
                            }
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
