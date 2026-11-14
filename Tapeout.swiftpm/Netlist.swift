import Foundation

// The synthesized design: a word-level netlist. Each cell works on a whole bus,
// so an 8-bit adder is one cell rather than forty gates.

struct VerilogError: Error, Equatable {
    let message: String
    let line: Int
}

func mask(_ width: Int) -> UInt64 {
    width >= 64 ? .max : (UInt64(1) << UInt64(max(width, 0))) - 1
}

enum GateKind: Hashable {
    case buf, not, and, or, xor, nand, nor, xnor
    case mux                      // [select, whenTrue, whenFalse]
    case add, sub, mul, div, mod
    case eq, ne, lt, le, gt, ge
    case shl, shr
    case redAnd(Int), redOr, redXor   // reduce a bus to one bit (redAnd carries the operand width)
    case slice(Int, Int)          // bits [hi:lo] of the input
    case concat([Int])            // input widths, most significant first
    case dff                      // a register; its input is the next value
    case memRead(Int)             // read one word of memory n; input is the address

    /// Short label printed on the cell.
    var rawValue: String {
        switch self {
        case .buf: return "BUF"
        case .not: return "NOT"
        case .and: return "AND"
        case .or: return "OR"
        case .xor: return "XOR"
        case .nand: return "NAND"
        case .nor: return "NOR"
        case .xnor: return "XNOR"
        case .mux: return "MUX"
        case .add: return "ADD"
        case .sub: return "SUB"
        case .mul: return "MUL"
        case .div: return "DIV"
        case .mod: return "MOD"
        case .eq: return "EQ"
        case .ne: return "NE"
        case .lt: return "LT"
        case .le: return "LE"
        case .gt: return "GT"
        case .ge: return "GE"
        case .shl: return "SHL"
        case .shr: return "SHR"
        case .redAnd: return "ALL"
        case .redOr: return "ANY"
        case .redXor: return "PAR"
        case .slice(let hi, let lo): return hi == lo ? "[\(hi)]" : "[\(hi):\(lo)]"
        case .concat: return "{ }"
        case .dff: return "REG"
        case .memRead: return "RAM"
        }
    }

    var isState: Bool {
        switch self {
        case .dff, .memRead: return true
        default: return false
        }
    }

    /// Slices and concatenations are only wiring; they take no time and no logic.
    var isWiring: Bool {
        switch self {
        case .slice, .concat, .buf: return true
        default: return false
        }
    }

    func eval(_ v: [UInt64], width: Int) -> UInt64 {
        let out: UInt64
        switch self {
        case .buf: out = v[0]
        case .not: out = ~v[0]
        case .and: out = v[0] & v[1]
        case .or: out = v[0] | v[1]
        case .xor: out = v[0] ^ v[1]
        case .nand: out = ~(v[0] & v[1])
        case .nor: out = ~(v[0] | v[1])
        case .xnor: out = ~(v[0] ^ v[1])
        case .mux: out = v[0] != 0 ? v[1] : v[2]
        case .add: out = v[0] &+ v[1]
        case .sub: out = v[0] &- v[1]
        case .mul: out = v[0] &* v[1]
        case .div: out = v[1] == 0 ? 0 : v[0] / v[1]
        case .mod: out = v[1] == 0 ? 0 : v[0] % v[1]
        case .eq: out = v[0] == v[1] ? 1 : 0
        case .ne: out = v[0] != v[1] ? 1 : 0
        case .lt: out = v[0] < v[1] ? 1 : 0
        case .le: out = v[0] <= v[1] ? 1 : 0
        case .gt: out = v[0] > v[1] ? 1 : 0
        case .ge: out = v[0] >= v[1] ? 1 : 0
        case .shl: out = v[1] >= 64 ? 0 : v[0] << v[1]
        case .shr: out = v[1] >= 64 ? 0 : v[0] >> v[1]
        case .redAnd(let w): out = v[0] & mask(w) == mask(w) ? 1 : 0
        case .redOr: out = v[0] != 0 ? 1 : 0
        case .redXor: out = UInt64(v[0].nonzeroBitCount & 1)
        case .slice(let hi, let lo): out = (v[0] >> UInt64(lo)) & mask(hi - lo + 1)
        case .concat(let widths):
            var acc: UInt64 = 0
            for (value, w) in zip(v, widths) { acc = (w >= 64 ? 0 : acc << UInt64(w)) | (value & mask(w)) }
            out = acc
        case .dff, .memRead: out = 0
        }
        return out & mask(width)
    }
}

enum Signal: Hashable {
    case input(String)
    case gate(Int)
    case const(UInt64)
}

struct Gate: Equatable, Hashable {
    let id: Int
    let kind: GateKind
    var inputs: [Signal]
    let width: Int
}

struct WritePort: Equatable {
    let enable: Signal
    let address: Signal
    let data: Signal
}

struct Memory: Equatable {
    let name: String
    let width: Int
    let depth: Int
    var writes: [WritePort] = []
}

