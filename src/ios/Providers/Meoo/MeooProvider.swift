import Foundation

// [T-meoo] Meoo (秒悟) 项目 Agent 聊天。
//
// 秒悟没有面向第三方账号的模型聊天 OAuth；网页聊天走同源
// `/api/v1/agent/*`，用网页登录会话 Cookie 鉴权。本 provider 复用该
// Cookie（来自 `MeooLoginSheet` 登录后持久化的 `MeooTokenStorage`），
// 直接对 `https://meoo.com` 发起同源请求（Cookie 放 header，绕过 CORS
// 与跨进程 WebView 问题）。
//
// 链路：`ensure`（拿 projectId）→ `queue/enqueue`（拿 taskId）→
// `/api/agent/build/run`（SSE：`BUILD_PROGRESS` 增量输出，`BUILD_COMPLETE`
// 结束）。模型列表来自 `/api/v1/agent/models`。

/// 秒悟同源 SSE/JSON 客户端。
final class MeooSSEClient {
    let site: MeooSite
    private let cookie: String

    init(site: MeooSite, cookie: String) {
        self.site = site
        self.cookie = cookie
    }

    // MARK: - Request helpers

    private func makeURL(_ path: String) -> URL {
        URL(string: site.webBase + path)!
    }

    private var baseHeaders: [String: String] {
        [
            "Cookie": cookie,
            "Accept": "application/json, text/event-stream",
        ]
    }

    /// 确保存在一个项目，返回 projectId。秒悟网页在首次对话前会
    /// `POST /api/v1/project/ensure`，body 含应用名/描述。
    func ensureProject(name: String = "Minis Chat") async throws -> String {
        var req = URLRequest(url: makeURL("/api/v1/project/ensure"))
        req.httpMethod = "POST"
        req.allHTTPHeaderFields = baseHeaders
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "description": "Created by Minis",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.providerError(message: "Meoo ensure failed (HTTP \(httpStatus(resp)))")
        }
        // 常见响应：{ data: { project_id } } 或 { project_id }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = (json["data"] as? [String: Any])?["project_id"] as? String
            ?? json["project_id"] as? String {
            return pid
        }
        // 若接口接受 name 但返回空，用固定 id 占位（后端可能已用 name 解析）。
        return "minis-chat-default"
    }

    /// 入队一条消息，返回 taskId。
    func enqueue(projectId: String, content: String, model: String) async throws -> String {
        var req = URLRequest(url: makeURL(site.enqueuePath))
        req.httpMethod = "POST"
        req.allHTTPHeaderFields = baseHeaders
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "projectId": projectId,
            "content": content,
            "model": model,
            "message_owner": "user",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.providerError(message: "Meoo enqueue failed (HTTP \(httpStatus(resp)))")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let task = json["taskId"] as? String ?? (json["data"] as? [String: Any])?["taskId"] as? String {
            return task
        }
        throw LLMError.providerError(message: "Meoo enqueue returned no taskId")
    }

    /// 运行任务并流式读取 SSE，把 `BUILD_PROGRESS` 的 `output` 回调给
    /// onDelta，`BUILD_COMPLETE` 结束。返回最终文本。
    func run(projectId: String, taskId: String, onDelta: @escaping (String) -> Void) async throws -> String {
        var req = URLRequest(url: makeURL(site.runPath))
        req.httpMethod = "POST"
        req.allHTTPHeaderFields = baseHeaders
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "projectId": projectId,
            "taskId": taskId,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.providerError(message: "Meoo run failed (HTTP \(httpStatus(resp)))")
        }
        return try parseSSE(data, onDelta: onDelta)
    }

    /// 解析秒悟 SSE：`BUILD_PROGRESS` 的 `data.output` 增量；`BUILD_COMPLETE` 结束。
    func parseSSE(_ data: Data, onDelta: (String) -> Void) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        var full = ""
        for block in text.components(separatedBy: "\n\n") {
            for line in block.components(separatedBy: "\n") {
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                let type = json["type"] as? String ?? ""
                if type == "BUILD_PROGRESS" || type == "build_progress" {
                    if let d = json["data"] as? [String: Any] {
                        if let out = d["output"] as? String, !out.isEmpty {
                            full += out
                            onDelta(out)
                        } else if let msg = d["message"] as? String, !msg.isEmpty {
                            full += msg
                            onDelta(msg)
                        }
                    }
                } else if type == "BUILD_COMPLETE" || type == "build_complete" {
                    break
                } else if type == "error" || (json["error"] != nil) {
                    if let m = json["message"] as? String { throw LLMError.providerError(message: m) }
                }
            }
        }
        return full
    }

    private func httpStatus(_ resp: URLResponse?) -> Int {
        (resp as? HTTPURLResponse)?.statusCode ?? -1
    }
}

/// [T-meoo] LLMProvider：包装 `MeooSSEClient`，产出流式 chunk。
final class MeooProvider: LLMProvider, TraeWireProvider {
    let name = "Meoo"
    var model: LLMModel
    private let site: MeooSite
    private let instanceId: String

    init(model: LLMModel, site: MeooSite, instanceId: String) {
        self.model = model
        self.site = site
        self.instanceId = instanceId
    }

    private func currentCookie() throws -> String {
        guard let st = ProviderKeychainHelper.loadOAuthToken(instanceId: instanceId, as: MeooTokenStorage.self),
              !st.cookie.isEmpty else {
            throw LLMError.providerError(message: "Meoo: 未登录，请在供应商页点「登录 Meoo」")
        }
        return st.cookie
    }

    func sendMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> LLMResponse {
        var text = ""
        let stream = try await streamMessage(
            messages: messages, systemPrompt: systemPrompt,
            maxTokens: maxTokens, temperature: temperature)
        for try await chunk in stream {
            if case .text(let t) = chunk { text += t }
        }
        return LLMResponse(text: text, stopReason: nil, usage: nil)
    }

    func streamMessage(
        messages: [LLMMessage],
        systemPrompt: String?,
        maxTokens: Int,
        temperature: Double?
    ) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let cookie = try currentCookie()
                    let client = MeooSSEClient(site: site, cookie: cookie)
                    // 取最后一条用户消息作为 content。
                    let content = messages.last?.content ?? messages.map(\.content).joined(separator: "\n")
                    let pid = try await client.ensureProject()
                    let task = try await client.enqueue(projectId: pid, content: content, model: model.id)
                    continuation.yield(.started)
                    let final = try await client.run(projectId: pid, taskId: task) { delta in
                        continuation.yield(.text(delta))
                    }
                    if !final.isEmpty {
                        continuation.yield(.usage(LLMUsage(inputTokens: 0, outputTokens: 0, cacheCreationInputTokens: nil, cacheReadInputTokens: nil)))
                    }
                    continuation.yield(.finished(stopReason: "stop"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - TraeWireProvider (agent loop reuse)

    func streamChat(
        messages: [[String: Any]],
        systemPrompt: String?,
        toolSchemas: [[String: Any]]?
    ) async throws -> AsyncThrowingStream<TraeProvider.ChatEvent, Error> {
        // 秒悟 Agent 暂不支持工具调用；把消息转成纯文本流。
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let cookie = try currentCookie()
                    let client = MeooSSEClient(site: site, cookie: cookie)
                    let content = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
                    let pid = try await client.ensureProject()
                    let task = try await client.enqueue(projectId: pid, content: content, model: model.id)
                    let final = try await client.run(projectId: pid, taskId: task) { delta in
                        continuation.yield(.text(delta))
                    }
                    if !final.isEmpty {
                        continuation.yield(.finished(.endTurn))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
