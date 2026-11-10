// BLE link + bulb state. Holds one session open while in use, drops it when idle so
// the Pi bridge / phone can grab the bulb (only one central at a time).
import CoreBluetooth
import Foundation
import Observation

typealias DPs = [(UInt8, DP)]

@MainActor @Observable
final class Bulb: NSObject {
    enum Link: Equatable { case offline, connecting, ready, failed(String) }

    var link = Link.offline
    var name = "Bulb"
    var on = false
    var color = false
    var white = 0.8   // brightness in white mode, 0...1
    var temp = 0.3    // 0 warm ... 1 cool
    var hue = 0.08
    var sat = 0.85
    var level = 1.0   // brightness in colour mode, 0...1
    var visible = false { didSet { lastActivity = .now; if visible { Task { try? await ensureConnected() } } } }

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var writeChar: CBCharacteristic?
    @ObservationIgnored private var linkCont: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var linkTimer: Task<Void, Never>?
    @ObservationIgnored private var connecting: Task<Void, Error>?
    @ObservationIgnored private var pending: [UInt32: CheckedContinuation<[UInt8], Error>] = [:]
    @ObservationIgnored private var keys: [UInt8: [UInt8]] = [:]
    @ObservationIgnored private var serial: UInt32 = 1
    @ObservationIgnored private var dpSeq: UInt32 = 1
    @ObservationIgnored private var buf: [UInt8] = []
    @ObservationIgnored private var want = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var queued: DPs?
    @ObservationIgnored private var pumping = false
    @ObservationIgnored private var lastEdit = Date.distantPast
    @ObservationIgnored private var lastActivity = Date.now

