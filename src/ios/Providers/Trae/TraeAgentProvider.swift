import Foundation
import os.log

private let logger = AppLogger(category: "TraeAgent")

/// AgentProvider implementation that wraps TraeProvider for the unified agent loop.
///
/// Trae's wire protocol (`llm_utils_chat`) is a custom SSE dialect, not
/// OpenAI Chat Completions. TraeProvider speaks it and emits `LLMStreamChunk`;
/// this adapter carries tool definitions up and maps returned `tool_calls`
/// into the agent loop's `AgentStreamEvent`.
/// Minimal wire surface shared by TraeProvider and MeooProvider (both speak a
/// non-OpenAI SSE chat dialect and emit `TraeProvider.ChatEvent`).
protocol TraeWireProvider: AnyObject {
    var name: String { get }
    var model: LLMModel { get }
    func streamChat(
        messages: [[String: Any]],
        systemPrompt: String?,
        toolSchemas: [[String: Any]]?
    ) async throws -> AsyncThrowingStream<TraeProvider.ChatEvent, Error>
}

extension TraeProvider: TraeWireProvider {}

final class TraeAgentProvider: AgentProvider {

    let provider: TraeWireProvider

    var name: String { provider.name }
    var model: LLMModel { provider.model }
    var defaultMaxTokens: Int { 16_384 }

    /// Trae's reasoning models can think for a minute or more before the
    /// first token, which brushes against the 120s default watchdog. Allow
    /// more idle time so a slow-but-alive stream isn't cut off.
    var responseIdleTimeout: TimeInterval { 240 }

    init(provider: TraeWireProvider) {
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
                // Repetition guard. DeepSeek-V4 collapses on long
                // arithmetic-heavy turns: after a stray token (typically
                // `</thread>`) it restates the same paragraph, over and over,
                // until the turn burns out. Two shapes need catching:
                //   1. one tiny fragment repeated (the stray token itself)
                //   2. a longer paragraph repeated verbatim
                // A tail comparison misses (1) because the loop interleaves
                // other text, so count fragment repeats in a sliding window.
                var recentFragments: [String] = []
                var fragmentCounts: [String: Int] = [:]
                var accumulated = ""
                var lastTail = ""
                var tailRepeats = 0

                /// Returns a human-readable reason when the model is looping.
                func loopReason() -> String? {
                    if let top = fragmentCounts.max(by: { $0.value < $1.value }),
                       top.value >= 5, top.key.count >= 3 {
                        return "fragment \(top.key.prefix(40)) ×\(top.value)"
                    }
                    if accumulated.count >= 600 {
                        let tail = String(accumulated.suffix(300))
                        if tail == lastTail {
                            tailRepeats += 1
                            if tailRepeats >= 2 { return "paragraph repeated \(tailRepeats + 1)×" }
                        } else {
                            tailRepeats = 0
                            lastTail = tail
                        }
                    }
                    return nil
                }

                func note(_ chunk: String) {
                    accumulated += chunk
                    let key = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard key.count >= 3 else { return }
                    recentFragments.append(key)
                    fragmentCounts[key, default: 0] += 1
                    if recentFragments.count > 40 {
                        let dropped = recentFragments.removeFirst()
                        let remaining = (fragmentCounts[dropped] ?? 1) - 1
                        if remaining <= 0 {
                            fragmentCounts[dropped] = nil
                        } else {
                            fragmentCounts[dropped] = remaining
                        }
                    }
                }
                do {
                    for try await event in raw {
                        switch event {
                        case .reasoning(let text):
                            continuation.yield(.thinkingDelta(text))
                        case .text(let text):
                            note(text)
                            if let reason = loopReason() {
                                logger.warning("[TraeWire] repetition loop (\(reason)) — aborting turn")
                                throw LLMError.providerError(
                                    message: "The model started repeating itself (\(reason)). Stopped this turn to save tokens — try asking it to compute with a tool instead of in its head.")
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
