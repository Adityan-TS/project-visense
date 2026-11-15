// =============================================================================
// SpeakerRecognition.swift — speaker profiles + diarization glue for the
// tone/translation pipeline. Voiceprints stay on-device.
//
// With FluidAudio: full diarization. Without it, live captions use a single
// default profile ("You") from CaptionPipeline.
// =============================================================================
import Foundation

// MARK: - Input from diarization

struct DiarizedSegment: Sendable {
    var localSpeakerID: String
    var start: TimeInterval
    var end: TimeInterval
    var embedding: [Float]?

    var duration: TimeInterval { end - start }
}

// MARK: - Saved profiles

struct SpeakerProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var displayName: String?
    var isOwner: Bool
    var unnamedNumber: Int
    var embeddings: [[Float]]
    var recordingCount: Int
    var firstSeen: Date
    var lastSeen: Date
    var averageLoudness: Double?
    var loudnessSamples: Int

    var label: String {
        if isOwner { return displayName ?? "You" }
        return displayName ?? "Speaker \(unnamedNumber)"
    }
    var isNamed: Bool { isOwner || displayName != nil }
}

enum MatchStatus: Equatable, Sendable {
    case identified
    case needsConfirmation(candidate: UUID, score: Float)
    case newSpeaker
    case unknown
}

struct RecognizedSpeaker: Identifiable, Sendable {
    var id: String { localSpeakerID }
    var localSpeakerID: String
    var profileID: UUID?
    var label: String
    var status: MatchStatus
    var score: Float
    var voiceprint: [Float]?
}

// MARK: - Recognizer

