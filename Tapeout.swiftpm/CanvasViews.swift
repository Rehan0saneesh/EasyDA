import SwiftUI
import simd

/// Maps layout coordinates (die centred on the origin) to view points.
struct Viewport {
    let size: CGSize
    let scale: CGFloat
    let center: SIMD2<Float>

    init(layout: ChipLayout, size: CGSize, zoom: CGFloat = 1, center: SIMD2<Float> = .zero, margin: Float = 0.5) {
        self.size = size
        self.center = center
        let fit = min(size.width / CGFloat(layout.dieW + margin * 2), size.height / CGFloat(layout.dieD + margin * 2))
        scale = max(fit, 2) * zoom
    }

    func point(_ p: SIMD2<Float>) -> CGPoint {
        CGPoint(x: size.width / 2 + CGFloat(p.x - center.x) * scale, y: size.height / 2 + CGFloat(p.y - center.y) * scale)
    }

    func rect(_ lower: SIMD2<Float>, _ upper: SIMD2<Float>) -> CGRect {
        let a = point(lower), b = point(upper)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    func layoutPoint(_ p: CGPoint) -> SIMD2<Float> {
        SIMD2(Float((p.x - size.width / 2) / scale) + center.x, Float((p.y - size.height / 2) / scale) + center.y)
    }
}

/// Pan and pinch state shared by the schematic and layout canvases.
struct PanZoom: ViewModifier {
    @Binding var zoom: CGFloat
    @Binding var center: SIMD2<Float>
    let scale: CGFloat
    var maxZoom: CGFloat = 40
    @State private var zoomAtPinch: CGFloat?
    @State private var centerAtDrag: SIMD2<Float>?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag in
                        let start = centerAtDrag ?? center
                        centerAtDrag = start
                        center = start - SIMD2(Float(drag.translation.width / scale), Float(drag.translation.height / scale))
                    }
                    .onEnded { _ in centerAtDrag = nil }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { amount in
                        let start = zoomAtPinch ?? zoom
                        zoomAtPinch = start
                        zoom = min(max(start * amount, 0.6), maxZoom)
                    }
                    .onEnded { _ in zoomAtPinch = nil }
            )
    }
}

private func isOn(_ signal: Signal, _ values: [Signal: UInt64]) -> Bool {
    if case .const(let c) = signal { return c != 0 }
    return (values[signal] ?? 0) != 0
}

// MARK: - Schematic

/// The elaborated schematic: logic gates, arithmetic blocks, registers and memory.
/// Tap a cell or pin to isolate its cone of influence. Drag to pan, pinch to zoom.
struct SchematicView: View {
    @ObservedObject var model: AppModel
    @State private var zoom: CGFloat = 1
    @State private var center = SIMD2<Float>(0, 0)

