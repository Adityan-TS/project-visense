// =============================================================================
// DatabricksSQL.swift — runs SQL on a Databricks SQL warehouse from the phone,
// via the SQL Statement Execution API:
//
//   POST /api/2.0/sql/statements
//   { warehouse_id, statement, parameters: [{name, value, type}], wait_timeout }
//   -> { statement_id, status: {state}, manifest: {schema: {columns}}, result: {data_array} }
//
// Always uses named :parameters for values (never string-pasted), so caption
// text can't break or inject into the SQL.
// =============================================================================
import Foundation

struct SQLParam {
    var name: String
    var value: String
    var type: String = "STRING"
}

enum DatabricksSQL {
    /// Rows as arrays of optional strings (Databricks returns every value as a string).
    typealias Rows = [[String?]]

    static func run(_ statement: String, _ params: [SQLParam] = []) async throws -> Rows {
        guard DatabricksConfig.isConfigured else { throw DatabricksError.notConfigured }
        let url = DatabricksConfig.host.appendingPathComponent("api/2.0/sql/statements")
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(DatabricksConfig.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(statement, params))

        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DatabricksError.http(code, String(decoding: data, as: UTF8.self)) }
        var json = try parse(data)

        // Warehouse still starting / query still running: poll until done.
        while let state = Self.state(json), state == "PENDING" || state == "RUNNING" {
            guard let id = json["statement_id"] as? String, Date().timeIntervalSince(t0) < 120 else { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            var get = URLRequest(url: url.appendingPathComponent(id))
            get.setValue("Bearer \(DatabricksConfig.token)", forHTTPHeaderField: "Authorization")
            let (d, _) = try await URLSession.shared.data(for: get)
            json = try parse(d)
        }
        Log.add(String(format: "SQL %@ in %.1f s", Self.state(json) ?? "?", Date().timeIntervalSince(t0)))
        return try rows(json)
    }

    static func body(_ statement: String, _ params: [SQLParam]) -> [String: Any] {
        [
            "warehouse_id": DatabricksConfig.warehouseID,
            "statement": statement,
            "parameters": params.map { ["name": $0.name, "value": $0.value, "type": $0.type] },
            "wait_timeout": "30s",
            "on_wait_timeout": "CONTINUE",
            "format": "JSON_ARRAY",
            "disposition": "INLINE",
        ]
    }

    static func rows(_ json: [String: Any]) throws -> Rows {
        if state(json) == "FAILED" || state(json) == "CANCELED" || state(json) == "CLOSED" {
            let status = json["status"] as? [String: Any]
            let msg = (status?["error"] as? [String: Any])?["message"] as? String ?? "query failed"
            throw DatabricksError.http(400, msg)
        }
        let result = json["result"] as? [String: Any]
        let array = result?["data_array"] as? [[Any]] ?? []
        return array.map { row in row.map { $0 as? String } }
    }

    private static func parse(_ d: Data) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    private static func state(_ json: [String: Any]) -> String? {
        (json["status"] as? [String: Any])?["state"] as? String
    }

    /// Fully qualified table name, e.g. workspace.visense.transcripts
    static func table(_ name: String) -> String {
        "\(DatabricksConfig.catalog).\(DatabricksConfig.schema).\(name)"
    }
}

extension Date {
    /// Epoch milliseconds: how timestamps go to/come from SQL (time-zone proof:
    /// timestamp_millis(:t) on the way in, unix_millis(ts) on the way out).
    var epochMillis: String { String(Int64((timeIntervalSince1970 * 1000).rounded())) }
    init?(epochMillis s: String?) {
        guard let s, let ms = Double(s) else { return nil }
        self.init(timeIntervalSince1970: ms / 1000)
    }
}
