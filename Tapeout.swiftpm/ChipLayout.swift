import Foundation
import simd

/// How much room the floorplan gives the router between columns of cells.
enum Density: String, CaseIterable {
    case compact = "Compact", normal = "Normal", roomy = "Roomy"

    /// Distance between columns of cells when a channel carries only a few wires.
    var columnSpacing: Float {
        switch self {
        case .compact: return 2.25
        case .normal: return 2.6
        case .roomy: return 3.6
        }
    }

    /// The track pitch a channel is widened to when it carries many wires.
    /// Compact squeezes tracks closer than the spacing rule allows.
    var trackPitch: Float {
        switch self {
        case .compact: return 0.12
        case .normal: return 0.17
        case .roomy: return 0.24
        }
    }
}

enum Layer: String, CaseIterable, Hashable {
    case cells = "Cells", m1 = "M1", m2 = "M2", m3 = "M3", m4 = "M4", vias = "Vias"

    static func metal(_ n: Int) -> Layer { [.m1, .m2, .m3, .m4][min(max(n, 1), 4) - 1] }
}

/// The physical design: where every cell, pad, wire and via sits on the die.
/// The 3D chip, the 2D layout canvas, the schematic, DRC and the congestion map all read from this.
///
/// Wires leave a cell on metal 1, cross the routing channel on metal 2, and enter the next
/// cell on metal 3, so wires on one layer never have to cross. A register's next value
/// travels back to it around the edge of the die on metal 4.
struct ChipLayout {
    struct Pin { let at: SIMD2<Float>; let signal: Signal }

    struct Cell {
        let signal: Signal?            // nil for a memory's write port
        let kind: GateKind?
        let label: String
        let center: SIMD2<Float>
        let size: SIMD2<Float>
        let pins: [Pin]                // input pins on the left edge, including constants
        let bits: Int
        var lower: SIMD2<Float> { center - size / 2 }
        var upper: SIMD2<Float> { center + size / 2 }
        func contains(_ p: SIMD2<Float>, slack: Float = 0) -> Bool {
            all(simd_abs(p - center) .<= size / 2 + SIMD2(repeating: slack))
        }
    }

    struct Pad {
        let name: String
        let isInput: Bool
        let isClock: Bool
        let center: SIMD2<Float>
        let signal: Signal
        let bits: Int
    }

    struct Wire {
        let net: Signal
        let layer: Int                 // 1 to 4
        let a: SIMD2<Float>
        let b: SIMD2<Float>
        let bits: Int
        var isHorizontal: Bool { abs(a.y - b.y) < 0.0001 }
        var lower: SIMD2<Float> { simd_min(a, b) - SIMD2(repeating: ChipLayout.wireWidth / 2) }
        var upper: SIMD2<Float> { simd_max(a, b) + SIMD2(repeating: ChipLayout.wireWidth / 2) }
    }

    struct Via { let net: Signal; let at: SIMD2<Float>; let from: Int; let to: Int }   // layer 0 is the pad surface

    struct Violation {
        let layer: Int
        let nets: (Signal, Signal)
        let distance: Float
        let lower: SIMD2<Float>
        let upper: SIMD2<Float>
    }

    static let cellWidth: Float = 1.1
    static let padSize: Float = 0.6
    static let wireWidth: Float = 0.06
    static let minSpacing: Float = 0.10
    static let gap: Float = 0.45

    let name: String
    let density: Density
    private(set) var cells: [Cell] = []
    private(set) var pads: [Pad] = []
    private(set) var wires: [Wire] = []
    private(set) var vias: [Via] = []
    private(set) var level: [Signal: Int] = [:]
    private(set) var dieW: Float = 5.2
    private(set) var dieD: Float = 3.6

    private enum Kind {
        case input(String), gate(Gate), output(String), passThrough
        case nextValue(Int)             // where a register's next value is collected
        case memWrite(Int, Int)         // memory, port
    }

