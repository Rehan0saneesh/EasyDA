import SwiftUI
import simd

/// The finished die: the standard-cell core in the middle, a ring of bond pads around it,
/// and the wiring that joins each pad to its pin on the core.
///
/// Sizes are estimates from stated assumptions, not a foundry's numbers: cells follow the
/// SkyWater 130 nm library, and pads are 60 µm on a 90 µm pitch.
struct DiePlan {
    struct Pad { let name: String; let center: SIMD2<Double> }   // mm, from the die's top-left corner
    /// A pad-to-pin connection: `ring` runs around the core, `stubs` cross the rings on another layer.
    struct Link { let ring: [SIMD2<Double>]; let stubs: [(SIMD2<Double>, SIMD2<Double>)] }

    static let padSize = 0.060
    static let padPitch = 0.090
    static let ring = 0.200          // pad ring, power rings and pad wiring, per side
    static let sealRing = 0.012
    static let scribe = 0.080        // saw lane between dies
    static let padInner = sealRing + 0.018 + padSize + 0.008     // inner edge of the pad ring

    let width: Double                // mm
    let height: Double
    let coreWidth: Double
    let coreHeight: Double
    let pads: [Pad]
    let links: [Link]
    let linkWidth: Double
    /// Insets of the power and ground rings, and the pads that feed them.
    let powerRings = (vdd: DiePlan.padInner + 0.010, vss: DiePlan.padInner + 0.030)
    /// True when the pads, not the logic, set the size of the die.
    let padLimited: Bool

    var area: Double { width * height }   // mm²
    var coreOrigin: SIMD2<Double> { SIMD2((width - coreWidth) / 2, (height - coreHeight) / 2) }

    init(silicon: Silicon) {
        coreWidth = Double(silicon.width) / 1000
        coreHeight = Double(silicon.height) / 1000

        // One pad per port bit, plus power and ground.
        let names = ["VDD", "VSS"] + silicon.pins.map(\.name)
        let perSide = Int((Double(names.count) / 4).rounded(.up))
        let minimum = Double(perSide) * DiePlan.padPitch + 0.24
        let w = max(coreWidth + DiePlan.ring * 2, minimum), h = max(coreHeight + DiePlan.ring * 2, minimum)
        width = w
        height = h
        padLimited = coreWidth + DiePlan.ring * 2 < minimum && coreHeight + DiePlan.ring * 2 < minimum

        // Pads run clockwise from the top-left corner.
        let inset = DiePlan.sealRing + 0.018 + DiePlan.padSize / 2
        var placed: [Pad] = []
        var sides: [Int] = []
        for (index, name) in names.enumerated() {
            let side = min(index / perSide, 3), slot = index % perSide
            let count = min(perSide, names.count - side * perSide)
            let along = (Double(slot) - Double(count - 1) / 2) * DiePlan.padPitch
            let center: SIMD2<Double>
            switch side {
            case 0: center = SIMD2(w / 2 + along, inset)
            case 1: center = SIMD2(w - inset, h / 2 + along)
            case 2: center = SIMD2(w / 2 - along, h - inset)
            default: center = SIMD2(inset, h / 2 - along)
            }
            placed.append(Pad(name: name, center: center))
            sides.append(side)
        }
        pads = placed

        // Each signal gets its own rectangular track around the core, so no two ever touch:
        // pad, straight in to its track, around to the top, then down to its pin.
        let origin = SIMD2((w - coreWidth) / 2, (h - coreHeight) / 2)
        let first = DiePlan.padInner + 0.050
        let room = min(origin.x, origin.y) - first - 0.008
        let pitch = min(max(room / Double(max(silicon.pins.count, 1)), 0.0004), 0.006)
        linkWidth = pitch * 0.5
        var made: [Link] = []
        for (k, pin) in silicon.pins.enumerated() {
            let d = first + (Double(k) + 0.5) * pitch
            let pad = placed[k + 2].center
            let end = SIMD2(origin.x + Double(pin.x) / 1000, d)
            var ring: [SIMD2<Double>]
            switch sides[k + 2] {
            case 0: ring = [SIMD2(pad.x, d)]
            case 1: ring = [SIMD2(w - d, pad.y), SIMD2(w - d, d)]
            case 2: ring = pad.x > w / 2 ? [SIMD2(pad.x, h - d), SIMD2(w - d, h - d), SIMD2(w - d, d)]
                                         : [SIMD2(pad.x, h - d), SIMD2(d, h - d), SIMD2(d, d)]
            default: ring = [SIMD2(d, pad.y), SIMD2(d, d)]
            }
            let foot = ring[0]
            ring.append(end)
            made.append(Link(ring: ring, stubs: [(pad, foot), (end, SIMD2(end.x, origin.y))]))
        }
        links = made
    }
}

