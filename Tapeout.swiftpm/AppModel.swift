import SwiftUI
import simd

enum Mode {
    case learn    // guided lessons
    case editor   // a blank bench
}

enum Verdict: Equatable {
    case freeBuild
    case broken              // the code doesn't synthesize
    case portsChanged
    case failing(Int)        // number of wrong truth-table rows
    case todo(String)        // logic is right, but the lesson asks for something more
    case passing
}

enum MainView: String, CaseIterable {
    case chip = "3D", schematic = "Schematic", layout = "Layout", wafer = "Wafer"
}

enum DockTab: String, CaseIterable {
    case bench = "Bench", waves = "Waves", timing = "Timing", checks = "Checks"
}

enum Overlay: String, CaseIterable {
    case none = "None", congestion = "Congestion", activity = "Activity", critical = "Critical path"
}

/// One entry in the Checks list: a design-rule violation on the layout, or a logic note.
struct Check: Identifiable {
    let id: Int
    let isRule: Bool
    let title: String
    let detail: String
    var lower = SIMD2<Float>(0, 0)
    var upper = SIMD2<Float>(0, 0)
    var signal: Signal? = nil
}

/// A request for the layout canvas to zoom to a spot.
struct LayoutFocus: Equatable {
    var id: Int
    var center: SIMD2<Float>
    var span: Float
}

@MainActor
final class AppModel: ObservableObject {
    let mode: Mode
    let lessons: [Lesson]

    @Published private(set) var lessonIndex = 0
    @Published var source: String = "" {
        didSet { if source != oldValue { compile() } }
    }
    /// The last design that synthesized. It stays on screen while the code is mid-edit.
    @Published private(set) var netlist: Netlist?
    @Published private(set) var error: VerilogError?
    @Published private(set) var completed: Set<Int> = []
    @Published var showHint = false

    // Simulation
    @Published private(set) var inputs: [String: UInt64] = [:]
    @Published private(set) var state = SimState()
    @Published private(set) var cycle = 0
    @Published private(set) var running = false
    private var history: [[Signal: UInt64]] = []     // every signal after each clock edge
    private var runner: Task<Void, Never>?

    // Derived views of the design
    @Published private(set) var analysis: Analysis?
    @Published private(set) var layout: ChipLayout?
    /// Changes whenever the physical layout does, so the 3D scene knows to rebuild.
    @Published private(set) var layoutVersion = 0
    @Published private(set) var checks: [Check] = []
    @Published private(set) var waveData = WaveData()
    @Published private(set) var activity: [Signal: Int] = [:]

    // Tool state
    @Published var mainView: MainView = .chip
    @Published var dockTab: DockTab = .bench
    @Published var overlay: Overlay = .none
    @Published var coneMode: ConeMode = .both
    @Published var radix: Radix = .bin { didSet { if radix != .bin { note("wave.radix") } } }
    @Published var density: Density = .normal { didSet { if density != oldValue { place() } } }
    @Published var budget = 6
    @Published var hiddenLayers: Set<Layer> = [] { didSet { if !hiddenLayers.isEmpty { note("layout.layer") } } }
    @Published var rulerOn = false
    /// Bumped to ask the layout canvas to zoom back out.
    @Published var fitToken = 0
    /// Bumped to ask the wafer view to zoom in on one die.
    @Published var dieToken = 0
    @Published var coreToken = 0
    /// The design mapped to standard cells, for the wafer view.
    @Published private(set) var silicon: Silicon?
    /// Wafer diameter in millimetres, and killer defects per square centimetre, for the wafer view.
    @Published var waferSize = 200
    @Published var defectDensity = 0.5
    @Published private(set) var selected: Signal?
    @Published private(set) var cursor: Int?
    @Published private(set) var focus: LayoutFocus?
    @Published private(set) var actions: Set<String> = []

    private var drafts: [Int: String] = [:]

    var lesson: Lesson { lessons[lessonIndex] }
    var hasNext: Bool { lessonIndex + 1 < lessons.count }