    private struct Node {
        var kind: Kind
        var signal: Signal?             // the net this node drives
        var col: Int
        var pins: [Signal] = []
        var sources: [Int?] = []        // per pin: the node in the previous column, or nil for a constant
        var y: Float = 0

        var height: Float {
            switch kind {
            case .input, .output: return ChipLayout.padSize
            case .passThrough, .nextValue: return 0.1
            case .gate, .memWrite: return max(0.8, 0.22 * Float(max(pins.count - 1, 0)) + 0.36)
            }
        }
        /// Clear space kept above and below.
        var margin: Float {
            switch kind {
            case .passThrough, .nextValue: return 0.12
            default: return ChipLayout.gap / 2
            }
        }
        var halfWidth: Float {
            switch kind {
            case .gate, .memWrite: return ChipLayout.cellWidth / 2
            case .input, .output: return ChipLayout.padSize / 2
            case .passThrough, .nextValue: return 0
            }
        }
        func pinOffset(_ index: Int) -> Float {
            let n = pins.count
            guard n > 1 else { return 0 }
            if case .gate = kind {} else if case .memWrite = kind {} else { return 0 }
            return (Float(index) - Float(n - 1) / 2) * (n == 2 ? 0.32 : 0.22)
        }
    }

    private struct Hop: Hashable {
        let signal: Signal
        let col: Int
    }