    private static let service = CBUUID(string: "FD50")
    private static let writeID = CBUUID(string: "00000001-0000-1001-8001-00805f9b07d0")
    private static let notifyID = CBUUID(string: "00000002-0000-1001-8001-00805f9b07d0")
    private static let idleTimeout: TimeInterval = 30

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        Task {
            while true {
                try? await Task.sleep(for: .seconds(5))
                if link == .ready, !visible, Date.now.timeIntervalSince(lastActivity) > Self.idleTimeout { disconnect() }
            }
        }
    }

    // MARK: commands

    func toggle() { on.toggle(); push([(20, .bool(on))]) }

    func applyWhite() {
        color = false; on = true
        push([(22, .int(10 + Int((white * 990).rounded()))), (23, .int(Int((temp * 1000).rounded()))),
              (21, .enm(0)), (20, .bool(true))])
    }

    func applyColor() {
        color = true; on = true
        push([(24, .str(colorString(hue: hue, sat: sat, val: 10 + Int((level * 990).rounded())))),
              (21, .enm(1)), (20, .bool(true))])
    }

    func retry() { link = .offline; Task { try? await ensureConnected() } }

    /// Latest-wins: while a write is in flight, newer edits replace the queued one, so
    /// dragging a slider never builds a backlog.
    private func push(_ dps: DPs) {
        queued = dps; lastEdit = .now; lastActivity = .now
        guard !pumping else { return }
        pumping = true
        Task {
            defer { pumping = false }
            while let d = queued {
                queued = nil
                do { try await ensureConnected(); try await write(d) } catch {
                    // drop the session so Retry/next edit rescans instead of reusing a wedged link
                    if link == .ready { disconnect(); link = .failed(error.localizedDescription) }
                }
            }
        }
    }

    // MARK: session

    func ensureConnected() async throws {
        if link == .ready { return }
        if connecting == nil { connecting = Task { defer { connecting = nil }; try await establish() } }
        try await connecting!.value
    }

    private func establish() async throws {
        link = .connecting
        do {
            let (lk, sk) = try loadCred()
            serial = 1; dpSeq = 1; keys = [14: md5(lk + sk)]
            try await withCheckedThrowingContinuation { c in
                linkCont = c
                linkTimer = Task {
                    guard (try? await Task.sleep(for: .seconds(15))) != nil else { return }
                    finishLink(BulbError("Bulb not found. Powered on, and phone app closed?"))
                }
                startLinking()
            }
            // device-info under mode 14 = md5(lk+sk); reply carries the 6-byte session nonce
            let info = try await request(opInfo, [0x00, 0x14], mode: 14)
            guard info.count >= 12 else { throw BulbError("Unexpected handshake reply") }
            keys[15] = md5(lk + sk + Array(info[6..<12]))
            link = .ready
            _ = try? await request(opStatus, [], mode: 15)  // state arrives as reports
        } catch {
            disconnect()
            link = .failed(error.localizedDescription)
            throw error
        }
    }

    private func loadCred() throws -> ([UInt8], [UInt8]) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/tuyable/devices.json")
        guard let data = try? Data(contentsOf: url),
              let devs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !devs.isEmpty
        else { throw BulbError("No credentials in ~/.config/tuyable/devices.json") }
        // ponytail: first light only; add a picker when there's a second bulb
        let d = devs.first { $0["category"] as? String == "dj" } ?? devs[0]
        guard let lk = d["local_key"] as? String, let sk = d["sec_key"] as? String
        else { throw BulbError("devices.json is missing local_key / sec_key") }
        name = d["name"] as? String ?? name
        return (Array(lk.utf8), Array(sk.utf8))
    }

    private func startLinking() {
        switch central.state {
        case .poweredOn: central.scanForPeripherals(withServices: [Self.service])
        case .unknown, .resetting: break  // centralManagerDidUpdateState resumes us
        case .unauthorized: finishLink(BulbError("Bluetooth access denied — allow it in System Settings › Privacy"))
        default: finishLink(BulbError("Bluetooth is off"))
        }
    }

    private func finishLink(_ error: Error?) {
        guard let c = linkCont else { return }
        linkCont = nil; linkTimer?.cancel()
        if let error { central.stopScan(); c.resume(throwing: error) } else { c.resume() }
    }

    private func disconnect() {
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        reset()
    }

    private func reset() {
        peripheral = nil; writeChar = nil; keys = [:]; buf = []; want = 0; generation += 1
        let failed = pending; pending = [:]
        failed.values.forEach { $0.resume(throwing: BulbError("Disconnected")) }
        if link == .ready || link == .connecting { link = .offline }
    }

    // MARK: framing

    private func send(_ op: UInt16, _ payload: [UInt8], mode: UInt8, ack: UInt32 = 0) {
        let s = serial; serial += 1
        guard let p = peripheral, let w = writeChar else { return }
        for pkt in frame(serial: s, ack: ack, op: op, payload: payload, mode: mode, key: keys[mode]) {
            p.writeValue(Data(pkt), for: w, type: .withResponse)
        }
    }

    private func request(_ op: UInt16, _ payload: [UInt8], mode: UInt8) async throws -> [UInt8] {
        guard peripheral != nil else { throw BulbError("Disconnected") }
        let s = serial
        return try await withCheckedThrowingContinuation { c in
            pending[s] = c
            send(op, payload, mode: mode)
            let gen = generation  // serials restart per connection; don't let old timers hit new requests
            Task {
                try? await Task.sleep(for: .seconds(8))
                guard gen == generation else { return }
                pending.removeValue(forKey: s)?.resume(throwing: BulbError("Bulb didn't respond"))
            }
        }
    }

    private func write(_ dps: DPs) async throws {
        var payload: [UInt8] = [0] + be(dpSeq); dpSeq += 1
        for (id, v) in dps { payload += [id, v.type] + be(UInt16(v.raw.count)) + v.raw }
        guard try await request(opDPs, payload, mode: 15).last == 0 else { throw BulbError("Bulb rejected the command") }
    }

    private func onNotify(_ d: [UInt8]) {
        var pos = 0
        if readVarint(d, &pos) == 0 { want = readVarint(d, &pos); pos += 1; buf = [] }
        guard pos <= d.count else { return }
        buf += d[pos...]
        if want > 1024 { buf = []; want = 0 }
        guard want > 0, buf.count >= want else { return }
        let env = Array(buf.prefix(want)); buf = []; want = 0
        guard let m = try? unframe(env, keys: keys) else { return }
        if m.op == opReport && m.ack == 0 {
            apply(parseDPs(m.payload))
            if m.payload.count >= 7, m.payload[5] & 0x80 == 0 {
                send(opReport, Array(m.payload[..<7]) + [0], mode: 15, ack: m.serial)
            }
        } else {
            pending.removeValue(forKey: m.ack)?.resume(returning: m.payload)
        }
    }

    private func apply(_ dps: [UInt8: DP]) {
        // ponytail: reports trailing a drag are stale echoes; ignore for 1.5s after a local edit
        guard Date.now.timeIntervalSince(lastEdit) > 1.5 else { return }
        let unit = { (v: Int, lo: Int) in min(1, max(0, Double(v - lo) / Double(1000 - lo))) }
        for (id, v) in dps {
            switch (id, v) {
            case (20, .bool(let b)): on = b
            case (21, .enm(let m)): color = m == 1
            case (22, .int(let n)): white = unit(n, 10)
            case (23, .int(let n)): temp = unit(n, 0)
            case (24, .str(let s)):
                if let c = parseColor(s) { hue = c.hue.truncatingRemainder(dividingBy: 1); sat = min(1, c.sat); level = unit(c.val, 10) }
            default: break
            }
        }
    }
}

extension Bulb: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if linkCont != nil { startLinking() }
        else if c.state == .poweredOn, visible, case .failed = link { retry() }
        if c.state != .poweredOn, link == .ready { reset(); link = .failed("Bluetooth is off") }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData _: [String: Any], rssi _: NSNumber) {
        guard linkCont != nil, peripheral == nil else { return }
        c.stopScan()
        peripheral = p; p.delegate = self
        c.connect(p)
    }

    func centralManager(_: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([Self.service]) }

    func centralManager(_: CBCentralManager, didFailToConnect _: CBPeripheral, error: Error?) {
        finishLink(error ?? BulbError("Couldn't connect"))
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error _: Error?) {
        guard p == peripheral else { return }
        finishLink(BulbError("Bulb dropped the connection"))
        reset()
        if visible { Task { try? await ensureConnected() } }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else {
            return finishLink(error ?? BulbError("Not a Tuya BLE bulb"))
        }
        p.discoverCharacteristics([Self.writeID, Self.notifyID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let chars = s.characteristics ?? []
        guard let w = chars.first(where: { $0.uuid == Self.writeID }),
              let n = chars.first(where: { $0.uuid == Self.notifyID })
        else { return finishLink(error ?? BulbError("Bulb is missing its control characteristics")) }
        writeChar = w
        p.setNotifyValue(true, for: n)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor _: CBCharacteristic, error: Error?) {
        if p == peripheral { finishLink(error) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error _: Error?) {
        if p == peripheral, ch.uuid == Self.notifyID, let v = ch.value { onNotify(Array(v)) }
    }
}
