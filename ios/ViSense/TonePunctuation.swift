// =============================================================================
// TonePunctuation.swift — tone-aware punctuation (. , ? ! ?! … —) without
// changing any words.
//
// Pipeline per utterance:
//   1. Rules (on-device): commas / ellipses from pauses, em dash on interruption,
//      ending marks from emotion + loudness.
//   2. Optional Databricks refinement (via DatabricksClient, same as Ask tab).
//   3. Safety: reject AI output if words differ or marks are overdone.
// =============================================================================
import Foundation
import AVFoundation

// MARK: - Models

struct TimedWord: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

enum VoiceEmotion: String, Codable, Sendable {
    case happy, neutral, sad, angry, frustrated, surprised, fearful, unknown
}

struct UtteranceCues: Codable, Sendable {
    var emotion: VoiceEmotion
    var confidence: Double
    var loudnessRatio: Double
    var interrupted: Bool
    var pauseAfter: TimeInterval
}

struct Utterance: Codable, Identifiable, Sendable {
    var id = UUID()
    var speakerID: String
    var words: [TimedWord]
    var cues: UtteranceCues

    var originalText: String { words.map(\.text).joined(separator: " ") }
}

// MARK: - Rule-based punctuation

struct PunctuationRules: Sendable {
    var shortPause: ClosedRange<TimeInterval> = 0.3...0.7
    var longPause: TimeInterval = 0.7
    var minConfidence: Double = 0.6
    var loudRatio: Double = 1.25

    func apply(to u: Utterance) -> String {
        guard !u.words.isEmpty else { return "" }
        var tokens: [String] = []

        for (i, word) in u.words.enumerated() {
            var token = word.text
            if i < u.words.count - 1, !token.endsWithPunctuation {
                let gap = u.words[i + 1].start - word.end
                if gap >= longPause { token += "…" }
                else if shortPause.contains(gap) { token += "," }
            }
            tokens.append(token)
        }
        return applyEnding(to: tokens.joined(separator: " "), cues: u.cues)
    }

    private func applyEnding(to text: String, cues: UtteranceCues) -> String {
        let wasQuestion = text.hasSuffix("?")
        let body = text.strippingTrailingPunctuation
        let confident = cues.confidence >= minConfidence
        let loud = cues.loudnessRatio >= loudRatio

        if cues.interrupted { return body + "—" }

        if wasQuestion {
            return (confident && cues.emotion == .surprised) ? body + "?!" : body + "?"
        }

        guard confident else { return body + "." }

        switch cues.emotion {
        case .angry:
            return body + "!"
        case .happy, .surprised:
            return loud ? body + "!" : body + "."
        case .frustrated:
            return loud ? body + "!" : body + "."
        case .sad, .fearful:
            return body + "…"
        case .neutral, .unknown:
            return body + "."
        }
    }
}

// MARK: - Databricks refinement (reuses DatabricksClient; no extra endpoint)

enum ToneDatabricksRefine {
    static let systemPrompt = """
    You adjust ONLY the punctuation of a transcribed spoken sentence so it reflects the speaker's tone.
    Rules:
    - Never add, remove, reorder, or change any word or its spelling. Keep capitalization as is.
    - Allowed marks: . , ? ! ?! … —
    - Use at most one "!" per sentence. Never write "!!" or "??".
    - "?" for genuine questions, "?!" for surprised disbelief, "…" for trailing off, hesitation, or sadness,
      "—" only if the speaker was interrupted, "!" for excitement or anger, "." for neutral statements.
    - If the tone cues are weak or unclear, keep the punctuation unchanged.
    Reply with the sentence only. No quotes, no explanation.
    """

    static func refine(text: String, cues: UtteranceCues) async throws -> String {
        guard DatabricksConfig.isConfigured else { throw DatabricksError.notConfigured }
        let user = """
        Sentence: \(text)
        Cues: emotion=\(cues.emotion.rawValue) (confidence \(String(format: "%.2f", cues.confidence))), \
        loudness=\(String(format: "%.2f", cues.loudnessRatio))x usual, \
        interrupted=\(cues.interrupted), pause_after=\(String(format: "%.1f", cues.pauseAfter))s
        """
        return try await DatabricksClient.chat([
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: user),
        ], maxTokens: 200)
    }
}

// MARK: - Safety check

enum PunctuationSafety {
    static func words(_ s: String) -> [String] {
        let normalized = s.replacingOccurrences(of: "’", with: "'").lowercased()
        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))
        return normalized.components(separatedBy: wordChars.inverted).filter { !$0.isEmpty }
    }

    static func isPunctuationOnlyChange(original: String, candidate: String) -> Bool {
        words(original) == words(candidate)
    }

    static func respectsLimits(_ s: String) -> Bool {
        let bangs = s.filter { $0 == "!" }.count
        return bangs <= 1 && !s.contains("!!") && !s.contains("??") && !s.contains("……")
    }
}

// MARK: - Pipeline