    init(_ netlist: Netlist, density: Density = .normal) {
        name = netlist.name
        self.density = density
        let spacing = density.columnSpacing

        // 1. Columns: inputs and registers, then logic by depth, then outputs and next-state points.
        var nodes: [Node] = []
        var driver: [Signal: Int] = [:]
        for input in netlist.inputs {
            driver[.input(input)] = nodes.count
            nodes.append(Node(kind: .input(input), signal: .input(input), col: 0))
        }
        for g in netlist.gates where g.kind == .dff {
            driver[.gate(g.id)] = nodes.count
            nodes.append(Node(kind: .gate(g), signal: .gate(g.id), col: 0, pins: [g.inputs[0]], sources: [nil]))
            level[.gate(g.id)] = 0
        }
        var hops: [Hop: Int] = [:]

        // Long connections pass through one point in every column they cross.
        func source(_ signal: Signal, into col: Int) -> Int? {
            guard var prev = driver[signal] else { return nil }
            var c = nodes[prev].col + 1
            while c < col {
                let key = Hop(signal: signal, col: c)
                if let existing = hops[key] {
                    prev = existing
                } else {
                    nodes.append(Node(kind: .passThrough, signal: signal, col: c, pins: [signal], sources: [prev]))
                    prev = nodes.count - 1
                    hops[key] = prev
                }
                c += 1
            }
            return prev
        }

        var gateCol: [Int: Int] = [:]
        for g in netlist.gates where g.kind != .dff {
            let col = 1 + (g.inputs.map { s -> Int in
                if case .gate(let id) = s { return gateCol[id] ?? 0 }
                return 0
            }.max() ?? 0)
            gateCol[g.id] = col
            level[.gate(g.id)] = col
        }
        let outCol = (gateCol.values.max() ?? 0) + 1
        for g in netlist.gates where g.kind != .dff {
            let col = gateCol[g.id]!
            let sources = g.inputs.map { source($0, into: col) }   // may add pass-through nodes first
            driver[.gate(g.id)] = nodes.count
            nodes.append(Node(kind: .gate(g), signal: .gate(g.id), col: col, pins: g.inputs, sources: sources))
        }
        for output in netlist.outputs {
            let d = netlist.drivers[output] ?? .const(0)
            let from = source(d, into: outCol)
            nodes.append(Node(kind: .output(output), signal: nil, col: outCol, pins: [d], sources: [from]))
        }
        for g in netlist.gates where g.kind == .dff {
            let d = g.inputs[0]
            guard driver[d] != nil else { continue }
            let from = source(d, into: outCol)
            nodes.append(Node(kind: .nextValue(g.id), signal: nil, col: outCol, pins: [d], sources: [from]))
        }
        for (m, memory) in netlist.memories.enumerated() {
            for (p, port) in memory.writes.enumerated() {
                let pins = [port.enable, port.address, port.data]
                let from = pins.map { source($0, into: outCol) }
                nodes.append(Node(kind: .memWrite(m, p), signal: nil, col: outCol, pins: pins, sources: from))
            }
        }

        // 2. Order each column by where its sources sit, to keep wires short and uncrossed.
        var tallest: Float = 1
        for col in 0...outCol {
            var members = nodes.indices.filter { nodes[$0].col == col }
            if col > 0 {
                func bary(_ i: Int) -> Float {
                    let s = nodes[i].sources.compactMap { $0 }
                    return s.isEmpty ? 0 : s.map { nodes[$0].y }.reduce(0, +) / Float(s.count)
                }
                let keyed = members.enumerated().map { (offset: $0.offset, index: $0.element, bary: bary($0.element)) }
                members = keyed.sorted { $0.bary != $1.bary ? $0.bary < $1.bary : $0.offset < $1.offset }.map { $0.index }
            }
            let total = members.reduce(Float(0)) { $0 + nodes[$1].height + nodes[$1].margin * 2 }
            var cursor = -total / 2
            for i in members {
                nodes[i].y = cursor + nodes[i].margin + nodes[i].height / 2
                cursor += nodes[i].height + nodes[i].margin * 2
            }
            tallest = max(tallest, total)
        }

        // Registers get a return lane each, below the logic.
        let returns = nodes.indices.filter { if case .nextValue = nodes[$0].kind { return true }; return false }
            .sorted { nodes[$0].y > nodes[$1].y }
        let lanePitch: Float = 0.2
        let laneRoom: Float = returns.isEmpty ? 0 : 0.4 + lanePitch * Float(returns.count)
        let sideRoom: Float = returns.isEmpty ? 0 : lanePitch * Float(returns.count) + 0.1
        let shift = -laneRoom / 2
        for i in nodes.indices { nodes[i].y += shift }
        let coreBottom = tallest / 2 + shift

        // A routing channel widens when many nets have to cross it.
        var channelNets: [[Int]] = [[]]
        var columnX: [Float] = [0]
        for col in 1...outCol {
            let members = nodes.indices.filter { nodes[$0].col == col }
            let nets = Array(Set(members.flatMap { nodes[$0].sources.compactMap { $0 } })).sorted { nodes[$0].y < nodes[$1].y }
            channelNets.append(nets)
            let channel = max(spacing - 1.56, density.trackPitch * Float(nets.count + 1))
            columnX.append(columnX[col - 1] + 1.56 + channel)
        }
        let span = columnX[outCol]
        func x(_ col: Int) -> Float { columnX[col] - span / 2 }
        dieW = max(span + 1.7 + sideRoom * 2, 5.2)
        dieD = max(tallest + 0.9 + laneRoom, 3.6)

        // 3. Cells and pads.
        for node in nodes {
            let p = SIMD2(x(node.col), node.y)
            func pins() -> [Pin] {
                node.pins.indices.map { Pin(at: SIMD2(p.x - node.halfWidth, p.y + node.pinOffset($0)), signal: node.pins[$0]) }
            }
            switch node.kind {
            case .input(let n):
                pads.append(Pad(name: n, isInput: true, isClock: n == netlist.clock, center: p, signal: .input(n),
                                bits: netlist.widths[n] ?? 1))
            case .output(let n):
                pads.append(Pad(name: n, isInput: false, isClock: false, center: p, signal: node.pins[0],
                                bits: netlist.widths[n] ?? 1))
            case .gate(let g):
                var label = g.kind.rawValue
                if case .memRead(let m) = g.kind, m < netlist.memories.count { label = "RAM" }
                cells.append(Cell(signal: .gate(g.id), kind: g.kind, label: label, center: p,
                                  size: SIMD2(ChipLayout.cellWidth, node.height), pins: pins(), bits: g.width))
            case .memWrite(let m, _):
                cells.append(Cell(signal: nil, kind: nil, label: "WRITE", center: p,
                                  size: SIMD2(ChipLayout.cellWidth, node.height), pins: pins(), bits: netlist.memories[m].width))
            case .passThrough, .nextValue:
                vias.append(Via(net: node.pins[0], at: p, from: 1, to: 3))
            }
        }

        // 4. Wires between neighbouring columns.
        var drawn: Set<Hop> = []
        for col in 1...outCol {
            let members = nodes.indices.filter { nodes[$0].col == col }
            // Each net entering this column gets its own vertical track in the routing channel.
            let nets = channelNets[col]
            let channelStart = x(col - 1) + 0.78
            let channelWidth = x(col) - x(col - 1) - 1.56
            var track: [Int: Float] = [:]
            for (k, s) in nets.enumerated() {
                track[s] = channelStart + channelWidth * Float(k + 1) / Float(nets.count + 1)
            }
            for i in members {
                let node = nodes[i]
                for (pin, maybe) in node.sources.enumerated() {
                    guard let s = maybe else { continue }
                    let src = nodes[s]
                    let net = src.signal!
                    let bits = netlist.width(net)
                    let startX = x(col - 1) + src.halfWidth
                    let endX = x(col) - node.halfWidth
                    let pinY = node.y + node.pinOffset(pin)
                    if abs(pinY - src.y) < 0.001 {
                        wires.append(Wire(net: net, layer: 1, a: SIMD2(startX, src.y), b: SIMD2(endX, src.y), bits: bits))
                        continue
                    }
                    let t = track[s]!
                    if drawn.insert(Hop(signal: net, col: col)).inserted {
                        wires.append(Wire(net: net, layer: 1, a: SIMD2(startX, src.y), b: SIMD2(t, src.y), bits: bits))
                        vias.append(Via(net: net, at: SIMD2(t, src.y), from: 1, to: 2))
                    }
                    wires.append(Wire(net: net, layer: 2, a: SIMD2(t, src.y), b: SIMD2(t, pinY), bits: bits))
                    vias.append(Via(net: net, at: SIMD2(t, pinY), from: 2, to: 3))
                    wires.append(Wire(net: net, layer: 3, a: SIMD2(t, pinY), b: SIMD2(endX, pinY), bits: bits))
                    if case .output = node.kind {
                        vias.append(Via(net: net, at: SIMD2(endX, pinY), from: 0, to: 3))
                    }
                }
            }
        }

        // 5. Each register's next value loops back around the die on metal 4. Outer lanes are
        //    wider than inner ones, so the loops nest and never cross.
        for (k, i) in returns.enumerated() {
            guard case .nextValue(let id) = nodes[i].kind, let home = driver[.gate(id)] else { continue }
            let net = nodes[i].pins[0]
            let bits = netlist.width(net)
            let from = SIMD2(x(outCol), nodes[i].y)
            let reg = nodes[home]
            let right = x(outCol) + 0.85 + lanePitch * Float(k)
            let left = x(0) - 0.85 - lanePitch * Float(k)
            let lane = coreBottom + 0.4 + lanePitch * Float(k)
            wires.append(Wire(net: net, layer: 1, a: from, b: SIMD2(right, from.y), bits: bits))
            vias.append(Via(net: net, at: SIMD2(right, from.y), from: 1, to: 4))
            wires.append(Wire(net: net, layer: 4, a: SIMD2(right, from.y), b: SIMD2(right, lane), bits: bits))
            wires.append(Wire(net: net, layer: 4, a: SIMD2(right, lane), b: SIMD2(left, lane), bits: bits))
            wires.append(Wire(net: net, layer: 4, a: SIMD2(left, lane), b: SIMD2(left, reg.y), bits: bits))
            vias.append(Via(net: net, at: SIMD2(left, reg.y), from: 3, to: 4))
            wires.append(Wire(net: net, layer: 3, a: SIMD2(left, reg.y), b: SIMD2(x(0) - reg.halfWidth, reg.y), bits: bits))
        }
    }

