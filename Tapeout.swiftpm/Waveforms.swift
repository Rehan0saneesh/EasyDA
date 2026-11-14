import Foundation

// Waveform data that the viewer draws, whether it came from the simulator or from an imported file,
// plus the value formats and protocol decoders that turn raw bits into something readable.

enum Radix: String, CaseIterable {
    case bin = "Bin", hex = "Hex", dec = "Dec", signed = "Signed", ascii = "ASCII", float = "Float"

    func format(_ value: UInt64, width: Int) -> String {
        let w = max(width, 1)
        let v = value & mask(w)
        switch self {
        case .bin:
            let s = String(v, radix: 2)
            return String(repeating: "0", count: max(w - s.count, 0)) + s
        case .hex:
            let s = String(v, radix: 16, uppercase: true)
            return String(repeating: "0", count: max((w + 3) / 4 - s.count, 0)) + s
        case .dec:
            return String(v)
        case .signed:
            guard w > 1, w < 64, v >> UInt64(w - 1) == 1 else { return w == 64 ? String(Int64(bitPattern: v)) : String(v) }
            return "-" + String((UInt64(1) << UInt64(w)) - v)
        case .ascii:
            guard w >= 7 else { return Radix.hex.format(v, width: w) }
            var text = "", readable = false
            for i in stride(from: (w - 1) / 8, through: 0, by: -1) {
                let byte = UInt8(truncatingIfNeeded: v >> UInt64(i * 8))
                if let c = Radix.printable(byte) { text.append(c); readable = true } else { text += "·" }
            }
            // A value with no printable characters is clearer as hex.
            return readable ? "‘\(text)’" : Radix.hex.format(v, width: w)
        case .float:
            switch w {
            case 64: return Radix.trim(Double(bitPattern: v))
            case 32: return Radix.trim(Double(Float(bitPattern: UInt32(truncatingIfNeeded: v))))
            case 16: return Radix.trim(Radix.half(UInt16(truncatingIfNeeded: v)))
            default: return Radix.hex.format(v, width: w)      // only 16, 32 and 64 bits are IEEE float sizes
            }
        }
    }

    static func printable(_ byte: UInt8) -> Character? {
        (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : nil
    }

    private static func trim(_ d: Double) -> String {
        d.isNaN ? "NaN" : d.isInfinite ? (d < 0 ? "-Inf" : "Inf") : String(format: "%.6g", d)
    }

    /// IEEE 754 half precision.
    private static func half(_ bits: UInt16) -> Double {
        let sign: Double = bits >> 15 == 1 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1F), fraction = Double(bits & 0x3FF) / 1024
        if exponent == 0 { return sign * fraction * pow(2, -14) }
        if exponent == 31 { return fraction == 0 ? sign * .infinity : .nan }
        return sign * (1 + fraction) * pow(2, Double(exponent - 15))
    }
}

struct WaveRow: Identifiable {
    let id: String
    let label: String
    let width: Int
    var signal: Signal? = nil      // set when the row is a signal in the current design
    var isAnalog = false
}

struct WaveData {
    var title = ""
    var length = 0                         // number of samples
    var division = 8                       // samples per grid line
    var timeStep = 1.0                     // time per sample, for the axis labels
    var unit = ""
    var rows: [WaveRow] = []
    var values: [String: [UInt64]] = [:]   // by row id
    var analog: [String: [Double]] = [:]

    func bit(_ id: String?) -> [UInt64]? { id.flatMap { values[$0] } }
}

// MARK: - Protocol decoding

enum ProtocolKind: String, CaseIterable {
    case none = "None", uart = "UART", spi = "SPI", i2c = "I2C"

    /// The single-bit signals each protocol needs, with name fragments used to guess them.
    var roles: [(name: String, hints: [String], required: Bool)] {
        switch self {
        case .none: return []
        case .uart: return [("Line", ["tx", "rx", "uart", "serial"], true)]
        case .spi: return [("Clock", ["sclk", "sck", "spi_clk", "clk"], true), ("Data", ["mosi", "miso", "sdo", "sdi", "data"], true),
                           ("Select", ["cs", "ss", "sel"], false)]
        case .i2c: return [("SCL", ["scl"], true), ("SDA", ["sda"], true)]
        }
    }
}

