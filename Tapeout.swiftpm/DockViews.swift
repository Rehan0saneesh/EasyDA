import SwiftUI

/// A compact pill-style picker that stays inside the black and gray palette.
struct Segmented<T: Hashable & CaseIterable & RawRepresentable>: View where T.RawValue == String {
    @Binding var selection: T
    var badge: (T) -> Int = { _ in 0 }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(T.allCases), id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    HStack(spacing: 6) {
                        Text(item.rawValue)
                        if badge(item) > 0 {
                            Text("\(badge(item))")
                                .uiFont(11, weight: .bold)
                                .foregroundStyle(.white)
                                .uiPadding(.horizontal, 5)
                                .uiFrame(minWidth: 18, minHeight: 18)
                                .background(Theme.bad, in: Capsule())
                        }
                    }
                    .uiFont(13, weight: .medium)
                    .foregroundStyle(selection == item ? Color.black : Theme.dim)
                    .fixedSize()
                    .uiPadding(.horizontal, 12)
                    .uiFrame(height: 32)
                    .background(selection == item ? Theme.accent : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .uiPadding(.all, 3)
        .background(Theme.raised, in: Capsule())
    }
}

/// A small rounded button used across the tools.
struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .uiFont(13, weight: .medium)
            .foregroundStyle(active ? Color.black : Theme.text)
            .fixedSize()
            .uiPadding(.horizontal, 12)
            .uiFrame(minWidth: 44, minHeight: 38)
            .background(active ? Theme.accent : Theme.raised, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The tool dock under the chip: test bench, waveforms, timing and checks.
struct Dock: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Segmented(selection: $model.dockTab) { tab in
                tab == .checks ? model.checks.filter { $0.isRule }.count : 0
            }
            Group {
                if let netlist = model.netlist {
                    switch model.dockTab {
                    case .bench:
                        BenchView(model: model, netlist: netlist)
                    case .waves:
                        WavesView(data: model.waveData, radix: $model.radix, cursor: model.cursor,
                                  selected: model.selected, highlight: model.highlight, live: model.signals,
                                  onCursor: { model.setCursor($0) }, onSelect: { model.select($0) },
                                  onStep: netlist.isSequential ? { model.stepClock($0) } : nil)
                    case .timing:
                        TimingView(model: model)
                    case .checks:
                        ChecksView(model: model)
                    }
                } else {
                    Text("Nothing to inspect yet.")
                        .uiFont(14)
                        .foregroundStyle(Theme.faint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .uiPadding(.horizontal, 20)
        .uiPadding(.vertical, 14)
        .background(Theme.panel)
    }
}

// MARK: - Bench

/// Drive the inputs, run the clock, and watch outputs, registers and memory.
struct BenchView: View {
    @ObservedObject var model: AppModel
    let netlist: Netlist

    var body: some View {
        let now = model.signals
        ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    if netlist.isSequential { clock }
                    Eyebrow("Inputs")
                    Flow(netlist.dataInputs.filter { netlist.widths[$0] == 1 }) { name in
                        InputSwitch(name: name, isOn: model.inputs[name] == 1) { model.toggle(name) }
                    }
                    ForEach(netlist.dataInputs.filter { (netlist.widths[$0] ?? 1) > 1 }, id: \.self) { name in
                        BusInput(name: name, width: netlist.widths[name] ?? 1, value: model.inputs[name] ?? 0,
                                 flip: { model.flip(name, bit: $0) }, set: { model.setInput(name, $0) })
                    }
                    Eyebrow("Outputs").uiPadding(.top, 6)
                    Flow(netlist.outputs.filter { netlist.widths[$0] == 1 }) { name in
                        Lamp(name: name, isOn: value(netlist.drivers[name], now) != 0)
                    }
                    ForEach(netlist.outputs.filter { (netlist.widths[$0] ?? 1) > 1 }, id: \.self) { name in
                        BusValue(name: name, width: netlist.widths[name] ?? 1, value: value(netlist.drivers[name], now))
                    }
                }
                if !model.truthRows.isEmpty {
                    Rectangle().fill(Theme.stroke).uiFrame(width: 1)
                    TruthTable(model: model, netlist: netlist)
                } else if netlist.isSequential {
                    Rectangle().fill(Theme.stroke).uiFrame(width: 1)
                    stored(now)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func value(_ signal: Signal?, _ now: [Signal: UInt64]) -> UInt64 {
        guard let signal else { return 0 }
        if case .const(let c) = signal { return c }
        return now[signal] ?? 0
    }

    private var clock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Clock")
            HStack(spacing: 8) {
                PillButton(title: "Step", symbol: "forward.frame.fill") { model.stepClock() }
                PillButton(title: model.running ? "Pause" : "Run", symbol: model.running ? "pause.fill" : "play.fill",
                           active: model.running) { model.toggleRunning() }
                PillButton(title: "Clear", symbol: "arrow.counterclockwise") { model.resetState() }
                Text("cycle \(model.cycle)")
                    .uiFont(13, design: .monospaced)
                    .foregroundStyle(Theme.dim)
            }
        }
        .uiPadding(.bottom, 6)
    }

    /// Register and memory contents.
    private func stored(_ now: [Signal: UInt64]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Registers")
            ForEach(netlist.gates.filter { $0.kind == .dff }, id: \.id) { g in
                HStack(spacing: 10) {
                    Text(netlist.label(.gate(g.id)))
                        .foregroundStyle(Theme.dim)
                        .uiFrame(minWidth: 84, alignment: .leading)
                    Text(Radix.hex.format(now[.gate(g.id)] ?? 0, width: g.width))
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.text)
                    Text(Radix.dec.format(now[.gate(g.id)] ?? 0, width: g.width))
                        .foregroundStyle(Theme.faint)
                }
                .uiFont(14, design: .monospaced)
            }
            ForEach(Array(netlist.memories.enumerated()), id: \.offset) { index, memory in
                Eyebrow("Memory \(memory.name)").uiPadding(.top, 6)
                let words = index < model.state.mems.count ? model.state.mems[index] : []
                ForEach(Array(stride(from: 0, to: min(words.count, 64), by: 8)), id: \.self) { start in
                    HStack(spacing: 8) {
                        Text(String(format: "%02X", start)).foregroundStyle(Theme.faint)
                        ForEach(start..<min(start + 8, words.count), id: \.self) { i in
                            Text(Radix.hex.format(words[i], width: memory.width))
                                .foregroundStyle(words[i] == 0 ? Theme.faint : Theme.text)
                        }
                    }
                    .uiFont(13, design: .monospaced)
                }
            }
        }
    }
}