/// The values held in registers and memories between clock edges.
struct SimState: Equatable {
    var regs: [Int: UInt64] = [:]
    var mems: [[UInt64]] = []
}

struct Netlist: Equatable {
    var name: String
    var inputs: [String]
    var outputs: [String]
    var widths: [String: Int] = [:]      // port widths
    var drivers: [String: Signal]        // output name -> what drives it
    var gates: [Gate]                    // registers first, then logic in dependency order
    var memories: [Memory] = []
    var clock: String? = nil
    /// Source names for signals (inputs, and cells that drive a named wire, reg or output).
    var names: [Signal: String] = [:]
    /// The source line that creates each signal, for cross-probing.
    var lines: [Signal: Int] = [:]

    var isSequential: Bool { clock != nil }
    /// Inputs the user drives by hand (everything but the clock).
    var dataInputs: [String] { inputs.filter { $0 != clock } }
    /// True when every port is a single bit, so a truth table makes sense.
    var isBitLevel: Bool { !isSequential && widths.values.allSatisfy { $0 == 1 } }

    /// True when the two designs have the same cells and connections, ignoring where they sit in the source.
    func sameStructure(as other: Netlist) -> Bool {
        name == other.name && inputs == other.inputs && outputs == other.outputs && widths == other.widths
            && drivers == other.drivers && gates == other.gates && memories == other.memories
            && clock == other.clock && names == other.names
    }

    func width(_ signal: Signal) -> Int {
        switch signal {
        case .input(let name): return widths[name] ?? 1
        case .gate(let id): return gates[id].width
        case .const(let value): return max(64 - value.leadingZeroBitCount, 1)
        }
    }

    func label(_ signal: Signal) -> String {
        if let name = names[signal] { return name }
        switch signal {
        case .input(let name): return name
        case .gate(let id): return "\(gates[id].kind.rawValue.lowercased().filter { $0.isLetter || $0.isNumber })\(id)"
        case .const(let value): return String(value)
        }
    }

    // MARK: Simulation

    func initialState() -> SimState {
        SimState(regs: [:], mems: memories.map { Array(repeating: 0, count: $0.depth) })
    }

    /// The settled value of every signal, given the inputs and the stored state.
    func evaluate(_ values: [String: UInt64], state: SimState) -> [Signal: UInt64] {
        var out: [Signal: UInt64] = [:]
        out.reserveCapacity(gates.count + inputs.count)
        for name in inputs { out[.input(name)] = (values[name] ?? 0) & mask(widths[name] ?? 1) }
        func value(_ s: Signal) -> UInt64 {
            if case .const(let c) = s { return c }
            return out[s] ?? 0
        }
        for g in gates where g.kind == .dff { out[.gate(g.id)] = state.regs[g.id] ?? 0 }
        for g in gates {
            switch g.kind {
            case .dff:
                continue
            case .memRead(let m):
                let address = value(g.inputs[0])
                out[.gate(g.id)] = m < state.mems.count && address < UInt64(state.mems[m].count) ? state.mems[m][Int(address)] : 0
            default:
                out[.gate(g.id)] = g.kind.eval(g.inputs.map(value), width: g.width)
            }
        }
        return out
    }

    /// One rising clock edge: every register and memory takes its next value.
    func step(_ values: [String: UInt64], state: SimState) -> SimState {
        let now = evaluate(values, state: state)
        func value(_ s: Signal) -> UInt64 {
            if case .const(let c) = s { return c }
            return now[s] ?? 0
        }
        var next = state
        for g in gates where g.kind == .dff { next.regs[g.id] = value(g.inputs[0]) & mask(g.width) }
        for (m, memory) in memories.enumerated() where m < next.mems.count {
            for port in memory.writes where value(port.enable) != 0 {
                let address = value(port.address)
                if address < UInt64(memory.depth) { next.mems[m][Int(address)] = value(port.data) & mask(memory.width) }
            }
        }
        return next
    }

    /// Single-bit convenience used by the lessons.
    func outputValues(_ values: [String: Bool]) -> [String: Bool] {
        let now = evaluate(values.mapValues { $0 ? 1 : 0 }, state: initialState())
        var out: [String: Bool] = [:]
        for name in outputs {
            switch drivers[name] {
            case .const(let c)?: out[name] = c != 0
            case let driver?: out[name] = (now[driver] ?? 0) != 0
            case nil: out[name] = false
            }
        }
        return out
    }

    /// Longest chain of logic cells between two registers, or between an input and an output.
    var depth: Int {
        var level: [Signal: Int] = [:]
        var deepest = 0
        for g in gates where g.kind != .dff {
            let l = (g.kind.isWiring ? 0 : 1) + (g.inputs.map { level[$0] ?? 0 }.max() ?? 0)
            level[.gate(g.id)] = l
            deepest = max(deepest, l)
        }
        return deepest
    }
}
