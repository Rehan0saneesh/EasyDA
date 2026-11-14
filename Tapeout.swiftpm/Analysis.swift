import Foundation

extension Gate {
    /// Relative switching delay. Wiring is free, inverting gates are fastest, arithmetic grows with width.
    var delay: Int {
        let log = max(1, Int((Double(max(width, 2))).log2().rounded(.up)))
        switch kind {
        case .slice, .concat, .buf: return 0
        case .not, .nand, .nor, .dff: return 1
        case .and, .or: return 2
        case .xor, .xnor, .mux: return 3
        case .redAnd, .redOr, .redXor: return 4
        case .eq, .ne: return 5
        case .lt, .le, .gt, .ge: return 7
        case .add, .sub: return 3 + 2 * log
        case .shl, .shr: return 3 * log
        case .mul: return 6 * log
        case .div, .mod: return 12 * log
        case .memRead: return 6
        }
    }
}

private extension Double {
    func log2() -> Double { Foundation.log2(self) }
}

enum ConeMode: String, CaseIterable {
    case both = "Both", fanIn = "Fan-in", fanOut = "Fan-out"
}

/// A combinational simulation run: input combinations in turn, with real cell delays.
struct Waves {
    var period = 8                          // time units each input vector is held
    var vectors: [[String: UInt64]] = []
    var length = 0
    var samples: [Signal: [UInt64]] = [:]   // one value per time unit
}

/// Everything the inspection tools need, derived from a netlist.
struct Analysis {
    let netlist: Netlist
    private(set) var arrival: [Signal: Int] = [:]
    private(set) var loads: [Signal: [Int]] = [:]      // cells each signal feeds
    private(set) var criticalPath: [Signal] = []
    private(set) var criticalDelay = 0
    /// Where the critical path ends, in words.
    private(set) var criticalEnd = ""
    private(set) var waves = Waves()
    private(set) var toggles: [Signal: Int] = [:]

    init(_ netlist: Netlist) {
        self.netlist = netlist

        // Static timing: the latest moment each signal can settle after a clock edge or input change.
        var slowestInput: [Signal: Signal] = [:]
        for name in netlist.inputs { arrival[.input(name)] = 0 }
        for g in netlist.gates where g.kind == .dff { arrival[.gate(g.id)] = g.delay }
        for g in netlist.gates {
            for input in Set(g.inputs) { loads[input, default: []].append(g.id) }
            guard g.kind != .dff else { continue }
            let worst = g.inputs.max { (arrival[$0] ?? 0) < (arrival[$1] ?? 0) }
            arrival[.gate(g.id)] = (worst.flatMap { arrival[$0] } ?? 0) + g.delay
            if let worst, arrival[worst] != nil { slowestInput[.gate(g.id)] = worst }
        }
        var ends: [(Signal, String)] = netlist.outputs.compactMap { out in netlist.drivers[out].map { ($0, "output \(out)") } }
        for g in netlist.gates where g.kind == .dff { ends.append((g.inputs[0], "register \(netlist.label(.gate(g.id)))")) }
        for memory in netlist.memories {
            for port in memory.writes {
                ends += [(port.enable, "memory \(memory.name)"), (port.address, "memory \(memory.name)"), (port.data, "memory \(memory.name)")]
            }
        }
        if let (end, label) = ends.max(by: { (arrival[$0.0] ?? 0) < (arrival[$1.0] ?? 0) }), var at = Optional(end), arrival[at] != nil {
            criticalDelay = arrival[at] ?? 0
            criticalEnd = label
            var path = [at]
            while let previous = slowestInput[at], path.count < 500 { path.append(previous); at = previous }
            criticalPath = path.reversed()
        }

        guard !netlist.isSequential else { return }

        // Simulation: count through the input combinations, holding each long enough to settle.
        let names = netlist.inputs
        let bits = names.reduce(0) { $0 + (netlist.widths[$1] ?? 1) }
        let count = bits >= 5 ? 32 : 1 << bits
        let vectors: [[String: UInt64]] = (0..<count).map { row in
            var v: [String: UInt64] = [:]
            var rest = UInt64(row)
            for name in names.reversed() {
                let w = netlist.widths[name] ?? 1
                v[name] = rest & mask(w)
                rest = w >= 64 ? 0 : rest >> UInt64(w)
            }
            return v
        }
        let period = max(criticalDelay + 3, 8)
        let length = count * period
        var samples: [Signal: [UInt64]] = [:]
        for name in names {
            samples[.input(name)] = (0..<length).map { vectors[$0 / period][name] ?? 0 }
        }
        let empty = SimState()
        let settled = netlist.evaluate(vectors.first ?? [:], state: empty)
        for g in netlist.gates {
            let d = g.delay
            let ins: [[UInt64]?] = g.inputs.map { if case .const = $0 { return nil }; return samples[$0] }
            let fixed: [UInt64] = g.inputs.map { if case .const(let c) = $0 { return c }; return 0 }
            samples[.gate(g.id)] = (0..<length).map { t in
                if t < d { return settled[.gate(g.id)] ?? 0 }
                return g.kind.eval(ins.indices.map { ins[$0]?[t - d] ?? fixed[$0] }, width: g.width)
            }
        }
        waves = Waves(period: period, vectors: vectors, length: length, samples: samples)
        toggles = Analysis.activity(samples)
    }