/// Lays items out in rows of four so six or eight inputs still fit.
struct Flow<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: items.count, by: 4)), id: \.self) { start in
                HStack(spacing: 8) {
                    ForEach(items[start..<min(start + 4, items.count)], id: \.self) { content($0) }
                }
            }
        }
    }
}

struct InputSwitch: View {
    let name: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name).uiFont(15, weight: .medium, design: .monospaced)
                Text(isOn ? "1" : "0").uiFont(15, weight: .bold, design: .monospaced)
            }
            .foregroundStyle(isOn ? Color.black : Theme.text)
            .uiPadding(.horizontal, 14)
            .uiFrame(minWidth: 64, minHeight: 44)
            .background(isOn ? Theme.accent : Theme.raised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(isOn ? Color.clear : Theme.stroke))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityLabel("Input \(name)")
        .accessibilityValue(isOn ? "1" : "0")
    }
}

/// A multi-bit input: one toggle per bit for small buses, plus and minus for wide ones.
struct BusInput: View {
    let name: String
    let width: Int
    let value: UInt64
    let flip: (Int) -> Void
    let set: (UInt64) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .uiFont(15, weight: .medium, design: .monospaced)
                .foregroundStyle(Theme.text)
                .uiFrame(minWidth: 70, alignment: .leading)
            if width <= 8 {
                HStack(spacing: 3) {
                    ForEach((0..<width).reversed(), id: \.self) { bit in
                        let on = (value >> UInt64(bit)) & 1 == 1
                        Button { flip(bit) } label: {
                            Text(on ? "1" : "0")
                                .uiFont(15, weight: .bold, design: .monospaced)
                                .foregroundStyle(on ? Color.black : Theme.dim)
                                .uiFrame(width: 30, height: 44)
                                .background(on ? Theme.accent : Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(name) bit \(bit)")
                        .accessibilityValue(on ? "1" : "0")
                    }
                }
            } else {
                PillButton(title: "−") { set(value &- 1) }
                PillButton(title: "+") { set(value &+ 1) }
            }
            readout(value, width)
        }
    }
}