/// How dies step across a round wafer.
struct WaferPlan {
    let diameter: Double        // mm
    let edge = 3.0              // unusable rim, mm
    let die: DiePlan
    let defects: Double         // per cm²

    var radius: Double { diameter / 2 }
    var pitch: SIMD2<Double> { SIMD2(die.width + DiePlan.scribe, die.height + DiePlan.scribe) }
    /// Small wafers have a flat edge; larger ones have a notch.
    var flatY: Double? { diameter <= 150 ? radius * 0.955 : nil }

    /// The chance a die has no killer defect (Poisson model).
    var yield: Double { exp(-die.area / 100 * defects) }

    /// Top-left corner of the die at a grid position. One die is centred on the wafer.
    func origin(_ i: Int, _ j: Int) -> SIMD2<Double> {
        SIMD2(Double(i) * pitch.x - die.width / 2, Double(j) * pitch.y - die.height / 2)
    }

    /// A die is usable only if all of it sits inside the edge exclusion.
    func isWhole(_ i: Int, _ j: Int) -> Bool {
        let o = origin(i, j)
        let far = SIMD2(max(abs(o.x), abs(o.x + die.width)), max(abs(o.y), abs(o.y + die.height)))
        if let flatY, o.y + die.height > flatY - edge { return false }
        return simd_length(far) <= radius - edge
    }

    /// Whether a random defect lands on this die. The same die always gets the same answer.
    func isGood(_ i: Int, _ j: Int) -> Bool {
        var h = UInt64(bitPattern: Int64(i &* 73_856_093 ^ j &* 19_349_663)) &+ 0x9E37_79B9_7F4A_7C15
        h ^= h >> 30; h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 27; h = h &* 0x94D0_49BB_1331_11EB
        h ^= h >> 31
        return Double(h >> 11) / Double(1 << 53) < yield
    }

    var span: (i: Int, j: Int) { (Int(radius / pitch.x) + 1, Int(radius / pitch.y) + 1) }

    func count() -> (whole: Int, good: Int) {
        var whole = 0, good = 0
        let n = span
        for j in -n.j...n.j {
            for i in -n.i...n.i where isWhole(i, j) {
                whole += 1
                if isGood(i, j) { good += 1 }
            }
        }
        return (whole, good)
    }
}

/// Layer colours for the silicon view, in the style of a layout viewer.
private enum Ink {
    static let substrate = Color(hex: 0x07080B)
    static let well = Color(hex: 0x141A22)
    static let diffusion = Color(hex: 0x35B45A)
    static let poly = Color(hex: 0xE2493B)
    static let local = Color(hex: 0xD9953A)       // local interconnect
    static let metal1 = Color(hex: 0x3F7BFF)
    static let metal2 = Color(hex: 0xE64BE0)
    static let metal3 = Color(hex: 0x27C7B8)
    static let metal4 = Color(hex: 0x8E55FF)
    static let metal5 = Color(hex: 0xE6B43C)
    static let pad = Color(hex: 0xC9CED6)

    /// A cell's colour when it is too small on screen to show what is inside it.
    static func flat(_ style: Silicon.Style) -> Color {
        switch style {
        case .logic: return Color(hex: 0xB9742C)
        case .flop: return Color(hex: 0xB4483A)
        case .clock: return Color(hex: 0x2A9FB0)
        case .buffer: return Color(hex: 0xC2A63A)
        case .decap: return Color(hex: 0x23683A)
        case .fill: return Color(hex: 0x10151B)
        case .tap: return Color(hex: 0x6A4A22)
        }
    }
}

