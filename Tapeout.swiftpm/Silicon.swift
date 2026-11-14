import Foundation
import simd

/// The design as a foundry would see it: every word-level block broken into single-bit standard
/// cells, placed in rows, filled, strapped for power and wired on three metal layers.
///
/// Cell sizes follow the open SkyWater 130 nm high-density library (0.46 µm sites, 2.72 µm rows)
/// and the outline is the smallest Tiny Tapeout tile the design fits. The cell counts and wiring
/// are estimates: a real flow would optimise the logic and route every net to exact rules.
struct Silicon {
    enum Style: UInt8 { case logic, flop, clock, buffer, decap, fill, tap }

    struct Cell {
        let site: Int          // left edge, in sites from the tile's left edge
        let sites: Int         // width
        let style: Style
    }

    struct Route {
        let layer: Int         // 1 and 3 run across, 2 runs up and down
        let a: SIMD2<Float>    // µm from the tile's top-left corner
        let b: SIMD2<Float>
    }

    struct Pin { let name: String; let x: Float }

    static let site: Float = 0.46
    static let rowHeight: Float = 2.72
    static let strapPitch: Float = 15.18
    static let strapWidth: Float = 1.6
    /// Tiny Tapeout tile outlines on sky130, in µm.
    static let tiles: [(name: String, width: Float, height: Float)] = [
        ("1×1", 161.00, 111.52), ("1×2", 161.00, 225.76), ("2×2", 334.88, 225.76), ("3×2", 508.76, 225.76),
        ("4×2", 682.64, 225.76), ("6×2", 1030.40, 225.76), ("8×2", 1378.16, 225.76),
    ]

    let tile: String?                  // nil when the design is too big for any standard tile
    let width: Float                   // µm
    let height: Float
    let top: Float                     // y of the first row
    let rows: [[Cell]]                 // each row sorted left to right, gaps filled
    let routes: [Route]
    let pins: [Pin]                    // along the top edge, one per port bit
    let straps: [Float]                // x of each vertical power strap, alternating power and ground
    let cellCount: Int                 // placed logic cells, without fill
    let flopCount: Int
    let utilization: Double            // share of the row area taken by logic
    let wireLength: Double             // µm

    /// How one word-level block breaks down into single-bit cells.
    private static func expand(_ g: Gate, _ n: Netlist) -> (count: Int, sites: Int, style: Style) {
        let w = g.width
        let fanIn = max(g.inputs.count - 1, 1)
        let widest = g.inputs.map { n.width($0) }.max() ?? 1
        switch g.kind {
        case .buf, .slice, .concat: return (0, 0, .logic)
        case .not: return (w, 3, .logic)
        case .and, .or: return (w * fanIn, 5, .logic)
        case .nand, .nor: return (w * fanIn, 3, .logic)
        case .xor, .xnor: return (w * fanIn, 7, .logic)
        case .mux: return (w, 9, .logic)
        case .add, .sub: return (w, 16, .logic)                       // a full adder per bit
        case .lt, .le, .gt, .ge: return (widest, 12, .logic)
        case .eq, .ne: return (widest * 2 - 1, 6, .logic)
        case .mul: return (min(w * w, 4096), 14, .logic)
        case .div, .mod: return (min(w * w, 4096), 20, .logic)
        case .shl, .shr:
            if g.inputs.count > 1, case .const = g.inputs[1] { return (0, 0, .logic) }   // a fixed shift is only wiring
            return (w * max(Int(log2(Double(max(w, 2))).rounded(.up)), 1), 9, .logic)
        case .redAnd, .redOr: return (max(widest - 1, 1), 5, .logic)
        case .redXor: return (max(widest - 1, 1), 7, .logic)
        case .dff: return (w, 16, .flop)
        case .memRead(let m): return (w * max(n.memories[m].depth - 1, 1), 9, .logic)
        }
    }

    private struct Item {
        let sites: Int
        let style: Style
        var want: SIMD2<Float>         // 0...1 across the placement region, before legalising
        var offset: SIMD2<Float> = .zero   // µm, position inside its block
        var row = 0
        var site = 0
    }

