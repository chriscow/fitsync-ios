import Foundation

struct FITRecord: Sendable {
    var timestamp: Date
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var heartRate: Int?
    var cadence: Int?
    var power: Int?
    var speed: Double?
    var distance: Double?
}

struct FITSession: Sendable {
    var sport: UInt8
    var subSport: UInt8?
    var startTime: Date?
    var totalElapsedTime: Double?
    var totalTimerTime: Double?
    var totalDistance: Double?
    var totalCalories: Double?
}

struct FITActivity: Sendable {
    var sessions: [FITSession]
    var records: [FITRecord]
}

enum FITParseError: Error, LocalizedError, Sendable {
    case notAFITFile
    case truncated
    case malformed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notAFITFile: return "The data is not a valid FIT file (missing .FIT header)."
        case .truncated: return "The FIT file is truncated or incomplete."
        case .malformed(let s): return "The FIT file is malformed: \(s)"
        case .unsupported(let s): return "Unsupported FIT feature: \(s)"
        }
    }
}

enum FITParser {
    private static let fitEpochOffset: TimeInterval = 631_065_600
    private static let semicircleToDegrees = 180.0 / 2147483648.0

    private struct FieldDef {
        var num: UInt8
        var size: Int
        var baseType: UInt8
    }

    private struct Definition {
        var globalMsg: UInt16
        var bigEndian: Bool
        var fields: [FieldDef]
        var devSize: Int
        var totalSize: Int
    }

