// =============================================================================
// BLEManager.swift — CoreBluetooth central for the ViSense glasses.
//
// * Scans for the ViSense service UUID, connects, subscribes STATUS (+ AUDIO when
//   wanted), writes TEXT without response.
// * Auto-reconnect: after any disconnect we immediately call connect() again.
//   A pending connect never times out on iOS and also works in the background,
//   so the glasses reconnect by themselves when they come back in range / reboot.
// * State restoration (restore identifier) lets iOS relaunch us for BLE events.
// * All CoreBluetooth work happens on `queue`; @Published values are set on main.
// =============================================================================
import CoreBluetooth
import Foundation

final class BLEManager: NSObject, ObservableObject {
    enum LinkState: String {
        case off = "Bluetooth off"
        case unauthorized = "Bluetooth not allowed"
        case scanning = "Searching for glasses…"
        case connecting = "Connecting…"
        case connected = "Connected"
    }

    // MARK: Published (main thread)
    @Published private(set) var state: LinkState = .off
    @Published private(set) var status = GlassesStatus()
    @Published private(set) var mtu = 0
    @Published private(set) var rttMs: Double?            // TEXT ping -> STATUS echo
    @Published private(set) var audioPacketsPerSec = 0

    /// Full 165-byte audio packets, called on the BLE queue (not main!).
    var onAudioPacket: ((Data) -> Void)?

    /// Subscribe to AUDIO notifications (glasses mic / monitor). Safe from any thread.
    var wantsAudio = false {
        didSet { queue.async { self.applyAudioSubscription() } }
    }

