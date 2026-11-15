// =============================================================================
// SpeechEngine.swift — continuous streaming speech recognition.
//
// SFSpeechRecognizer is built for one utterance per task, so we run a chain
// of tasks and rotate seamlessly:
//
//   * PAUSE: partial text unchanged for `pauseCommit` s  -> commit it as a final
//            but KEEP the same task running (a fresh task needs ~1 s to warm
//            up before its first partial, which made the first words of every
//            sentence slow). We just remember how many words of the task's
//            transcript are already committed and only report what follows.
//   * FINAL from the recognizer (e.g. server 1-min limit) -> commit + new task.
//   * ERROR / timeout / "no speech" after long silence    -> commit what we had,
//            restart (with back-off if it keeps failing). Audio arriving while no
//            task exists is buffered in `pending` and fed to the next task.
//   * The task is replaced during a silence once it is older than
//     `maxRequestSeconds` (55 s for server recognition = its 1-min limit,
//     4 min on-device), so the transcript doesn't grow forever.
//
// requiresOnDeviceRecognition = true when supported -> no network, no 1-minute
// server limit, lower latency.
// =============================================================================
import AVFoundation
import Speech

final class SpeechEngine: NSObject {
    /// Full text of the current utterance so far (main thread).
    var onPartial: ((String) -> Void)?
    /// Committed utterance (main thread).
    var onFinal: ((String) -> Void)?
    /// Human readable state for the UI (main thread).
    var onStatus: ((String) -> Void)?

    var pauseCommit: TimeInterval = 1.0        // silence before a line is committed
    private var maxRequestSeconds: TimeInterval = 55

    private let queue = DispatchQueue(label: "visense.speech", qos: .userInteractive)
    private let recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskID = 0
    private var running = false
    private var lastPartial = ""               // uncommitted words of the current utterance
    private var taskWords: [String] = []       // full transcript of the current task
    private var committedWords = 0             // how many of `taskWords` are already final
    private var committedSnapshot: [String] = []   // `taskWords` at the last commit
    private var lastPartialTime: CFAbsoluteTime = 0
    private var requestStart: CFAbsoluteTime = 0
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingFrames: AVAudioFrameCount = 0
    private var errorStreak = 0
    private var watchdog: DispatchSourceTimer?

