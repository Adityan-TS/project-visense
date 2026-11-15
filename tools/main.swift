// tools/main.swift — decodes packets.bin with the iOS ADPCM.swift and
// compares to the original PCM (built on macOS together with Protocol.swift, ADPCM.swift).
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "packets.bin"
let packets = try! Data(contentsOf: URL(fileURLWithPath: path))
let original = try! Data(contentsOf: URL(fileURLWithPath: path + ".pcm"))
let orig: [Int16] = original.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }

let rx = GlassesAudioReceiver()
var decoded: [Int16] = []
var i = 0, n = 0
while i + VS.packetBytes <= packets.count {
    let p = packets.subdata(in: i..<(i + VS.packetBytes))
    // Simulate a dropped packet (#40): decoder must recover on #41 and fill silence.
    if n != 40 { decoded += rx.process(p)! }
    i += VS.packetBytes; n += 1
}
precondition(decoded.count == orig.count, "length mismatch \(decoded.count) vs \(orig.count)")
precondition(rx.lostFrames == 1, "expected 1 lost frame")
var sig = 0.0, err = 0.0
for k in 0..<orig.count where k / VS.frameSamples != 40 {
    let a = Double(orig[k]), d = a - Double(decoded[k]); sig += a * a; err += d * d
}
let snr = 10 * log10(sig / err)
print(String(format: "Swift decode SNR: %.1f dB, lost frames filled: %d", snr, rx.lostFrames))
exit(snr > 15 ? 0 : 1)