    static let blank = Lesson(
        id: 0, title: "Editor", concept: "", goal: "",
        starter: """
        module my_chip(
          input a,
          input b,
          output y
        );
          assign y = a & b;
        endmodule
        """,
        hint: "", solution: "", expected: nil, inputs: [], outputs: []
    )

    init(mode: Mode) {
        self.mode = mode
        lessons = mode == .learn ? Lessons.all : [AppModel.blank]
        source = lesson.starter
        compile()
    }

    func open(_ index: Int) {
        guard lessons.indices.contains(index), index != lessonIndex else { return }
        drafts[lessonIndex] = source
        lessonIndex = index
        showHint = false
        resetTools()
        density = lesson.density
        source = drafts[index] ?? lesson.starter
        compile()
    }

    func resetLesson() {
        showHint = false
        source = lesson.starter
    }

    /// Replaces the code with an example or an imported file (editor mode).
    func load(_ text: String) {
        resetTools()
        source = text
        compile()
    }

    private func resetTools() {
        stopRunning()
        netlist = nil
        layout = nil
        analysis = nil
        inputs = [:]
        selected = nil
        cursor = nil
        focus = nil
        actions = []
        overlay = .none
        rulerOn = false
        hiddenLayers = []
        density = .normal
        mainView = .chip
        dockTab = .bench
        radix = .bin
    }

    // MARK: Inputs and the clock

    func toggle(_ input: String) { flip(input, bit: 0) }

    func flip(_ input: String, bit: Int) {
        inputs[input] = (inputs[input] ?? 0) ^ (UInt64(1) << UInt64(bit))
        cursor = nil
    }

    func setInput(_ input: String, _ value: UInt64) {
        inputs[input] = value & mask(netlist?.widths[input] ?? 1)
        cursor = nil
    }

    func setInputs(_ values: [String: Bool]) {
        inputs = values.mapValues { $0 ? 1 : 0 }
        cursor = nil
    }

    var boolInputs: [String: Bool] { inputs.mapValues { $0 != 0 } }

    /// One or more rising clock edges.
    func stepClock(_ count: Int = 1) {
        guard let netlist, netlist.isSequential else { return }
        for _ in 0..<count {
            state = netlist.step(inputs, state: state)
            cycle += 1
            history.append(netlist.evaluate(inputs, state: state))
        }
        if history.count > 400 { history.removeFirst(history.count - 400) }
        cursor = nil
        rebuildWaves()
    }

    /// Clears every register and memory back to zero.
    func resetState() {
        guard let netlist else { return }
        stopRunning()
        state = netlist.initialState()
        cycle = 0
        history = netlist.isSequential ? [netlist.evaluate(inputs, state: state)] : []
        cursor = nil
        rebuildWaves()
    }