/// The chip as it would leave the fab: stepped across a wafer, with scribe lanes, an edge
/// exclusion ring and an estimated yield map. Pinch in to reach one die, then its standard cells.
struct WaferView: View {
    @ObservedObject var model: AppModel
    @Environment(\.uiScale) private var ui
    @State private var zoom: CGFloat
    @State private var center: SIMD2<Float>

    init(model: AppModel, zoom: CGFloat = 1, center: SIMD2<Float> = .zero) {
        self.model = model
        _zoom = State(initialValue: zoom)
        _center = State(initialValue: center)
    }

    var body: some View {
        if let silicon = model.silicon {
            let plan = WaferPlan(diameter: Double(model.waferSize), die: DiePlan(silicon: silicon), defects: model.defectDensity)
            VStack(spacing: 10 * ui) {
                GeometryReader { geo in
                    let fit = min(geo.size.width, geo.size.height) / CGFloat(plan.diameter + 8)
                    let scale = fit * zoom
                    Canvas { context, size in
                        draw(&context, plan: plan, silicon: silicon, size: size, scale: scale)
                    }
                    .contentShape(Rectangle())
                    .modifier(PanZoom(zoom: $zoom, center: $center, scale: scale, maxZoom: 12000))
                    .onChange(of: model.fitToken) { withAnimation(.easeInOut(duration: 0.4)) { zoom = 1; center = .zero } }
                    .onChange(of: model.dieToken) {
                        // Fill most of the view with the centre die.
                        let target = min(geo.size.width / CGFloat(plan.die.width), geo.size.height / CGFloat(plan.die.height)) * 0.86
                        withAnimation(.easeInOut(duration: 0.6)) { zoom = max(target / fit, 1); center = .zero }
                    }
                    .onChange(of: model.coreToken) {
                        // Fill the view with the standard-cell core of the centre die.
                        let target = min(geo.size.width / CGFloat(plan.die.coreWidth), geo.size.height / CGFloat(plan.die.coreHeight)) * 0.94
                        withAnimation(.easeInOut(duration: 0.6)) { zoom = max(target / fit, 1); center = .zero }
                    }
                    .onChange(of: model.layoutVersion) { zoom = 1; center = .zero }
                }
                .clipped()
                controls(plan, silicon)
            }
        }
    }