actor SpeakerRecognizer {
    struct Config: Sendable {
        var autoMatch: Float = 0.75
        var askToConfirm: Float = 0.60
        var minCleanSegment: TimeInterval = 3.0
        var maxEmbeddingsPerProfile = 20
        var anchorCount = 3
        var askToNameAfterRecordings = 3
    }

    static let shared = SpeakerRecognizer()

    private(set) var profiles: [SpeakerProfile] = []
    private let config: Config
    private let storeURL: URL

    init(config: Config = Config(), storeURL: URL? = nil) {
        self.config = config
        self.storeURL = storeURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("speaker_profiles.json")
        if let data = try? Data(contentsOf: self.storeURL),
           let saved = try? JSONDecoder().decode([SpeakerProfile].self, from: data) {
            profiles = saved
        }
        ensureOwnerProfile()
    }

    /// Stable owner row for single-speaker / phone-mic captions.
    private func ensureOwnerProfile() {
        guard !profiles.contains(where: \.isOwner) else { return }
        let now = Date()
        profiles.append(SpeakerProfile(id: UUID(), displayName: nil, isOwner: true, unnamedNumber: 0,
                                       embeddings: [], recordingCount: 0, firstSeen: now, lastSeen: now,
                                       averageLoudness: nil, loudnessSamples: 0))
        save()
    }

    var ownerProfileID: UUID? { profiles.first(where: \.isOwner)?.id }

    func recognize(_ segments: [DiarizedSegment], at date: Date = Date()) -> [RecognizedSpeaker] {
        let clusters = Dictionary(grouping: segments, by: \.localSpeakerID)
        var voiceprints: [String: [Float]] = [:]
        for (localID, segs) in clusters {
            if let vp = clusterVoiceprint(segs) { voiceprints[localID] = vp }
        }

        var candidates: [(local: String, profile: Int, score: Float)] = []
        for (localID, vp) in voiceprints {
            for (pi, profile) in profiles.enumerated() {
                let score = profile.embeddings.map { Self.cosine(vp, $0) }.max() ?? -1
                if score >= config.askToConfirm { candidates.append((localID, pi, score)) }
            }
        }

        candidates.sort { $0.score > $1.score }
        var usedLocal = Set<String>(), usedProfile = Set<Int>()
        var results: [String: RecognizedSpeaker] = [:]

        for c in candidates where !usedLocal.contains(c.local) && !usedProfile.contains(c.profile) {
            usedLocal.insert(c.local); usedProfile.insert(c.profile)
            let profile = profiles[c.profile]
            if c.score >= config.autoMatch {
                let isClean = clusters[c.local]?.contains { $0.duration >= config.minCleanSegment } ?? false
                updateProfile(at: c.profile, with: isClean ? voiceprints[c.local] : nil, seenAt: date)
                results[c.local] = RecognizedSpeaker(localSpeakerID: c.local, profileID: profile.id,
                                                     label: profiles[c.profile].label, status: .identified,
                                                     score: c.score, voiceprint: voiceprints[c.local])
            } else {
                results[c.local] = RecognizedSpeaker(localSpeakerID: c.local, profileID: profile.id,
                                                     label: profile.label + "?",
                                                     status: .needsConfirmation(candidate: profile.id, score: c.score),
                                                     score: c.score, voiceprint: voiceprints[c.local])
            }
        }

        for localID in clusters.keys where results[localID] == nil {
            if let vp = voiceprints[localID] {
                let p = createProfile(voiceprint: vp, at: date)
                results[localID] = RecognizedSpeaker(localSpeakerID: localID, profileID: p.id, label: p.label,
                                                     status: .newSpeaker, score: 0, voiceprint: vp)
            } else {
                results[localID] = RecognizedSpeaker(localSpeakerID: localID, profileID: nil,
                                                     label: "Unknown speaker", status: .unknown,
                                                     score: 0, voiceprint: nil)
            }
        }

        save()
        return clusters.keys.sorted().compactMap { results[$0] }
    }

    func resolveConfirmation(_ speaker: RecognizedSpeaker, accepted: Bool,
                             at date: Date = Date()) -> RecognizedSpeaker {
        guard case .needsConfirmation(let candidateID, let score) = speaker.status else { return speaker }
        var updated = speaker

        if accepted, let index = profiles.firstIndex(where: { $0.id == candidateID }) {
            updateProfile(at: index, with: speaker.voiceprint, seenAt: date)
            updated.profileID = candidateID
            updated.label = profiles[index].label
            updated.status = .identified
            updated.score = score
        } else if let vp = speaker.voiceprint {
            let p = createProfile(voiceprint: vp, at: date)
            updated.profileID = p.id
            updated.label = p.label
            updated.status = .newSpeaker
        }
        save()
        return updated
    }

    func enrollOwner(from segments: [DiarizedSegment], name: String? = nil, at date: Date = Date()) {
        func talkTime(_ segs: [DiarizedSegment]) -> TimeInterval { segs.reduce(0) { $0 + $1.duration } }
        let byTalkTime = Dictionary(grouping: segments, by: \.localSpeakerID)
            .max { a, b in talkTime(a.value) < talkTime(b.value) }
        guard let segs = byTalkTime?.value, let vp = clusterVoiceprint(segs) else { return }

        if let i = profiles.firstIndex(where: \.isOwner) {
            profiles[i].embeddings.insert(vp, at: 0)
            profiles[i].displayName = name ?? profiles[i].displayName
        } else {
            profiles.append(SpeakerProfile(id: UUID(), displayName: name, isOwner: true, unnamedNumber: 0,
                                           embeddings: [vp], recordingCount: 0, firstSeen: date, lastSeen: date,
                                           averageLoudness: nil, loudnessSamples: 0))
        }
        save()
    }

    // MARK: Live captions: one voiceprint per finished line

    /// Similarity (cosine, FluidAudio/WeSpeaker voiceprints of single caption lines)
    /// above which a line is the same person. Calibrated in tools/speakers.
    static let lineMatch: Float = 0.50
    /// Only very confident matches from longer lines refine the saved voice.
    static let lineUpdate: Float = 0.65
    /// A brand-new speaker needs this much voice (short lines are too noisy).
    static let newSpeakerSeconds: Double = 1.5

    /// Match one line's voiceprint to a saved speaker, or create "Speaker N".
    /// nil = not sure (no match and too short to start a new speaker).
    func assign(voiceprint raw: [Float], speechSeconds: Double, at date: Date = Date()) -> SpeakerTag? {
        let vp = Self.normalized(raw)
        var best: (index: Int, score: Float)?
        for (i, p) in profiles.enumerated() where !p.embeddings.isEmpty {
            // Average of the 3 closest saved prints: robust to one odd recording.
            let top = p.embeddings.map { Self.cosine(vp, $0) }.sorted(by: >).prefix(3)
            let score = top.reduce(0, +) / Float(top.count)
            if score > (best?.score ?? -1) { best = (i, score) }
        }
        if let b = best, b.score >= Self.lineMatch {
            let refine = b.score >= Self.lineUpdate && speechSeconds >= 2.0
            updateProfile(at: b.index, with: refine ? vp : nil, seenAt: date)
            save()
            return SpeakerTag(profileID: profiles[b.index].id, name: profiles[b.index].label, isNew: false)
        }
        guard speechSeconds >= Self.newSpeakerSeconds else { return nil }
        let p = createProfile(voiceprint: vp, at: date)
        save()
        return SpeakerTag(profileID: p.id, name: p.label, isNew: true)
    }

    /// "Teach a voice": save several voiceprints of one person under a name.
    /// Same name as an existing speaker = add to that person (more angles of their voice).
    /// Taught prints go first, so they are kept as anchors when the list is trimmed.
    func enroll(name: String, voiceprints: [[Float]], at date: Date = Date()) -> SpeakerTag? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let vps = voiceprints.map(Self.normalized)
        guard !n.isEmpty, !vps.isEmpty else { return nil }
        if let i = profiles.firstIndex(where: { ($0.displayName ?? "").caseInsensitiveCompare(n) == .orderedSame }) {
            profiles[i].embeddings.insert(contentsOf: vps, at: 0)
            profiles[i].lastSeen = date
            trimEmbeddings(at: i)
            save()
            return SpeakerTag(profileID: profiles[i].id, name: profiles[i].label, isNew: false)
        }
        let taken = Set(profiles.filter { !$0.isNamed }.map(\.unnamedNumber))
        let p = SpeakerProfile(id: UUID(), displayName: n, isOwner: false, unnamedNumber: (1...).first { !taken.contains($0) }!,
                               embeddings: vps, recordingCount: 0, firstSeen: date, lastSeen: date,
                               averageLoudness: nil, loudnessSamples: 0)
        profiles.append(p)
        save()
        return SpeakerTag(profileID: p.id, name: n, isNew: true)
    }

    /// Speakers heard in captions (have a voiceprint), most recent first.
    func heardSpeakers() -> [SpeakerProfile] {
        profiles.filter { !$0.embeddings.isEmpty }.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Forget every voice (keeps the owner row).
    func forgetAll() {
        profiles.removeAll { !$0.isOwner }
        save()
    }

    func rename(_ profileID: UUID, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        profiles[i].displayName = trimmed.isEmpty ? nil : trimmed
        if trimmed.isEmpty, !profiles[i].isOwner {           // back to "Speaker N": take a free N
            let taken = Set(profiles.indices.filter { $0 != i && !profiles[$0].isNamed }.map { profiles[$0].unnamedNumber })
            profiles[i].unnamedNumber = (1...).first { !taken.contains($0) }!
        }
        save()
    }

    func profilesToName() -> [SpeakerProfile] {
        profiles.filter { !$0.isNamed && $0.recordingCount >= config.askToNameAfterRecordings }
            .sorted { $0.recordingCount > $1.recordingCount }
    }

    func merge(keep: UUID, remove: UUID) {
        guard keep != remove,
              let k = profiles.firstIndex(where: { $0.id == keep }),
              let r = profiles.firstIndex(where: { $0.id == remove }) else { return }
        let other = profiles[r]
        profiles[k].embeddings = Array((profiles[k].embeddings + other.embeddings)
            .prefix(config.maxEmbeddingsPerProfile))
        profiles[k].recordingCount += other.recordingCount
        profiles[k].firstSeen = min(profiles[k].firstSeen, other.firstSeen)
        profiles[k].lastSeen = max(profiles[k].lastSeen, other.lastSeen)
        if profiles[k].displayName == nil { profiles[k].displayName = other.displayName }
        profiles.remove(at: r)
        save()
    }

    func delete(_ profileID: UUID) {
        profiles.removeAll { $0.id == profileID && !$0.isOwner }
        save()
    }

    func label(for profileID: UUID?) -> String {
        guard let profileID, let p = profiles.first(where: { $0.id == profileID }) else { return "Unknown speaker" }
        return p.label
    }

    func loudnessRatio(for profileID: UUID?, rms: Double) -> Double {
        guard rms > 0, let profileID, let i = profiles.firstIndex(where: { $0.id == profileID }) else { return 1 }
        let ratio = profiles[i].averageLoudness.map { $0 > 0 ? rms / $0 : 1 } ?? 1
        let n = Double(min(profiles[i].loudnessSamples, 200))
        profiles[i].averageLoudness = ((profiles[i].averageLoudness ?? rms) * n + rms) / (n + 1)
        profiles[i].loudnessSamples += 1
        return ratio
    }

    func persist() { save() }

    private func clusterVoiceprint(_ segs: [DiarizedSegment]) -> [Float]? {
        let clean = segs.filter { $0.duration >= config.minCleanSegment && $0.embedding != nil }
        let source = clean.isEmpty ? segs.filter { $0.embedding != nil } : clean
        let vectors = source.compactMap(\.embedding)
        guard let first = vectors.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == sum.count {
            for i in 0..<sum.count { sum[i] += v[i] }
        }
        return Self.normalized(sum)
    }

    private func updateProfile(at index: Int, with voiceprint: [Float]?, seenAt date: Date) {
        profiles[index].recordingCount += 1
        profiles[index].lastSeen = date
        guard let vp = voiceprint else { return }
        profiles[index].embeddings.append(vp)
        trimEmbeddings(at: index)
    }

    private func trimEmbeddings(at index: Int) {
        let maxCount = config.maxEmbeddingsPerProfile
        guard profiles[index].embeddings.count > maxCount else { return }
        let dropFrom = min(config.anchorCount, profiles[index].embeddings.count)
        let toRemove = profiles[index].embeddings.count - maxCount
        let dropEnd = min(dropFrom + toRemove, profiles[index].embeddings.count)
        guard dropEnd > dropFrom else { return }
        profiles[index].embeddings.removeSubrange(dropFrom..<dropEnd)
    }

    private func createProfile(voiceprint: [Float], at date: Date) -> SpeakerProfile {
        // Lowest number not used by another UNNAMED speaker: once "Speaker 1" is
        // named Priya, the next new voice is "Speaker 1" again, not "Speaker 2".
        let taken = Set(profiles.filter { !$0.isNamed }.map(\.unnamedNumber))
        let next = (1...).first { !taken.contains($0) }!
        let p = SpeakerProfile(id: UUID(), displayName: nil, isOwner: false, unnamedNumber: next,
                               embeddings: [voiceprint], recordingCount: 1, firstSeen: date, lastSeen: date,
                               averageLoudness: nil, loudnessSamples: 0)
        profiles.append(p)
        return p
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: storeURL, options: [.atomic, .completeFileProtection])
        } catch {
            Log.add("SpeakerRecognizer save failed: \(error.localizedDescription)")
        }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : -1
    }
}