actor TonePunctuator {
    private let rules: PunctuationRules
    private let useDatabricks: Bool

    init(rules: PunctuationRules = PunctuationRules(), useDatabricksRefinement: Bool = false) {
        self.rules = rules
        self.useDatabricks = useDatabricksRefinement
    }

    func punctuate(_ u: Utterance) async -> String {
        let ruleBased = rules.apply(to: u)

        guard useDatabricks,
              DatabricksConfig.isConfigured,
              u.cues.confidence >= rules.minConfidence,
              u.cues.emotion != .neutral, u.cues.emotion != .unknown else {
            return ruleBased
        }

        do {
            let refined = try await ToneDatabricksRefine.refine(text: ruleBased, cues: u.cues)
            let trimmed = refined.trimmingCharacters(in: .whitespacesAndNewlines)
            if PunctuationSafety.isPunctuationOnlyChange(original: u.originalText, candidate: trimmed),
               PunctuationSafety.respectsLimits(trimmed) {
                return trimmed
            }
            return ruleBased
        } catch {
            return ruleBased
        }
    }
}

// MARK: - Cue helpers

enum CueBuilder {
    struct Segment {
        var speakerID: String
        var start: TimeInterval
        var end: TimeInterval
    }

    static func wasInterrupted(_ s: Segment, next: Segment?) -> Bool {
        guard let next, next.speakerID != s.speakerID else { return false }
        return next.start < s.end - 0.05
    }

    static func pauseAfter(_ s: Segment, next: Segment?) -> TimeInterval {
        guard let next else { return 0 }
        return max(0, next.start - s.end)
    }
}

enum LoudnessMeter {
    /// RMS of a time range in a file. Caps frame count so corrupt ranges cannot allocate huge buffers.
    static func rms(of url: URL, from start: TimeInterval, to end: TimeInterval) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard end > start, sampleRate > 0 else { return 0 }

        let startFrame = max(0, AVAudioFramePosition(start * sampleRate))
        let endFrame = min(file.length, AVAudioFramePosition(end * sampleRate))
        let frameCount = AVAudioFrameCount(max(0, endFrame - startFrame))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return 0 }

        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)
        guard let samples = buffer.floatChannelData?[0] else { return 0 }

        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<n { let v = Double(samples[i]); sum += v * v }
        return (sum / Double(n)).squareRoot()
    }
}

// MARK: - Heuristic TimedWord (SFSpeechRecognizer on iOS 17 has no word timings)

enum TimedWordEstimator {
    private static let minWordDuration: TimeInterval = 0.05
    private static let defaultWordDuration: TimeInterval = 0.28

    static func words(from text: String, spokenDuration: TimeInterval) -> [TimedWord] {
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !parts.isEmpty else { return [] }
        let perWord = max(minWordDuration, spokenDuration / Double(parts.count))
        var t = 0.0
        return parts.map { w in
            let tw = TimedWord(text: w, start: t, end: t + perWord)
            t += perWord
            return tw
        }
    }
}

// MARK: - String helpers

private let endingMarks: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "—"]

private extension String {
    var endsWithPunctuation: Bool {
        guard let last = last else { return false }
        return endingMarks.contains(last)
    }

    var strippingTrailingPunctuation: String {
        var s = self.trimmingCharacters(in: .whitespaces)
        while let last = s.last, endingMarks.contains(last) { s.removeLast() }
        return s
    }
}

#if DEBUG
enum TonePunctuationDemo {
    static func run() async {
        func w(_ t: String, _ s: Double, _ e: Double) -> TimedWord { TimedWord(text: t, start: s, end: e) }

        let samples: [Utterance] = [
            Utterance(speakerID: "priya",
                      words: [w("We", 0, 0.2), w("hit", 0.2, 0.4), w("the", 0.4, 0.5),
                              w("milestone", 0.5, 1.0), w("early", 1.0, 1.4)],
                      cues: .init(emotion: .happy, confidence: 0.86, loudnessRatio: 1.4,
                                  interrupted: false, pauseAfter: 0.8)),
            Utterance(speakerID: "me",
                      words: [w("I'm", 0, 0.2), w("fine", 0.2, 0.5), w("honestly", 0.9, 1.4),
                              w("it's", 2.3, 2.5), w("just", 2.5, 2.7), w("been", 2.7, 2.9),
                              w("a", 2.9, 3.0), w("long", 3.0, 3.3), w("week", 3.3, 3.7)],
                      cues: .init(emotion: .sad, confidence: 0.78, loudnessRatio: 0.8,
                                  interrupted: false, pauseAfter: 1.2)),
            Utterance(speakerID: "alex",
                      words: [w("I", 0, 0.1), w("was", 0.1, 0.3), w("going", 0.3, 0.5),
                              w("to", 0.5, 0.6), w("say", 0.6, 0.8)],
                      cues: .init(emotion: .neutral, confidence: 0.7, loudnessRatio: 1.0,
                                  interrupted: true, pauseAfter: 0)),
        ]

        let punctuator = TonePunctuator()
        for (u, out) in zip(samples, await punctuator.punctuate(samples)) {
            print("\(u.speakerID): \(u.originalText)  →  \(out)")
        }
    }
}

extension TonePunctuator {
    fileprivate func punctuate(_ utterances: [Utterance]) async -> [String] {
        var out: [String] = []
        for u in utterances { out.append(await punctuate(u)) }
        return out
    }
}
#endif