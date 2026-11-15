// =============================================================================
// Translation.swift — translate punctuated caption lines to English.
//
// Pipeline: transcription → speaker → tone → **Translation** → display / Databricks
//
// • Live: Apple Translation (on-device) when iOS 18+ and languages are downloaded.
// • Final: Databricks model (whole conversation) with Apple fallback per line.
// =============================================================================
import Foundation
import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

// MARK: - Models (EnrichedCaptionLine avoids clashing with TranscriptStore.TranscriptLine)

struct EnrichedCaptionLine: Codable, Identifiable, Sendable {
    var id: UUID
    var speakerID: String
    var speakerLabel: String
    var text: String

    init(id: UUID = UUID(), speakerID: String, speakerLabel: String, text: String) {
        self.id = id; self.speakerID = speakerID; self.speakerLabel = speakerLabel; self.text = text
    }

    init(utterance: Utterance, punctuatedText: String, speakerLabel: String) {
        self.init(id: utterance.id, speakerID: utterance.speakerID,
                  speakerLabel: speakerLabel, text: punctuatedText)
    }
}

enum TranslationEngine: String, Codable, Sendable {
    case none, apple, llm, failed
}

struct TranslatedLine: Codable, Identifiable, Sendable {
    var id: UUID
    var speakerID: String
    var speakerLabel: String
    var originalText: String
    var translatedText: String
    var sourceLanguage: String
    var targetLanguage: String
    var engine: TranslationEngine
    var toneRestored: Bool
}

// MARK: - Language detection

enum LanguageDetector {
    struct Result: Sendable {
        var language: Locale.Language?
        var confidence: Double
        var isMixed: Bool
    }

    static func detect(_ text: String, mixedThreshold: Double = 0.25) -> Result {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }

        guard let top = hypotheses.first else { return Result(language: nil, confidence: 0, isMixed: false) }
        let second = hypotheses.dropFirst().first?.value ?? 0
        return Result(language: Locale.Language(identifier: top.key.rawValue),
                      confidence: top.value,
                      isMixed: second >= mixedThreshold)
    }

    static func dominantLanguage(of lines: [EnrichedCaptionLine]) -> Locale.Language? {
        detect(lines.map(\.text).joined(separator: " ")).language
    }
}

// MARK: - Tone preservation

enum TonePreserver {
    private static let marks = ["?!", "…", "—", "!", "?"]

    static func endingMark(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "...", with: "…")
        return marks.first { t.hasSuffix($0) }
    }

    static func restore(original: String, translated: String) -> (text: String, restored: Bool) {
        guard let mark = endingMark(original) else { return (translated, false) }
        var t = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "...", with: "…")
        if endingMark(t) == mark { return (t, false) }

        let stripSet: Set<Character> = [".", "!", "?", "…", "—", ",", ";", ":", "。", "！", "？"]
        while let last = t.last, stripSet.contains(last) { t.removeLast() }
        return (t + mark, true)
    }
}

// MARK: - Apple Translation (live, on-device)

#if canImport(Translation)
struct OnDeviceTranslationUnavailable: LocalizedError {
    var errorDescription: String? { "On-device translation needs iOS 26" }
}

@available(iOS 18.0, *)
actor AppleTranslator {
    private let target: Locale.Language
    private var sessions: [String: TranslationSession] = [:]

    init(target: Locale.Language = Locale.Language(identifier: "en")) {
        self.target = target
    }

    enum Availability: Sendable { case installed, needsDownload, unsupported }

    func availability(from source: Locale.Language) async -> Availability {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    func translate(_ lines: [EnrichedCaptionLine], from source: Locale.Language) async throws -> [UUID: String] {
        guard !lines.isEmpty else { return [:] }
        let session = try session(for: source)
        let requests = lines.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
        }
        let responses = try await session.translations(from: requests)

        var out: [UUID: String] = [:]
        for r in responses {
            if let idString = r.clientIdentifier, let id = UUID(uuidString: idString) {
                out[id] = r.targetText
            }
        }
        return out
    }

    private func session(for source: Locale.Language) throws -> TranslationSession {
        let key = source.minimalIdentifier
        if let s = sessions[key] { return s }
        // Creating a session outside SwiftUI needs iOS 26; older iOS uses the Databricks fallback.
        guard #available(iOS 26.0, *) else { throw OnDeviceTranslationUnavailable() }
        let s = try TranslationSession(installedSource: source, target: target)
        sessions[key] = s
        return s
    }
}
#endif

