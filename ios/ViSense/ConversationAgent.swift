// =============================================================================
// ConversationAgent.swift — answers questions about past conversations stored
// in Databricks. Three steps per question:
//
//   1. PLAN     The model gets the question, the current local time and an index
//               of this user's recent conversations (start/end/first line), and
//               picks the time window to read, e.g. "convo at 3 PM" ->
//               14:58-15:08, or the whole conversation if it ran longer.
//   2. RETRIEVE The app runs a fixed, parameterized SQL query for that window,
//               for THIS user only. The model never writes SQL.
//   3. ANSWER   The model summarizes / answers using those timestamped lines.
// =============================================================================
import Foundation

struct AgentAnswer {
    var text: String
    var window: DateInterval?
    var lines: Int
}

enum ConversationAgent {
    struct SessionInfo: Identifiable, Hashable {
        var id: String            // session_id
        var start: Date; var end: Date; var lines: Int; var firstLine: String
    }
    struct Line: Hashable { var time: Date; var text: String }

    /// `user` defaults to this phone's user; only ever reads that user's rows.
    /// `focus`: a fixed window (e.g. "ask about this conversation" from History) skips planning.
    static func ask(_ question: String, history: [ChatMessage],
                    user: String = TranscriptSync.shared.userID,
                    focus: DateInterval? = nil) async throws -> AgentAnswer {
        let sessions = try await sessionIndex(user: user)
        var window: DateInterval?
        var analytics = false
        if let focus { window = focus } else { (window, analytics) = try await plan(question, history: history, sessions: sessions) }
        // "Who did I talk to most / how long / how often": exact numbers from Databricks SQL.
        if analytics, let w = window {
            let stats = try await speakerStats(user: user, window: w)
            let text = try await answerAnalytics(question, history: history, window: w, stats: stats)
            return AgentAnswer(text: text, window: w, lines: stats.totalLines)
        }
        var lines: [Line] = []
        if let w = window { lines = try await retrieve(user: user, window: w) }
        // Window came back empty: use the nearest conversation within 30 min of it.
        if lines.isEmpty, let w = window, let near = nearestSession(to: w, in: sessions, within: 30 * 60) {
            let nw = DateInterval(start: near.start.addingTimeInterval(-1), end: near.end.addingTimeInterval(1))
            Log.add("Agent: nothing in window, using nearest conversation instead")
            lines = try await retrieve(user: user, window: nw)
            window = nw
        }
        let answer = try await answer(question, history: history, window: window, lines: lines, sessions: sessions)
        return AgentAnswer(text: answer, window: window, lines: lines.count)
    }

    // MARK: 1. Plan

    static func plan(_ question: String, history: [ChatMessage], sessions: [SessionInfo]) async throws -> (DateInterval?, Bool) {
        let system = ChatMessage(role: "system", content: """
            You pick which part of a user's recorded conversations to read.
            Current local time: \(Fmt.full.string(from: Date())) (\(TimeZone.current.identifier)).

            The user's recent conversations (local time):
            \(sessions.isEmpty ? "(none recorded yet)" : sessions.map(describe).joined(separator: "\n"))

            Reply with ONLY a JSON object, no other text:
            {"start": "YYYY-MM-DD HH:MM", "end": "YYYY-MM-DD HH:MM", "kind": "transcript" or "analytics", "reason": "<a few words>"}
            "end" must be later than "start".
            "kind": "analytics" when the question is about amounts or patterns across a period: who they talked
              to (most), how long / how much / how often, time per person, comparisons, busiest day, an overview
              or summary of their day/week. Otherwise "transcript" (what was said in a specific conversation).
            Rules:
            - A point in time ("at 3 PM", "around 10") -> start ~2 min before it and end 5 to 10 min after it.
              If a listed conversation was still going on at that time, widen to cover that conversation
              (up to 60 min) when that helps answer the request.
            - "last / latest conversation" -> exactly that conversation's start and end.
            - A day or part of day ("this morning", "yesterday") -> that whole period.
            - No time mentioned -> the most recent conversation(s) that could contain the answer;
              for "analytics" with no period mentioned, the last 7 days.
            - Times are local. "3 PM" means today unless that is in the future, then yesterday.
            """)
        let reply = try await DatabricksClient.chat([system] + history.suffix(4) + [ChatMessage(role: "user", content: question)],
                                                    maxTokens: 500)
        guard let json = extractJSON(reply),
              let s = json["start"] as? String, let e = json["end"] as? String,
              let start = Fmt.input.date(from: s), var end = Fmt.input.date(from: e) else {
            Log.add("Agent: couldn't read plan (\(reply.prefix(80))), using last conversation")
            return (sessions.first.map { DateInterval(start: $0.start.addingTimeInterval(-1), end: $0.end.addingTimeInterval(1)) }, false)
        }
        if end <= start { end = start.addingTimeInterval(10 * 60) }   // a single moment: read 10 min from it
        let analytics = (json["kind"] as? String)?.lowercased() == "analytics"
        Log.add("Agent: \(analytics ? "analytics" : "transcript") \(s) → \(Fmt.input.string(from: end)) (\(json["reason"] as? String ?? ""))")
        return (DateInterval(start: start, end: end.addingTimeInterval(59)), analytics)   // end minute inclusive
    }

