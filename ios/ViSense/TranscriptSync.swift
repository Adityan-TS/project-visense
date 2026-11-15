// =============================================================================
// TranscriptSync.swift — uploads every finished caption line to Databricks.
//
// * Each install gets a random user ID; on first contact the app creates the
//   schema/tables if needed and its own row in workspace.visense.users.
// * Lines are queued on the phone (survives app restarts) and uploaded in
//   batches every 2 minutes, and only while nobody is talking: an upload keeps
//   the radio busy ~2 s, and Wi-Fi shares it with Bluetooth, so the glasses lag
//   mid-sentence. Writing often also trips Databricks' SQL rate limit. No network?
//   Lines wait and retry; captions never depend on this upload.
// * Uploads use MERGE on line_id, so a retried batch never creates duplicates.
// =============================================================================
import Foundation

struct PendingLine: Codable {
    var lineID: String
    var sessionID: String
    var ts: Date
    var text: String
    var speaker: String? = nil        // voice-matched name, nil if unknown
    var durationMs: Int? = nil        // how long the line took to say
}

final class TranscriptSync: ObservableObject {
    static let shared = TranscriptSync()

    @Published private(set) var pending = 0
    @Published private(set) var uploaded = 0
    @Published private(set) var lastError: String?
    @Published private(set) var ready = false        // schema + user row exist

