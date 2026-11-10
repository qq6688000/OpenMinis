//
//  ChatOptimizer.swift
//  Minis — chat helpers: prompt rewrite ("优化词条"), latency speed-test,
//  auto-pick fastest model, auto-switch when a model becomes unavailable,
//  and 10s-no-first-token auto-retry.
//
//  All entry points are @MainActor: ProviderConfigStore, LLMProviderFactory,
//  AIChatViewModel and the View all live on the main actor.

import Foundation

// MARK: - Settings keys (UserDefaults via @AppStorage elsewhere)

enum ChatOptimizerSettings {
    /// Rewrite the composer text into a clearer prompt before sending.
    static let optimizePromptEnabled = "chatOptimizer.optimizePromptEnabled"
    /// Speed-test models and auto-pick the lowest-latency entry when the user
    /// has not pinned a specific model for the session.
    static let autoPickFastest = "chatOptimizer.autoPickFastest"
    /// When the active model becomes unavailable, silently switch to another
    /// available entry instead of failing.
    static let autoSwitchUnavailable = "chatOptimizer.autoSwitchUnavailable"
    /// If no first token arrives within `timeoutSeconds`, auto-retry once.
    static let autoRetryOnTimeout = "chatOptimizer.autoRetryOnTimeout"
    static let timeoutSeconds: TimeInterval = 10
    /// Latency cache: entryId -> best measured first-token latency (seconds).
    static let latencyCacheKey = "chatOptimizer.latencyCache"
}

// MARK: - Latency cache

struct ModelLatencyCache: Codable {
    var entries: [String: Double] = [:]
}

/// Errors surfaced by `ChatOptimizer`.
enum ChatOptimizerError: LocalizedError {
    case rewriteFailed(underlying: Error)
    var errorDescription: String? {
        switch self {
        case .rewriteFailed(let underlying):
            return String(format: NSLocalizedString("提示词优化失败：%@", comment: "optimize rewrite failure"), underlying.localizedDescription)
        }
    }
}

@MainActor
final class ChatOptimizer {
    static let shared = ChatOptimizer()

    private let store = ProviderConfigStore.shared
    private let userDefaults = UserDefaults.standard

    private init() {}

    // MARK: Prompt rewrite ("优化词条")

    /// Rewrite `text` into a clearer, more professional prompt using `entry`'s
    /// provider. Returns the rewritten text, or the original on any failure.
    ///
    /// - Parameter sessionId: the live conversation session id. OpenCode-family
    ///   channels (WorkBuddy, OpenCode, OpenRouter, …) **require** a non-nil
    ///   session id on every request — calling with `nil` is a hard 400 from the
    ///   upstream ("missing x-opencode-session"). Always pass the real session id.
    /// - Throws: `ChatOptimizerError.rewriteFailed` when the rewrite request
    ///   fails, so the caller can surface a visible error to the user instead of
    ///   silently returning the original text.
    func optimize(_ text: String, using entry: ModelEntry, sessionId: String?) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let system = """
        你是一个提示词优化助手。请把用户给出的原始指令改写成更清晰、更专业、\
        更易于大模型理解的提示词。要求：
        - 保留用户真实意图，不要改变任务本身；
        - 补充必要的结构（如目标、约束、输出格式、语气）；
        - 删除口语化废话；
        - 直接输出优化后的提示词，不要解释、不要前后缀。
        """

        let messages: [LLMMessage] = [
            LLMMessage(role: .user, content: trimmed)
        ]

