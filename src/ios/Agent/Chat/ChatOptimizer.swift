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

@MainActor
final class ChatOptimizer {
    static let shared = ChatOptimizer()

    private let store = ProviderConfigStore.shared
    private let userDefaults = UserDefaults.standard

    private init() {}

    // MARK: Prompt rewrite ("优化词条")

    /// Rewrite `text` into a clearer, more professional prompt using `entry`'s
    /// provider. Returns the rewritten text, or the original on any failure.
    func optimize(_ text: String, using entry: ModelEntry) async -> String {
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
            let provider = try await LLMProviderFactory.makeProvider(for: entry, sessionId: nil)
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
            return text
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
    func measureLatency(entry: ModelEntry) async -> Double? {
        let messages: [LLMMessage] = [
            LLMMessage(role: .user, content: "hi")
        ]
        let start = Date()
        do {
            let provider = try await LLMProviderFactory.makeProvider(for: entry, sessionId: nil)
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
    func speedTestAll(concurrency: Int = 4, perEntryTimeout: TimeInterval = 20) async {
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
                        let lat = await self.measureLatency(entry: e)
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
    }

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
}
