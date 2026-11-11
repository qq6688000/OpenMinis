import Foundation
import os.log

private let logger = AppLogger(category: "TraeAgent")

/// AgentProvider implementation that wraps TraeProvider for the unified agent loop.
///
/// Trae's wire protocol (`llm_utils_chat`) is a custom SSE dialect, not
/// OpenAI Chat Completions. TraeProvider already speaks it and emits
/// `LLMStreamChunk` (text / usage / finished). This adapter maps those to the
/// agent loop's `AgentStreamEvent`.
final class TraeAgentProvider: AgentProvider {

    let provider: TraeProvider

    var name: String { provider.name }
    var model: LLMModel { provider.model }
    var defaultMaxTokens: Int { 16_384 }

    init(provider: TraeProvider) {
        self.provider = provider
    }

    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        // Trae's chat endpoint takes a flat text/message list. Flatten each
        // AgentMessage to a single "user"/"assistant" text block (no tool
        // parts in this provider; tool support is a later enhancement).
        let llmMessages: [LLMMessage] = messages.compactMap { msg in
            var text = ""
            for part in msg.parts {
                if case .text(let t) = part {
                    text += t
                }
            }
            guard !text.isEmpty || msg.role == .user else { return nil }
            return LLMMessage(
                role: msg.role == .user ? .user : .assistant,
                content: text
            )
        }

        let llmStream: AsyncThrowingStream<LLMStreamChunk, Error>
        do {
            llmStream = try await provider.streamMessage(
                messages: llmMessages,
                systemPrompt: systemPrompt,
                maxTokens: maxTokens,
                temperature: nil
            )
        } catch {
            throw error
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedTextStart = false
                do {
                    for try await chunk in llmStream {
                        switch chunk {
                        case .started:
                            break
                        case .text(let text):
                            if !emittedTextStart {
                                continuation.yield(.contentBlockStart(.text))
                                emittedTextStart = true
                            }
                            continuation.yield(.textDelta(text))
                        case .usage(let u):
                            continuation.yield(.usage(u))
                        case .finished(let reason):
                            continuation.yield(.done(stopReason: reason == "max_tokens" ? .maxTokens : .endTurn))
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