        do {
            // Use a per-request session id resolver so a nil/draft id (or a
            // draft→real promotion that happens before this call) is resolved at
            // request-build time — exactly like the live conversation path. This
            // avoids the OpenCode 400 that the old `sessionId: nil` snapshot hit.
            let provider = try await LLMProviderFactory.makeProvider(for: entry, resolveSessionId: { sessionId })
            let resp = try await provider.sendMessage(
                messages: messages,
                systemPrompt: system,
                maxTokens: 1024,
                temperature: 0.2
            )
            let out = resp.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? trimmed : out
        } catch {
            AppLogger(category: "ChatOptimizer").warning("[optimize] rewrite failed: \(error.localizedDescription)")
            throw ChatOptimizerError.rewriteFailed(underlying: error)
        }
    }

    // MARK: Latency speed-test

    private func readLatencyCache() -> ModelLatencyCache {
        guard let data = userDefaults.data(forKey: ChatOptimizerSettings.latencyCacheKey),
              let c = try? JSONDecoder().decode(ModelLatencyCache.self, from: data) else {
            return ModelLatencyCache()
        }
        return c
    }

    private func writeLatencyCache(_ cache: ModelLatencyCache) {
        if let data = try? JSONEncoder().encode(cache) {
            userDefaults.set(data, forKey: ChatOptimizerSettings.latencyCacheKey)
        }
    }

    /// All entries that are usable: instance enabled, has credentials,
    /// not hidden, and not currently reported absent by the provider.
    func availableEntries() -> [ModelEntry] {
        var result: [ModelEntry] = []
        for instance in store.instances where instance.isEnabled && instance.hasAnyCredential {
            for entry in store.visibleEntries(for: instance.id) {
                guard !entry.isUnavailableFromProvider else { continue }
                result.append(entry)
            }
        }
        return result
    }

    /// Measure first-token latency for one entry using a tiny prompt.
    /// Returns seconds, or nil on failure.
    /// `sessionId` must be a real session for OpenCode-routed models; pass nil
    /// only for providers that don't need one (most will fail without it).
    func measureLatency(entry: ModelEntry, sessionId: String?) async -> Double? {
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, content: "hi")
        ]
        let start = Date()
        do {
            let provider = try await LLMProviderFactory.makeProvider(for: entry, sessionId: sessionId)
            // Use the streaming path so we can capture time-to-first-token.
            let stream = try await provider.streamMessage(
                messages: messages,
                systemPrompt: nil,
                maxTokens: 4,
                temperature: 0
            )
            for try await chunk in stream {
                if case .text(let t) = chunk, !t.isEmpty {
                    return Date().timeIntervalSince(start)
                }
            }
            // Stream ended with no text — treat as a (slow) miss.
            return nil
        } catch {
            AppLogger(category: "ChatOptimizer").info("[latency] \(entry.id) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Speed-test every available entry (respecting an overall budget), update
    /// the cache with the best latency seen per entry.
    func speedTestAll(sessionId: String?, concurrency: Int = 4, perEntryTimeout: TimeInterval = 20) async {
        let entries = availableEntries()
        guard !entries.isEmpty else { return }
        let cache = readLatencyCache()
        var updated = cache

        // Run with a bounded concurrency using a simple actor-free serial loop
        // with TaskGroup-equivalent manual pacing: we cap simultaneous in-flight.
        await withTaskGroup(of: (String, Double?).self) { group in
            var idx = 0
            var inFlight = 0
            // Seed the group up to concurrency.
            func pump() {
                while idx < entries.count, inFlight < concurrency {
                    let e = entries[idx]; idx += 1; inFlight += 1
                    group.addTask {
                        let lat = await self.measureLatency(entry: e, sessionId: sessionId)
                        return (e.id, lat)
                    }
                }
            }
            pump()
            for await (id, lat) in group {
                inFlight -= 1
                if let lat = lat { updated.entries[id] = lat }
                pump()
            }
        }
        writeLatencyCache(updated)
        // Notify UI so the model picker badges repaint with fresh latencies.
        NotificationCenter.default.post(name: ChatOptimizer.latencyUpdatedNotification, object: nil)
    }

    /// Posted after a background speed test finishes so list rows can refresh.
    static let latencyUpdatedNotification = Notification.Name("chatOptimizer.latencyUpdated")

    /// The fastest available entry per the latency cache, or nil if untested.
    func fastestEntry() -> ModelEntry? {
        let cache = readLatencyCache()
        let entries = availableEntries()
        guard !cache.entries.isEmpty else { return nil }
        return entries.min(by: { (a, b) -> Bool in
            let la = cache.entries[a.id] ?? Double.greatestFiniteMagnitude
            let lb = cache.entries[b.id] ?? Double.greatestFiniteMagnitude
            return la < lb
        })
    }

    /// Ensure the active entry is still usable; if not and auto-switch is on,
    /// return a replacement entry. Returns nil when no switch is needed.
    func replacementIfUnavailable(_ active: ModelEntry?) -> ModelEntry? {
        guard let active = active else { return nil }
        // Still good?
        if let inst = store.instance(for: active.providerInstanceId),
           inst.isEnabled, inst.hasAnyCredential, !active.isHidden, !active.isUnavailableFromProvider {
            return nil
        }
        // Find another available entry (prefer same instance, then any).
        let others = availableEntries().filter { $0.id != active.id }
        if let sameInstance = others.first(where: { $0.providerInstanceId == active.providerInstanceId }) {
            return sameInstance
        }
        return others.first
    }

    // MARK: - Auto-pick / auto-switch wiring

    /// Switch a session's primary binding to the given entry (direct entry, no
    /// group), preserving any existing sub-model binding. Persists via
    /// `ProviderConfigStore.setBinding` and bumps `configRevision` so the VM's
    /// `resolveCurrentEntry` cache re-resolves on the next access.
    private func bindSession(_ sessionId: String, to entry: ModelEntry) {
        let existing = store.binding(for: sessionId)
        let binding = SessionModelBinding(
            sessionId: sessionId,
            primarySource: .directEntry(modelEntryId: entry.id),
            subModelSource: existing?.subModelSource
        )
        store.setBinding(binding, for: sessionId)
        // Keep the session row's displayed model id in sync.
        Task {
            await ChatStore.shared.updateSessionModelId(sessionId, modelId: entry.model.id)
        }
        NotificationCenter.default.post(
            name: .sessionModelBindingChanged,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }

    /// Resolve the current entry for a session, honoring the live binding.
    private func currentEntry(for sessionId: String) -> ModelEntry? {
        guard let binding = store.binding(for: sessionId) else { return nil }
        let entryId: String
        switch binding.primarySource {
        case .directEntry(let eid, _): entryId = eid
        case .group(_, let eid): entryId = eid
        }
        return store.entry(for: entryId)
    }

    /// True when the user has explicitly pinned a model for this session
    /// (a direct-entry binding). When the binding routes through the default
    /// group — i.e. the user never picked a specific model — auto-pick may
    /// override it.
    private func isManuallyPinned(for sessionId: String) -> Bool {
        guard let binding = store.binding(for: sessionId) else { return false }
        if case .directEntry = binding.primarySource { return true }
        return false
    }

    /// Whether `autoPickFastest` is enabled (AppStorage-backed UserDefaults).
    private var autoPickFastestEnabled: Bool {
        UserDefaults.standard.bool(forKey: ChatOptimizerSettings.autoPickFastest)
    }

    /// Whether `autoSwitchUnavailable` is enabled (AppStorage-backed UserDefaults).
    private var autoSwitchUnavailableEnabled: Bool {
        UserDefaults.standard.bool(forKey: ChatOptimizerSettings.autoSwitchUnavailable)
    }

    /// Apply the auto-pick-fastest and auto-switch-unavailable rules before a
    /// send. Called from the composer's `performSend` (on @MainActor) with the
    /// session id that this turn will use. Returns true if a binding change was
    /// applied (the resolve cache will re-resolve automatically because
    /// `setBinding` bumps `configRevision`).
    ///
    /// - Parameters:
    ///   - sessionId: the resolved session id (caller must `ensureSession` first).
    ///   - beforeSpeedTest: synchronous hook run when the cache is empty and we
    ///     trigger a one-shot background speed test; lets the caller decide
    ///     whether to block the send.
    ///   - speedTest: async speed-test function (defaults to `speedTestAll`).
    /// - Returns: true if the active binding was changed.
    @discardableResult
    func applyAutoRules(
        sessionId: String,
        beforeSpeedTest: (() -> Void)? = nil,
        speedTest: (@Sendable () async -> Void)? = nil
    ) async -> Bool {
        guard !sessionId.isEmpty else { return false }
        var changed = false

        // 1) Auto-switch unavailable: if the current entry is unusable, swap it.
        if autoSwitchUnavailableEnabled {
            let active = currentEntry(for: sessionId)
            if let replacement = replacementIfUnavailable(active) {
                bindSession(sessionId, to: replacement)
                changed = true
                AppLogger(category: "ChatOptimizer").info("[autoSwitch] session=\(sessionId.prefix(8)) switched \(active?.id ?? "nil") → \(replacement.id)")
            }
        }

        // 2) Auto-pick fastest: only when the user has NOT pinned a specific model.
        if autoPickFastestEnabled, !isManuallyPinned(for: sessionId) {
            let cache = readLatencyCache()
            if cache.entries.isEmpty {
                // No latency data yet: kick off a background speed test (non-blocking)
                // and don't change the binding this turn.
                beforeSpeedTest?()
                if let speedTest {
                    Task { await speedTest() }
                } else {
                    Task { await self.speedTestAll(sessionId: sessionId) }
                }
            } else if let fastest = fastestEntry() {
                let active = currentEntry(for: sessionId)
                if active?.id != fastest.id {
                    bindSession(sessionId, to: fastest)
                    changed = true
                    AppLogger(category: "ChatOptimizer").info("[autoPick] session=\(sessionId.prefix(8)) picked fastest \(fastest.id) (was \(active?.id ?? "nil"))")
                }
            }
        }

        return changed
    }

    /// Ensure latency data exists; if empty, run a (non-blocking) speed test.
    /// Safe to call from app launch / picker appear. No-op if already populated.
    /// `sessionId` is a real session used so OpenCode-routed models can be tested.
    func ensureLatencyDataOnce(sessionId: String?) async {
        guard readLatencyCache().entries.isEmpty else { return }
        await speedTestAll(sessionId: sessionId)
    }

    /// Public read-only view of the latency cache for UI (model picker badges).
    var latencyCache: ModelLatencyCache {
        readLatencyCache()
    }
}
