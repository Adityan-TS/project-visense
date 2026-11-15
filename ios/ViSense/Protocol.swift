// Protocol.swift — mirror of firmware/ViSense/visense_protocol.h.
// If you change one, change the other.
import CoreBluetooth

enum VS {
    // MARK: UUIDs
    static let serviceUUID = CBUUID(string: "4f1d0001-8b6e-4c3a-9a2f-6e5d1c0b7a90")
    static let audioUUID   = CBUUID(string: "4f1d0002-8b6e-4c3a-9a2f-6e5d1c0b7a90") // notify
    static let textUUID    = CBUUID(string: "4f1d0003-8b6e-4c3a-9a2f-6e5d1c0b7a90") // write w/o resp
    static let statusUUID  = CBUUID(string: "4f1d0004-8b6e-4c3a-9a2f-6e5d1c0b7a90") // notify + read

    // MARK: Audio packet
    static let sampleRate: Double = 16_000
    static let frameSamples = 320                         // 20 ms
    static let headerBytes = 5
    static let packetBytes = headerBytes + frameSamples / 2   // 165

    // MARK: TEXT message types (first byte)
    enum Msg: UInt8 {
        case partial = 0x01   // UTF-8: replace live bottom line
        case final   = 0x02   // UTF-8: commit + scroll
        case clear   = 0x03
        case ping    = 0x04   // UInt32 token, echoed in STATUS
        case font    = 0x05   // UInt8 0/1/2
        case gain    = 0x06   // UInt8 1..64
    }
    static let textMax = 240
}

/// One message to the glasses (TEXT characteristic).
struct TextMessage: Equatable {
    var type: VS.Msg
    var payload: Data = Data()

    static func partial(_ s: String) -> TextMessage { .init(type: .partial, payload: Data(s.glassesSafe.utf8)) }
    static func final(_ s: String) -> TextMessage   { .init(type: .final, payload: Data(s.glassesSafe.utf8)) }
    static let clear = TextMessage(type: .clear)
    static func font(_ size: Int) -> TextMessage { .init(type: .font, payload: Data([UInt8(clamping: size)])) }
    static func gain(_ g: Int) -> TextMessage    { .init(type: .gain, payload: Data([UInt8(clamping: g)])) }
    static func ping(_ token: UInt32) -> TextMessage {
        TextMessage(type: .ping, payload: withUnsafeBytes(of: token.littleEndian) { Data($0) })
    }

    /// Wire bytes, truncated to `maxLength` (the BLE write limit).
    func encoded(maxLength: Int) -> Data {
        var d = Data([type.rawValue])
        d.append(payload.prefix(max(0, min(maxLength, VS.textMax + 1) - 1)))
        return d
    }
}

/// Parsed STATUS notification (18 bytes, little-endian).
struct GlassesStatus: Equatable {
    var fwVersion = "?"
    var micLevel = 0            // 0..100
    var audioSubscribed = false
    var micOK = false
    var packetsSent: UInt32 = 0
    var notifyFailures: UInt32 = 0
    var pingToken: UInt32 = 0
    var gain = 0
    var drawMs = 0

    init() {}
    init?(_ d: Data) {
        guard d.count >= 18 else { return nil }
        let b = [UInt8](d)
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24 }
        fwVersion = "\(b[0]).\(b[1])"
        micLevel = Int(b[2])
        audioSubscribed = b[3] & 1 != 0
        micOK = b[3] & 2 != 0
        packetsSent = u32(4)
        notifyFailures = u32(8)
        pingToken = u32(12)
        gain = Int(b[16])
        drawMs = Int(b[17])
    }
}

extension String {
    /// The OLED fonts are ASCII-only: strip accents, straighten quotes, drop the rest.
    var glassesSafe: String {
        let folded = self.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .replacingOccurrences(of: "\u{2026}", with: "...")
        return String(folded.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }.map(Character.init))
    }
}