struct Frame {
    let start: Int
    let end: Int
    let text: String
}

enum Decoder {
    static func byteText(_ byte: UInt8) -> String {
        let hex = String(format: "%02X", byte)
        return Radix.printable(byte).map { "\(hex) ‘\($0)’" } ?? hex
    }

    static func decode(_ kind: ProtocolKind, _ lines: [String: [UInt64]]) -> [Frame] {
        switch kind {
        case .none: return []
        case .uart: return lines["Line"].map(uart) ?? []
        case .spi:
            guard let clock = lines["Clock"], let data = lines["Data"] else { return [] }
            return spi(clock: clock, data: data, select: lines["Select"])
        case .i2c:
            guard let scl = lines["SCL"], let sda = lines["SDA"] else { return [] }
            return i2c(scl: scl, sda: sda)
        }
    }

    /// 8N1 serial, least significant bit first. The bit time is taken from the shortest pulse on the line.
    static func uart(_ line: [UInt64]) -> [Frame] {
        guard line.count > 10 else { return [] }
        var shortest = Int.max, run = 1
        var changes = 0
        for t in 1..<line.count {
            if (line[t] != 0) == (line[t - 1] != 0) { run += 1; continue }
            if changes > 0 { shortest = min(shortest, run) }
            changes += 1
            run = 1
        }
        guard shortest != .max, shortest >= 1 else { return [] }
        let bit = shortest
        var frames: [Frame] = []
        var t = 1
        while t + bit * 10 <= line.count {
            guard line[t - 1] != 0, line[t] == 0 else { t += 1; continue }     // start bit: a falling edge
            var byte: UInt8 = 0
            for i in 0..<8 where line[t + bit * (i + 1) + bit / 2] != 0 { byte |= 1 << UInt8(i) }
            let stop = line[min(t + bit * 9 + bit / 2, line.count - 1)] != 0
            frames.append(Frame(start: t, end: t + bit * 10, text: byteText(byte) + (stop ? "" : " (bad stop)")))
            t += bit * 10
        }
        return frames
    }

    /// SPI mode 0: data is sampled on each rising clock edge, most significant bit first.
    static func spi(clock: [UInt64], data: [UInt64], select: [UInt64]?) -> [Frame] {
        var frames: [Frame] = []
        var byte: UInt8 = 0, count = 0, start = 0
        for t in 1..<min(clock.count, data.count) {
            if let select, t < select.count, select[t] != 0 { count = 0; continue }   // not selected (active low)
            guard clock[t - 1] == 0, clock[t] != 0 else { continue }
            if count == 0 { start = t; byte = 0 }
            byte = byte << 1 | (data[t] != 0 ? 1 : 0)
            count += 1
            if count == 8 {
                frames.append(Frame(start: start, end: t + 1, text: byteText(byte)))
                count = 0
            }
        }
        return frames
    }

    /// I2C: start and stop conditions, the address byte, data bytes and their acknowledge bits.
    static func i2c(scl: [UInt64], sda: [UInt64]) -> [Frame] {
        var frames: [Frame] = []
        var active = false, first = true
        var value: UInt16 = 0, count = 0, start = 0
        for t in 1..<min(scl.count, sda.count) {
            let high = scl[t] != 0 && scl[t - 1] != 0
            if high, sda[t - 1] != 0, sda[t] == 0 {                 // start
                frames.append(Frame(start: t, end: t + 1, text: "S"))
                active = true; first = true; count = 0
                continue
            }
            if high, sda[t - 1] == 0, sda[t] != 0 {                 // stop
                frames.append(Frame(start: t, end: t + 1, text: "P"))
                active = false
                continue
            }
            guard active, scl[t - 1] == 0, scl[t] != 0 else { continue }
            if count == 0 { start = t; value = 0 }
            value = value << 1 | (sda[t] != 0 ? 1 : 0)
            count += 1
            if count == 9 {
                let byte = UInt8(truncatingIfNeeded: value >> 1)
                let ack = value & 1 == 0 ? "ACK" : "NAK"
                let text = first ? String(format: "addr %02X %@", byte >> 1, byte & 1 == 1 ? "R" : "W") : byteText(byte)
                frames.append(Frame(start: start, end: t + 1, text: "\(text) \(ack)"))
                first = false
                count = 0
            }
        }
        return frames
    }
}

