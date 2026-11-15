// =============================================================================
// SpeakerLabeler.swift — "who said this line?" for finished caption lines.
//
//   recognizer audio (16 kHz) ──► AudioHistory (last 30 s)
//   line finished ──► clip of that line's audio ──► FluidAudio voiceprint
//                ──► SpeakerRecognizer.assign (saved profiles) ──► "Speaker 2" / "Priya"
//
// Live word-by-word captions never wait for this; only the finished line gets
// a name. Short lines (< minSpeech s of voice) get no name: too little audio
// to tell voices apart reliably. Everything runs on-device.
// =============================================================================
import AVFoundation
import Foundation
import FluidAudio

/// The last `seconds` of recognizer audio, with wall-clock times. Any thread.
final class AudioHistory {
    private let lock = NSLock()
    private let capacity: Int
    private var ring: [Float]
    private var written = 0                    // total samples ever written
    private var lastWriteTime: CFAbsoluteTime = 0
    private let rate = 16_000.0

    init(seconds: Double = 30) {
        capacity = Int(seconds * 16_000)
        ring = [Float](repeating: 0, count: capacity)
    }

    func append(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        lock.lock(); defer { lock.unlock() }
        for i in 0..<n { ring[(written + i) % capacity] = ch[i] }
        written += n
        lastWriteTime = CFAbsoluteTimeGetCurrent()
    }

    /// Samples between two wall-clock times (clamped to what is still stored).
    func clip(from start: CFAbsoluteTime, to end: CFAbsoluteTime) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard written > 0, end > start else { return [] }
        let endIdx = written - max(0, Int((lastWriteTime - end) * rate))
        let startIdx = max(written - capacity, endIdx - Int((end - start) * rate), 0)
        guard endIdx > startIdx else { return [] }
        return (startIdx..<endIdx).map { ring[$0 % capacity] }
    }

    func reset() { lock.lock(); written = 0; lock.unlock() }
}

struct SpeakerTag: Sendable, Equatable {
    var profileID: UUID
    var name: String
    var isNew: Bool

    /// Short form for the glasses (≈12 characters per line): "Priya:", "Ad:" or "S2:".
    var glassesTag: String { Self.glassesTag(for: name) }

    static func glassesTag(for name: String) -> String {
        if name.hasPrefix("Speaker "), let n = name.split(separator: " ").last { return "S\(n):" }
        return name.count <= 6 ? "\(name):" : "\(name.prefix(2)):"   // long names: first 2 letters
    }
}

actor SpeakerLabeler {
    static let shared = SpeakerLabeler()

    /// Seconds of actual voice a line needs before we trust its voiceprint.
    static let minSpeech: Double = 1.0

    private var manager: DiarizerManager?
    private var loading: Task<Void, Never>?
    private(set) var lastError: String?

    var isReady: Bool { manager != nil }

    /// Download (first launch only, from Hugging Face) and load the Core ML models.
    func prepare() {
        guard manager == nil, loading == nil else { return }
        loading = Task {
            let t0 = Date()
            do {
                let models = try await DiarizerModels.downloadIfNeeded()
                let m = DiarizerManager()
                m.initialize(models: models)
                manager = m
                Log.add(String(format: "Speakers: voice models ready (%.1f s)", Date().timeIntervalSince(t0)))
            } catch {
                lastError = error.localizedDescription
                Log.add("Speakers: model load failed: \(error.localizedDescription)")
            }
            loading = nil
        }
    }

    /// Name the speaker of one finished line, or nil (models not ready / too little voice).
    func label(_ samples: [Float]) async -> SpeakerTag? {
        guard let manager else { prepare(); return nil }
        let voice = Self.trimSilence(samples)
        let seconds = Double(voice.count) / 16_000
        guard seconds >= Self.minSpeech else { return nil }
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let vp = try manager.extractSpeakerEmbedding(from: voice)
            let tag = await SpeakerRecognizer.shared.assign(voiceprint: vp, speechSeconds: seconds)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if let tag {
                Log.add(String(format: "Speakers: %@ (%.1f s voice, %.0f ms)%@", tag.name, seconds, ms, tag.isNew ? " NEW" : ""))
            }
            return tag
        } catch {
            Log.add("Speakers: voiceprint failed: \(error.localizedDescription)")
            return nil
        }
    }

    enum TeachError: LocalizedError {
        case notReady, tooQuiet(Double)
        var errorDescription: String? {
            switch self {
            case .notReady: return "Voice models are still loading. Try again in a few seconds."
            case .tooQuiet(let s): return String(format: "Only %.1f s of voice heard. Talk continuously, close to the mic.", s)
            }
        }
    }

    /// Voiceprints for "Teach a voice": the whole recording plus overlapping
    /// 3 s windows, so the saved voice covers different moments of the speech.
    func teachingVoiceprints(_ samples: [Float]) throws -> [[Float]] {
        guard let manager else { prepare(); throw TeachError.notReady }
        let voice = Self.trimSilence(samples)
        let seconds = Double(voice.count) / 16_000
        guard seconds >= 3 else { throw TeachError.tooQuiet(seconds) }
        var prints = [try manager.extractSpeakerEmbedding(from: voice)]
        let win = 3 * 16_000, hop = 3 * 8_000
        var i = 0
        while i + win <= voice.count, prints.count < 6 {
            prints.append(try manager.extractSpeakerEmbedding(from: Array(voice[i..<(i + win)])))
            i += hop
        }
        Log.add(String(format: "Speakers: taught %d voiceprints from %.1f s of voice", prints.count, seconds))
        return prints
    }

    /// Keep 20 ms frames that contain voice (energy within 35 dB of the loudest
    /// frame), so pauses and room noise don't dilute the voiceprint.
    static func trimSilence(_ s: [Float]) -> [Float] {
        let frame = 320
        guard s.count >= frame else { return [] }
        var energies: [Float] = []
        var i = 0
        while i + frame <= s.count {
            var e: Float = 0
            for j in i..<(i + frame) { e += s[j] * s[j] }
            energies.append(e / Float(frame))
            i += frame
        }
        guard let peak = energies.max(), peak > 1e-7 else { return [] }
        let floor = peak * 0.000_316          // -35 dB
        var out: [Float] = []
        out.reserveCapacity(s.count)
        for (k, e) in energies.enumerated() where e >= floor {
            out.append(contentsOf: s[(k * frame)..<((k + 1) * frame)])
        }
        return out
    }
}