    // MARK: 2. Retrieve (SQL)

    /// This user's conversations, newest first. The agent uses the last 14 days;
    /// the History screen asks for everything (`days: nil`).
    static func sessionIndex(user: String, days: Int? = 14, limit: Int = 30) async throws -> [SessionInfo] {
        let since = days.map { "AND ts >= current_timestamp() - INTERVAL \($0) DAYS" } ?? ""
        let rows = try await DatabricksSQL.run("""
            SELECT session_id, unix_millis(min(ts)), unix_millis(max(ts)), count(*), min_by(text, ts)
            FROM \(DatabricksSQL.table("transcripts"))
            WHERE user_id = :u \(since)
            GROUP BY session_id ORDER BY 2 DESC LIMIT \(limit)
            """, [SQLParam(name: "u", value: user)])
        return rows.compactMap { r in
            guard r.count >= 5, let id = r[0], let a = Date(epochMillis: r[1]), let b = Date(epochMillis: r[2]) else { return nil }
            return SessionInfo(id: id, start: a, end: b, lines: Int(r[3] ?? "") ?? 0, firstLine: r[4] ?? "")
        }
    }

    /// Every line of one conversation (History detail screen).
    static func sessionLines(user: String = TranscriptSync.shared.userID, session: String) async throws -> [Line] {
        let rows = try await DatabricksSQL.run("""
            SELECT unix_millis(ts), text FROM \(DatabricksSQL.table("transcripts"))
            WHERE user_id = :u AND session_id = :s ORDER BY ts LIMIT 5000
            """, [SQLParam(name: "u", value: user), SQLParam(name: "s", value: session)])
        return rows.compactMap { r in
            guard r.count >= 2, let t = Date(epochMillis: r[0]), let text = r[1] else { return nil }
            return Line(time: t, text: text)
        }
    }

    static func retrieve(user: String, window: DateInterval) async throws -> [Line] {
        let rows = try await DatabricksSQL.run("""
            SELECT unix_millis(ts), text FROM \(DatabricksSQL.table("transcripts"))
            WHERE user_id = :u AND ts BETWEEN timestamp_millis(:a) AND timestamp_millis(:b)
            ORDER BY ts LIMIT 600
            """, [SQLParam(name: "u", value: user),
                  SQLParam(name: "a", value: window.start.epochMillis, type: "BIGINT"),
                  SQLParam(name: "b", value: window.end.epochMillis, type: "BIGINT")])
        let lines = rows.compactMap { r -> Line? in
            guard r.count >= 2, let t = Date(epochMillis: r[0]), let text = r[1] else { return nil }
            return Line(time: t, text: text)
        }
        Log.add("Agent: retrieved \(lines.count) lines")
        return lines
    }

    // MARK: 3. Answer