    var body: some View {
        GeometryReader { geo in
            if let layout = model.layout, let netlist = model.netlist {
                let viewport = Viewport(layout: layout, size: geo.size, zoom: zoom, center: center, margin: 0.8)
                Canvas { context, _ in
                    draw(&context, layout: layout, netlist: netlist, viewport: viewport)
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    let p = viewport.layoutPoint(tap.location)
                    if let signal = layout.cells.first(where: { $0.contains(p, slack: 0.08) })?.signal {
                        model.select(signal)
                    } else if let pad = layout.pads.first(where: { simd_distance(p, $0.center) < 0.5 }), !pad.isClock {
                        model.select(pad.signal)
                    } else {
                        model.select(nil)
                    }
                })
                .modifier(PanZoom(zoom: $zoom, center: $center, scale: viewport.scale))
                .onChange(of: model.fitToken) { zoom = 1; center = .zero }
                .onChange(of: model.layoutVersion) { zoom = 1; center = .zero }
            }
        }
        .clipped()
    }

    private func draw(_ context: inout GraphicsContext, layout: ChipLayout, netlist: Netlist, viewport: Viewport) {
        let values = model.signals
        let highlight = model.highlight
        let detail = viewport.scale > 16
        func strength(_ s: Signal?) -> Double {
            guard let highlight else { return 1 }
            return s.map { highlight.contains($0) ? 1 : 0.12 } ?? 0.12
        }
        func ink(_ s: Signal) -> Color { .white.opacity((isOn(s, values) ? 0.95 : 0.42) * strength(s)) }

        for wire in layout.wires {
            var end = wire.b
            // Run input wires a little way into the cell so they meet curved backs cleanly.
            if wire.isHorizontal, layout.cells.contains(where: {
                abs(end.x - $0.lower.x) < 0.001 && end.y > $0.lower.y && end.y < $0.upper.y
            }) { end.x += 0.16 }
            let width: CGFloat = wire.bits > 1 ? 3 : (isOn(wire.net, values) ? 2 : 1.5)
            context.stroke(Path { $0.move(to: viewport.point(wire.a)); $0.addLine(to: viewport.point(end)) },
                           with: .color(ink(wire.net)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }

        let fill = Color(hex: 0x141414)
        for cell in layout.cells {
            let frame = viewport.rect(cell.lower, cell.upper)
            let selected = cell.signal != nil && model.selected == cell.signal
            let alpha = strength(cell.signal)
            let stroke = cell.signal.map(ink) ?? .white.opacity(0.6 * alpha)
            let line: CGFloat = selected ? 3 : 1.75
            let (body, accents) = GateSymbol.paths(cell.kind, in: frame)
            context.fill(body, with: .color(fill))
            context.stroke(body, with: .color(stroke), style: StrokeStyle(lineWidth: line, lineJoin: .round))
            context.fill(accents.bubble, with: .color(fill))
            context.stroke(accents.bubble, with: .color(stroke), lineWidth: line)
            context.stroke(accents.line, with: .color(stroke), lineWidth: line)

            guard detail else { continue }
            if let glyph = GateSymbol.glyph(cell.kind, label: cell.label) {
                context.draw(Text(glyph).font(.system(size: max(min(viewport.scale * 0.2, 15), 7), weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8 * alpha)), at: CGPoint(x: frame.midX, y: frame.midY))
            }
            if let signal = cell.signal {
                context.draw(Text(netlist.label(signal)).font(.system(size: max(min(viewport.scale * 0.17, 13), 7), design: .monospaced))
                    .foregroundColor(.white.opacity(0.5 * alpha)), at: CGPoint(x: frame.midX, y: frame.maxY + 3), anchor: .top)
            }
            // Constants wired straight into a pin.
            for pin in cell.pins {
                guard case .const(let c) = pin.signal else { continue }
                let at = viewport.point(pin.at)
                context.draw(Text(c > 9 ? String(c, radix: 16, uppercase: true) + "h" : String(c))
                    .font(.system(size: max(min(viewport.scale * 0.15, 11), 6), design: .monospaced))
                    .foregroundColor(.white.opacity(0.45 * alpha)), at: CGPoint(x: at.x - 4, y: at.y), anchor: .trailing)
            }
        }

        for pad in layout.pads {
            let on = isOn(pad.signal, values) && !pad.isClock
            let half = SIMD2<Float>(ChipLayout.padSize / 2, 0.2)
            let frame = viewport.rect(pad.center - half, pad.center + half)
            let shape = Path(roundedRect: frame, cornerRadius: 5)
            let alpha = pad.isClock ? (highlight == nil ? 1 : 0.12) : strength(pad.signal)
            context.fill(shape, with: .color(on ? .white.opacity(0.95 * alpha) : fill))
            context.stroke(shape, with: .color(.white.opacity((on ? 0.95 : 0.5) * alpha)),
                           lineWidth: model.selected == pad.signal && !pad.isClock ? 3 : 1.5)
            guard detail else { continue }
            let text = pad.bits > 1 ? "\(pad.name)[\(pad.bits)]" : pad.name
            if pad.bits > 1 || pad.name.count > 4 {
                // Long names sit outside the pin so they stay readable.
                let side: CGFloat = pad.isInput ? frame.minX - 5 : frame.maxX + 5
                context.draw(Text(text).font(.system(size: max(min(viewport.scale * 0.18, 13), 7), weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8 * alpha)), at: CGPoint(x: side, y: frame.midY),
                             anchor: pad.isInput ? .trailing : .leading)
            } else {
                context.draw(Text(text).font(.system(size: max(min(viewport.scale * 0.2, 14), 7), weight: .medium, design: .monospaced))
                    .foregroundColor(on ? .black : .white.opacity(0.85 * alpha)), at: CGPoint(x: frame.midX, y: frame.midY))
            }
        }
    }
}

/// Standard logic-gate outlines, with plain boxes for larger blocks.
enum GateSymbol {
    /// The text drawn inside a block that has no classic shape.
    static func glyph(_ kind: GateKind?, label: String) -> String? {
        guard let kind else { return label }
        switch kind {
        case .and, .or, .xor, .nand, .nor, .xnor, .not, .buf: return nil
        case .add: return "+"
        case .sub: return "−"
        case .mul: return "×"
        case .div: return "÷"
        case .mod: return "%"
        case .eq: return "="
        case .ne: return "≠"
        case .lt: return "<"
        case .le: return "≤"
        case .gt: return ">"
        case .ge: return "≥"
        case .shl: return "<<"
        case .shr: return ">>"
        default: return label
        }
    }

    static func paths(_ kind: GateKind?, in frame: CGRect) -> (body: Path, accents: (bubble: Path, line: Path)) {
        var body = Path()
        var line = Path()
        var bubble = Path()
        guard let kind else {
            body.addRoundedRect(in: frame, cornerSize: CGSize(width: 5, height: 5))
            return (body, (bubble, line))
        }
        let inverted = [GateKind.not, .nand, .nor, .xnor].contains(kind)
        let r = min(frame.height, frame.width) * 0.1                // bubble radius
        var b = frame.insetBy(dx: 0, dy: min(frame.height * 0.06, 4))
        if inverted { b.size.width -= r * 2 }

        func orShape(_ left: CGFloat) {
            body.move(to: CGPoint(x: left, y: b.minY))
            body.addQuadCurve(to: CGPoint(x: b.maxX, y: b.midY), control: CGPoint(x: left + (b.maxX - left) * 0.72, y: b.minY))
            body.addQuadCurve(to: CGPoint(x: left, y: b.maxY), control: CGPoint(x: left + (b.maxX - left) * 0.72, y: b.maxY))
            body.addQuadCurve(to: CGPoint(x: left, y: b.minY), control: CGPoint(x: left + b.width * 0.2, y: b.midY))
        }

        switch kind {
        case .and, .nand:
            let radius = min(b.height / 2, b.width * 0.5)
            let arcX = b.maxX - radius
            body.move(to: CGPoint(x: b.minX, y: b.minY))
            body.addLine(to: CGPoint(x: arcX, y: b.minY))
            body.addQuadCurve(to: CGPoint(x: b.maxX, y: b.midY), control: CGPoint(x: b.maxX, y: b.minY))
            body.addQuadCurve(to: CGPoint(x: arcX, y: b.maxY), control: CGPoint(x: b.maxX, y: b.maxY))
            body.addLine(to: CGPoint(x: b.minX, y: b.maxY))
            body.closeSubpath()
        case .or, .nor:
            orShape(b.minX)
        case .xor, .xnor:
            orShape(b.minX + b.width * 0.1)
            line.move(to: CGPoint(x: b.minX, y: b.minY))
            line.addQuadCurve(to: CGPoint(x: b.minX, y: b.maxY), control: CGPoint(x: b.minX + b.width * 0.2, y: b.midY))
        case .not, .buf:
            body.move(to: CGPoint(x: b.minX + b.width * 0.12, y: b.minY))
            body.addLine(to: CGPoint(x: b.maxX, y: b.midY))
            body.addLine(to: CGPoint(x: b.minX + b.width * 0.12, y: b.maxY))
            body.closeSubpath()
            line.move(to: CGPoint(x: b.minX, y: b.midY))
            line.addLine(to: CGPoint(x: b.minX + b.width * 0.12, y: b.midY))
        case .mux:
            let slant = min(b.height * 0.22, 14)
            body.move(to: CGPoint(x: b.minX, y: b.minY))
            body.addLine(to: CGPoint(x: b.maxX, y: b.minY + slant))
            body.addLine(to: CGPoint(x: b.maxX, y: b.maxY - slant))
            body.addLine(to: CGPoint(x: b.minX, y: b.maxY))
            body.closeSubpath()
        case .dff:
            body.addRect(b)
            // The clock input is marked with a small triangle.
            line.move(to: CGPoint(x: b.minX, y: b.maxY - b.height * 0.32))
            line.addLine(to: CGPoint(x: b.minX + b.width * 0.14, y: b.maxY - b.height * 0.2))
            line.addLine(to: CGPoint(x: b.minX, y: b.maxY - b.height * 0.08))
        default:
            body.addRoundedRect(in: b, cornerSize: CGSize(width: 5, height: 5))
        }
        if inverted {
            bubble.addEllipse(in: CGRect(x: b.maxX, y: b.midY - r, width: r * 2, height: r * 2))
        }
        return (body, (bubble, line))
    }
}

struct SchematicControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let selected = model.selected, let netlist = model.netlist {
                Text("Tracing \(netlist.label(selected))")
                    .uiFont(13, weight: .medium, design: .monospaced)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Segmented(selection: $model.coneMode)
                PillButton(title: "Clear") { model.select(nil) }
            } else {
                Text("Tap a cell or pin to trace its cone of influence")
                    .uiFont(13)
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
            PillButton(title: "Fit", symbol: "arrow.up.left.and.arrow.down.right") { model.fitToken += 1 }
        }
    }
}