    // MARK: Private (BLE queue only)
    private let queue = DispatchQueue(label: "visense.ble", qos: .userInteractive)
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var textChar: CBCharacteristic?
    private var audioChar: CBCharacteristic?
    private var outbox: [TextMessage] = []       // finals / clear / font / ping, in order
    private var pendingPartial: TextMessage?     // only the newest partial matters
    private var audioAccum = Data()
    private var pings: [UInt32: CFAbsoluteTime] = [:]
    private var audioCount = 0
    private var tickTimer: DispatchSourceTimer?
    private let savedIDKey = "visense.peripheralID"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "visense.central",
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
        startTicker()
    }

    // MARK: Public API

    /// Queue a message for the glasses. Partials replace any unsent partial.
    func send(_ msg: TextMessage) {
        queue.async {
            switch msg.type {
            case .partial:
                self.pendingPartial = msg
            case .final, .clear:
                self.pendingPartial = nil          // a final/clear supersedes the partial
                self.outbox.append(msg)
            default:
                self.outbox.append(msg)
            }
            if self.outbox.count > 50 { self.outbox.removeFirst(self.outbox.count - 50) }
            self.flush()
        }
    }

    /// Max bytes per TEXT write (MTU - 3). Read on any thread; approximate.
    var maxWriteLength: Int { max(20, mtu - 3) }

    // MARK: Internals

    private func setState(_ s: LinkState) {
        DispatchQueue.main.async { if self.state != s { self.state = s } }
        Log.add("BLE: \(s.rawValue)")
    }

    private func startConnecting() {
        guard central.state == .poweredOn else { return }
        // 1) Reconnect directly to the glasses we know (works without advertising scan).
        if peripheral == nil,
           let s = UserDefaults.standard.string(forKey: savedIDKey), let id = UUID(uuidString: s),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            peripheral = known
        }
        if let p = peripheral {
            p.delegate = self
            if p.state == .connected { p.discoverServices([VS.serviceUUID]); return }
            central.connect(p, options: nil)          // pending forever until it appears
            setState(.connecting)
        }
        // 2) Also scan, in case the glasses have a new identity (e.g. first run).
        if !central.isScanning {
            central.scanForPeripherals(withServices: [VS.serviceUUID], options: nil)
        }
        if peripheral == nil { setState(.scanning) }
    }

    private func flush() {
        guard let p = peripheral, p.state == .connected, let c = textChar else { return }
        let maxLen = p.maximumWriteValueLength(for: .withoutResponse)
        while p.canSendWriteWithoutResponse {
            let msg: TextMessage
            if !outbox.isEmpty { msg = outbox.removeFirst() }
            else if let pp = pendingPartial { msg = pp; pendingPartial = nil }
            else { return }
            p.writeValue(msg.encoded(maxLength: maxLen), for: c, type: .withoutResponse)
        }
    }

    private func applyAudioSubscription() {
        guard let p = peripheral, p.state == .connected, let c = audioChar else { return }
        if c.isNotifying != wantsAudio { p.setNotifyValue(wantsAudio, for: c) }
    }

    private func handleAudioNotification(_ d: Data) {
        // Normal case: one notification == one 165-byte packet.
        if d.count == VS.packetBytes && audioAccum.isEmpty {
            deliverAudio(d); return
        }
        // Small MTU: firmware split the packet; glue the pieces back together.
        if d.count == VS.packetBytes { audioAccum.removeAll() ; deliverAudio(d); return }
        audioAccum.append(d)
        while audioAccum.count >= VS.packetBytes {
            deliverAudio(audioAccum.prefix(VS.packetBytes))
            audioAccum.removeFirst(VS.packetBytes)
        }
        if audioAccum.count > VS.packetBytes * 4 { audioAccum.removeAll() }  // resync
    }

    private func deliverAudio(_ d: Data) {
        audioCount += 1
        onAudioPacket?(Data(d))
    }

    private func sendPing() {
        guard peripheral?.state == .connected, textChar != nil else { return }
        let token = UInt32.random(in: 1...UInt32.max)
        pings[token] = CFAbsoluteTimeGetCurrent()
        if pings.count > 10 { pings.removeAll() }
        send(.ping(token))
    }

    /// 1 Hz housekeeping: packets/sec counter + latency ping every 2 s.
    private func startTicker() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        var n = 0
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let pps = self.audioCount; self.audioCount = 0
            DispatchQueue.main.async { self.audioPacketsPerSec = pps }
            n += 1
            if n % 2 == 0, self.peripheral?.state == .connected { self.sendPing() }
        }
        t.resume()
        tickTimer = t
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: startConnecting()
        case .unauthorized: setState(.unauthorized)
        default: setState(.off)
        }
    }

    /// iOS relaunched / restored us in the background: take the peripheral back.
    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let ps = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = ps.first {
            peripheral = p
            p.delegate = self
            Log.add("BLE: restored peripheral \(p.identifier)")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        Log.add("BLE: found \(p.name ?? "?") rssi \(rssi)")
        c.stopScan()
        if peripheral?.identifier != p.identifier, let old = peripheral { c.cancelPeripheralConnection(old) }
        peripheral = p
        p.delegate = self
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedIDKey)
        c.connect(p, options: nil)
        setState(.connecting)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        c.stopScan()
        p.delegate = self
        p.discoverServices([VS.serviceUUID])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Log.add("BLE: connect failed \(error?.localizedDescription ?? "")")
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Log.add("BLE: disconnected \(error?.localizedDescription ?? "")")
        textChar = nil; audioChar = nil
        audioAccum.removeAll()
        pendingPartial = nil
        outbox.removeAll()
        DispatchQueue.main.async { self.mtu = 0; self.rttMs = nil }
        setState(.connecting)
        c.connect(p, options: nil)        // auto-reconnect, no timeout
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == VS.serviceUUID }) else {
            Log.add("BLE: ViSense service missing"); return
        }
        p.discoverCharacteristics([VS.audioUUID, VS.textUUID, VS.statusUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            switch c.uuid {
            case VS.textUUID:   textChar = c
            case VS.audioUUID:  audioChar = c
            case VS.statusUUID: p.setNotifyValue(true, for: c); p.readValue(for: c)
            default: break
            }
        }
        let m = p.maximumWriteValueLength(for: .withoutResponse) + 3
        DispatchQueue.main.async { self.mtu = m }
        Log.add("BLE: ready, MTU \(m)")
        setState(.connected)
        applyAudioSubscription()
        flush()
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { flush() }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let d = c.value else { return }
        if c.uuid == VS.audioUUID {
            handleAudioNotification(d)
        } else if c.uuid == VS.statusUUID, let st = GlassesStatus(d) {
            var rtt: Double?
            if st.pingToken != 0, let t0 = pings.removeValue(forKey: st.pingToken) {
                rtt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            }
            DispatchQueue.main.async {
                self.status = st
                if let rtt { self.rttMs = self.rttMs.map { $0 * 0.7 + rtt * 0.3 } ?? rtt }
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if c.uuid == VS.audioUUID { Log.add("BLE: audio notify \(c.isNotifying ? "on" : "off")") }
        if c.uuid == VS.audioUUID, let error { Log.add("BLE: audio notify error \(error.localizedDescription)") }
    }
}
