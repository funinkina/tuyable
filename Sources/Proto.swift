// Tuya BLE 4.x (FD50) wire format. Line-for-line port of bulb.py.
import CommonCrypto
import CryptoKit
import Foundation

let opInfo: UInt16 = 0x00, opStatus: UInt16 = 0x03, opDPs: UInt16 = 0x27, opReport: UInt16 = 0x8006

struct BulbError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

enum DP: Equatable {
    case bool(Bool), int(Int), str(String), enm(Int)
    var type: UInt8 { switch self { case .bool: 1; case .int: 2; case .str: 3; case .enm: 4 } }
    var raw: [UInt8] {
        switch self {
        case .bool(let b): [b ? 1 : 0]
        case .int(let v): be(Int32(v))
        case .str(let s): Array(s.utf8)
        case .enm(let v): [UInt8(v)]
        }
    }
}

struct Msg: Equatable { let serial, ack: UInt32; let op: UInt16; let payload: [UInt8] }

func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }
func uint(_ d: ArraySlice<UInt8>) -> Int { d.reduce(0) { $0 << 8 | Int($1) } }

func crc16(_ d: [UInt8]) -> UInt16 {
    var c: UInt16 = 0xFFFF
    for b in d {
        c ^= UInt16(b)
        for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
    }
    return c
}

func varint(_ n: Int) -> [UInt8] {
    var n = n, out: [UInt8] = []
    repeat { out.append(UInt8(n & 0x7F) | (n > 0x7F ? 0x80 : 0)); n >>= 7 } while n > 0
    return out
}

func readVarint(_ d: [UInt8], _ pos: inout Int) -> Int {
    var n = 0, shift = 0
    while pos < d.count {
        let b = d[pos]; pos += 1
        n |= Int(b & 0x7F) << shift; shift += 7
        if b & 0x80 == 0 { break }
    }
    return n
}

func aes(_ data: [UInt8], key: [UInt8], iv: [UInt8], encrypt: Bool) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: data.count + 16), moved = 0
    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
            key, key.count, iv, data, data.count, &out, out.count, &moved)
    return Array(out.prefix(moved))
}

func md5(_ d: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: d)) }

/// One application message -> 20-byte GATT fragments.
func frame(serial: UInt32, ack: UInt32, op: UInt16, payload: [UInt8], mode: UInt8, key: [UInt8]?,
           iv: [UInt8] = (0..<16).map { _ in .random(in: 0...255) }) -> [[UInt8]] {
    var body = be(serial) + be(ack) + be(op) + be(UInt16(payload.count)) + payload
    body += be(crc16(body))
    var env: [UInt8] = [mode]
    if mode == 0 { env += body } else {
        body += [UInt8](repeating: 0, count: (16 - body.count % 16) % 16)
        env += iv + aes(body, key: key ?? [], iv: iv, encrypt: true)
    }
    var packets: [[UInt8]] = [], off = 0
    while off < env.count {
        var head = varint(packets.count)
        if packets.isEmpty { head += varint(env.count) + [0x20 | UInt8((serial &- 1) & 15)] }
        let take = min(20 - head.count, env.count - off)
        packets.append(head + env[off..<off + take]); off += take
    }
    return packets
}

func unframe(_ env: [UInt8], keys: [UInt8: [UInt8]]) throws -> Msg {
    guard let mode = env.first else { throw BulbError("empty frame") }
    var body = Array(env.dropFirst())
    if mode != 0 {
        guard let key = keys[mode], env.count > 17, (env.count - 17) % 16 == 0 else { throw BulbError("bad frame") }
        body = aes(Array(env[17...]), key: key, iv: Array(env[1..<17]), encrypt: false)
    }
    guard body.count >= 14 else { throw BulbError("short frame") }
    let n = uint(body[10..<12])
    guard body.count >= 14 + n, crc16(Array(body[..<(12 + n)])) == uint(body[(12 + n)..<(14 + n)]) else {
        throw BulbError("CRC mismatch — wrong local_key?")
    }
    return Msg(serial: UInt32(uint(body[0..<4])), ack: UInt32(uint(body[4..<8])),
               op: UInt16(uint(body[8..<10])), payload: Array(body[12..<(12 + n)]))
}

/// V4 report: 0, seq:u32, type, flag, then records id:u8 type:u8 len:u16 data.
func parseDPs(_ p: [UInt8]) -> [UInt8: DP] {
    var out: [UInt8: DP] = [:], pos = 7
    while pos + 4 <= p.count {
        let id = p[pos], kind = p[pos + 1], n = uint(p[(pos + 2)..<(pos + 4)])
        guard pos + 4 + n <= p.count else { break }
        let raw = p[(pos + 4)..<(pos + 4 + n)]; pos += 4 + n
        switch kind {
        case 1: out[id] = .bool((raw.first ?? 0) != 0)
        case 2: out[id] = .int(uint(raw))
        case 3: out[id] = .str(String(decoding: raw, as: UTF8.self))
        case 4: out[id] = .enm(uint(raw))
        default: break
        }
    }
    return out
}

/// DP 24: "hhhhssssvvvv" hex, h 0..360, s/v 0..1000.
func colorString(hue: Double, sat: Double, val: Int) -> String {
    String(format: "%04x%04x%04x", Int((hue * 360).rounded()), Int((sat * 1000).rounded()), val)
}

func parseColor(_ s: String) -> (hue: Double, sat: Double, val: Int)? {
    let v = stride(from: 0, to: 12, by: 4).compactMap { i -> Int? in
        guard s.count == 12 else { return nil }
        let a = s.index(s.startIndex, offsetBy: i)
        return Int(s[a..<s.index(a, offsetBy: 4)], radix: 16)
    }
    return v.count == 3 ? (Double(v[0]) / 360, Double(v[1]) / 1000, v[2]) : nil
}

/// Same checks as `bulb.py selftest`, plus the colour round-trip.
func selftest() {
    precondition(crc16(Array("123456789".utf8)) == 0x4B37)
    var pos = 0
    precondition(readVarint(varint(300), &pos) == 300 && pos == 2)
    let key = [UInt8](0..<16), msg = Array("hello world, this spans fragments".utf8)
    let pkts = frame(serial: 7, ack: 0, op: opDPs, payload: msg, mode: 5, key: key)
    precondition(pkts.count > 1 && pkts.allSatisfy { $0.count <= 20 })
    var env: [UInt8] = []
    for (i, p) in pkts.enumerated() {
        var pos = 0
        _ = readVarint(p, &pos)
        if i == 0 { _ = readVarint(p, &pos); pos += 1 }
        env += p[pos...]
    }
    precondition(try! unframe(env, keys: [5: key]) == Msg(serial: 7, ack: 0, op: opDPs, payload: msg))
    precondition(colorString(hue: 0, sat: 1, val: 1000) == "000003e803e8")
    let c = parseColor("00b4026c01f4")!
    precondition(c.hue == 0.5 && c.sat == 0.62 && c.val == 500)
    let rep = [0] + be(UInt32(5)) + [0, 0, 20, 1, 0, 1, 1, 22, 2, 0, 4] + be(Int32(500))
    precondition(parseDPs(rep) == [20: .bool(true), 22: .int(500)])
    print("selftest ok")
}