    /// How many bit flips each signal makes over a run.
    static func activity(_ samples: [Signal: [UInt64]]) -> [Signal: Int] {
        samples.mapValues { values in
            zip(values, values.dropFirst()).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
        }
    }

    // MARK: Cones

    /// Everything that can affect a signal, back to the nearest registers and inputs.
    func fanIn(of signal: Signal) -> Set<Signal> {
        var seen: Set<Signal> = [signal]
        var stack = [signal]
        while let s = stack.popLast() {
            guard case .gate(let id) = s else { continue }
            if netlist.gates[id].kind == .dff, s != signal { continue }
            for input in netlist.gates[id].inputs where seen.insert(input).inserted { stack.append(input) }
        }
        return seen
    }

    /// Everything a signal can affect, forward to the nearest registers and outputs.
    func fanOut(of signal: Signal) -> Set<Signal> {
        var seen: Set<Signal> = [signal]
        var stack = [signal]
        while let s = stack.popLast() {
            for id in loads[s] ?? [] where seen.insert(.gate(id)).inserted {
                if netlist.gates[id].kind != .dff { stack.append(.gate(id)) }
            }
        }
        return seen
    }

    func cone(of signal: Signal, mode: ConeMode) -> Set<Signal> {
        switch mode {
        case .fanIn: return fanIn(of: signal)
        case .fanOut: return fanOut(of: signal)
        case .both: return fanIn(of: signal).union(fanOut(of: signal))
        }
    }

    func arrival(ofOutput name: String) -> Int {
        netlist.drivers[name].flatMap { arrival[$0] } ?? 0
    }

    // MARK: Lint

    /// Logic problems that synthesize fine but are almost certainly mistakes.
    func lint() -> [(title: String, detail: String, signal: Signal?)] {
        var notes: [(String, String, Signal?)] = []
        var used: Set<Signal> = Set(netlist.drivers.values)
        for g in netlist.gates { used.formUnion(g.inputs) }
        for memory in netlist.memories {
            for port in memory.writes { used.formUnion([port.enable, port.address, port.data]) }
        }
        for name in netlist.inputs where name != netlist.clock && !used.contains(.input(name)) {
            notes.append(("Input ‘\(name)’ is never used", "No output or register depends on it.", .input(name)))
        }
        for out in netlist.outputs {
            if case .const(let value)? = netlist.drivers[out] {
                notes.append(("Output ‘\(out)’ is stuck at \(value)", "Its logic simplifies to a constant.", nil))
            }
        }
        for (signal, cells) in loads.sorted(by: { netlist.label($0.key) < netlist.label($1.key) }) where cells.count > 8 {
            notes.append(("‘\(netlist.label(signal))’ drives \(cells.count) cells",
                          "High fan-out slows a signal down. Real tools would add buffers.", signal))
        }
        return notes
    }
}
