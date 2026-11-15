// =============================================================================
// CaptionPipeline.swift — wires live captions through tone (and optional translation).
//
//   Apple speech → CaptionPipeline → TonePunctuator → glasses / TranscriptStore
//
// Live path uses estimated word timings, mic level, and pause-between-lines cues.
// Full speaker diarization + SenseVoice plug in via UtteranceBuilder when available.
// =============================================================================
import Foundation

actor CaptionPipeline {
    static let shared = CaptionPipeline()

    private var punctuator: TonePunctuator
    private let recognizer = SpeakerRecognizer.shared

    private var utteranceStart: Date?
    private var lastFinalAt: Date?
    private var recentLevels: [Float] = []
    private let maxRecentLevels = 32

    /// Rule-based tone punctuation for each committed line.
    var toneEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "visense.tonePunctuation") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "visense.tonePunctuation") }
    }

    /// Optional Databricks punctuation polish (off by default to avoid extra API calls).
    var databricksTone: Bool {
        get { UserDefaults.standard.bool(forKey: "visense.databricksTone") }
        set {
            UserDefaults.standard.set(newValue, forKey: "visense.databricksTone")
            punctuator = TonePunctuator(useDatabricksRefinement: newValue)
        }
    }

    // Actor properties can't be assigned from outside the actor; callers use these.
    func setToneEnabled(_ on: Bool) { toneEnabled = on }
    func setDatabricksTone(_ on: Bool) { databricksTone = on }

  #if canImport(Translation)
    /// Live English translation for display (iOS 18+, on-device). Off by default.
    var liveTranslation: Bool {
        get { UserDefaults.standard.bool(forKey: "visense.liveTranslation") }
        set { UserDefaults.standard.set(newValue, forKey: "visense.liveTranslation") }
    }
  #endif

    init() {
        let ai = UserDefaults.standard.bool(forKey: "visense.databricksTone")
        punctuator = TonePunctuator(useDatabricksRefinement: ai)
    }

    func beginSession() {
        utteranceStart = Date()
        lastFinalAt = nil
        recentLevels.removeAll()
    }

    /// First partial of a new utterance — anchors spoken-duration estimate.
    func notePartialActivity() {
        if utteranceStart == nil { utteranceStart = Date() }
    }

    func endSession() {
        utteranceStart = nil
        lastFinalAt = nil
        recentLevels.removeAll()
    }

    /// Call from the audio path with the current RMS level (0...1).
    func noteLevel(_ level: Float) {
        recentLevels.append(level)
        if recentLevels.count > maxRecentLevels { recentLevels.removeFirst(recentLevels.count - maxRecentLevels) }
    }

    /// Turn raw speech recognizer text into a display / store line.
    func finishLine(_ raw: String, speechLevel: Float) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard toneEnabled else {
            lastFinalAt = Date()
            return trimmed
        }

        let now = Date()
        let spokenDuration = utteranceStart.map { max(0.3, now.timeIntervalSince($0)) } ?? Double(trimmed.split(separator: " ").count) * 0.28
        utteranceStart = now

        let pauseAfter = lastFinalAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        lastFinalAt = now

        let words = TimedWordEstimator.words(from: trimmed, spokenDuration: spokenDuration)
        let rms = Double(max(0.05, speechLevel))
        let profileID = await recognizer.ownerProfileID
        let loudness = await recognizer.loudnessRatio(for: profileID, rms: rms)
        let emotion = Self.emotion(from: speechLevel, text: trimmed)

        let utterance = Utterance(
            speakerID: profileID?.uuidString ?? "owner",
            words: words,
            cues: UtteranceCues(emotion: emotion.emotion, confidence: emotion.confidence,
                                loudnessRatio: loudness, interrupted: false, pauseAfter: pauseAfter))

        var line = await punctuator.punctuate(utterance)
        line = Self.clampLineLength(line)

      #if canImport(Translation)
        if #available(iOS 18.0, *), liveTranslation {
            line = await translateSingleLine(line, profileID: profileID)
        }
      #endif

        return line
    }

  #if canImport(Translation)
    @available(iOS 18.0, *)
    private func translateSingleLine(_ line: String, profileID: UUID?) async -> String {
        let label = await recognizer.label(for: profileID)
        let enriched = EnrichedCaptionLine(speakerID: profileID?.uuidString ?? "owner",
                                           speakerLabel: label, text: line)
        let translator = TranscriptTranslator(useDatabricksFinal: false)
        guard let translated = await translator.translateLive([enriched]).first else { return line }
        if translated.engine == .none || translated.engine == .failed { return line }
        return Self.clampLineLength(translated.translatedText)
    }
  #endif

    private static func emotion(from level: Float, text: String) -> (emotion: VoiceEmotion, confidence: Double) {
        let lower = text.lowercased()
        if lower.hasSuffix("?") || lower.hasPrefix("what") || lower.hasPrefix("why") || lower.hasPrefix("how") {
            return (.surprised, 0.55)
        }
        if level > 0.72 { return (.happy, 0.52) }
        if level < 0.18 { return (.sad, 0.45) }
        return (.neutral, 0.35)
    }

    /// Glasses TEXT payload is capped (VS.textMax); keep committed lines within that budget.
    private static func clampLineLength(_ s: String) -> String {
        let maxLen = VS.textMax
        guard s.count > maxLen else { return s }
        let end = s.index(s.startIndex, offsetBy: maxLen)
        return String(s[..<end])
    }
}