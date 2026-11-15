// =============================================================================
// WordPacer.swift — mirrors the live transcript onto the glasses.
//
// Every partial from the recognizer is sent to the glasses IMMEDIATELY, so
// the OLED shows exactly what the app shows, with no added delay or pacing.
// (BLEManager keeps only the newest unsent partial if the radio is busy, so
// we can never fall behind.)
//
// The only thing this adds is line management for the small display:
// when the live text gets longer than (rows - 1) display lines, its leading
// words are committed as a finished line, so text scrolls up line by line
// instead of the whole live text constantly re-wrapping.
//
// Pure logic (the BLE send is injected), unit-tested on the Mac by
// tools/pacer/main.swift.
// =============================================================================
import Foundation

final class WordPacer {
    // Display geometry (chars per line / rows for the current glasses font).
    var charsPerLine = 12
    var rows = 3

    private let send: (TextMessage) -> Void
    private var committed = 0      // utterance words already sent as finished lines
    private var lastSent = ""

    init(send: @escaping (TextMessage) -> Void) {
        self.send = send
    }

    /// Full text of the current utterance so far (from the recognizer).
    func partial(_ text: String) {
        let all = Self.words(text)
        var live = Array(all.dropFirst(min(committed, all.count)))

        // Live text too long for the display: commit its first line's worth of words.
        let budget = charsPerLine * max(1, rows - 1)
        while live.count > 1 && live.joined(separator: " ").count > budget {
            var chunk = 0, len = 0
            for w in live {
                let add = (chunk == 0 ? 0 : 1) + w.count
                if chunk > 0 && len + add > charsPerLine { break }
                chunk += 1; len += add
            }
            if chunk >= live.count { break }
            send(.final(live.prefix(chunk).joined(separator: " ")))
            committed += chunk
            live.removeFirst(chunk)
            lastSent = ""
        }

        let line = live.joined(separator: " ")
        if !line.isEmpty && line != lastSent {
            lastSent = line
            send(.partial(line))
        }
    }

    /// Utterance finished: commit what's left of it.
    /// `prefix` (e.g. a speaker tag "P:") goes in front of what's left of the line.
    func final(_ text: String, prefix: String? = nil) {
        let all = Self.words(text)
        var tail = all.dropFirst(min(committed, all.count)).joined(separator: " ")   // "" clears the live line
        if let prefix, !tail.isEmpty { tail = prefix + " " + tail }
        send(.final(tail))
        reset()
    }

    func reset() {
        committed = 0
        lastSent = ""
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}
