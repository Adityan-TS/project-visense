import Foundation
import AVFoundation

func load16k(_ path: String) -> [Float] {
    let f = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let conv = AVAudioConverter(from: f.processingFormat, to: fmt)!
    let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: inBuf)
    let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(f.length) * 16000 / f.processingFormat.sampleRate) + 1024)!
    var done = false
    _ = conv.convert(to: out, error: nil) { _, st in if done { st.pointee = .noDataNow; return nil }; done = true; st.pointee = .haveData; return inBuf }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}
let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
let history = AudioHistory(seconds: 30)
// Feed audio "live": small buffers + a little room noise; returns wall-clock span of the speech.
func play(_ samples: [Float], silenceAfter: Double) -> (CFAbsoluteTime, CFAbsoluteTime) {
    let noise = { Float.random(in: -0.003...0.003) }
    let all = samples.map { $0 + noise() } + (0..<Int(silenceAfter * 16000)).map { _ in noise() }
    var start: CFAbsoluteTime = 0, end: CFAbsoluteTime = 0
    var i = 0
    while i < all.count {
        let n = min(1600, all.count - i)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        for k in 0..<n { b.floatChannelData![0][k] = all[i + k] }
        history.append(b)
        if i == 0 { start = CFAbsoluteTimeGetCurrent() }
        if i + n >= samples.count && end == 0 { end = CFAbsoluteTimeGetCurrent() }
        i += n
        usleep(100_000)                     // real time, like the microphone
    }
    return (start, end)
}
// What the app does: first partial ~1 s after speech start, last partial at speech end.
let dir = CommandLine.arguments[1]
let script: [(String, String)] = [("daniel","daniel1"),("aman","aman1"),("daniel","daniel2"),("samantha","samantha1"),
    ("aman","aman3"),("samantha","samantha2"),("daniel","daniel3"),("karen","karen1"),("samantha","samantha3"),("karen","karen3"),("aman","aman2")]
await SpeakerRecognizer.shared.forgetAll()
await SpeakerLabeler.shared.prepare()
while !(await SpeakerLabeler.shared.isReady) { try? await Task.sleep(nanoseconds: 200_000_000) }
var truth: [String: String] = [:]   // detected name -> true voice
var errors = 0
for (who, file) in script {
    let audio = load16k("\(dir)/\(file).aiff")
    let (s, e) = play(audio, silenceAfter: 1.2)
    // app: utteranceStart = firstPartial - 1.0 ≈ speech start; clip to lastPartial + 0.25
    let clip = history.clip(from: s - 0.05, to: e + 0.25)
    let tag = await SpeakerLabeler.shared.label(clip)
    let name = tag?.name ?? "(no name: too short)"
    var ok = "ok"
    if let t = tag { if let prev = truth[t.name], prev != who { ok = "WRONG (that is \(prev))"; errors += 1 }; truth[t.name] = truth[t.name] ?? who }
    print("\(who.padding(toLength: 9, withPad: " ", startingAt: 0)) \(file.padding(toLength: 10, withPad: " ", startingAt: 0)) -> \(name)  glasses:\(tag?.glassesTag ?? "-")  \(ok)")
}
let distinct = Set(truth.values).count, names = truth.count
print("\n\(names) speakers created for \(distinct) real voices, \(errors) wrong labels")
