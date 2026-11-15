// =============================================================================
// AudioIO.swift — AVAudioSession + AVAudioEngine.
//
// * Phone mic: input tap, converted to 16 kHz mono Float32 (same format as the
//   glasses audio, so the rest of the pipeline doesn't care where audio came from).
// * Monitor: a player node to listen to the glasses mic (Milestone 4 check).
// * Background keep-alive: the engine keeps the mic input running even in
//   "glasses mic" mode. An app that is actively recording (with the `audio`
//   background mode) is never suspended by iOS, and speech recognition keeps
//   being allowed. That's why you'll see the orange mic dot while captioning.
// =============================================================================
import AVFoundation

final class AudioIO {
    /// The one format used everywhere downstream.
    static let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VS.sampleRate,
                                         channels: 1, interleaved: false)!

    /// Phone-mic audio, 16 kHz mono. Called on an audio thread.
    var onPhoneMicBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        // Phone call / Siri etc. interrupt the session: restart when it ends.
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Log.add("Audio: interruption \(type == .began ? "began" : "ended")")
            if type == .ended { self.restart() }
        })
        // Route / sample-rate change (headphones plugged etc.) invalidates the tap format.
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Log.add("Audio: engine config changed -> restart")
            self?.restart()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Log.add("Audio: media services reset -> restart")
            self?.restart()
        })
    }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        // .mixWithOthers: don't kill music; .defaultToSpeaker: monitor goes to speaker, not earpiece.
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setPreferredIOBufferDuration(0.01)   // small buffers = lower phone-mic latency
        try session.setActive(true)

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw NSError(domain: "ViSense", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available"]) }
        converter = AVAudioConverter(from: inFormat, to: Self.format16k)

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.convertAndForward(buf)
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format16k)
        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true
        Log.add("Audio: engine running (input \(Int(inFormat.sampleRate)) Hz)")
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func restart() {
        let was = isRunning
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            isRunning = false
        }
        guard was else { return }
        do { try start() } catch { Log.add("Audio: restart failed \(error.localizedDescription)") }
    }

    /// Play glasses audio through the speaker/headphones (monitor). Use headphones
    /// or you'll get feedback into the glasses mic.
    func play(_ buffer: AVAudioPCMBuffer) {
        guard isRunning else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Private

    private func convertAndForward(_ buf: AVAudioPCMBuffer) {
        guard let converter, let handler = onPhoneMicBuffer else { return }
        let ratio = VS.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format16k, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if out.frameLength > 0 { handler(out) }
    }
}

extension AVAudioPCMBuffer {
    /// Make a 16 kHz mono Float32 buffer from Int16 samples.
    static func make16k(from samples: [Int16]) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: AudioIO.format16k, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = b.floatChannelData?[0] else { return nil }
        for i in 0..<samples.count { ch[i] = Float(samples[i]) / 32768 }
        b.frameLength = AVAudioFrameCount(samples.count)
        return b
    }

    /// RMS level in dBFS (-100 for silence).
    var rmsDBFS: Float {
        guard let ch = floatChannelData?[0], frameLength > 0 else { return -100 }
        var sum: Float = 0
        for i in 0..<Int(frameLength) { sum += ch[i] * ch[i] }
        let rms = (sum / Float(frameLength)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -100
    }
}