// MARK: - Layout

/// The physical layout, top down. Drag to pan, pinch to zoom, toggle layers and overlays,
/// and measure with the ruler.
struct LayoutView: View {
    @ObservedObject var model: AppModel
    @State private var zoom: CGFloat = 1
    @State private var center = SIMD2<Float>(0, 0)
    @State private var ruler: [SIMD2<Float>] = []

    var body: some View {
        GeometryReader { geo in
            if let layout = model.layout {
                let viewport = Viewport(layout: layout, size: geo.size, zoom: zoom, center: center)
                Canvas { context, _ in
                    draw(&context, layout: layout, viewport: viewport)
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap(at: viewport.layoutPoint($0.location), layout: layout) })
                .modifier(PanZoom(zoom: $zoom, center: $center, scale: viewport.scale))
                .onAppear { follow(model.focus, layout: layout, size: geo.size) }
                .onChange(of: model.focus) { follow(model.focus, layout: layout, size: geo.size) }
                .onChange(of: model.fitToken) { zoom = 1; center = .zero }
                .onChange(of: model.layoutVersion) { ruler = [] }
                .onChange(of: model.rulerOn) { ruler = [] }
            }
        }
        .clipped()
    }

    private func follow(_ focus: LayoutFocus?, layout: ChipLayout, size: CGSize) {
        guard let focus else { return }
        let fit = Viewport(layout: layout, size: size).scale
        withAnimation(.easeInOut(duration: 0.35)) {
            center = focus.center
            // Show the spot at roughly 150 points per unit, whatever the size of the die.
            zoom = min(max(min(size.width, size.height) / (CGFloat(focus.span) * 4.5) / fit, 1), 40)
        }
    }

    private func tap(at p: SIMD2<Float>, layout: ChipLayout) {
        if model.rulerOn {
            if ruler.count == 2 { ruler = [] }
            ruler.append(snap(p, layout: layout))
            if ruler.count == 2 { model.note("layout.ruler") }
            return
        }
        model.select(layout.cells.first { $0.contains(p) }?.signal)
    }

    /// Snaps each coordinate to the nearest shape edge, if one is close.
    private func snap(_ p: SIMD2<Float>, layout: ChipLayout) -> SIMD2<Float> {
        var xs: [Float] = [], ys: [Float] = []
        for wire in layout.wires where !model.hiddenLayers.contains(Layer.metal(wire.layer)) {
            guard simd_distance(simd_clamp(p, wire.lower, wire.upper), p) < 0.5 else { continue }
            xs += [wire.lower.x, wire.upper.x]
            ys += [wire.lower.y, wire.upper.y]
        }
        for cell in layout.cells where cell.contains(p, slack: 0.5) {
            xs += [cell.lower.x, cell.upper.x]
            ys += [cell.lower.y, cell.upper.y]
        }
        func nearest(_ v: Float, _ candidates: [Float]) -> Float {
            guard let best = candidates.min(by: { abs($0 - v) < abs($1 - v) }), abs(best - v) < 0.09 else { return v }
            return best
        }
        return SIMD2(nearest(p.x, xs), nearest(p.y, ys))
    }

    private func draw(_ context: inout GraphicsContext, layout: ChipLayout, viewport: Viewport) {
        let hidden = model.hiddenLayers
        let highlight = model.highlight
        func strength(_ s: Signal?) -> Double {
            guard let highlight else { return 1 }
            return s.map { highlight.contains($0) ? 1 : 0.14 } ?? 0.14
        }

        let die = SIMD2(layout.dieW, layout.dieD) / 2
        let dieRect = viewport.rect(-die, die)
        context.fill(Path(dieRect), with: .color(Color(hex: 0x0B0B0B)))
        context.stroke(Path(dieRect), with: .color(.white.opacity(0.22)), lineWidth: 1)

        if model.overlay == .congestion {
            let grid = layout.congestion()
            let size = SIMD2(repeating: ChipLayout.binSize)
            for r in 0..<grid.rows {
                for c in 0..<grid.columns {
                    let use = grid.utilization(c, r)
                    guard use > 0.02 else { continue }
                    let lower = grid.origin + SIMD2(Float(c), Float(r)) * size
                    let bin = viewport.rect(lower, lower + size).insetBy(dx: 0.5, dy: 0.5)
                    context.fill(Path(bin), with: .color(.white.opacity(Double(min(use, 1)) * 0.5)))
                    if use > 1 { context.stroke(Path(bin), with: .color(Theme.bad), lineWidth: 1.5) }
                }
            }
        }

        if !hidden.contains(.cells) {
            let busiest = max(model.activity.values.max() ?? 1, 1)
            for cell in layout.cells {
                let frame = viewport.rect(cell.lower, cell.upper)
                var fill = 0.07
                if model.overlay == .activity, let signal = cell.signal {
                    fill = 0.04 + 0.7 * Double(model.activity[signal] ?? 0) / Double(busiest)
                }
                let alpha = strength(cell.signal)
                let selected = cell.signal != nil && model.selected == cell.signal
                context.fill(Path(frame), with: .color(.white.opacity(fill * alpha)))
                context.stroke(Path(frame), with: .color(.white.opacity((selected ? 1 : 0.45) * alpha)), lineWidth: selected ? 2.5 : 1)
                if viewport.scale > 30 {
                    context.draw(Text(cell.label).font(.system(size: min(viewport.scale * 0.16, 14), weight: .semibold))
                        .foregroundColor(.white.opacity(0.6 * alpha)), at: CGPoint(x: frame.midX, y: frame.midY))
                }
            }
            let padHalf = SIMD2(repeating: ChipLayout.padSize / 2)
            for pad in layout.pads {
                let frame = viewport.rect(pad.center - padHalf, pad.center + padHalf)
                let alpha = pad.isClock ? (highlight == nil ? 1 : 0.14) : strength(pad.signal)
                context.fill(Path(frame), with: .color(.white.opacity(0.1 * alpha)))
                context.stroke(Path(frame), with: .color(.white.opacity(0.6 * alpha)), lineWidth: 1)
                if viewport.scale > 30 {
                    context.draw(Text(pad.name).font(.system(size: min(viewport.scale * 0.17, 13), design: .monospaced))
                        .foregroundColor(.white.opacity(0.75 * alpha)),
                                 at: CGPoint(x: frame.midX, y: frame.minY - 3), anchor: .bottom)
                }
            }
        }

        // Metal, bottom layer first.
        for layer in 1...4 where !hidden.contains(Layer.metal(layer)) {
            for wire in layout.wires where wire.layer == layer {
                let shape = Path(viewport.rect(wire.lower, wire.upper))
                let alpha = strength(wire.net)
                switch layer {
                case 1: context.fill(shape, with: .color(.white.opacity(0.88 * alpha)))
                case 2: context.fill(shape, with: .color(.white.opacity(0.46 * alpha)))
                case 3:
                    context.fill(shape, with: .color(.black.opacity(0.75)))
                    context.stroke(shape, with: .color(.white.opacity(0.95 * alpha)), lineWidth: 1)
                default:
                    context.fill(shape, with: .color(.white.opacity(0.2 * alpha)))
                    context.stroke(shape, with: .color(.white.opacity(0.7 * alpha)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
        if !hidden.contains(.vias) {
            let half = SIMD2<Float>(repeating: 0.055)
            for via in layout.vias {
                let frame = viewport.rect(via.at - half, via.at + half)
                context.fill(Path(frame), with: .color(.white.opacity(strength(via.net))))
                context.stroke(Path(frame), with: .color(.black), lineWidth: 0.5)
            }
        }

        // Design-rule markers.
        for check in model.checks where check.isRule {
            let pad = SIMD2<Float>(repeating: 0.07)
            let frame = viewport.rect(check.lower - pad, check.upper + pad)
            context.fill(Path(frame), with: .color(Theme.bad.opacity(0.22)))
            context.stroke(Path(frame), with: .color(Theme.bad), lineWidth: 1.5)
            context.draw(Text("\(check.id + 1)").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.bad),
                         at: CGPoint(x: frame.minX - 4, y: frame.minY), anchor: .topTrailing)
        }

        // Ruler.
        for p in ruler {
            let at = viewport.point(p)
            context.stroke(Path { $0.move(to: CGPoint(x: at.x - 7, y: at.y)); $0.addLine(to: CGPoint(x: at.x + 7, y: at.y))
                                  $0.move(to: CGPoint(x: at.x, y: at.y - 7)); $0.addLine(to: CGPoint(x: at.x, y: at.y + 7)) },
                           with: .color(.white), lineWidth: 1.5)
        }
        if ruler.count == 2 {
            let (a, b) = (viewport.point(ruler[0]), viewport.point(ruler[1]))
            context.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, with: .color(.white),
                           style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            let delta = simd_abs(ruler[1] - ruler[0])
            let text = String(format: "%.3f   (Δx %.3f, Δy %.3f)", simd_length(delta), delta.x, delta.y)
            let label = context.resolve(Text(text).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(.black))
            let size = label.measure(in: CGSize(width: 400, height: 40))
            let mid = CGPoint(x: (a.x + b.x) / 2, y: min(a.y, b.y) - 18)
            context.fill(Path(roundedRect: CGRect(x: mid.x - size.width / 2 - 8, y: mid.y - size.height / 2 - 4,
                                                  width: size.width + 16, height: size.height + 8), cornerRadius: 7),
                         with: .color(.white))
            context.draw(label, at: mid)
        }
    }
}

struct LayoutControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Layer.allCases, id: \.self) { layer in
                    let visible = !model.hiddenLayers.contains(layer)
                    Button {
                        if visible { model.hiddenLayers.insert(layer) } else { model.hiddenLayers.remove(layer) }
                    } label: {
                        HStack(spacing: 6) {
                            swatch(layer).opacity(visible ? 1 : 0.3)
                            Text(layer.rawValue)
                        }
                        .chip(active: false)
                        .opacity(visible ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(layer.rawValue) layer")
                    .accessibilityValue(visible ? "shown" : "hidden")
                }
                Rectangle().fill(Theme.stroke).uiFrame(width: 1, height: 22)
                Menu {
                    Picker("Overlay", selection: $model.overlay) {
                        ForEach(Overlay.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label(model.overlay == .none ? "Overlay" : model.overlay.rawValue, systemImage: "square.3.layers.3d")
                        .chip(active: model.overlay != .none)
                }
                Button {
                    model.rulerOn.toggle()
                } label: {
                    Label("Ruler", systemImage: "ruler").chip(active: model.rulerOn)
                }
                .buttonStyle(.plain)
                Menu {
                    Picker("Floorplan", selection: $model.density) {
                        ForEach(Density.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Label("Floorplan: \(model.density.rawValue)", systemImage: "rectangle.expand.vertical").chip(active: false)
                }
                Button {
                    model.fitToken += 1
                } label: {
                    Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right").chip(active: false)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A sample of how each layer is drawn.
    @ViewBuilder
    private func swatch(_ layer: Layer) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        switch layer {
        case .cells: shape.strokeBorder(Color.white.opacity(0.5)).uiFrame(width: 12, height: 12)
        case .m1: shape.fill(Color.white.opacity(0.88)).uiFrame(width: 12, height: 12)
        case .m2: shape.fill(Color.white.opacity(0.46)).uiFrame(width: 12, height: 12)
        case .m3: shape.strokeBorder(Color.white, lineWidth: 1.5).uiFrame(width: 12, height: 12)
        case .m4: shape.strokeBorder(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).uiFrame(width: 12, height: 12)
        case .vias: Rectangle().fill(Color.white).uiFrame(width: 7, height: 7).uiFrame(width: 12, height: 12)
        }
    }
}

private extension View {
    func chip(active: Bool) -> some View {
        self.uiFont(13, weight: .medium)
            .foregroundStyle(active ? Color.black : Theme.text)
            .fixedSize()
            .uiPadding(.horizontal, 12)
            .uiFrame(height: 38)
            .background(active ? Theme.accent : Theme.raised, in: Capsule())
            .contentShape(Capsule())
    }
}
