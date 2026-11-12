import Foundation
import os.log

/// One tool call the model emitted on Trae's wire.
struct TraeToolCall: Sendable {
    var id: String
    var name: String
    var arguments: String
}

extension TraeProvider {

    /// Builds Trae's chat body including tool definitions.
    ///
    /// This wire needs `parameters` as a JSON *string*, not an object —
    /// mending it any other way makes the validator answer `4001`.
    static func buildBody(
        messages: [[String: Any]],
        systemPrompt: String?,
        model: String,
        tools: [[String: Any]]? = nil
    ) -> [String: Any] {
        var msgs: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            msgs.append(["role": "system", "content": [["type": "text", "text": systemPrompt]]])
        }
        msgs.append(contentsOf: messages)

        var body: [String: Any] = [
            "app_id": "6eefa01c-1036-4c7e-9ca5-d891f63bfcd8",
            "app_version_code": 20260820,
            "function": "solo_work_remote",
            "model": model,
            "config_name": model,
            "stream": true,
            "messages": msgs,
        ]
        if let tools, !tools.isEmpty {
            body["tools"] = mendTools(tools)
        }
        return body
    }

    /// `parameters` is a JSON *string* on this wire, not an object.
    static func mendTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool in
            guard var function = tool["function"] as? [String: Any] else { return nil }
            if let parameters = function["parameters"], !(parameters is NSNull),
               let data = try? JSONSerialization.data(withJSONObject: parameters),
               let text = String(data: data, encoding: .utf8) {
                function["parameters"] = text
            } else {
                function["parameters"] = #"{"type":"object","properties":{}}"#
            }
            return ["type": "function", "function": function]
        }
    }
}
