// =============================================================================
// TranscriptStore.swift — remembers every finished caption line on the phone,
// grouped into sessions (one per "Start captions", or after 5 min of silence).
// Saved as JSON in the app's Documents folder; the Ask tab uses it as the
// chatbot's memory.
// =============================================================================
import Foundation

struct TranscriptLine: Codable, Hashable {
    var time: Date
    var text: String
}

struct TranscriptSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Date
    var lines: [TranscriptLine] = []
}

final class TranscriptStore: ObservableObject {
    static let shared = TranscriptStore()

    @Published private(set) var sessions: [TranscriptSession] = []

    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("transcripts.json")
    private var saveScheduled = false
    private let newSessionAfterSilence: TimeInterval = 5 * 60

    init() {
        if let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder.iso.decode([TranscriptSession].self, from: data) {
            sessions = s
        }
    }

    /// Call when captions start: the next line opens a new session.
    func beginSession() {
        if let last = sessions.last, last.lines.isEmpty { return }
        sessions.append(TranscriptSession(start: Date()))
        scheduleSave()
    }

    /// Add one finished caption line (main thread).
    func add(_ text: String, speaker: String? = nil, durationMs: Int? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let now = Date()
        if sessions.isEmpty || (sessions.last!.lines.last.map { now.timeIntervalSince($0.time) > newSessionAfterSilence } ?? false) {
            sessions.append(TranscriptSession(start: now))
        }
        sessions[sessions.count - 1].lines.append(TranscriptLine(time: now, text: t))
        scheduleSave()
        // Also upload to the Databricks transcripts table (queued, retried).
        TranscriptSync.shared.add(t, sessionID: sessions[sessions.count - 1].id, at: now,
                                  speaker: speaker, durationMs: durationMs)
    }

    func deleteAll() {
        sessions = []
        scheduleSave()
    }

    var lineCount: Int { sessions.reduce(0) { $0 + $1.lines.count } }

    /// Transcripts as plain text for the LLM, newest sessions kept when the
    /// total would exceed `maxChars` (keeps the request small and fast).
    func contextText(maxChars: Int = 24_000) -> String {
        let day = DateFormatter(); day.dateFormat = "EEE d MMM yyyy, HH:mm"
        let time = DateFormatter(); time.dateFormat = "HH:mm:ss"
        var blocks: [String] = []
        var total = 0
        for s in sessions.reversed() where !s.lines.isEmpty {
            var b = "## Conversation started \(day.string(from: s.start))\n"
            for l in s.lines { b += "[\(time.string(from: l.time))] \(l.text)\n" }
            if total + b.count > maxChars {
                if blocks.isEmpty { blocks.append(String(b.suffix(maxChars))) }   // newest session, trimmed
                break
            }
            blocks.append(b); total += b.count
        }
        return blocks.reversed().joined(separator: "\n")
    }

    // MARK: - Saving (batched, off the main thread)

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let snapshot = self.sessions
            let url = self.url
            DispatchQueue.global(qos: .utility).async {
                if let data = try? JSONEncoder.iso.encode(snapshot) { try? data.write(to: url, options: .atomic) }
            }
        }
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