struct BusValue: View {
    let name: String
    let width: Int
    let value: UInt64

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .uiFont(15, weight: .medium, design: .monospaced)
                .foregroundStyle(value == 0 ? Theme.dim : Theme.text)
                .uiFrame(minWidth: 70, alignment: .leading)
            readout(value, width)
        }
        .uiFrame(minHeight: 30)
    }
}

/// Hex, decimal and (for a byte) the character it spells.
private func readout(_ value: UInt64, _ width: Int) -> some View {
    HStack(spacing: 10) {
        Text("0x" + Radix.hex.format(value, width: width)).fontWeight(.semibold).foregroundStyle(Theme.text)
        Text(Radix.dec.format(value, width: width)).foregroundStyle(Theme.faint)
        if width == 8, let c = Radix.printable(UInt8(truncatingIfNeeded: value)) {
            Text("‘\(String(c))’").foregroundStyle(Theme.dim)
        }
    }
    .uiFont(14, design: .monospaced)
    .fixedSize()
}

struct Lamp: View {
    let name: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isOn ? Theme.accent : Color.white.opacity(0.12))
                .uiFrame(width: 10, height: 10)
                .shadow(color: isOn ? Theme.accent.opacity(0.8) : .clear, radius: 6)
            Text(name).uiFont(15, weight: .medium, design: .monospaced)
                .foregroundStyle(isOn ? Theme.text : Theme.dim)
        }
        .uiPadding(.horizontal, 12)
        .uiFrame(minHeight: 36)
        .background(Theme.raised.opacity(0.6), in: Capsule())
        .animation(.easeOut(duration: 0.2).delay(0.15), value: isOn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Output \(name)")
        .accessibilityValue(isOn ? "1" : "0")
    }
}

struct TruthTable: View {
    @ObservedObject var model: AppModel
    let netlist: Netlist