    /// Stable per-install user ID (this phone = one ViSense user).
    let userID: String = {
        if let id = UserDefaults.standard.string(forKey: "visense.userID") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "visense.userID")
        return id
    }()
    var displayName: String { "ViSense user \(userID.prefix(4))" }

    private var queue: [PendingLine] = []
    private var flushing = false
    private var flushScheduled = false
    private var retryDelay: TimeInterval = 30
    /// Minimum gap between SQL writes. One statement every few seconds (and a
    /// follow-up 0.2 s later) was enough to get HTTP 429s and stall transcription.
    private let uploadInterval: TimeInterval = 120
    /// True when nobody is talking. Uploading uses the phone's radio for ~2 s, which
    /// Wi-Fi shares with Bluetooth, so the glasses lag if we upload mid-sentence.
    var isQuietNow: () -> Bool = { true }
    private var deferrals = 0
    private var flushWork: DispatchWorkItem?
    private let batchSize = 40
    private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("upload-queue.json")

    init() {
        if let d = try? Data(contentsOf: fileURL), let q = try? JSONDecoder().decode([PendingLine].self, from: d) {
            queue = q
        }
        pending = queue.count
    }

    // MARK: Public (main thread)

    /// Queue one finished caption line for upload.
    func add(_ text: String, sessionID: UUID, at time: Date, speaker: String? = nil, durationMs: Int? = nil) {
        queue.append(PendingLine(lineID: UUID().uuidString.lowercased(), sessionID: sessionID.uuidString.lowercased(),
                                 ts: time, text: text, speaker: speaker, durationMs: durationMs))
        pending = queue.count
        persist()
        scheduleFlush(after: uploadInterval)   // hold lines so each write is a bigger batch
    }

    /// Call at launch / when the app becomes active.
    func start() { scheduleFlush(after: 0.5) }

    /// Captions stopped: upload what's waiting in a few seconds (not in 2 min).
    func flushSoon() { if !queue.isEmpty { scheduleFlush(after: 3, replacing: true) } }

    // MARK: Setup: schema, tables, this user's row

    private func ensureSetup() async throws {
        if ready { return }
        // Creating objects may be refused if the token lacks rights; the tables may
        // already exist (databricks/setup.sql), so only the user MERGE must succeed.
        for sql in Self.setupStatements {
            do { _ = try await DatabricksSQL.run(sql) } catch { Log.add("Setup (ok if tables exist): \(error.localizedDescription)") }
        }
        _ = try await DatabricksSQL.run("""
            MERGE INTO \(DatabricksSQL.table("users")) u
            USING (SELECT :user_id AS user_id, :name AS display_name, :tz AS timezone) s
            ON u.user_id = s.user_id
            WHEN MATCHED THEN UPDATE SET u.last_seen_at = current_timestamp(), u.timezone = s.timezone
            WHEN NOT MATCHED THEN INSERT (user_id, display_name, timezone, created_at, last_seen_at)
              VALUES (s.user_id, s.display_name, s.timezone, current_timestamp(), current_timestamp())
            """, [SQLParam(name: "user_id", value: userID),
                  SQLParam(name: "name", value: displayName),
                  SQLParam(name: "tz", value: TimeZone.current.identifier)])
        await MainActor.run { ready = true }
        Log.add("Databricks: user \(userID.prefix(8))… registered")
    }

    static let setupStatements = [
        "CREATE SCHEMA IF NOT EXISTS \(DatabricksConfig.catalog).\(DatabricksConfig.schema)",
        """
        CREATE TABLE IF NOT EXISTS \(DatabricksSQL.table("users")) (
          user_id STRING NOT NULL, display_name STRING, timezone STRING,
          created_at TIMESTAMP, last_seen_at TIMESTAMP)
        """,
        """
        CREATE TABLE IF NOT EXISTS \(DatabricksSQL.table("transcripts")) (
          line_id STRING NOT NULL, user_id STRING NOT NULL, session_id STRING NOT NULL,
          ts TIMESTAMP NOT NULL, text STRING NOT NULL, speaker STRING, duration_ms BIGINT)
          CLUSTER BY (user_id, ts)
        """,
    ]

    // MARK: Upload

    private func scheduleFlush(after delay: TimeInterval, replacing: Bool = false) {
        if flushScheduled && !replacing { return }
        flushWork?.cancel()
        flushScheduled = true
        let work = DispatchWorkItem { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flush() {
        guard !flushing, DatabricksConfig.isConfigured else { return }
        guard !queue.isEmpty || !ready else { return }
        // Someone is talking: wait for a pause (5 s steps, at most 1 extra minute).
        if !isQuietNow() && deferrals < 12 {
            deferrals += 1
            scheduleFlush(after: 5)
            return
        }
        deferrals = 0
        flushing = true
        let batch = Array(queue.prefix(batchSize))
        Task {
            do {
                try await ensureSetup()
                if !batch.isEmpty { try await upload(batch) }
                await MainActor.run {
                    let sent = Set(batch.map(\.lineID))
                    queue.removeAll { sent.contains($0.lineID) }
                    pending = queue.count
                    uploaded += batch.count
                    lastError = nil
                    retryDelay = uploadInterval
                    persist()
                    flushing = false
                    // Backlog (more than one batch): next batch soon, still only in a quiet moment.
                    if !queue.isEmpty { scheduleFlush(after: queue.count >= batchSize ? 20 : uploadInterval) }
                }
            } catch {
                await MainActor.run {
                    lastError = error.localizedDescription
                    flushing = false
                    if Self.isRateLimit(error) { retryDelay = max(retryDelay, 60) }
                    Log.add("Upload failed, retry in \(Int(retryDelay)) s: \(error.localizedDescription)")
                    scheduleFlush(after: retryDelay)
                    retryDelay = min(retryDelay * 2, 120)
                }
            }
        }
    }

    /// Databricks reports the SQL rate limit as HTTP 429, or as a failed statement
    /// whose message mentions the limit. Either one needs a long pause, not a quick retry.
    private static func isRateLimit(_ error: Error) -> Bool {
        guard case DatabricksError.http(let code, let body) = error else { return false }
        if code == 429 { return true }
        let msg = body.lowercased()
        return msg.contains("rate limit") || msg.contains("too many") || msg.contains("resource_exhausted")
    }

    private func upload(_ batch: [PendingLine]) async throws {
        let (sql, params) = Self.mergeStatement(batch, userID: userID)
        _ = try await DatabricksSQL.run(sql, params)
    }

    /// MERGE … USING (VALUES …) so re-sending a batch is harmless.
    static func mergeStatement(_ batch: [PendingLine], userID: String) -> (String, [SQLParam]) {
        var rows: [String] = []
        var params = [SQLParam(name: "u", value: userID)]
        for (i, l) in batch.enumerated() {
            // "" / -1 stand for unknown and become NULL in SQL.
            rows.append("(:l\(i), :u, :s\(i), timestamp_millis(:t\(i)), :x\(i), nullif(:p\(i), ''), nullif(:d\(i), -1))")
            params += [SQLParam(name: "l\(i)", value: l.lineID),
                       SQLParam(name: "s\(i)", value: l.sessionID),
                       SQLParam(name: "t\(i)", value: l.ts.epochMillis, type: "BIGINT"),
                       SQLParam(name: "x\(i)", value: l.text),
                       SQLParam(name: "p\(i)", value: l.speaker ?? ""),
                       SQLParam(name: "d\(i)", value: String(l.durationMs ?? -1), type: "BIGINT")]
        }
        let sql = """
            MERGE INTO \(DatabricksSQL.table("transcripts")) t
            USING (SELECT * FROM VALUES \(rows.joined(separator: ", ")) AS v(line_id, user_id, session_id, ts, text, speaker, duration_ms)) v
            ON t.line_id = v.line_id
            WHEN NOT MATCHED THEN INSERT (line_id, user_id, session_id, ts, text, speaker, duration_ms)
              VALUES (v.line_id, v.user_id, v.session_id, v.ts, v.text, v.speaker, v.duration_ms)
            """
        return (sql, params)
    }

    private func persist() {
        let snapshot = queue, url = fileURL
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }
}