    // MARK: - Design rule check

    /// False when the design is too large to check every pair of wires interactively.
    var canCheckRules: Bool { wires.count <= 2600 }

    /// Same-layer wires from different nets that sit closer than the minimum spacing (or touch: a short).
    func designRuleViolations() -> [Violation] {
        guard canCheckRules else { return [] }
        var worst: [String: Violation] = [:]
        let lowers = wires.map { $0.lower }, uppers = wires.map { $0.upper }
        for i in wires.indices {
            for j in wires.indices where j > i {
                let (a, b) = (wires[i], wires[j])
                guard a.layer == b.layer, a.net != b.net else { continue }
                let gap = simd_max(simd_max(lowers[i] - uppers[j], lowers[j] - uppers[i]), SIMD2(repeating: 0))
                let distance = simd_length(gap)
                guard distance < ChipLayout.minSpacing - 0.0005 else { continue }
                // Report the stretch where the two wires actually run side by side.
                let lower = simd_min(simd_max(lowers[i], lowers[j]), simd_min(uppers[i], uppers[j]))
                let upper = simd_max(simd_max(lowers[i], lowers[j]), simd_min(uppers[i], uppers[j]))
                let key = "\(a.layer)|\(min("\(a.net)", "\(b.net)"))|\(max("\(a.net)", "\(b.net)"))"
                if let existing = worst[key] {
                    worst[key] = Violation(layer: a.layer, nets: existing.nets, distance: min(existing.distance, distance),
                                           lower: simd_min(existing.lower, lower), upper: simd_max(existing.upper, upper))
                } else {
                    worst[key] = Violation(layer: a.layer, nets: (a.net, b.net), distance: distance, lower: lower, upper: upper)
                }
            }
        }
        return worst.values.sorted { ($0.lower.x, $0.lower.y) < ($1.lower.x, $1.lower.y) }
    }

