// =============================================================================
// CaptionController.swift — glue between audio sources, speech and the glasses.
//
//   phone mic (AudioIO) ──┐
//                         ├─> SpeechEngine ──partials/finals──> BLE TEXT -> OLED
//   glasses mic (BLE) ────┘
//
// Text policy for the small display:
//   * partials are throttled to ~10/s and only sent when they changed
//   * a long running utterance is chopped: once the live part is longer than
//     the display can show, its leading words are committed as a final line,
//     so the glasses never get one huge, constantly re-wrapping partial
// =============================================================================
import AVFoundation
import Combine
import SwiftUI

final class CaptionController: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case phone = "Phone mic"
        case glasses = "Glasses mic"
        var id: String { rawValue }
    }

    // MARK: Published UI state (main thread)
    @Published var source: Source = .glasses { didSet { if source != oldValue { sourceChanged() } } }
    @Published private(set) var running = false
    @Published private(set) var lines: [String] = []          // committed transcript
    @Published private(set) var partial = ""
    @Published private(set) var level: Float = 0               // 0...1 meter
    @Published private(set) var speechStatus = "idle"
    @Published var fontSize = 1 {
        didSet {
            ble.send(.font(fontSize))
            pacer.charsPerLine = charsPerLine; pacer.rows = rows
        }
    }
    /// Play the glasses mic through the phone (use headphones!) to verify audio.
    @Published var monitorGlasses = false { didSet { monitorChanged() } }
    @Published var glassesGain = 4 { didSet { ble.send(.gain(glassesGain)) } }
    @Published private(set) var glassesLostFrames = 0
    /// Glasses mode: if no glasses audio for 1.5 s (disconnected / out of range),
    /// transcribe the phone mic instead until glasses audio comes back.
    @Published var autoFallback = true { didSet { setAudioFlags() } }
    @Published private(set) var usingFallback = false
    /// Speech onset (audio level jumps after >=0.4 s quiet) -> first partial, ms (smoothed).
    @Published private(set) var recognizerMs: Double?
    /// Silence (s) before the live line is committed. Lower = snappier line breaks,
    /// higher = fewer mid-sentence breaks.
    @Published var pauseCommit = 1.0 { didSet { speech.pauseCommit = pauseCommit } }
    @Published var tonePunctuation = UserDefaults.standard.object(forKey: "visense.tonePunctuation") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(tonePunctuation, forKey: "visense.tonePunctuation")
            Task { await CaptionPipeline.shared.setToneEnabled(tonePunctuation) }
        }
    }
    @Published var databricksTone = UserDefaults.standard.bool(forKey: "visense.databricksTone") {
        didSet {
            UserDefaults.standard.set(databricksTone, forKey: "visense.databricksTone")
            Task { await CaptionPipeline.shared.setDatabricksTone(databricksTone) }
        }
    }

    /// Name each finished line's speaker from their voice (FluidAudio, on-device).
    @Published var speakerNames = UserDefaults.standard.object(forKey: "visense.speakerNames") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(speakerNames, forKey: "visense.speakerNames")
            if speakerNames { Task { await SpeakerLabeler.shared.prepare() } }
        }
    }
    @Published private(set) var lastSpeaker: SpeakerTag?

    let ble: BLEManager
    let audio = AudioIO()
    let speech = SpeechEngine()
    private let receiver = GlassesAudioReceiver()     // BLE queue only
    private var reportedLost = 0                       // BLE queue only

    // Mirrors every partial to the glasses instantly (main thread), see WordPacer.swift
    private lazy var pacer = WordPacer(send: { [weak self] m in self?.ble.send(m) })

    // Audio-thread state (guarded by `lock`)
    private let lock = NSLock()
    private var rtSource: Source = .glasses
    private var rtRunning = false
    private var rtMonitor = false
    private var rtAutoFallback = true
    private var rtUsingFallback = false
    private var lastGlassesAudio: CFAbsoluteTime = 0
    private var lastLevelPublish: CFAbsoluteTime = 0
    private var lastLoud: CFAbsoluteTime = 0
    private var pendingOnset: CFAbsoluteTime?

    // Background health counters (main thread) — see README "Locked phone".
    private var backgroundSince: Date?
    private var bgPartials = 0, bgFinals = 0
    private var observers: [NSObjectProtocol] = []

    init(ble: BLEManager) {
        self.ble = ble
        audio.onPhoneMicBuffer = { [weak self] buf in self?.phoneAudio(buf) }
        speech.onPartial = { [weak self] t in self?.handlePartial(t) }
        speech.onFinal = { [weak self] t in self?.handleFinal(t) }
        speech.onStatus = { [weak self] s in self?.speechStatus = s }
        ble.onAudioPacket = { [weak self] p in self?.glassesAudio(p) }
        observeAppState()
        if speakerNames { Task { await SpeakerLabeler.shared.prepare() } }   // first launch downloads models
        // Upload transcripts only while nobody is talking (see TranscriptSync.isQuietNow).
        TranscriptSync.shared.isQuietNow = { [weak self] in
            guard let self, self.running else { return true }
            return CFAbsoluteTimeGetCurrent() - self.lastPartialAt > 4
        }
    }

    // MARK: Controls

    func start() {
        guard !running else { return }
        SpeechEngine.requestPermissions { [weak self] ok in
            guard let self else { return }
            guard ok else { self.speechStatus = "Allow Speech + Microphone in Settings"; return }
            do {
                try self.audio.start()
            } catch {
                self.speechStatus = "Audio error: \(error.localizedDescription)"
                return
            }
            self.running = true
            TranscriptStore.shared.beginSession()
            Task { await CaptionPipeline.shared.beginSession() }
            self.setAudioFlags()
            self.speech.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    func stop() {
        guard running else { return }
        running = false
        commitPendingFinal()
        Task { await CaptionPipeline.shared.endSession() }
        TranscriptSync.shared.flushSoon()  // stopped: upload what's left now
        setAudioFlags()
        speech.stop()
        if !monitorGlasses { audio.stop() }
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// The last `seconds` of the audio being transcribed (for "Teach a voice").
    func recentAudio(seconds: Double) -> [Float] {
        let now = CFAbsoluteTimeGetCurrent()
        return audioHistory.clip(from: now - seconds, to: now)
    }

    func clear() {
        pendingFinal = nil
        lines.removeAll(); partial = ""
        pacer.reset()
        ble.send(.clear)
    }

    func sendTyped(_ text: String, final: Bool) {
        ble.send(final ? .final(text) : .partial(text))
    }

    // MARK: Audio routing (audio / BLE threads)

    private func setAudioFlags() {
        lock.lock()
        rtSource = source; rtRunning = running; rtMonitor = monitorGlasses; rtAutoFallback = autoFallback
        lock.unlock()
        // Only ask the glasses for audio when someone uses it (saves their radio time).
        ble.wantsAudio = monitorGlasses || (running && source == .glasses)
    }

    private func flags() -> (Source, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (rtSource, rtRunning, rtMonitor)
    }

    private func phoneAudio(_ buf: AVAudioPCMBuffer) {
        let (src, run, _) = flags()
        guard run else { return }
        if src == .phone { feedRecognizer(buf); return }
        // Glasses mode: the phone mic normally only keeps the app alive in the background.
        lock.lock()
        let fallback = rtAutoFallback && CFAbsoluteTimeGetCurrent() - lastGlassesAudio > 1.5
        let changed = fallback != rtUsingFallback
        rtUsingFallback = fallback
        lock.unlock()
        if changed {
            Log.add(fallback ? "No glasses audio -> using phone mic" : "Glasses audio back")
            DispatchQueue.main.async { self.usingFallback = fallback }
        }
        if fallback { feedRecognizer(buf) }
    }

    /// Glasses mic packet (BLE queue): decode, fill gaps, route.
    private func glassesAudio(_ packet: Data) {
        guard let samples = receiver.process(packet), let buf = AVAudioPCMBuffer.make16k(from: samples) else { return }
        let (src, run, mon) = flags()
        lock.lock(); lastGlassesAudio = CFAbsoluteTimeGetCurrent(); let fb = rtUsingFallback; lock.unlock()
        if fb { return }                 // phone mic is feeding; it hands back within 20 ms
        if mon { audio.play(buf) }
        if run && src == .glasses {
            feedRecognizer(buf)         // glasses mic -> speech -> glasses OLED
        } else if mon {
            publishLevel(buf.rmsDBFS)
        }
        let lost = receiver.lostFrames
        if lost != reportedLost { reportedLost = lost; DispatchQueue.main.async { self.glassesLostFrames = lost } }
    }

    private func monitorChanged() {
        if monitorGlasses && !audio.isRunning {
            do { try audio.start() } catch { Log.add("Monitor: \(error.localizedDescription)") }
        }
        if !monitorGlasses && !running { audio.stop() }
        setAudioFlags()
    }

    /// Single entry point for audio that should be transcribed.
    private func feedRecognizer(_ buf: AVAudioPCMBuffer) {
        speech.append(buf)
        audioHistory.append(buf)           // for speaker voiceprints of finished lines
        let db = buf.rmsDBFS
        publishLevel(db)
        // Latency probe: remember when speech starts after a pause.
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if db > -42 {
            if now - lastLoud > 0.4 && pendingOnset == nil { pendingOnset = now }
            lastLoud = now
        }
        lock.unlock()
    }

    /// Called on main when the recognizer produced new text.
    private func measureRecognizerLatency() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); let onset = pendingOnset; pendingOnset = nil; lock.unlock()
        guard let onset else { return }
        let ms = (now - onset) * 1000
        guard ms > 30 && ms < 3000 else { return }    // ignore nonsense samples
        recognizerMs = recognizerMs.map { $0 * 0.7 + ms * 0.3 } ?? ms
        Log.add(String(format: "Latency: speech onset -> partial %.0f ms", ms))
    }

    private func publishLevel(_ db: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let due = now - lastLevelPublish > 0.05
        if due { lastLevelPublish = now }
        lock.unlock()
        guard due else { return }
        let v = max(0, min(1, (db + 60) / 60))      // -60 dBFS..0 -> 0..1
        Task { await CaptionPipeline.shared.noteLevel(v) }
        DispatchQueue.main.async { self.level = v }
    }

    private func sourceChanged() {
        setAudioFlags()
        Log.add("Source: \(source.rawValue)")
    }

    // MARK: Background / locked phone

    /// Logs how much work happened while the app was in the background, so you
    /// can verify on the device that captions kept flowing with the phone locked.
    private func observeAppState() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.backgroundSince = Date(); self.bgPartials = 0; self.bgFinals = 0
            Log.add("App -> background (running=\(self.running), audio engine=\(self.audio.isRunning))")
        })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let since = self.backgroundSince else { return }
            self.backgroundSince = nil
            let secs = Int(Date().timeIntervalSince(since))
            Log.add("App -> foreground after \(secs) s: \(self.bgPartials) partials, \(self.bgFinals) finals in background")
            // If something stopped the audio engine meanwhile, bring it back.
            if self.running && !self.audio.isRunning { try? self.audio.start() }
        })
    }

    // MARK: Text policy (main thread)

    /// Characters per line / rows for each glasses font size (matches firmware).
    private var charsPerLine: Int { [18, 12, 9][min(max(fontSize, 0), 2)] }
    private var rows: Int { [4, 3, 2][min(max(fontSize, 0), 2)] }

    private func handlePartial(_ text: String) {
        if backgroundSince != nil { bgPartials += 1 }
        measureRecognizerLatency()
        commitPendingFinal()               // next sentence started: never hold it back
        let now = CFAbsoluteTimeGetCurrent()
        if utteranceStart == nil { utteranceStart = now - 1.0 }   // first partial lags speech ~1 s
        lastPartialAt = now
        partial = text
        Task { await CaptionPipeline.shared.notePartialActivity() }
        pacer.partial(text)                // same text, same moment, on the glasses
    }

    // A finished line waits briefly for tone punctuation / translation, but live
    // text never waits for it: if the next sentence starts first, or the pipeline
    // takes longer than `polishDeadline` (Databricks / translation are network
    // calls that can take seconds when rate-limited), the raw line is committed
    // and the polished one only replaces it in the app list + saved transcript.
    private var pendingFinal: (id: UUID, raw: String)?
    private var utteranceStart: CFAbsoluteTime?
    private var lastPartialAt: CFAbsoluteTime = 0
    private let audioHistory = AudioHistory(seconds: 30)
    private let polishDeadline: TimeInterval = 2.0

    private func handleFinal(_ text: String) {
        if backgroundSince != nil { bgFinals += 1 }
        commitPendingFinal()               // two finals in a row: flush the older one
        partial = ""
        let id = UUID()
        pendingFinal = (id, text)
        let level = level
        // This line's audio: from ~1 s before its first word to just after its last.
        let start = max(utteranceStart ?? lastPartialAt - 3, lastPartialAt - 10)
        let clip = speakerNames ? audioHistory.clip(from: start, to: lastPartialAt + 0.25) : []
        let durationMs = Int(max(0.3, lastPartialAt + 0.25 - start) * 1000)   // talk time for analytics
        utteranceStart = nil
        Task {
            async let polished = Self.withDeadline(polishDeadline, fallback: text) {
                await CaptionPipeline.shared.finishLine(text, speechLevel: level)
            }
            async let speaker: SpeakerTag? = clip.isEmpty ? nil : Self.withDeadline(polishDeadline, fallback: nil) {
                await SpeakerLabeler.shared.label(clip)
            }
            let (line, tag) = await (polished, speaker)
            await MainActor.run {
                let shown = tag.map { "\($0.name): \(line)" } ?? line
                if self.pendingFinal?.id == id {
                    self.pendingFinal = nil
                    self.commitLine(line, tag: tag)    // in time: glasses get the name + punctuated line
                } else if let i = self.lines.lastIndex(of: text), shown != text {
                    self.lines[i] = shown              // already shown raw: name/polish the app copy
                }
                if let tag { self.lastSpeaker = tag }
                TranscriptStore.shared.add(line.isEmpty ? text : shown,          // memory for History / Ask
                                           speaker: tag?.name, durationMs: durationMs)
            }
        }
    }

    /// Commit a waiting final as-is (its polished text still goes to the store later).
    private func commitPendingFinal() {
        guard let p = pendingFinal else { return }
        pendingFinal = nil
        commitLine(p.raw)
    }

    private func commitLine(_ line: String, tag: SpeakerTag? = nil) {
        pacer.final(line, prefix: tag?.glassesTag)
        guard !line.isEmpty else { return }
        lines.append(tag.map { "\($0.name): \(line)" } ?? line)
        if lines.count > 100 { lines.removeFirst(lines.count - 100) }
    }

    /// Result of `op`, or `fallback` if it takes longer than `seconds`.
    private static func withDeadline<T: Sendable>(_ seconds: TimeInterval, fallback: T,
                                                  _ op: @escaping @Sendable () async -> T) async -> T {
        let once = OnceFlag()
        return await withCheckedContinuation { c in
            Task { let r = await op(); if once.take() { c.resume(returning: r) } }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.take() { c.resume(returning: fallback) }
            }
        }
    }
}

/// Lets exactly one of several racing tasks win (see `withDeadline`).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