    private func controls(_ plan: WaferPlan, _ silicon: Silicon) -> some View {
        let tally = plan.count()
        let outline = silicon.tile.map { "Tiny Tapeout \($0) tile" } ?? "custom outline"
        return VStack(alignment: .leading, spacing: 6 * ui) {
            Text(String(format: "Core %.0f × %.0f µm (%@) · %@ cells, %@ flip-flops · %.0f%% full · %.1f mm of wire",
                        silicon.width, silicon.height, outline, silicon.cellCount.formatted(), silicon.flopCount.formatted(),
                        silicon.utilization * 100, silicon.wireLength / 1000))
                .uiFont(13, design: .monospaced)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(format: "Die %.2f × %.2f mm%@ · %@ whole dies · est. yield %.1f%% · %@ good",
                        plan.die.width, plan.die.height, plan.die.padLimited ? " (set by its pads)" : "",
                        tally.whole.formatted(), plan.yield * 100, tally.good.formatted()))
                .uiFont(13, design: .monospaced)
                .foregroundStyle(Theme.dim)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8 * ui) {
                    PillButton(title: "Wafer", symbol: "circle") { model.fitToken += 1 }
                    PillButton(title: "Die", symbol: "square") { model.dieToken += 1 }
                    PillButton(title: "Cells", symbol: "square.grid.3x3") { model.coreToken += 1 }
                    Menu {
                        Picker("Wafer", selection: $model.waferSize) {
                            ForEach([100, 150, 200, 300], id: \.self) { Text("\($0) mm").tag($0) }
                        }
                    } label: {
                        Label("\(model.waferSize) mm", systemImage: "circle.dashed").waferChip()
                    }
                    Menu {
                        Picker("Defects", selection: $model.defectDensity) {
                            ForEach([0.1, 0.5, 2.0, 10.0, 50.0], id: \.self) { Text(String(format: "%g per cm²", $0)).tag($0) }
                        }
                    } label: {
                        Label(String(format: "%g defects/cm²", model.defectDensity), systemImage: "sparkle").waferChip()
                    }
                    Text("Estimates: 130 nm cells, 60 µm pads")
                        .uiFont(12)
                        .foregroundStyle(Theme.faint)
                        .fixedSize()
                }
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, plan: WaferPlan, silicon: Silicon, size: CGSize, scale: CGFloat) {
        func point(_ p: SIMD2<Double>) -> CGPoint {
            CGPoint(x: size.width / 2 + (CGFloat(p.x) - CGFloat(center.x)) * scale,
                    y: size.height / 2 + (CGFloat(p.y) - CGFloat(center.y)) * scale)
        }
        let middle = point(.zero)
        let r = CGFloat(plan.radius) * scale

        // The wafer: polished silicon with a soft sheen, and a flat or a notch for alignment.
        var disc = Path(ellipseIn: CGRect(x: middle.x - r, y: middle.y - r, width: r * 2, height: r * 2))
        if let flatY = plan.flatY {
            disc = disc.intersection(Path(CGRect(x: middle.x - r, y: middle.y - r, width: r * 2, height: r + CGFloat(flatY) * scale)))
        }
        if r < 40_000 {
            let sheen = Gradient(stops: [
                .init(color: Color(white: 0.30), location: 0), .init(color: Color(white: 0.52), location: 0.12),
                .init(color: Color(white: 0.26), location: 0.3), .init(color: Color(white: 0.40), location: 0.5),
                .init(color: Color(white: 0.58), location: 0.63), .init(color: Color(white: 0.28), location: 0.8),
                .init(color: Color(white: 0.30), location: 1),
            ])
            context.fill(disc, with: .conicGradient(sheen, center: middle, angle: .degrees(-35)))
            context.stroke(disc, with: .color(.white.opacity(0.5)), lineWidth: 1)
            if plan.flatY == nil {
                var notch = Path()
                notch.move(to: CGPoint(x: middle.x - r * 0.012, y: middle.y + r + 1))
                notch.addLine(to: CGPoint(x: middle.x, y: middle.y + r * 0.985))
                notch.addLine(to: CGPoint(x: middle.x + r * 0.012, y: middle.y + r + 1))
                context.fill(notch, with: .color(.black))
            }
            context.clip(to: disc)
        } else {
            // So far in that the wafer's edge is nowhere near the screen.
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.3)))
        }
        let usable = r - CGFloat(plan.edge) * scale
        if r < 40_000 {
            context.stroke(Path(ellipseIn: CGRect(x: middle.x - usable, y: middle.y - usable, width: usable * 2, height: usable * 2)),
                           with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }

        let diePx = CGSize(width: CGFloat(plan.die.width) * scale, height: CGFloat(plan.die.height) * scale)
        guard min(diePx.width, diePx.height) >= 2 else {
            // Too many dies to draw one by one at this zoom: show the patterned area as a whole.
            let grid = Path(ellipseIn: CGRect(x: middle.x - usable, y: middle.y - usable, width: usable * 2, height: usable * 2))
            context.fill(grid, with: .color(.black.opacity(0.28)))
            context.draw(Text("Pinch in to see individual dies").font(.system(size: 13 * ui, weight: .medium))
                .foregroundColor(.white.opacity(0.8)), at: middle)
            return
        }

        // Only the dies on screen are drawn.
        let pitch = plan.pitch
        let half = SIMD2(Double(size.width / scale), Double(size.height / scale)) / 2
        let c = SIMD2(Double(center.x), Double(center.y))
        let n = plan.span
        let iLow = max(-n.i, Int(((c.x - half.x) / pitch.x).rounded(.down)) - 1), iHigh = min(n.i, Int(((c.x + half.x) / pitch.x).rounded(.up)) + 1)
        let jLow = max(-n.j, Int(((c.y - half.y) / pitch.y).rounded(.down)) - 1), jHigh = min(n.j, Int(((c.y + half.y) / pitch.y).rounded(.up)) + 1)
        guard iLow <= iHigh, jLow <= jHigh else { return }

        let detailed = diePx.width > 70
        for j in jLow...jHigh {
            for i in iLow...iHigh {
                let corner = point(plan.origin(i, j))
                let frame = CGRect(x: corner.x, y: corner.y, width: diePx.width, height: diePx.height)
                let whole = plan.isWhole(i, j)
                let good = whole && plan.isGood(i, j)
                if !whole {
                    // Partial dies at the rim are printed but thrown away.
                    context.fill(Path(frame), with: .color(.black.opacity(0.22)))
                    continue
                }
                context.fill(Path(frame), with: .color(good ? Ink.substrate : Color(hex: 0x1A0908)))
                if !detailed {
                    if diePx.width > 9 {
                        // A hint of what is on each die: the pad ring and the core.
                        context.stroke(Path(frame.insetBy(dx: diePx.width * 0.06, dy: diePx.height * 0.06)),
                                       with: .color(Ink.pad.opacity(0.5)), lineWidth: max(diePx.width * 0.03, 0.5))
                        let core = CGSize(width: CGFloat(plan.die.coreWidth) * scale, height: CGFloat(plan.die.coreHeight) * scale)
                        context.fill(Path(CGRect(x: frame.midX - core.width / 2, y: frame.midY - core.height / 2, width: core.width, height: core.height)),
                                     with: .color(Ink.flat(.logic)))
                    }
                    if !good, diePx.width > 6 {
                        context.stroke(Path { $0.move(to: frame.origin); $0.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
                                              $0.move(to: CGPoint(x: frame.maxX, y: frame.minY)); $0.addLine(to: CGPoint(x: frame.minX, y: frame.maxY)) },
                                       with: .color(Theme.bad.opacity(0.9)), lineWidth: 1)
                    } else if !good {
                        context.fill(Path(frame), with: .color(Theme.bad.opacity(0.55)))
                    }
                    continue
                }
                drawDie(&context, plan: plan.die, silicon: silicon, frame: frame, scale: scale, good: good, size: size)
            }
        }
    }

    /// One die up close: seal ring, bond pads, power rings, pad wiring, and the core in the middle.
    private func drawDie(_ context: inout GraphicsContext, plan: DiePlan, silicon: Silicon, frame: CGRect, scale: CGFloat, good: Bool, size: CGSize) {
        func at(_ p: SIMD2<Double>) -> CGPoint { CGPoint(x: frame.minX + CGFloat(p.x) * scale, y: frame.minY + CGFloat(p.y) * scale) }
        let screen = CGRect(origin: .zero, size: size)
        let seal = frame.insetBy(dx: CGFloat(DiePlan.sealRing) * scale, dy: CGFloat(DiePlan.sealRing) * scale)
        context.stroke(Path(seal), with: .color(Ink.metal5.opacity(0.7)), lineWidth: max(1, CGFloat(DiePlan.sealRing) * scale * 0.5))

        let origin = at(plan.coreOrigin)
        let core = CGRect(x: origin.x, y: origin.y, width: CGFloat(plan.coreWidth) * scale, height: CGFloat(plan.coreHeight) * scale)
        let wiring = frame.width > 150

        if wiring {
            // Each signal's own track around the core, then the stubs that cross them.
            var rings = Path(), stubs = Path()
            for link in plan.links {
                rings.addLines(link.ring.map(at))
                for stub in link.stubs { stubs.move(to: at(stub.0)); stubs.addLine(to: at(stub.1)) }
            }
            let line = max(CGFloat(plan.linkWidth) * scale, 0.5)
            context.stroke(rings, with: .color(Ink.metal5.opacity(0.85)), style: StrokeStyle(lineWidth: line, lineJoin: .miter))
            let spacing = silicon.pins.count > 1 ? CGFloat(silicon.pins[1].x - silicon.pins[0].x) * scale / 1000 : line
            context.stroke(stubs, with: .color(Ink.metal3.opacity(0.9)), lineWidth: max(min(line, spacing * 0.3), 0.5))

            // Power and ground rings, fed from their pads.
            let power = max(0.012 * scale, 1)
            for (inset, pad) in [(plan.powerRings.vdd, plan.pads[0]), (plan.powerRings.vss, plan.pads[1])] {
                context.stroke(Path(frame.insetBy(dx: CGFloat(inset) * scale, dy: CGFloat(inset) * scale)), with: .color(Ink.metal5), lineWidth: power)
                context.stroke(Path { $0.move(to: at(pad.center)); $0.addLine(to: at(SIMD2(pad.center.x, inset))) },
                               with: .color(Ink.metal4), lineWidth: power)
            }
        }

        // Bond pads.
        let padPx = CGFloat(DiePlan.padSize) * scale
        for pad in plan.pads {
            let p = at(pad.center)
            let box = CGRect(x: p.x - padPx / 2, y: p.y - padPx / 2, width: padPx, height: padPx)
            guard box.intersects(screen) else { continue }
            context.fill(Path(roundedRect: box, cornerRadius: padPx * 0.06), with: .color(Ink.pad))
            context.stroke(Path(box.insetBy(dx: padPx * 0.1, dy: padPx * 0.1)), with: .color(Ink.metal5.opacity(0.9)), lineWidth: max(padPx * 0.03, 0.5))
            if padPx > 26 {
                context.draw(Text(pad.name).font(.system(size: min(padPx * 0.2, 11), weight: .medium, design: .monospaced))
                    .foregroundColor(.black.opacity(0.8)), at: p)
            }
        }

        drawCore(&context, silicon: silicon, core: core, unit: scale / 1000, screen: screen)

        if wiring {
            // Vertical power straps run from ring to ring, straight over the core.
            let topY = frame.minY + CGFloat(plan.powerRings.vdd) * scale, bottomY = frame.maxY - CGFloat(plan.powerRings.vdd) * scale
            let step = CGFloat(Silicon.strapPitch) * scale / 1000, thick = max(CGFloat(Silicon.strapWidth) * scale / 1000, 0.6)
            let phase = CGFloat(silicon.straps.first ?? 0) * scale / 1000
            let leftX = frame.minX + CGFloat(plan.powerRings.vss + 0.02) * scale, rightX = frame.maxX - CGFloat(plan.powerRings.vss + 0.02) * scale
            var straps = Path()
            var k = ((leftX - core.minX - phase) / step).rounded(.up)
            while core.minX + phase + k * step < rightX {
                let x = core.minX + phase + k * step
                if x + thick > 0, x - thick < size.width { straps.addRect(CGRect(x: x - thick / 2, y: topY, width: thick, height: bottomY - topY)) }
                k += 1
            }
            context.fill(straps, with: .color(Ink.metal4.opacity(step > 6 ? 0.5 : 0.3)))
        }

        if !good {
            context.fill(Path(frame), with: .color(Theme.bad.opacity(0.14)))
            context.stroke(Path(frame.insetBy(dx: 1, dy: 1)), with: .color(Theme.bad), lineWidth: 2)
        }
    }

    /// The standard-cell core. `unit` is points per µm; more is drawn as it grows.
    private func drawCore(_ context: inout GraphicsContext, silicon: Silicon, core: CGRect, unit: CGFloat, screen: CGRect) {
        guard core.intersects(screen) else { return }
        context.fill(Path(core), with: .color(Ink.well))
        guard core.width > 36 else {
            context.fill(Path(core.insetBy(dx: core.width * 0.2, dy: core.height * 0.2)), with: .color(Ink.flat(.logic)))
            return
        }
        let site = CGFloat(Silicon.site) * unit, rowHeight = CGFloat(Silicon.rowHeight) * unit
        let inside = rowHeight >= 9                 // enough room to show what is in each cell
        let firstRow = max(Int(((screen.minY - core.minY) / rowHeight - CGFloat(silicon.top / Silicon.rowHeight)).rounded(.down)), 0)
        let lastRow = min(Int(((screen.maxY - core.minY) / rowHeight - CGFloat(silicon.top / Silicon.rowHeight)).rounded(.up)), silicon.rows.count - 1)

        var flat: [Silicon.Style: Path] = [:]
        var diffusion = Path(), poly = Path(), local = Path(), metal1 = Path()
        if firstRow <= lastRow {
            for r in firstRow...lastRow {
                let y = core.minY + CGFloat(silicon.top) * unit + CGFloat(r) * rowHeight
                // Rows alternate upside down so neighbours share a power rail.
                func band(_ from: CGFloat, _ to: CGFloat) -> (CGFloat, CGFloat) {
                    r % 2 == 0 ? (y + from * rowHeight, (to - from) * rowHeight) : (y + (1 - to) * rowHeight, (to - from) * rowHeight)
                }
                for cell in silicon.rows[r] {
                    let x = core.minX + CGFloat(cell.site) * site, w = CGFloat(cell.sites) * site
                    guard x + w > screen.minX, x < screen.maxX else { continue }
                    guard inside else {
                        if cell.style != .fill { flat[cell.style, default: Path()].addRect(CGRect(x: x, y: y + rowHeight * 0.08, width: max(w - 0.3, 0.4), height: rowHeight * 0.84)) }
                        continue
                    }
                    let edge = site * 0.3
                    switch cell.style {
                    case .fill:
                        break
                    case .tap:
                        let (ty, th) = band(0.1, 0.9)
                        local.addRect(CGRect(x: x + site * 0.25, y: ty, width: site * 0.5, height: th))
                    case .decap:
                        for (from, to) in [(0.1, 0.42), (0.58, 0.9)] as [(CGFloat, CGFloat)] {
                            let (dy, dh) = band(from, to)
                            diffusion.addRect(CGRect(x: x + edge, y: dy, width: w - edge * 2, height: dh))
                        }
                        let (py, ph) = band(0.33, 0.67)
                        poly.addRect(CGRect(x: x + edge * 1.6, y: py, width: max(w - edge * 3.2, site * 0.3), height: ph))
                    default:
                        // Transistors: p-type on the well side, n-type on the other, gates running across both.
                        let (pY, pH) = band(0.1, 0.42), (nY, nH) = band(0.62, 0.9)
                        diffusion.addRect(CGRect(x: x + edge, y: pY, width: w - edge * 2, height: pH))
                        diffusion.addRect(CGRect(x: x + edge, y: nY, width: w - edge * 2, height: nH))
                        let (gY, gH) = band(0.05, 0.95)
                        for k in 1..<max(cell.sites, 2) {
                            poly.addRect(CGRect(x: x + CGFloat(k) * site - site * 0.16, y: gY, width: site * 0.32, height: gH))
                            if (k + cell.site) % 2 == 0 {
                                local.addRect(CGRect(x: x + (CGFloat(k) + 0.5) * site - site * 0.17, y: pY + pH * 0.15, width: site * 0.34, height: pH * 0.7))
                            } else {
                                local.addRect(CGRect(x: x + (CGFloat(k) + 0.5) * site - site * 0.17, y: nY + nH * 0.15, width: site * 0.34, height: nH * 0.7))
                            }
                        }
                        // The cell's own metal: one strap for simple gates, two for flip-flops and buffers.
                        let (mY, mH) = band(0.47, 0.56)
                        metal1.addRect(CGRect(x: x + site, y: mY, width: max(w - site * 2, site * 0.5), height: mH))
                        if cell.style != .logic {
                            let (m2Y, m2H) = band(0.26, 0.33)
                            metal1.addRect(CGRect(x: x + site * 1.5, y: m2Y, width: max(w - site * 4, site * 0.5), height: m2H))
                        }
                    }
                }
            }
        }
        if inside {
            context.fill(diffusion, with: .color(Ink.diffusion))
            context.fill(poly, with: .color(Ink.poly.opacity(0.92)))
            context.fill(local, with: .color(Ink.local))
        } else {
            for style in [Silicon.Style.decap, .tap, .logic, .flop, .buffer, .clock] {
                if let path = flat[style] { context.fill(path, with: .color(Ink.flat(style))) }
            }
        }

        // Power rails on metal 1, shared between each pair of rows.
        if rowHeight >= 3, firstRow <= lastRow {
            let rail = CGFloat(0.48) * unit
            for r in firstRow...(lastRow + 1) {
                let y = core.minY + CGFloat(silicon.top) * unit + CGFloat(r) * rowHeight
                metal1.addRect(CGRect(x: max(core.minX, screen.minX - 2), y: y - rail / 2, width: min(core.maxX, screen.maxX + 2) - max(core.minX, screen.minX - 2), height: rail))
            }
        }
        context.fill(metal1, with: .color(Ink.metal1.opacity(0.9)))

        // Signal routing, culled to what is on screen.
        let visible = screen.insetBy(dx: -4, dy: -4)
        var layers = [Path(), Path(), Path()]
        for route in silicon.routes {
            let a = CGPoint(x: core.minX + CGFloat(route.a.x) * unit, y: core.minY + CGFloat(route.a.y) * unit)
            let b = CGPoint(x: core.minX + CGFloat(route.b.x) * unit, y: core.minY + CGFloat(route.b.y) * unit)
            guard max(a.x, b.x) >= visible.minX, min(a.x, b.x) <= visible.maxX, max(a.y, b.y) >= visible.minY, min(a.y, b.y) <= visible.maxY else { continue }
            layers[route.layer - 1].move(to: a)
            layers[route.layer - 1].addLine(to: b)
        }
        // Up close the upper metal turns translucent, so the transistors under it stay visible.
        let fine = StrokeStyle(lineWidth: max(0.14 * unit, 0.55), lineCap: .square)
        let see: Double = inside ? 0.6 : 1
        context.stroke(layers[0], with: .color(Ink.metal1.opacity(0.95)), style: fine)
        context.stroke(layers[2], with: .color(Ink.metal3.opacity(0.75 * see)), style: StrokeStyle(lineWidth: max(0.2 * unit, 0.6), lineCap: .square))
        context.stroke(layers[1], with: .color(Ink.metal2.opacity(0.9 * see)), style: fine)

        // Pins on the top edge.
        if unit > 1 {
            var marks = Path()
            let spacing = silicon.pins.count > 1 ? CGFloat(silicon.pins[1].x - silicon.pins[0].x) * unit : 100
            for pin in silicon.pins {
                let x = core.minX + CGFloat(pin.x) * unit
                guard x > screen.minX - 20, x < screen.maxX + 20 else { continue }
                marks.addRect(CGRect(x: x - 0.22 * unit, y: core.minY - 0.4 * unit, width: 0.44 * unit, height: 1.6 * unit))
                if spacing > 9 {
                    var turned = context
                    turned.translateBy(x: x, y: core.minY - 0.8 * unit - 2)
                    turned.rotate(by: .degrees(-90))
                    turned.draw(Text(pin.name).font(.system(size: min(spacing * 0.7, 10), design: .monospaced)).foregroundColor(.white.opacity(0.85)),
                                at: .zero, anchor: .leading)
                }
            }
            context.fill(marks, with: .color(Ink.metal3))
        }
        context.stroke(Path(core), with: .color(.white.opacity(0.35)), lineWidth: 1)
    }
}

private extension View {
    func waferChip() -> some View {
        self.uiFont(13, weight: .medium)
            .foregroundStyle(Theme.text)
            .fixedSize()
            .uiPadding(.horizontal, 12)
            .uiFrame(height: 38)
            .background(Theme.raised, in: Capsule())
            .contentShape(Capsule())
    }
}