    // MARK: - Routing congestion

    static let binSize: Float = 0.5
    /// Wire length one bin can carry in one direction before it overflows.
    static let binCapacity: Float = binSize * (binSize / (wireWidth + minSpacing))

    struct Congestion {
        let columns: Int
        let rows: Int
        let origin: SIMD2<Float>
        let horizontal: [Float]   // utilization per bin, 1.0 = full
        let vertical: [Float]
        func utilization(_ c: Int, _ r: Int) -> Float { max(horizontal[r * columns + c], vertical[r * columns + c]) }
    }

    func congestion() -> Congestion {
        let size = ChipLayout.binSize
        let columns = max(1, Int((dieW / size).rounded(.up)))
        let rows = max(1, Int((dieD / size).rounded(.up)))
        let origin = SIMD2(-Float(columns) * size / 2, -Float(rows) * size / 2)
        var h = [Float](repeating: 0, count: columns * rows)
        var v = h
        let step: Float = 0.05
        for wire in wires {
            let length = simd_distance(wire.a, wire.b)
            let n = max(1, Int(length / step))
            for k in 0..<n {
                let p = wire.a + (wire.b - wire.a) * ((Float(k) + 0.5) / Float(n))
                let c = Int((p.x - origin.x) / size), r = Int((p.y - origin.y) / size)
                guard c >= 0, c < columns, r >= 0, r < rows else { continue }
                if wire.isHorizontal { h[r * columns + c] += length / Float(n) } else { v[r * columns + c] += length / Float(n) }
            }
        }
        return Congestion(columns: columns, rows: rows, origin: origin,
                          horizontal: h.map { $0 / ChipLayout.binCapacity },
                          vertical: v.map { $0 / ChipLayout.binCapacity })
    }
}