// MARK: - VCD import

/// Reads a Value Change Dump, the standard waveform file every Verilog simulator can write.
enum VCD {
    struct ParseError: Error { let message: String }

    static func parse(_ text: String, title: String) throws -> WaveData {
        struct Variable { let rowID: String; let isReal: Bool }
        var variables: [String: [Variable]] = [:]          // VCD id code -> rows
        var rows: [WaveRow] = []
        var scope: [String] = []
        var unit = ""
        var events: [String: [(Int, UInt64)]] = [:]
        var reals: [String: [(Int, Double)]] = [:]
        var times: Set<Int> = [0]
        var now = 0

        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        var i = 0
        func untilEnd() -> [Substring] {
            var out: [Substring] = []
            while i < tokens.count, tokens[i] != "$end" { out.append(tokens[i]); i += 1 }
            i += 1
            return out
        }
        func record(_ code: Substring, _ value: UInt64) {
            for v in variables[String(code)] ?? [] { events[v.rowID, default: []].append((now, value)) }
        }

        while i < tokens.count {
            let token = tokens[i]
            i += 1
            switch token {
            case "$scope":
                let parts = untilEnd()
                if parts.count >= 2 { scope.append(String(parts[1])) }
            case "$upscope":
                _ = untilEnd()
                _ = scope.popLast()
            case "$timescale":
                unit = untilEnd().joined(separator: " ")
            case "$var":
                let parts = untilEnd()
                guard parts.count >= 4, rows.count < 300 else { continue }
                let width = Int(parts[1]) ?? 1
                let isReal = parts[0] == "real"
                let path = (scope.dropFirst() + [String(parts[3])]).joined(separator: ".")
                let id = "vcd:\(rows.count)"
                rows.append(WaveRow(id: id, label: path, width: isReal ? 64 : min(max(width, 1), 64), isAnalog: isReal))
                variables[String(parts[2]), default: []].append(Variable(rowID: id, isReal: isReal))
            case "$comment", "$date", "$version", "$enddefinitions":
                _ = untilEnd()
            case "$dumpvars", "$dumpall", "$dumpon", "$dumpoff", "$end":
                continue
            default:
                guard let first = token.first else { continue }
                if first == "#" {
                    now = Int(token.dropFirst()) ?? now
                    times.insert(now)
                } else if first == "b" || first == "B" {
                    guard i < tokens.count else { break }
                    let bits = token.dropFirst().map { $0 == "1" ? Character("1") : Character("0") }
                    record(tokens[i], UInt64(String(bits.suffix(64)), radix: 2) ?? 0)
                    i += 1
                } else if first == "r" || first == "R" {
                    guard i < tokens.count else { break }
                    let value = Double(token.dropFirst()) ?? 0
                    for v in variables[String(tokens[i])] ?? [] { reals[v.rowID, default: []].append((now, value)) }
                    i += 1
                } else if "01xXzZ".contains(first) {
                    record(token.dropFirst(), first == "1" ? 1 : 0)
                }
            }
        }
        guard !rows.isEmpty else { throw ParseError(message: "No signals were found. Is this a VCD file?") }

        // Resample onto a uniform grid fine enough to keep every edge (capped for very long dumps).
        let last = times.max() ?? 0
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        var step = times.reduce(0) { gcd($0, $1) }
        step = max(step, 1, Int((Double(last) / 4_000).rounded(.up)))
        let length = last / step + 2

        var data = WaveData(title: title, length: length, division: max(length / 24, 1), timeStep: Double(step), unit: unit, rows: rows)
        for row in rows {
            if row.isAnalog {
                var samples = [Double](repeating: 0, count: length)
                var current = 0.0, k = 0
                let list = reals[row.id] ?? []
                for t in 0..<length {
                    while k < list.count, list[k].0 <= t * step { current = list[k].1; k += 1 }
                    samples[t] = current
                }
                data.analog[row.id] = samples
            } else {
                var samples = [UInt64](repeating: 0, count: length)
                var current: UInt64 = 0, k = 0
                let list = events[row.id] ?? []
                for t in 0..<length {
                    while k < list.count, list[k].0 <= t * step { current = list[k].1; k += 1 }
                    samples[t] = current
                }
                data.values[row.id] = samples
            }
        }
        return data
    }
}