    private let cell: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Truth table")
            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    ForEach(netlist.inputs, id: \.self) { head($0) }
                    Color.clear.uiFrame(width: 14, height: 1)
                    ForEach(netlist.outputs, id: \.self) { head($0) }
                }
                ForEach(Array(model.truthRows.enumerated()), id: \.offset) { _, row in
                    rowView(row)
                }
            }
        }
    }

    private func head(_ name: String) -> some View {
        Text(name)
            .uiFont(12, weight: .medium, design: .monospaced)
            .foregroundStyle(Theme.faint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: cell, height: 20)
    }

    private func rowView(_ row: [String: Bool]) -> some View {
        let actual = netlist.outputValues(row)
        let expected = model.verdict == .portsChanged ? nil : model.lesson.expected?(row)
        let current = row == model.boolInputs
        return Button {
            model.setInputs(row)
        } label: {
            HStack(spacing: 0) {
                ForEach(netlist.inputs, id: \.self) { name in
                    bit(row[name] ?? false, color: Theme.dim)
                }
                Color.clear.uiFrame(width: 14, height: 1)
                ForEach(netlist.outputs, id: \.self) { name in
                    let value = actual[name] ?? false
                    let wrong = expected.map { $0[name] != value } ?? false
                    bit(value, color: wrong ? Theme.bad : (value ? Theme.accent : Theme.dim))
                        .overlay(alignment: .bottom) {
                            if wrong { Rectangle().fill(Theme.bad).uiFrame(width: 12, height: 1.5).offset(y: -3) }
                        }
                }
            }
            .background(current ? Color.white.opacity(0.09) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func bit(_ value: Bool, color: Color) -> some View {
        Text(value ? "1" : "0")
            .uiFont(14, weight: value ? .bold : .regular, design: .monospaced)
            .foregroundStyle(color)
            .frame(width: cell, height: 24)
    }
}

// MARK: - Waveforms

/// Signals against time, from the simulator or an imported file.
/// Tap the timeline to move the cursor, tap a name to cross-probe it, pinch or use the buttons to zoom.
struct WavesView: View {
    let data: WaveData
    @Binding var radix: Radix
    var cursor: Int?
    var selected: Signal? = nil
    var highlight: Set<Signal>? = nil
    var live: [Signal: UInt64] = [:]
    var onCursor: (Int) -> Void = { _ in }
    var onSelect: (Signal) -> Void = { _ in }
    var onStep: ((Int) -> Void)? = nil

    @State private var scale: CGFloat = 5          // points per sample
    @State private var scaleAtPinch: CGFloat?
    @State private var decoder: ProtocolKind = .none
    @State private var roles: [String: String] = [:]   // protocol role -> row id

    private let rowHeight: CGFloat = 30
    private let axisHeight: CGFloat = 22
    private let labelWidth: CGFloat = 150

    var body: some View {
        let frames = decoded
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Segmented(selection: $radix)
                    decodeMenu
                    if decoder != .none { roleMenus }
                    if let onStep {
                        PillButton(title: "+1", symbol: "forward.frame.fill") { onStep(1) }
                        PillButton(title: "+16") { onStep(16) }
                    }
                    PillButton(title: "", symbol: "minus.magnifyingglass") { scale = max(scale / 1.5, 0.4) }
                    PillButton(title: "", symbol: "plus.magnifyingglass") { scale = min(scale * 1.5, 40) }
                    Text(cursor.map { "t = \(timeText($0))" } ?? "Tap the timeline")
                        .uiFont(13, design: .monospaced)
                        .foregroundStyle(Theme.dim)
                        .fixedSize()
                }
            }
            if data.length == 0 {
                Text(onStep == nil ? "No samples to show." : "Step the clock to start recording.")
                    .uiFont(14)
                    .foregroundStyle(Theme.faint)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: axisHeight)
                            ForEach(data.rows) { label($0) }
                            if decoder != .none { decodedLabel(frames) }
                        }
                        .frame(width: labelWidth)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Canvas { context, _ in
                                draw(&context, frames: frames)
                            }
                            .frame(width: CGFloat(data.length) * scale + 1, height: canvasHeight)
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { tap in
                                onCursor(Int(tap.location.x / scale))
                            })
                        }
                    }
                }
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { amount in
                            let start = scaleAtPinch ?? scale
                            scaleAtPinch = start
                            scale = min(max(start * amount, 0.4), 40)
                        }
                        .onEnded { _ in scaleAtPinch = nil }
                )
            }
        }
        .onChange(of: decoder) { guessRoles() }
    }

    private func height(_ row: WaveRow) -> CGFloat { row.isAnalog ? rowHeight * 2 : rowHeight }

    private var canvasHeight: CGFloat {
        axisHeight + data.rows.reduce(0) { $0 + height($1) } + (decoder == .none ? 0 : rowHeight)
    }

    private func timeText(_ t: Int) -> String {
        let time = Double(t) * data.timeStep
        let number = time == time.rounded() ? String(Int(time)) : String(format: "%.1f", time)
        return data.unit.isEmpty ? number : "\(number) \(data.unit)"
    }

    // MARK: Protocol decoding

    private var decoded: [Frame] {
        var lines: [String: [UInt64]] = [:]
        for role in decoder.roles {
            if let samples = data.bit(roles[role.name]) { lines[role.name] = samples }
        }
        return Decoder.decode(decoder, lines)
    }

    /// Picks likely signals for each role from their names.
    private func guessRoles() {
        var guess: [String: String] = [:]
        let bits = data.rows.filter { $0.width == 1 && !$0.isAnalog }
        for role in decoder.roles {
            let match = role.hints.lazy.compactMap { hint in
                bits.first { $0.label.lowercased().contains(hint) && !guess.values.contains($0.id) }
            }.first
            if let match { guess[role.name] = match.id }
        }
        roles = guess
    }

    private var decodeMenu: some View {
        Menu {
            Picker("Decode", selection: $decoder) {
                ForEach(ProtocolKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                Text(decoder == .none ? "Decode" : decoder.rawValue)
            }
            .uiFont(13, weight: .medium)
            .foregroundStyle(decoder == .none ? Theme.text : Color.black)
            .fixedSize()
            .uiPadding(.horizontal, 12)
            .uiFrame(height: 38)
            .background(decoder == .none ? Theme.raised : Theme.accent, in: Capsule())
        }
    }

    private var roleMenus: some View {
        ForEach(decoder.roles, id: \.name) { role in
            Menu {
                if !role.required { Button("None") { roles[role.name] = nil } }
                ForEach(data.rows.filter { $0.width == 1 && !$0.isAnalog }) { row in
                    Button(row.label) { roles[role.name] = row.id }
                }
            } label: {
                let chosen = data.rows.first { $0.id == roles[role.name] }?.label
                Text("\(role.name): \(chosen ?? (role.required ? "choose" : "none"))")
                    .uiFont(13, weight: .medium)
                    .foregroundStyle(chosen == nil && role.required ? Theme.bad : Theme.text)
                    .fixedSize()
                    .uiPadding(.horizontal, 12)
                    .uiFrame(height: 38)
                    .background(Theme.raised, in: Capsule())
            }
        }
    }

    private func decodedLabel(_ frames: [Frame]) -> some View {
        HStack(spacing: 6) {
            Text(decoder.rawValue).foregroundStyle(Theme.dim)
            Spacer(minLength: 0)
            Text(frames.isEmpty ? "nothing" : "\(frames.count)").foregroundStyle(Theme.faint)
        }
        .uiFont(13, design: .monospaced)
        .uiPadding(.horizontal, 8)
        .frame(height: rowHeight)
    }

    // MARK: Labels

    private func value(of row: WaveRow) -> String {
        if row.isAnalog {
            guard let samples = data.analog[row.id], !samples.isEmpty else { return "" }
            return String(format: "%.3g", samples[min(cursor ?? samples.count - 1, samples.count - 1)])
        }
        var value: UInt64 = 0
        if let samples = data.values[row.id], !samples.isEmpty {
            if let t = cursor, t < samples.count {
                value = samples[t]
            } else if let signal = row.signal, case .const = signal {
                value = samples[0]
            } else if let signal = row.signal, let now = live[signal] {
                value = now
            } else {
                value = samples[samples.count - 1]
            }
        }
        return row.width == 1 ? (value != 0 ? "1" : "0") : radix.format(value, width: row.width)
    }

    private func label(_ row: WaveRow) -> some View {
        let isSelected = row.signal != nil && row.signal == selected
        return Button {
            if let signal = row.signal { onSelect(signal) }
        } label: {
            HStack(spacing: 6) {
                Text(row.label)
                    .foregroundStyle(row.signal == nil && row.id.hasPrefix("bus:") ? Theme.dim : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                Text(value(of: row))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            .uiFont(13, design: .monospaced)
            .uiPadding(.horizontal, 8)
            .frame(height: height(row))
            .background(isSelected ? Color.white.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Drawing

    private func cell(_ x0: CGFloat, _ x1: CGFloat, _ high: CGFloat, _ low: CGFloat) -> Path {
        let mid = (high + low) / 2, nib = min(3, (x1 - x0) / 2)
        var p = Path()
        p.move(to: CGPoint(x: x0, y: mid))
        p.addLine(to: CGPoint(x: x0 + nib, y: high))
        p.addLine(to: CGPoint(x: x1 - nib, y: high))
        p.addLine(to: CGPoint(x: x1, y: mid))
        p.addLine(to: CGPoint(x: x1 - nib, y: low))
        p.addLine(to: CGPoint(x: x0 + nib, y: low))
        p.closeSubpath()
        return p
    }

    private func draw(_ context: inout GraphicsContext, frames: [Frame]) {
        let total = canvasHeight
        let division = max(data.division, 1)

        // Time axis.
        let labelEvery = max(1, Int((44 / (CGFloat(division) * scale)).rounded(.up)))
        for (index, t) in stride(from: 0, through: data.length, by: division).enumerated() {
            let x = CGFloat(t) * scale
            if CGFloat(division) * scale >= 3 || index % labelEvery == 0 {
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: axisHeight - 6)); $0.addLine(to: CGPoint(x: x, y: total)) },
                               with: .color(.white.opacity(0.07)), lineWidth: 1)
            }
            if index % labelEvery == 0, t < data.length {
                context.draw(Text(timeText(t)).font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35)), at: CGPoint(x: x + 4, y: axisHeight / 2), anchor: .leading)
            }
        }

        var top = axisHeight
        for row in data.rows {
            let rowH = height(row)
            let high = top + 7, low = top + rowH - 7
            defer { top += rowH }
            let dim = highlight.map { set in row.signal.map { !set.contains($0) } ?? true } ?? false
            let ink = Color.white.opacity(dim ? 0.2 : 0.9)

            if row.isAnalog {
                // A real-valued signal is drawn as a curve between its smallest and largest values.
                guard let samples = data.analog[row.id], let lo = samples.min(), let hi = samples.max() else { continue }
                let range = hi - lo == 0 ? 1 : hi - lo
                var curve = Path()
                for (t, v) in samples.enumerated() {
                    let point = CGPoint(x: (CGFloat(t) + 0.5) * scale, y: low - CGFloat((v - lo) / range) * (low - high))
                    if t == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                context.draw(Text(String(format: "%.3g", hi)).font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35)), at: CGPoint(x: 3, y: high), anchor: .leading)
                context.draw(Text(String(format: "%.3g", lo)).font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35)), at: CGPoint(x: 3, y: low), anchor: .leading)
                continue
            }
            guard let samples = data.values[row.id], !samples.isEmpty else { continue }

            if row.width > 1 {
                // A bus is drawn as a chain of cells, one per stable value.
                var start = 0
                for t in 1...samples.count where t == samples.count || samples[t] != samples[start] {
                    let x0 = CGFloat(start) * scale, x1 = CGFloat(t) * scale
                    let shape = cell(x0, x1, high, low)
                    context.fill(shape, with: .color(.white.opacity(0.06)))
                    context.stroke(shape, with: .color(ink.opacity(0.7)), lineWidth: 1)
                    let text = radix.format(samples[start], width: row.width)
                    if x1 - x0 > CGFloat(text.count) * 7.5 + 8 {
                        context.draw(Text(text).font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(ink), at: CGPoint(x: (x0 + x1) / 2, y: (high + low) / 2))
                    }
                    start = t
                }
            } else {
                func y(_ value: UInt64) -> CGFloat { value != 0 ? high : low }
                var trace = Path()
                trace.move(to: CGPoint(x: 0, y: y(samples[0])))
                var runStart = 0
                for t in 1...samples.count {
                    guard t == samples.count || (samples[t] != 0) != (samples[t - 1] != 0) else { continue }
                    let x = CGFloat(t) * scale
                    if samples[t - 1] != 0 {
                        context.fill(Path(CGRect(x: CGFloat(runStart) * scale, y: high, width: x - CGFloat(runStart) * scale, height: low - high)),
                                     with: .color(.white.opacity(dim ? 0.03 : 0.12)))
                    }
                    trace.addLine(to: CGPoint(x: x, y: y(samples[t - 1])))
                    if t < samples.count { trace.addLine(to: CGPoint(x: x, y: y(samples[t]))) }
                    runStart = t
                }
                context.stroke(trace, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }

        // Decoded protocol frames.
        if decoder != .none {
            let high = top + 5, low = top + rowHeight - 5
            for frame in frames {
                let x0 = CGFloat(frame.start) * scale, x1 = CGFloat(frame.end) * scale
                let shape = cell(x0, x1, high, low)
                context.fill(shape, with: .color(.white.opacity(0.92)))
                if x1 - x0 > CGFloat(frame.text.count) * 7 + 6 {
                    context.draw(Text(frame.text).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.black), at: CGPoint(x: (x0 + x1) / 2, y: (high + low) / 2))
                }
            }
        }

        if let cursor {
            let x = (CGFloat(cursor) + 0.5) * scale
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: total)) },
                           with: .color(.white), lineWidth: 1.5)
        }
    }
}