    init(localeID: String = "en-US") {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID))
        super.init()
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        recognizer?.queue = q                     // results off the main thread
        recognizer?.delegate = self
    }

    var onDeviceSupported: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    static func requestPermissions(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { micOK in
                DispatchQueue.main.async { done(status == .authorized && micOK) }
            }
        }
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.errorStreak = 0
            self.startRequest()
            self.startWatchdog()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.watchdog?.cancel(); self.watchdog = nil
            self.commitIfNeeded()
            self.taskID += 1
            self.task?.cancel(); self.task = nil
            self.request = nil
            self.pending.removeAll(); self.pendingFrames = 0
            self.status("stopped")
        }
    }

    /// Feed 16 kHz mono audio. Any thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async {
            guard self.running else { return }
            if let r = self.request {
                r.append(buffer)
            } else {
                // Between tasks: keep up to ~5 s so nothing is lost during a restart.
                self.pending.append(buffer)
                self.pendingFrames += buffer.frameLength
                while self.pendingFrames > 5 * 16_000, !self.pending.isEmpty {
                    self.pendingFrames -= self.pending.removeFirst().frameLength
                }
            }
        }
    }

    // MARK: - Private (all on `queue`)

    private func startRequest() {
        guard running else { return }
        guard let rec = recognizer, rec.isAvailable else {
            status("recognizer unavailable, retrying…")
            retry(after: 1)
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        maxRequestSeconds = req.requiresOnDeviceRecognition ? 240 : 55
        req.taskHint = .dictation
        req.addsPunctuation = true

        taskID += 1
        let id = taskID
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            self?.queue.async { self?.handle(id: id, result: result, error: error) }
        }
        request = req
        requestStart = CFAbsoluteTimeGetCurrent()
        lastPartial = ""
        taskWords = []
        committedWords = 0
        committedSnapshot = []
        // Flush audio that arrived while there was no task.
        for b in pending { req.append(b) }
        pending.removeAll(); pendingFrames = 0
        status(req.requiresOnDeviceRecognition ? "listening (on-device)" : "listening (server, 1-min limit)")
    }

    private func handle(id: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        guard id == taskID, running else { return }     // stale callback from a rotated task
        if let result {
            taskWords = result.bestTranscription.formattedString
                .split(separator: " ").map(String.init)
            realignCommitted()
            // Only the words after the last committed line belong to this utterance.
            let text = taskWords.dropFirst(min(committedWords, taskWords.count)).joined(separator: " ")
            errorStreak = 0
            if result.isFinal {
                if !text.isEmpty { emitFinal(text) }
                lastPartial = ""
                rotate(commit: false)
                return
            }
            if text != lastPartial {
                lastPartial = text
                lastPartialTime = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async { self.onPartial?(text) }
            }
        }
        if let error {
            let ns = error as NSError
            let lived = CFAbsoluteTimeGetCurrent() - requestStart
            Log.add("Speech: task ended \(ns.domain) \(ns.code) after \(Int(lived)) s: \(ns.localizedDescription)")
            commitIfNeeded()
            task = nil; request = nil                    // audio now goes to `pending`
            // A task that ran a while and then ended (silence timeout etc.) is normal.
            errorStreak = lived > 3 ? 0 : errorStreak + 1
            retry(after: errorStreak == 0 ? 0 : min(5, 0.25 * pow(2, Double(errorStreak))))
        }
    }

    /// End the current task and immediately start a new one (no audio gap).
    private func rotate(commit: Bool) {
        if commit { commitIfNeeded() }
        taskID += 1                     // ignore anything the old task still says
        task?.cancel()
        request?.endAudio()
        task = nil; request = nil
        startRequest()
    }

    private func commitIfNeeded() {
        if !lastPartial.isEmpty { emitFinal(lastPartial); lastPartial = "" }
        committedWords = taskWords.count
        committedSnapshot = taskWords
    }

    /// The recognizer doesn't always keep the whole task transcript: after a pause
    /// it can start over with only the new words, or rewrite/shorten what it had.
    /// Counting "first N words are already shown" then hides every new word until
    /// the speaker has said more than N again, i.e. captions stop after a sentence.
    private func realignCommitted() {
        guard committedWords > 0 else { return }
        let n = Self.alignedCommitCount(snapshot: committedSnapshot, committed: committedWords, words: taskWords)
        if n == 0 {
            Log.add("Speech: recognizer restarted its transcript, showing new words")
            committedSnapshot = []
        }
        committedWords = n
    }

    /// How many leading words of `words` (the recognizer's current transcript) were
    /// already shown, given the transcript `snapshot` at the last commit (whose first
    /// `committed` words were shown). Pure, unit-tested in tools/realign.
    ///  1. Find where the last shown words END in the new transcript (near the old
    ///     position). Robust to the recognizer rewriting earlier words.
    ///  2. Not found, but the start still mostly matches -> same transcript with a
    ///     rewritten tail: keep the count (never re-show = no duplicate lines).
    ///  3. Otherwise the recognizer started over -> 0 (all of it is new speech).
    static func alignedCommitCount(snapshot: [String], committed: Int, words: [String]) -> Int {
        guard committed > 0, !snapshot.isEmpty else { return 0 }
        func norm(_ w: String) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let s = snapshot.prefix(committed).map(norm), w = words.map(norm)

        for m in stride(from: min(3, s.count), through: 2, by: -1) {
            let tail = Array(s.suffix(m))
            let candidates = (max(m, committed - 4)...max(m, committed + 4)).filter { $0 <= w.count }
            if let p = candidates.sorted(by: { abs($0 - committed) < abs($1 - committed) })
                .first(where: { Array(w[($0 - m)..<$0]) == tail }) {
                return p
            }
        }
        // Just the last shown word, if it's distinctive, close to where it was.
        if let last = s.last, last.count >= 4 {
            let candidates = (max(1, committed - 2)...max(1, committed + 2)).filter { $0 <= w.count }
            if let p = candidates.sorted(by: { abs($0 - committed) < abs($1 - committed) })
                .first(where: { w[$0 - 1] == last }) {
                return p
            }
        }
        let n = min(s.count, w.count)
        let same = (0..<n).filter { s[$0] == w[$0] }.count
        if n > 0 && Double(same) >= Double(min(s.count, 4)) * 0.5 && same * 2 >= n {
            return min(committed, w.count)
        }
        return 0
    }

    private func emitFinal(_ text: String) {
        DispatchQueue.main.async { self.onFinal?(text) }
    }

    private func retry(after seconds: TimeInterval) {
        queue.asyncAfter(deadline: .now() + seconds) {
            if self.running && self.request == nil { self.startRequest() }
        }
    }

    /// 10 Hz: detect pauses (commit line) and over-long requests.
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self, self.running, self.request != nil else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if !self.lastPartial.isEmpty && now - self.lastPartialTime > self.pauseCommit {
                // Speaker paused: commit the line, keep the (warm) task running.
                self.commitIfNeeded()
            } else if now - self.requestStart > self.maxRequestSeconds &&
                        now - self.lastPartialTime > 1.5 {
                self.rotate(commit: true)                          // old task, during silence
            }
        }
        t.resume()
        watchdog = t
    }

    private func status(_ s: String) {
        Log.add("Speech: \(s)")
        DispatchQueue.main.async { self.onStatus?(s) }
    }
}

extension SpeechEngine: SFSpeechRecognizerDelegate {
    func speechRecognizer(_ r: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Log.add("Speech: recognizer available = \(available)")
    }
}