    func toggleRunning() {
        if running { stopRunning(); return }
        guard netlist?.isSequential == true else { return }
        running = true
        runner = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled, let self, self.running else { return }
                self.stepClock()
            }
        }
    }

    private func stopRunning() {
        running = false
        runner?.cancel()
        runner = nil
    }

    // MARK: Tools

    /// Cross-probe: picking a signal anywhere highlights it in the code, the chip, the schematic and the waveform.
    func select(_ signal: Signal?) {
        selected = signal == selected ? nil : signal
        if selected != nil {
            if overlay == .critical { overlay = .none }
            note("probe.select")
        }
    }

    /// Moves the waveform cursor. For pure logic, the chip takes the inputs it had at that moment.
    func setCursor(_ time: Int) {
        guard waveData.length > 0 else { return }
        let t = min(max(time, 0), waveData.length - 1)
        cursor = t
        if let waves = analysis?.waves, waves.length > 0 { inputs = waves.vectors[t / waves.period] }
        note("wave.cursor")
    }

    func jump(to check: Check) {
        note("checks.jump")
        if check.isRule {
            mainView = .layout
            let size = check.upper - check.lower
            focus = LayoutFocus(id: (focus?.id ?? 0) + 1, center: (check.lower + check.upper) / 2,
                                span: max(size.x, size.y, 0.5))
        } else if let signal = check.signal {
            selected = signal
        }
    }

    func note(_ action: String) {
        guard actions.insert(action).inserted else { return }
        refreshCompletion()
    }

    // MARK: Derived state

    var signals: [Signal: UInt64] { netlist?.evaluate(inputs, state: state) ?? [:] }

    /// The signals to keep lit while everything else dims: the critical path, or the selected signal's cone.
    var highlight: Set<Signal>? {
        guard let analysis else { return nil }
        if overlay == .critical { return Set(analysis.criticalPath) }
        if let selected { return analysis.cone(of: selected, mode: coneMode) }
        return nil
    }

    /// The source line of the selected signal.
    var focusLine: Int? {
        guard error == nil, let selected else { return nil }
        return netlist?.lines[selected]
    }

    private func rows(limit: Int) -> [[String: Bool]] {
        guard let netlist, netlist.isBitLevel, netlist.inputs.count <= limit else { return [] }
        let names = netlist.inputs
        return (0..<(1 << names.count)).map { row in
            var values: [String: Bool] = [:]
            for (i, name) in names.enumerated() {
                values[name] = (row >> (names.count - 1 - i)) & 1 == 1
            }
            return values
        }
    }

    /// Every input combination, in binary counting order (shown for up to four single-bit inputs).
    var truthRows: [[String: Bool]] { rows(limit: 4) }

    var verdict: Verdict {
        guard error == nil, let netlist else { return .broken }
        guard let expected = lesson.expected else { return .freeBuild }
        guard netlist.isBitLevel, Set(netlist.inputs) == Set(lesson.inputs), Set(netlist.outputs) == Set(lesson.outputs) else {
            return .portsChanged
        }
        let wrong = rows(limit: 10).filter { netlist.outputValues($0) != expected($0) }.count
        if wrong > 0 { return .failing(wrong) }
        if let todo = lesson.requirement?(self) { return .todo(todo) }
        return .passing
    }

    private func refreshCompletion() {
        if verdict == .passing { completed.insert(lesson.id) }
    }

    private func compile() {
        switch Verilog.synthesize(source) {
        case .success(let net):
            let moved = netlist.map { !$0.sameStructure(as: net) } ?? true
            netlist = net
            error = nil
            inputs = Dictionary(uniqueKeysWithValues: net.inputs.map { ($0, (inputs[$0] ?? 0) & mask(net.widths[$0] ?? 1)) })
            analysis = Analysis(net)
            if moved {
                selected = nil
                stopRunning()
                state = net.initialState()
                cycle = 0
                history = net.isSequential ? [net.evaluate(inputs, state: state)] : []
                cursor = nil
                // Outside the lessons, start with a timing budget the design just meets.
                if mode == .editor, let delay = analysis?.criticalDelay { budget = max((delay + 4) / 5 * 5, 5) }
                place()
            } else {
                refreshCompletion()
            }
            rebuildWaves()
        case .failure(let e):
            error = e
        }
    }

    /// Places and routes the current netlist, then re-runs the checks.
    private func place() {
        guard let netlist, let analysis else { return }
        let placed = ChipLayout(netlist, density: density)
        layout = placed
        silicon = Silicon(netlist: netlist, layout: placed)
        layoutVersion += 1

        var found: [Check] = []
        for v in placed.designRuleViolations() {
            let a = netlist.label(v.nets.0), b = netlist.label(v.nets.1)
            let title = v.distance == 0 ? "M\(v.layer) short: \(a) touches \(b)" : "M\(v.layer) spacing: \(a) and \(b)"
            let detail = String(format: "%.3f apart. The rule is at least %.2f between different nets.",
                                v.distance, ChipLayout.minSpacing)
            found.append(Check(id: found.count, isRule: true, title: title, detail: detail, lower: v.lower, upper: v.upper))
        }
        if !placed.canCheckRules {
            found.append(Check(id: found.count, isRule: false, title: "Design rules weren't checked",
                               detail: "This design has too many wires to check live on the device."))
        }
        for note in analysis.lint() {
            found.append(Check(id: found.count, isRule: false, title: note.title, detail: note.detail, signal: note.signal))
        }
        checks = found
        refreshCompletion()
    }

    /// Builds the rows the waveform viewer shows: a delay-accurate sweep for pure logic,
    /// or the recorded clock cycles for a design with registers.
    private func rebuildWaves() {
        guard let netlist, let analysis else { waveData = WaveData(); return }
        var data = WaveData(title: netlist.name)
        func add(_ row: WaveRow, _ samples: [UInt64]) {
            data.rows.append(row)
            data.values[row.id] = samples
        }
        let outs = netlist.outputs.map { ($0, netlist.drivers[$0] ?? .const(0)) }
        let driven = Set(outs.map { $0.1 })
        let internals = netlist.gates.filter { g in
            !driven.contains(.gate(g.id)) && (netlist.names[.gate(g.id)] != nil || (netlist.gates.count <= 40 && !g.kind.isWiring))
        }

        if netlist.isSequential {
            data.length = history.count * 2
            data.division = 2
            data.timeStep = 0.5
            func series(_ signal: Signal) -> [UInt64] {
                if case .const(let c) = signal { return Array(repeating: c, count: data.length) }
                return history.flatMap { [$0[signal] ?? 0, $0[signal] ?? 0] }
            }
            if let clock = netlist.clock {
                add(WaveRow(id: "clk", label: clock, width: 1), history.flatMap { _ in [UInt64(1), 0] })
            }
            for name in netlist.dataInputs {
                add(WaveRow(id: "in:\(name)", label: name, width: netlist.widths[name] ?? 1, signal: .input(name)), series(.input(name)))
            }
            for g in internals {
                add(WaveRow(id: "net:\(g.id)", label: netlist.label(.gate(g.id)), width: g.width, signal: .gate(g.id)), series(.gate(g.id)))
            }
            for (name, driver) in outs {
                add(WaveRow(id: "out:\(name)", label: name, width: netlist.widths[name] ?? 1, signal: driver), series(driver))
            }
            var samples: [Signal: [UInt64]] = [:]
            for g in netlist.gates { samples[.gate(g.id)] = history.map { $0[.gate(g.id)] ?? 0 } }
            activity = Analysis.activity(samples)
        } else {
            let waves = analysis.waves
            data.length = waves.length
            data.division = waves.period
            func series(_ signal: Signal) -> [UInt64] {
                if case .const(let c) = signal { return Array(repeating: c, count: waves.length) }
                return waves.samples[signal] ?? Array(repeating: 0, count: waves.length)
            }
            /// Groups single-bit signals into one bus row, first signal most significant.
            func group(_ signals: [Signal]) -> [UInt64] {
                let columns = signals.map(series)
                return (0..<waves.length).map { t in columns.reduce(0) { $0 << 1 | ($1[t] & 1) } }
            }
            let ins = netlist.inputs.map { Signal.input($0) }
            if netlist.isBitLevel, ins.count > 1 { add(WaveRow(id: "bus:in", label: "in", width: ins.count), group(ins)) }
            for name in netlist.inputs {
                add(WaveRow(id: "in:\(name)", label: name, width: netlist.widths[name] ?? 1, signal: .input(name)), series(.input(name)))
            }
            for g in internals {
                add(WaveRow(id: "net:\(g.id)", label: netlist.label(.gate(g.id)), width: g.width, signal: .gate(g.id)), series(.gate(g.id)))
            }
            for (name, driver) in outs {
                add(WaveRow(id: "out:\(name)", label: name, width: netlist.widths[name] ?? 1, signal: driver), series(driver))
            }
            if netlist.isBitLevel, outs.count > 1 {
                add(WaveRow(id: "bus:out", label: "out", width: outs.count), group(outs.map { $0.1 }))
            }
            activity = analysis.toggles
        }
        waveData = data
    }
}