    init(netlist: Netlist, layout: ChipLayout) {
        // 1. Break every block into cells.
        var items: [Item] = []
        var group: [Int: [Int]] = [:]              // gate id -> its cells
        var memoryCells: [Int: [Int]] = [:]
        var home: [Int: SIMD2<Float>] = [:]
        for cell in layout.cells where cell.kind != nil {
            if case .gate(let id)? = cell.signal {
                home[id] = SIMD2(cell.center.x / max(layout.dieW, 1) + 0.5, cell.center.y / max(layout.dieD, 1) + 0.5)
            }
        }
        func block(_ count: Int, _ sites: Int, _ style: Style, at want: SIMD2<Float>) -> [Int] {
            guard count > 0 else { return [] }
            let tall = max(Int((Float(count * sites) * Silicon.site / Silicon.rowHeight).squareRoot().rounded(.up)), 1)
            let columns = (count + tall - 1) / tall
            var made: [Int] = []
            for i in 0..<count {
                let offset = SIMD2((Float(i / tall) - Float(columns - 1) / 2) * Float(sites) * Silicon.site,
                                   (Float(i % tall) - Float(tall - 1) / 2) * Silicon.rowHeight)
                made.append(items.count)
                items.append(Item(sites: sites, style: style, want: want, offset: offset))
            }
            return made
        }
        for g in netlist.gates {
            let want = home[g.id] ?? SIMD2(0.5, 0.5)
            let e = Silicon.expand(g, netlist)
            group[g.id] = block(e.count, e.sites, e.style, at: want)
            if case .memRead(let m) = g.kind, memoryCells[m] == nil {
                // The storage itself: a flip-flop per bit, each with a write-enable mux.
                let memory = netlist.memories[m]
                let bits = min(memory.depth * memory.width, 8192)
                memoryCells[m] = block(bits, 16, .flop, at: want) + block(bits, 9, .logic, at: want)
            }
        }

        // One pin per port bit along the top edge, with a buffer behind each output.
        var pinNames: [String] = []
        var pinsOf: [String: [Int]] = [:]
        for port in netlist.inputs + netlist.outputs {
            let bits = netlist.widths[port] ?? 1
            pinsOf[port] = Array(pinNames.count..<(pinNames.count + bits))
            pinNames += bits == 1 ? [port] : (0..<bits).reversed().map { "\(port)[\($0)]" }
        }
        func pinX(_ i: Int) -> Float { 0.06 + 0.88 * (Float(i) + 0.5) / Float(max(pinNames.count, 1)) }
        var outputBuffers: [String: [Int]] = [:]
        for port in netlist.outputs {
            outputBuffers[port] = (pinsOf[port] ?? []).map { pin in
                items.append(Item(sites: 4, style: .buffer, want: SIMD2(pinX(pin), 0)))
                return items.count - 1
            }
        }

        // A two-level clock tree: one root buffer, and a leaf buffer for every dozen flip-flops.
        let flops = items.indices.filter { items[$0].style == .flop }
        var leaves: [(buffer: Int, flops: [Int])] = []
        var root: Int?
        if netlist.clock != nil, !flops.isEmpty {
            for start in stride(from: 0, to: flops.count, by: 12) {
                let members = Array(flops[start..<min(start + 12, flops.count)])
                let middle = members.reduce(SIMD2<Float>.zero) { $0 + items[$1].want } / Float(members.count)
                items.append(Item(sites: 8, style: .clock, want: middle))
                leaves.append((items.count - 1, members))
            }
            let middle = leaves.reduce(SIMD2<Float>.zero) { $0 + items[$1.buffer].want } / Float(leaves.count)
            items.append(Item(sites: 12, style: .clock, want: middle))
            root = items.count - 1
        }

        // 2. Pick the smallest tile that leaves room to route (at most 60% full).
        let needed = items.reduce(0) { $0 + $1.sites }
        func capacity(_ w: Float, _ h: Float) -> (rows: Int, sites: Int) {
            (max(Int(h / Silicon.rowHeight) - 2, 1), max(Int(w / Silicon.site) - 12, 1))
        }
        var chosen = Silicon.tiles.first { let c = capacity($0.width, $0.height); return Double(needed) <= 0.6 * Double(c.rows * c.sites) }
            .map { (name: Optional($0.name), width: $0.width, height: $0.height) }
        if chosen == nil {
            let side = (Float(needed) * Silicon.site * Silicon.rowHeight / 0.5).squareRoot() + 12
            chosen = (nil, (side / Silicon.site).rounded(.up) * Silicon.site, (side / Silicon.rowHeight).rounded(.up) * Silicon.rowHeight)
        }
        tile = chosen!.name
        width = chosen!.width
        height = chosen!.height
        let room = capacity(width, height)
        let left = 6
        top = Silicon.rowHeight
        utilization = Double(needed) / Double(room.rows * room.sites)

        // 3. Place. Logic gathers in the middle of the tile at about three-quarters density,
        //    then each cell drops into the nearest free spot in a row.
        let share = min(max((Float(utilization) / 0.75).squareRoot(), 0.22), 0.94)
        let regionW = Float(room.sites) * Silicon.site * share, regionH = Float(room.rows) * Silicon.rowHeight * share
        let regionX = Float(left) * Silicon.site + (Float(room.sites) * Silicon.site - regionW) / 2
        let regionY = top + (Float(room.rows) * Silicon.rowHeight - regionH) / 2
        var target = items.map { SIMD2(regionX + $0.want.x * regionW, regionY + $0.want.y * regionH) + $0.offset }
        for buffers in outputBuffers.values { for b in buffers { target[b] = SIMD2(items[b].want.x * width, top + Silicon.rowHeight * 1.5) } }
        var cursor = Array(repeating: left, count: room.rows)
        let right = left + room.sites
        for i in items.indices.sorted(by: { target[$0].x < target[$1].x }) {
            let wantSite = min(max(Int(target[i].x / Silicon.site) - items[i].sites / 2, left), right - items[i].sites)
            let wantRow = min(max(Int((target[i].y - top) / Silicon.rowHeight), 0), room.rows - 1)
            var best = -1
            var bestCost = Float.infinity
            for r in 0..<room.rows {
                let at = max(cursor[r], wantSite)
                guard at + items[i].sites <= right else { continue }
                let cost = Float(abs(r - wantRow)) * Silicon.rowHeight + Float(at - wantSite) * Silicon.site
                if cost < bestCost { bestCost = cost; best = r }
            }
            if best < 0 { best = cursor.indices.min { cursor[$0] < cursor[$1] } ?? 0 }
            items[i].row = best
            items[i].site = min(max(cursor[best], wantSite), max(right - items[i].sites, left))
            cursor[best] = items[i].site + items[i].sites
        }

        // 4. Fill every gap, so the wells and power rails run unbroken, and drop in well taps.
        var placed = Array(repeating: [Cell](), count: room.rows)
        for item in items { placed[item.row].append(Cell(site: item.site, sites: item.sites, style: item.style)) }
        let total = Int(width / Silicon.site)
        var filled: [[Cell]] = []
        for (r, row) in placed.enumerated() {
            var out: [Cell] = []
            var at = 0
            func fill(to end: Int) {
                while at < end {
                    let gap = end - at
                    if (at + r * 14) % 28 == 0 { out.append(Cell(site: at, sites: 1, style: .tap)); at += 1; continue }
                    let untilTap = 28 - (at + r * 14) % 28
                    let seed = (at &* 31 &+ r &* 17) % 5
                    let size = min(gap, untilTap, [12, 8, 6, 12, 4][seed])
                    out.append(Cell(site: at, sites: size, style: size >= 3 ? .decap : .fill))
                    at += size
                }
            }
            for cell in row.sorted(by: { $0.site < $1.site }) {
                fill(to: cell.site)
                out.append(cell)
                at = cell.site + cell.sites
            }
            fill(to: total)
            filled.append(out)
        }
        rows = filled
        cellCount = items.count
        flopCount = flops.count

        // 5. Wire it up: across on metal 1 (short) or metal 3 (long), up and down on metal 2.
        pins = pinNames.enumerated().map { Pin(name: $1, x: pinX($0) * chosen!.width) }
        let pinList = pins
        let rowTop = top
        func position(_ ref: Int) -> SIMD2<Float> {
            if ref < 0 { return SIMD2(pinList[-ref - 1].x, 0) }
            let item = items[ref]
            return SIMD2((Float(item.site) + Float(item.sites) / 2) * Silicon.site, rowTop + (Float(item.row) + 0.5) * Silicon.rowHeight)
        }
        var wires: [Route] = []
        var length = 0.0
        func connect(_ from: Int, _ to: Int) {
            guard wires.count < 16000, from != to else { return }
            let n = wires.count
            let a = position(from)
            var b = position(to)
            b.x += Float(n * 7 % 5 - 2) * Silicon.site * 0.5
            b.y += Float(n * 3 % 5 - 2) * 0.34
            let across = abs(a.x - b.x) < 30 ? 1 : 3
            if from < 0 || to < 0 || n % 2 == 0 {
                let x = a.x + (from < 0 ? 0 : Float(n * 5 % 3 - 1) * Silicon.site * 0.5)
                wires.append(Route(layer: 2, a: SIMD2(x, a.y), b: SIMD2(x, b.y)))
                wires.append(Route(layer: across, a: SIMD2(x, b.y), b: b))
            } else {
                let y = a.y + Float(n * 5 % 5 - 2) * 0.34
                wires.append(Route(layer: across, a: SIMD2(a.x, y), b: SIMD2(b.x, y)))
                wires.append(Route(layer: 2, a: SIMD2(b.x, y), b: b))
            }
            length += Double(abs(a.x - b.x) + abs(a.y - b.y))
        }
        /// The cells (or pins) that actually drive a signal, looking through pure wiring.
        func sources(_ signal: Signal, _ depth: Int = 0) -> [Int] {
            switch signal {
            case .const: return []
            case .input(let name): return (pinsOf[name] ?? []).map { -$0 - 1 }
            case .gate(let id):
                if let cells = group[id], !cells.isEmpty { return cells }
                guard depth < 12 else { return [] }
                return netlist.gates[id].inputs.flatMap { sources($0, depth + 1) }
            }
        }
        func link(_ from: [Int], _ to: [Int]) {
            guard !from.isEmpty else { return }
            for i in 0..<min(to.count, 256) { connect(from[i % from.count], to[i]) }
        }
        for g in netlist.gates {
            guard let cells = group[g.id], !cells.isEmpty else { continue }
            for input in g.inputs { link(sources(input), cells) }
            switch g.kind {
            case .add, .sub, .lt, .le, .gt, .ge:
                for i in 1..<cells.count { connect(cells[i - 1], cells[i]) }      // the carry chain
            case .memRead(let m):
                link(memoryCells[m] ?? [], cells)
            default: break
            }
        }
        for (m, memory) in netlist.memories.enumerated() {
            guard let cells = memoryCells[m] else { continue }
            let half = cells.count / 2
            for i in 0..<min(half, 256) { connect(cells[half + i], cells[i]) }    // enable mux into its flip-flop
            for port in memory.writes {
                link(sources(port.data), Array(cells[half...]))
                link(sources(port.address) + sources(port.enable), Array(cells[half...].prefix(64)))
            }
        }
        for port in netlist.outputs {
            guard let buffers = outputBuffers[port], let driver = netlist.drivers[port] else { continue }
            link(sources(driver), buffers)
            for (buffer, pin) in zip(buffers, pinsOf[port] ?? []) { connect(buffer, -pin - 1) }
        }
        if let root, let clock = netlist.clock, let pin = pinsOf[clock]?.first {
            connect(-pin - 1, root)
            for leaf in leaves {
                connect(root, leaf.buffer)
                for flop in leaf.flops { connect(leaf.buffer, flop) }
            }
        }
        routes = wires
        wireLength = length

        var lines: [Float] = []
        var x = Silicon.strapPitch / 2
        while x < chosen!.width - Silicon.strapWidth { lines.append(x); x += Silicon.strapPitch }
        straps = lines
    }
}