    static func answer(_ question: String, history: [ChatMessage], window: DateInterval?,
                       lines: [Line], sessions: [SessionInfo]) async throws -> String {
        let windowText = window.map { "\(Fmt.full.string(from: $0.start)) to \(Fmt.time.string(from: $0.end))" } ?? "(no window)"
        let transcript = lines.isEmpty
            ? "(nothing was recorded in this window)"
            : lines.map { "[\(Fmt.time.string(from: $0.time))] \($0.text)" }.joined(separator: "\n")
        let system = ChatMessage(role: "system", content: """
            You are ViSense, an assistant for a deaf or hard-of-hearing user who wears caption glasses.
            You answer from automatic speech-to-text transcripts of their conversations (they may contain
            recognition errors; speakers are not labelled). Current local time: \(Fmt.full.string(from: Date())).

            Transcript retrieved for \(windowText):
            \(transcript)

            Other recent conversations (for reference if the window is empty or wrong):
            \(sessions.prefix(10).map(describe).joined(separator: "\n"))

            Do what the user asks (summary, answer, list of action items, etc.) using ONLY the transcript.
            Be concise. Mention times when useful. If the transcript doesn't contain the answer, say so
            and point to the closest other conversation if one looks relevant.
            """)
        return try await DatabricksClient.chat([system] + history.suffix(4) + [ChatMessage(role: "user", content: question)],
                                               maxTokens: 1500)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Analytics (Databricks SQL does the counting, the model only explains)

    struct SpeakerStat: Identifiable, Hashable {
        var id: String { who }
        var who: String; var minutes: Double; var lines: Int; var words: Int
        var conversations: Int; var days: Int; var first: Date; var last: Date
    }
    struct DayStat: Hashable { var day: String; var who: String; var minutes: Double }
    struct ConversationStat: Hashable { var start: Date; var end: Date; var lines: Int; var people: [String] }
    struct Stats {
        var speakers: [SpeakerStat] = []
        var days: [DayStat] = []
        var conversations: [ConversationStat] = []
        var samples: [(who: String, time: Date, text: String)] = []
        var totalLines: Int { speakers.reduce(0) { $0 + $1.lines } }
        var totalMinutes: Double { speakers.reduce(0) { $0 + $1.minutes } }
    }

    static let unknownSpeaker = "(voice not identified)"
    /// Talk time of a line: measured on the phone, or ~0.4 s per word for older lines.
    private static let talkMs = "coalesce(duration_ms, size(split(text, ' ')) * 400)"
    private static let who = "coalesce(speaker, '\(unknownSpeaker)')"

    static func speakerStats(user: String, window w: DateInterval) async throws -> Stats {
        let t = DatabricksSQL.table("transcripts")
        let filter = "user_id = :u AND ts BETWEEN timestamp_millis(:a) AND timestamp_millis(:b)"
        let p = [SQLParam(name: "u", value: user),
                 SQLParam(name: "a", value: w.start.epochMillis, type: "BIGINT"),
                 SQLParam(name: "b", value: w.end.epochMillis, type: "BIGINT")]
        let tz = [SQLParam(name: "tz", value: TimeZone.current.identifier)]
        var st = Stats()

        // Statements run one after another: the workspace rate-limits bursts.
        for r in try await DatabricksSQL.run("""
            SELECT \(who), round(sum(\(talkMs)) / 60000.0, 2), count(*), sum(size(split(text, ' '))),
                   count(DISTINCT session_id), count(DISTINCT to_date(from_utc_timestamp(ts, :tz))),
                   unix_millis(min(ts)), unix_millis(max(ts))
            FROM \(t) WHERE \(filter) GROUP BY 1 ORDER BY 2 DESC
            """, p + tz) where r.count >= 8 {
            st.speakers.append(SpeakerStat(who: r[0] ?? unknownSpeaker, minutes: Double(r[1] ?? "") ?? 0,
                                           lines: Int(r[2] ?? "") ?? 0, words: Int(r[3] ?? "") ?? 0,
                                           conversations: Int(r[4] ?? "") ?? 0, days: Int(r[5] ?? "") ?? 0,
                                           first: Date(epochMillis: r[6]) ?? w.start, last: Date(epochMillis: r[7]) ?? w.end))
        }
        guard !st.speakers.isEmpty else { return st }

        for r in try await DatabricksSQL.run("""
            SELECT date_format(from_utc_timestamp(ts, :tz), 'EEE yyyy-MM-dd'), \(who), round(sum(\(talkMs)) / 60000.0, 2)
            FROM \(t) WHERE \(filter) GROUP BY 1, 2 ORDER BY 1, 3 DESC
            """, p + tz) where r.count >= 3 {
            st.days.append(DayStat(day: r[0] ?? "", who: r[1] ?? unknownSpeaker, minutes: Double(r[2] ?? "") ?? 0))
        }

        for r in try await DatabricksSQL.run("""
            SELECT unix_millis(min(ts)), unix_millis(max(ts)), count(*), concat_ws(', ', array_sort(collect_set(speaker)))
            FROM \(t) WHERE \(filter) GROUP BY session_id ORDER BY 1 DESC LIMIT 40
            """, p) where r.count >= 4 {
            guard let a = Date(epochMillis: r[0]), let b = Date(epochMillis: r[1]) else { continue }
            let people = (r[3] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            st.conversations.append(ConversationStat(start: a, end: b, lines: Int(r[2] ?? "") ?? 0, people: people))
        }

        // A spread of lines per person so the model can say what they talked about.
        for r in try await DatabricksSQL.run("""
            SELECT who, unix_millis(ts), text FROM (
              SELECT \(who) AS who, ts, text,
                     row_number() OVER (PARTITION BY \(who) ORDER BY xxhash64(line_id)) AS rn
              FROM \(t) WHERE \(filter)) WHERE rn <= 30 ORDER BY ts
            """, p) where r.count >= 3 {
            guard let d = Date(epochMillis: r[1]) else { continue }
            st.samples.append((r[0] ?? unknownSpeaker, d, r[2] ?? ""))
        }
        Log.add("Agent: analytics \(st.speakers.count) people, \(st.totalLines) lines, \(st.conversations.count) conversations")
        return st
    }

    static func answerAnalytics(_ question: String, history: [ChatMessage], window w: DateInterval, stats st: Stats) async throws -> String {
        func m(_ x: Double) -> String { x < 1 ? String(format: "%.0f s", x * 60) : String(format: "%.1f min", x) }
        let people = st.speakers.map {
            "- \($0.who): \(m($0.minutes)) talk time, \($0.lines) lines, \($0.words) words, \($0.conversations) conversations on \($0.days) day(s), first \(Fmt.full.string(from: $0.first)), last \(Fmt.full.string(from: $0.last))"
        }.joined(separator: "\n")
        let days = st.days.map { "- \($0.day): \($0.who) \(m($0.minutes))" }.joined(separator: "\n")
        let convos = st.conversations.map {
            "- \(Fmt.full.string(from: $0.start))–\(Fmt.time.string(from: $0.end)), \($0.lines) lines, people: \($0.people.isEmpty ? "not identified" : $0.people.joined(separator: ", "))"
        }.joined(separator: "\n")
        let samples = st.samples.map { "[\(Fmt.full.string(from: $0.time))] \($0.who): \($0.text)" }.joined(separator: "\n")
        let system = ChatMessage(role: "system", content: """
            You are ViSense, an assistant for a deaf or hard-of-hearing user who wears caption glasses.
            You answer questions about their conversation habits using EXACT statistics computed by
            Databricks SQL from their transcripts. Current local time: \(Fmt.full.string(from: Date())).
            Period analysed: \(Fmt.full.string(from: w.start)) to \(Fmt.full.string(from: w.end)).
            Speakers are people around the user, named by voice recognition on the phone. The user may
            appear under their own name. "\(unknownSpeaker)" = lines whose voice wasn't recognised.

            PEOPLE (sorted by talk time; total \(m(st.totalMinutes)), \(st.totalLines) lines):
            \(people.isEmpty ? "(nothing recorded in this period)" : people)

            TALK TIME PER DAY:
            \(days)

            CONVERSATIONS (newest first):
            \(convos)

            SAMPLE LINES PER PERSON (for topics, not for counting):
            \(samples)

            Answer the user's question. Use the numbers exactly as given; never recount from the samples.
            Lead with the direct answer, then a short, friendly insight summary (who, how much, what about,
            notable patterns). Use short bullet points. Keep it under 150 words.
            """)
        return try await DatabricksClient.chat([system] + history.suffix(4) + [ChatMessage(role: "user", content: question)],
                                               maxTokens: 1500)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    /// The conversation overlapping `w`, or else the one closest to it (if within `limit` seconds).
    static func nearestSession(to w: DateInterval, in sessions: [SessionInfo], within limit: TimeInterval) -> SessionInfo? {
        func gap(_ s: SessionInfo) -> TimeInterval {
            if s.end >= w.start && s.start <= w.end { return 0 }
            return s.end < w.start ? w.start.timeIntervalSince(s.end) : s.start.timeIntervalSince(w.end)
        }
        return sessions.min { gap($0) < gap($1) }.flatMap { gap($0) <= limit ? $0 : nil }
    }

    static func describe(_ s: SessionInfo) -> String {
        "- \(Fmt.full.string(from: s.start)) to \(Fmt.time.string(from: s.end)), \(s.lines) lines, starts: \"\(s.firstLine.prefix(60))\""
    }

    /// First {...} object in the model's reply (models sometimes wrap JSON in prose or ``` fences).
    static func extractJSON(_ s: String) -> [String: Any]? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(s[a...b].utf8))) as? [String: Any]
    }

    enum Fmt {
        static let input = make("yyyy-MM-dd HH:mm")
        static let full = make("EEE yyyy-MM-dd HH:mm")
        static let time = make("HH:mm:ss")
        private static func make(_ f: String) -> DateFormatter {
            let d = DateFormatter(); d.locale = Locale(identifier: "en_US_POSIX"); d.timeZone = .current; d.dateFormat = f
            return d
        }
    }
}