// MARK: - Timing

struct TimingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let analysis = model.analysis, let netlist = model.netlist {
            let slack = model.budget - analysis.criticalDelay
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 28) {
                        stat("Critical delay", "\(analysis.criticalDelay)")
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(netlist.isSequential ? "Clock period" : "Budget")
                            HStack(spacing: 10) {
                                Text("\(model.budget)")
                                    .uiFont(24, weight: .semibold, design: .monospaced)
                                    .foregroundStyle(Theme.text)
                                Stepper("Budget", value: $model.budget, in: 1...200).labelsHidden()
                            }
                        }
                        stat("Slack", slack >= 0 ? "+\(slack)" : "\(slack)", color: slack < 0 ? Theme.bad : Theme.text)
                        Spacer(minLength: 0)
                        PillButton(title: model.overlay == .critical ? "Hide path" : "Show path",
                                   symbol: "point.topleft.down.to.point.bottomright.curvepath",
                                   active: model.overlay == .critical) {
                            model.overlay = model.overlay == .critical ? .none : .critical
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Critical path" + (analysis.criticalEnd.isEmpty ? "" : " · ends at \(analysis.criticalEnd)"))
                        Text(analysis.criticalPath.filter { signal in
                            if case .gate(let id) = signal { return !netlist.gates[id].kind.isWiring }
                            return true
                        }.map { netlist.label($0) }.joined(separator: "  →  "))
                            .uiFont(14, design: .monospaced)
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow("Outputs")
                        ForEach(netlist.outputs, id: \.self) { name in
                            let arrival = analysis.arrival(ofOutput: name)
                            HStack(spacing: 12) {
                                Text(name)
                                    .uiFont(14, weight: .medium, design: .monospaced)
                                    .foregroundStyle(Theme.text)
                                    .uiFrame(width: 90, alignment: .leading)
                                bar(arrival: arrival, limit: max(model.budget, analysis.criticalDelay, 1))
                                Text("settles at \(arrival)")
                                    .uiFont(13, design: .monospaced)
                                    .foregroundStyle(arrival > model.budget ? Theme.bad : Theme.dim)
                            }
                        }
                    }
                    Text("Delay per cell: NOT, NAND, NOR 1 · AND, OR 2 · XOR, MUX 3 · compare 5 to 7 · add grows with width · RAM read 6")
                        .uiFont(12)
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String, color: Color = Theme.text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(title)
            Text(value)
                .uiFont(24, weight: .semibold, design: .monospaced)
                .foregroundStyle(color)
        }
    }

    private func bar(arrival: Int, limit: Int) -> some View {
        let width: CGFloat = 180
        let late = arrival > model.budget
        return ZStack(alignment: .leading) {
            Capsule().fill(Theme.raised).frame(width: width, height: 8)
            Capsule().fill(late ? Theme.bad : Theme.accent)
                .frame(width: max(width * CGFloat(arrival) / CGFloat(limit), arrival > 0 ? 8 : 0), height: 8)
            Rectangle().fill(Color.white.opacity(0.6))
                .uiFrame(width: 1.5, height: 16)
                .offset(x: width * CGFloat(min(model.budget, limit)) / CGFloat(limit) - 0.75)
        }
        .frame(width: width, height: 16)
    }
}

// MARK: - Checks

struct ChecksView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.checks.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .uiFont(18)
                    .foregroundStyle(Theme.text)
                Text("Clean. No design-rule violations, and nothing odd in the logic.")
                    .uiFont(14)
                    .foregroundStyle(Theme.dim)
            }
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(model.checks) { check in
                        Button {
                            model.jump(to: check)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: check.isRule ? "exclamationmark.triangle.fill" : "info.circle")
                                    .uiFont(15)
                                    .foregroundStyle(check.isRule ? Theme.bad : Theme.dim)
                                    .uiFrame(width: 20)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(check.title)
                                        .uiFont(14, weight: .medium)
                                        .foregroundStyle(Theme.text)
                                    Text(check.detail)
                                        .uiFont(13)
                                        .foregroundStyle(Theme.dim)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if check.isRule || check.signal != nil {
                                    Image(systemName: check.isRule ? "scope" : "arrow.up.left")
                                        .uiFont(13, weight: .semibold)
                                        .foregroundStyle(Theme.faint)
                                }
                            }
                            .uiPadding(.all, 12)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
