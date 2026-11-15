// =============================================================================
// DatabricksClient.swift — the app's single Databricks connection.
//
// Fixed workspace + endpoint (no connect screen). The access token and SQL
// warehouse ID come from ios/Secrets.xcconfig (git-ignored) via Info.plist.
//
//   Chat model : visense-chat (Model Serving / AI Gateway)
//   Database   : SQL Statement Execution API on a SQL warehouse (DatabricksSQL.swift)
// =============================================================================
import Foundation

struct ChatMessage: Codable, Hashable {
    var role: String       // "system" | "user" | "assistant"
    var content: String
}

enum DatabricksConfig {
    static let host = URL(string: "https://dbc-2a25625f-05c4.cloud.databricks.com")!
    static let endpoint = "workspace.default.visense-chat"
    static let catalog = "workspace"
    static let schema = "visense"

    static var token: String { plist("DatabricksToken") }
    static var warehouseID: String { plist("DatabricksWarehouseID") }

    static var isConfigured: Bool { !token.isEmpty && !warehouseID.isEmpty }

    private static func plist(_ key: String) -> String {
        var v = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "").trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("$(") { v = "" }             // unset xcconfig variable
        // Mac-side tests (no Info.plist): DatabricksToken -> env DATABRICKS_TOKEN etc.
        if v.isEmpty, let env = ProcessInfo.processInfo.environment[key == "DatabricksToken" ? "DATABRICKS_TOKEN" : "DATABRICKS_WAREHOUSE_ID"] {
            v = env
        }
        return v
    }
}

enum DatabricksError: LocalizedError {
    case notConfigured, badURL, http(Int, String), noAnswer
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Databricks token / warehouse ID missing: fill in ios/Secrets.xcconfig and rebuild."
        case .badURL: return "The workspace URL looks wrong. Example: https://adb-1234567890.12.azuredatabricks.net"
        case .http(let code, let body):
            switch code {
            case 401, 403: return "Databricks rejected the token (\(code)). Check ios/Secrets.xcconfig."
            case 404: return "Not found (404): check the endpoint name / warehouse ID."
            case 429: return "Rate limited by Databricks (429). Wait a moment and retry."
            default: return "Databricks error \(code): \(body.prefix(200))"
            }
        case .noAnswer: return "The model returned no answer."
        }
    }
}

enum DatabricksClient {
    /// Which API worked last time, so we don't retry the wrong one on every question.
    private static var useGateway = UserDefaults.standard.bool(forKey: "db.useGateway") {
        didSet { UserDefaults.standard.set(useGateway, forKey: "db.useGateway") }
    }

    /// Ask the model. Tries the classic endpoint API and the newer AI Gateway
    /// "Responses" API (whichever this workspace's endpoint speaks).
    static func chat(_ messages: [ChatMessage], maxTokens: Int = 600) async throws -> String {
        guard !DatabricksConfig.token.isEmpty else { throw DatabricksError.notConfigured }
        let base = DatabricksConfig.host
        let name = DatabricksConfig.endpoint
        let token = DatabricksConfig.token

        let order = useGateway ? [true, false] : [false, true]
        var failures: [(code: Int, body: String)] = []
        for gateway in order {
            do {
                let answer = gateway
                    ? try await responsesAPI(base, name, token, messages, maxTokens)
                    : try await invocationsAPI(base, name, token, messages, maxTokens)
                useGateway = gateway
                return answer
            } catch DatabricksError.http(let code, let body) where code == 404 || code == 400 {
                failures.append((code, body))      // wrong API for this endpoint: try the other one
            }
        }
        // Both failed: report a 400 (it explains what's wrong) over a 404 ("not here").
        let best = failures.first { $0.code != 404 } ?? failures.last!
        throw DatabricksError.http(best.code, best.body)
    }

    // MARK: Classic: POST /serving-endpoints/<name>/invocations  (OpenAI chat format)

    private static func invocationsAPI(_ base: URL, _ name: String, _ token: String,
                                       _ messages: [ChatMessage], _ maxTokens: Int) async throws -> String {
        let endpoint = name.split(separator: ".").last.map(String.init) ?? name   // "workspace.default.x" -> "x"
        let url = base.appendingPathComponent("serving-endpoints").appendingPathComponent(endpoint)
            .appendingPathComponent("invocations")
        let data = try await post(url, token, [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": 0.2,
        ])
        return try parseAnswer(data)
    }

    // MARK: AI Gateway: POST /ai-gateway/mlflow/v1/responses  (Responses format)

    private static func responsesAPI(_ base: URL, _ name: String, _ token: String,
                                     _ messages: [ChatMessage], _ maxTokens: Int) async throws -> String {
        // The gateway wants the full Unity Catalog name, e.g. "workspace.default.visense-chat".
        let model = name.contains(".") ? name : "workspace.default.\(name)"
        let url = base.appendingPathComponent("ai-gateway/mlflow/v1/responses")
        let data = try await post(url, token, responsesBody(model: model, messages: messages, maxTokens: maxTokens))
        return try parseAnswer(data)
    }

    static func responsesBody(model: String, messages: [ChatMessage], maxTokens: Int) -> [String: Any] {
        [
            "model": model,
            // Reasoning models (gpt-oss) spend output tokens "thinking" first; low effort
            // keeps answers fast and stops the token budget being used up before the answer.
            "reasoning": ["effort": "low"],
            "max_output_tokens": maxTokens,
            "input": messages.map { m -> [String: Any] in
                ["role": m.role,
                 "content": [["type": m.role == "assistant" ? "output_text" : "input_text", "text": m.content]]]
            },
        ]
    }

    private static func post(_ url: URL, _ token: String, _ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let t0 = Date()
        var (data, resp) = try await URLSession.shared.data(for: req)
        var code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 429 = workspace rate limit (pay-per-token endpoints allow only a few req/s): wait and retry.
        for attempt in 1...3 where code == 429 {
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            (data, resp) = try await URLSession.shared.data(for: req)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        }
        Log.add(String(format: "Databricks: %@ -> HTTP %d in %.1f s", url.path, code, Date().timeIntervalSince(t0)))
        guard code == 200 else { throw DatabricksError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    /// Reads either format:
    ///  chat:      choices[0].message.content  (string or [{type:"text", text}])
    ///  responses: output_text, or output[].content[] items of type "output_text"
    static func parseAnswer(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DatabricksError.noAnswer }
        if let choices = json["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] {
            if let s = message["content"] as? String, !s.isEmpty { return s }
            if let parts = message["content"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { return text }
            }
        }
        if let s = json["output_text"] as? String, !s.isEmpty { return s }
        if let output = json["output"] as? [[String: Any]] {
            let text = output.filter { ($0["type"] as? String ?? "message") == "message" }
                .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
                .filter { ($0["type"] as? String) == "output_text" || $0["type"] == nil }
                .compactMap { $0["text"] as? String }
                .joined()
            if !text.isEmpty { return text }
        }
        throw DatabricksError.noAnswer
    }
}
