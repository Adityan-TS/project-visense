// =============================================================================
// ADPCM.swift — IMA-ADPCM decoder for ViSense audio packets
// (mirror of firmware/ViSense/adpcm.cpp) + sequence/gap handling.
// =============================================================================
import Foundation

enum IMAADPCM {
    static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
        253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
        1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
        3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
        11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
        32767]
    static let indexTable: [Int32] = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

    /// Decode one 165-byte packet. Each packet carries its own predictor/index,
    /// so a lost packet never corrupts the following ones.
    static func decodePacket(_ data: Data) -> (seq: UInt16, samples: [Int16])? {
        guard data.count == VS.packetBytes else { return nil }
        let b = [UInt8](data)
        let seq = UInt16(b[0]) | UInt16(b[1]) << 8
        var predictor = Int32(Int16(bitPattern: UInt16(b[2]) | UInt16(b[3]) << 8))
        var index = Int32(b[4])
        guard index <= 88 else { return nil }     // garbage / misaligned packet

        var out = [Int16](repeating: 0, count: VS.frameSamples)
        @inline(__always) func decode(_ nib: Int32) -> Int16 {
            let step = stepTable[Int(index)]
            var diff = step >> 3
            if nib & 4 != 0 { diff += step }
            if nib & 2 != 0 { diff += step >> 1 }
            if nib & 1 != 0 { diff += step >> 2 }
            predictor += (nib & 8 != 0) ? -diff : diff
            predictor = min(32767, max(-32768, predictor))
            index = min(88, max(0, index + indexTable[Int(nib)]))
            return Int16(predictor)
        }
        for i in 0..<(VS.frameSamples / 2) {
            let byte = Int32(b[VS.headerBytes + i])
            out[2 * i] = decode(byte & 0x0F)        // low nibble = earlier sample
            out[2 * i + 1] = decode(byte >> 4)
        }
        return (seq, out)
    }
}

/// Turns the packet stream into continuous PCM: fills lost frames with silence
/// so the recognizer's timeline stays right.
final class GlassesAudioReceiver {
    private var lastSeq: UInt16?
    private(set) var lostFrames = 0
    private(set) var badPackets = 0

    func reset() { lastSeq = nil }

    func process(_ packet: Data) -> [Int16]? {
        guard let (seq, samples) = IMAADPCM.decodePacket(packet) else { badPackets += 1; return nil }
        var out: [Int16] = []
        if let last = lastSeq {
            let gap = Int(seq &- last &- 1)        // UInt16 wrap-around safe
            if gap > 0 && gap <= 25 {              // up to 0.5 s lost: insert silence
                lostFrames += gap
                out.append(contentsOf: repeatElement(0, count: gap * VS.frameSamples))
            }
        }
        lastSeq = seq
        out.append(contentsOf: samples)
        return out
    }
}