// MARK: - Databricks batch translation

enum DatabricksTranslator {
    static func systemPrompt(target: String) -> String {
        """
        You translate a spoken conversation transcript into \(target).
        Rules:
        - Translate every line. Keep the same ids. Return one translation per id.
        - Do NOT translate or include speaker names; they're given only for context.
        - Keep the speaker's tone and the same ending punctuation marks: … — ! ? ?!
        - Lines may mix languages. Translate the meaning naturally.
        - Lines already in \(target) stay unchanged.
        - Reply with JSON only: {"translations":[{"id":"<id>","text":"<translation>"}]}
        """
    }

    static func translate(_ lines: [EnrichedCaptionLine], target: String = "English") async throws -> [UUID: String] {
        guard DatabricksConfig.isConfigured, !lines.isEmpty else { throw DatabricksError.notConfigured }

        struct InLine: Encodable { let id: String; let speaker: String; let text: String }
        let payload = try JSONEncoder().encode(lines.map {
            InLine(id: $0.id.uuidString, speaker: $0.speakerLabel, text: $0.text)
        })
        let userContent = "Conversation lines (JSON):\n" + String(decoding: payload, as: UTF8.self)

        let content = try await DatabricksClient.chat([
            ChatMessage(role: "system", content: systemPrompt(target: target)),
            ChatMessage(role: "user", content: userContent),
        ], maxTokens: 4000)

        struct Result: Decodable { struct Item: Decodable { let id: String; let text: String }; let translations: [Item] }

        let json = extractJSON(content)
        let result = try JSONDecoder().decode(Result.self, from: Data(json.utf8))

        var out: [UUID: String] = [:]
        for item in result.translations {
            if let id = UUID(uuidString: item.id) {
                out[id] = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }

    static func extractJSON(_ s: String) -> String {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") else { return s }
        return String(s[start...end])
    }
}

// MARK: - Pipeline

@available(iOS 18.0, *)
actor TranscriptTranslator {
    private let targetLanguage: Locale.Language
    #if canImport(Translation)
    private let apple: AppleTranslator
    #endif
    private let useDatabricksFinal: Bool

    init(target: Locale.Language = Locale.Language(identifier: "en"), useDatabricksFinal: Bool = true) {
        self.targetLanguage = target
        #if canImport(Translation)
        self.apple = AppleTranslator(target: target)
        #endif
        self.useDatabricksFinal = useDatabricksFinal
    }

    private var targetCode: String { targetLanguage.minimalIdentifier }

    func translateLive(_ lines: [EnrichedCaptionLine]) async -> [TranslatedLine] {
        #if canImport(Translation)
        return await translateLiveApple(lines)
        #else
        return lines.map { keep($0, engine: .failed, source: "und") }
        #endif
    }

    #if canImport(Translation)
    private func translateLiveApple(_ lines: [EnrichedCaptionLine]) async -> [TranslatedLine] {
        let fallbackSource = LanguageDetector.dominantLanguage(of: lines)
        var results: [UUID: TranslatedLine] = [:]
        var bySource: [String: (language: Locale.Language, lines: [EnrichedCaptionLine])] = [:]

        for line in lines {
            let detected = LanguageDetector.detect(line.text)
            let source = (detected.confidence >= 0.6 ? detected.language : nil) ?? fallbackSource
            guard let source else { results[line.id] = keep(line, engine: .failed, source: "und"); continue }

            if source.minimalIdentifier == targetCode {
                results[line.id] = keep(line, engine: .none, source: targetCode)
            } else {
                bySource[source.minimalIdentifier, default: (source, [])].lines.append(line)
            }
        }

        for (code, group) in bySource {
            do {
                let translations = try await apple.translate(group.lines, from: group.language)
                for line in group.lines {
                    if let t = translations[line.id] {
                        results[line.id] = make(line, translated: t, source: code, engine: .apple)
                    } else {
                        results[line.id] = keep(line, engine: .failed, source: code)
                    }
                }
            } catch {
                for line in group.lines { results[line.id] = keep(line, engine: .failed, source: code) }
            }
        }
        return lines.compactMap { results[$0.id] }
    }
    #endif

    func translateFinal(_ lines: [EnrichedCaptionLine]) async -> [TranslatedLine] {
        guard useDatabricksFinal, DatabricksConfig.isConfigured else { return await translateLive(lines) }

        let needsTranslation = lines.filter { line in
            let d = LanguageDetector.detect(line.text)
            return d.isMixed || d.language?.minimalIdentifier != targetCode
        }
        if needsTranslation.isEmpty {
            return lines.map { keep($0, engine: .none, source: targetCode) }
        }

        do {
            let translations = try await DatabricksTranslator.translate(lines, target: Self.languageName(targetLanguage))
            let needed = Set(needsTranslation.map(\.id))
            var missing: [EnrichedCaptionLine] = []
            var results: [UUID: TranslatedLine] = [:]

            for line in lines {
                if !needed.contains(line.id) {
                    results[line.id] = keep(line, engine: .none, source: targetCode)
                } else if let t = translations[line.id], !t.isEmpty {
                    let d = LanguageDetector.detect(line.text)
                    let source = d.isMixed ? "mixed" : (d.language?.minimalIdentifier ?? "und")
                    results[line.id] = make(line, translated: t, source: source, engine: .llm)
                } else {
                    missing.append(line)
                }
            }

            if !missing.isEmpty {
                for r in await translateLive(missing) { results[r.id] = r }
            }
            return lines.compactMap { results[$0.id] }
        } catch {
            return await translateLive(lines)
        }
    }

    private func make(_ line: EnrichedCaptionLine, translated: String, source: String,
                      engine: TranslationEngine) -> TranslatedLine {
        let (text, restored) = TonePreserver.restore(original: line.text, translated: translated)
        return TranslatedLine(id: line.id, speakerID: line.speakerID, speakerLabel: line.speakerLabel,
                              originalText: line.text, translatedText: text,
                              sourceLanguage: source, targetLanguage: targetCode,
                              engine: engine, toneRestored: restored)
    }

    private func keep(_ line: EnrichedCaptionLine, engine: TranslationEngine, source: String) -> TranslatedLine {
        TranslatedLine(id: line.id, speakerID: line.speakerID, speakerLabel: line.speakerLabel,
                       originalText: line.text, translatedText: line.text,
                       sourceLanguage: source, targetLanguage: targetCode,
                       engine: engine, toneRestored: false)
    }

    private static func languageName(_ language: Locale.Language) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: language.minimalIdentifier) ?? "English"
    }
}