    static func parse(_ data: Data) throws -> FITActivity {
        let b = [UInt8](data)
        guard b.count >= 12 else { throw FITParseError.notAFITFile }
        let headerSize = Int(b[0])
        guard headerSize == 12 || headerSize == 14 else { throw FITParseError.notAFITFile }
        guard b[8] == 0x2E, b[9] == 0x46, b[10] == 0x49, b[11] == 0x54 else { throw FITParseError.notAFITFile }
        guard b.count >= headerSize else { throw FITParseError.truncated }
        let dataSize = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        let end = headerSize + dataSize
        guard end <= b.count else { throw FITParseError.truncated }

        var defs = [Definition?](repeating: nil, count: 16)
        var lastTimestamp: UInt32 = 0
        var sessions: [FITSession] = []
        var records: [FITRecord] = []
        var pos = headerSize

        func readUInt(_ at: Int, _ size: Int, _ big: Bool) -> UInt64 {
            var v: UInt64 = 0
            if big {
                for i in 0..<size { v = (v << 8) | UInt64(b[at + i]) }
            } else {
                for i in stride(from: size - 1, through: 0, by: -1) { v = (v << 8) | UInt64(b[at + i]) }
            }
            return v
        }

        /// Reads the first element of a field as an integer; nil when invalid or unreadable.
        func readValue(_ at: Int, _ f: FieldDef, _ big: Bool) -> Int64? {
            let elem: Int
            var signed = false
            var invalid: UInt64
            switch f.baseType & 0x1F {
            case 0, 2, 13: elem = 1; invalid = 0xFF
            case 1: elem = 1; signed = true; invalid = 0x7F
            case 10: elem = 1; invalid = 0
            case 3: elem = 2; signed = true; invalid = 0x7FFF
            case 4: elem = 2; invalid = 0xFFFF
            case 11: elem = 2; invalid = 0
            case 5: elem = 4; signed = true; invalid = 0x7FFF_FFFF
            case 6: elem = 4; invalid = 0xFFFF_FFFF
            case 12: elem = 4; invalid = 0
            default: return nil // strings, floats, 64-bit: not needed
            }
            guard f.size >= elem else { return nil }
            let raw = readUInt(at, elem, big)
            if raw == invalid { return nil }
            if signed {
                let bits = UInt64(elem * 8)
                let signBit = UInt64(1) << (bits - 1)
                return raw & signBit != 0 ? Int64(raw) - Int64(1 << bits) : Int64(raw)
            }
            return Int64(raw)
        }

        while pos < end {
            let header = b[pos]
            pos += 1
            if header & 0x80 != 0 {
                // Compressed timestamp data message
                let local = Int((header >> 5) & 0x03)
                guard let def = defs[local] else { throw FITParseError.malformed("data message with undefined local type") }
                let offset = UInt32(header & 0x1F)
                var ts = (lastTimestamp & ~UInt32(0x1F)) &+ offset
                if offset < (lastTimestamp & 0x1F) { ts = ts &+ 32 }
                lastTimestamp = ts
                guard pos + def.totalSize <= end else { throw FITParseError.truncated }
                handle(def, at: pos, injectedTimestamp: ts)
                pos += def.totalSize
            } else if header & 0x40 != 0 {
                // Definition message
                let local = Int(header & 0x0F)
                let hasDev = header & 0x20 != 0
                guard pos + 5 <= end else { throw FITParseError.truncated }
                let big = b[pos + 1] != 0
                let global = UInt16(readUInt(pos + 2, 2, big))
                let nFields = Int(b[pos + 4])
                pos += 5
                guard pos + nFields * 3 <= end else { throw FITParseError.truncated }
                var fields: [FieldDef] = []
                fields.reserveCapacity(nFields)
                var total = 0
                for i in 0..<nFields {
                    let o = pos + i * 3
                    fields.append(FieldDef(num: b[o], size: Int(b[o + 1]), baseType: b[o + 2]))
                    total += Int(b[o + 1])
                }
                pos += nFields * 3
                var devSize = 0
                if hasDev {
                    guard pos + 1 <= end else { throw FITParseError.truncated }
                    let nDev = Int(b[pos])
                    pos += 1
                    guard pos + nDev * 3 <= end else { throw FITParseError.truncated }
                    for i in 0..<nDev { devSize += Int(b[pos + i * 3 + 1]) }
                    pos += nDev * 3
                }
                defs[local] = Definition(globalMsg: global, bigEndian: big, fields: fields,
                                         devSize: devSize, totalSize: total + devSize)
            } else {
                // Normal data message
                let local = Int(header & 0x0F)
                guard let def = defs[local] else { throw FITParseError.malformed("data message with undefined local type") }
                guard pos + def.totalSize <= end else { throw FITParseError.truncated }
                handle(def, at: pos, injectedTimestamp: nil)
                pos += def.totalSize
            }
        }

        func handle(_ def: Definition, at start: Int, injectedTimestamp: UInt32?) {
            let isRecord = def.globalMsg == 20
            let isSession = def.globalMsg == 18
            var ts: UInt32? = injectedTimestamp
            var rec = FITRecord(timestamp: Date(timeIntervalSince1970: 0))
            var ses = FITSession(sport: 0)
            var rawAlt: Int64?, rawEAlt: Int64?, rawSpeed: Int64?, rawESpeed: Int64?
            var o = start
            for f in def.fields {
                defer { o += f.size }
                guard let v = readValue(o, f, def.bigEndian) else { continue }
                if f.num == 253 {
                    ts = UInt32(truncatingIfNeeded: v)
                    lastTimestamp = ts!
                    continue
                }
                if isRecord {
                    switch f.num {
                    case 0: rec.latitude = Double(v) * semicircleToDegrees
                    case 1: rec.longitude = Double(v) * semicircleToDegrees
                    case 2: rawAlt = v
                    case 3: rec.heartRate = Int(v)
                    case 4: rec.cadence = Int(v)
                    case 5: rec.distance = Double(v) / 100
                    case 6: rawSpeed = v
                    case 7: rec.power = Int(v)
                    case 73: rawESpeed = v
                    case 78: rawEAlt = v
                    default: break
                    }
                } else if isSession {
                    switch f.num {
                    case 2: ses.startTime = Date(timeIntervalSince1970: fitEpochOffset + Double(v))
                    case 5: ses.sport = UInt8(truncatingIfNeeded: v)
                    case 6: ses.subSport = UInt8(truncatingIfNeeded: v)
                    case 7: ses.totalElapsedTime = Double(v) / 1000
                    case 8: ses.totalTimerTime = Double(v) / 1000
                    case 9: ses.totalDistance = Double(v) / 100
                    case 11: ses.totalCalories = Double(v)
                    default: break
                    }
                }
            }
            if isRecord {
                guard let t = ts else { return }
                rec.timestamp = Date(timeIntervalSince1970: fitEpochOffset + Double(t))
                if let a = rawEAlt ?? rawAlt {
                    rec.altitude = Double(a) / 5 - 500
                }
                if let s = rawESpeed ?? rawSpeed { rec.speed = Double(s) / 1000 }
                records.append(rec)
            } else if isSession {
                sessions.append(ses)
            }
        }

        records = records.enumerated()
            .sorted { $0.element.timestamp != $1.element.timestamp
                ? $0.element.timestamp < $1.element.timestamp : $0.offset < $1.offset }
            .map { $0.element }
        return FITActivity(sessions: sessions, records: records)
    }
}