// MARK: - Build Utterances (offline / FluidAudio path)

enum UtteranceBuilder {
    static func build(
        words: [TimedWord],
        segments: [DiarizedSegment],
        speakers: [RecognizedSpeaker],
        recognizer: SpeakerRecognizer,
        emotion: (DiarizedSegment) async -> (VoiceEmotion, Double),
        rms: (DiarizedSegment) -> Double
    ) async -> [Utterance] {
        let sorted = segments.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }
        let speakerByLocal = Dictionary(uniqueKeysWithValues: speakers.map { ($0.localSpeakerID, $0) })

        var wordsBySegment = [[TimedWord]](repeating: [], count: sorted.count)
        for word in words {
            let mid = (word.start + word.end) / 2
            let index: Int
            if let containing = sorted.firstIndex(where: { mid >= $0.start && mid <= $0.end }) {
                index = containing
            } else if let nearest = sorted.indices.min(by: { distance(mid, sorted[$0]) < distance(mid, sorted[$1]) }) {
                index = nearest
            } else { continue }
            wordsBySegment[index].append(word)
        }

        var utterances: [Utterance] = []
        for (i, seg) in sorted.enumerated() where !wordsBySegment[i].isEmpty {
            let next = i + 1 < sorted.count ? sorted[i + 1] : nil
            let speaker = speakerByLocal[seg.localSpeakerID]
            let (tone, confidence) = await emotion(seg)
            let ratio = await recognizer.loudnessRatio(for: speaker?.profileID, rms: rms(seg))

            let interrupted = next.map { $0.localSpeakerID != seg.localSpeakerID && $0.start < seg.end - 0.05 } ?? false
            let pauseAfter = next.map { max(0, $0.start - seg.end) } ?? 0

            utterances.append(Utterance(
                speakerID: speaker?.profileID?.uuidString ?? seg.localSpeakerID,
                words: wordsBySegment[i],
                cues: UtteranceCues(emotion: tone, confidence: confidence, loudnessRatio: ratio,
                                    interrupted: interrupted, pauseAfter: pauseAfter)))
        }
        await recognizer.persist()
        return utterances
    }

    private static func distance(_ t: TimeInterval, _ s: DiarizedSegment) -> TimeInterval {
        t < s.start ? s.start - t : (t > s.end ? t - s.end : 0)
    }
}

#if canImport(FluidAudio)
import FluidAudio

actor FluidAudioDiarizer {
    private var manager: OfflineDiarizerManager?

    func prepare() async throws {
        guard manager == nil else { return }
        let m = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await m.prepareModels()
        manager = m
    }

    func diarize(fileURL: URL) async throws -> [DiarizedSegment] {
        try await prepare()
        guard let manager else { return [] }
        let result = try await manager.process(fileURL)
        return result.segments.map { segment in
            DiarizedSegment(
                localSpeakerID: "\(segment.speakerId)",
                start: TimeInterval(segment.startTimeSeconds),
                end: TimeInterval(segment.endTimeSeconds),
                embedding: segment.embedding
            )
        }
    }
}
#endif