// MARK: - SwiftUI: download languages during setup

#if canImport(Translation)
@available(iOS 18.0, *)
private struct PrepareTranslationLanguages: ViewModifier {
    let sources: [Locale.Language]
    let target: Locale.Language
    let onFinished: (Bool) -> Void

    @State private var configuration: TranslationSession.Configuration?
    @State private var index = 0
    @State private var allSucceeded = true

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                do { try await session.prepareTranslation() }
                catch { await MainActor.run { allSucceeded = false } }
                await MainActor.run { advance() }
            }
            .task { start() }
    }

    @MainActor private func start() {
        guard !sources.isEmpty else { onFinished(true); return }
        index = 0
        configuration = .init(source: sources[0], target: target)
    }

    @MainActor private func advance() {
        index += 1
        if index < sources.count {
            configuration = .init(source: sources[index], target: target)
        } else {
            configuration = nil
            onFinished(allSucceeded)
        }
    }
}

@available(iOS 18.0, *)
extension View {
    func prepareTranslationLanguages(_ sourceCodes: [String], target: String = "en",
                                     onFinished: @escaping (Bool) -> Void = { _ in }) -> some View {
        modifier(PrepareTranslationLanguages(
            sources: sourceCodes.map { Locale.Language(identifier: $0) },
            target: Locale.Language(identifier: target),
            onFinished: onFinished))
    }
}
#endif

struct TranslatedLineRow: View {
    let line: TranslatedLine
    let showTranslation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line.speakerLabel).font(.subheadline.weight(.semibold))

            if showTranslation && line.engine != .none {
                Text(line.translatedText)
                Text(line.originalText).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(line.originalText)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}