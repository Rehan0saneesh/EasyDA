import SwiftUI

struct ContentView: View {
    private enum Screen { case home, learn, editor, waveform }

    // Both workspaces stay alive, so work survives a trip back to the home screen.
    @StateObject private var learn = AppModel(mode: .learn)
    @StateObject private var editor = AppModel(mode: .editor)
    @State private var screen = Screen.home
    @State private var imported = WaveData()

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            switch screen {
            case .learn:
                Workspace(model: learn) { go(.home) }.transition(.opacity)
            case .editor:
                Workspace(model: editor) { go(.home) }.transition(.opacity)
            case .waveform:
                WaveformScreen(data: imported) { go(.home) }.transition(.opacity)
            case .home:
                HomeView(open: { go($0 == .learn ? .learn : .editor) }, importFile: { file in
                    switch file {
                    case .verilog(let text):
                        editor.load(text)
                        go(.editor)
                    case .waveform(let data):
                        imported = data
                        go(.waveform)
                    }
                })
                .transition(.opacity)
            }
        }
        .tint(Theme.accent)
        .fitsScreen()
    }

    private func go(_ next: Screen) {
        withAnimation(.easeInOut(duration: 0.25)) { screen = next }
    }
}

/// Chip on the left, code on the right, with a draggable divider between them.
struct Workspace: View {
    @ObservedObject var model: AppModel
    let goHome: () -> Void

    /// The code pane's share of the screen along the split axis.
    @State private var share: CGFloat = 0.42
    @State private var shareAtDragStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            let total = wide ? geo.size.width : geo.size.height
            let minimum: CGFloat = wide ? 320 : 260
            let extent = min(max(total * share, minimum), max(total - minimum, minimum))
            if wide {
                HStack(spacing: 0) {
                    ChipPane(model: model)
                    handle(wide: true, total: total)
                    EditorPane(model: model, goHome: goHome).frame(width: extent)
                }
            } else {
                VStack(spacing: 0) {
                    ChipPane(model: model)
                    handle(wide: false, total: total)
                    EditorPane(model: model, goHome: goHome).frame(height: extent)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func handle(wide: Bool, total: CGFloat) -> some View {
        let dragging = shareAtDragStart != nil
        return ZStack {
            Rectangle().fill(Theme.panel)
            Capsule()
                .fill(Color.white.opacity(dragging ? 0.7 : 0.28))
                .frame(width: wide ? 4 : 44, height: wide ? 44 : 4)
        }
        .frame(width: wide ? 14 : nil, height: wide ? nil : 14)
        .contentShape(Rectangle().inset(by: -8))
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    let start = shareAtDragStart ?? share
                    shareAtDragStart = start
                    let moved = wide ? drag.translation.width : drag.translation.height
                    share = min(max(start - moved / total, 0.2), 0.8)
                }
                .onEnded { _ in shareAtDragStart = nil }
        )
        .ignoresSafeArea()
        .accessibilityLabel("Resize code pane")
    }
}

// MARK: - Right: lesson and code

struct EditorPane: View {
    @ObservedObject var model: AppModel
    let goHome: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.mode == .learn { lessonCard }
            Rectangle().fill(Theme.stroke).uiFrame(height: 1)
            CodeEditor(text: $model.source, errorLine: model.error?.line, focusLine: model.focusLine)
            statusBar
        }
        .background(Theme.panel.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: goHome) {
                Image(systemName: "chevron.left")
                    .uiFont(15, weight: .semibold)
                    .foregroundStyle(Theme.text)
                    .uiFrame(width: 34, height: 34)
                    .background(Theme.raised, in: Circle())
            }
            .accessibilityLabel("Home")
            Text(model.mode == .learn ? "Learn" : "Editor")
                .uiFont(17, weight: .semibold)
                .foregroundStyle(Theme.text)
            Spacer()
            Menu {
                if model.mode == .learn {
                    ForEach(model.lessons) { lesson in
                        Button {
                            model.open(lesson.id)
                        } label: {
                            Label("\(lesson.id + 1). \(lesson.title)",
                                  systemImage: model.completed.contains(lesson.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } else {
                    Button("Blank module") { model.load(AppModel.blank.starter) }
                    Divider()
                    ForEach(Examples.all, id: \.title) { example in
                        Button(example.title) { model.load(example.source) }
                    }
                    Divider()
                    ForEach(Lessons.all.filter { $0.expected != nil }) { example in
                        Button(example.title) { model.load(example.solution) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.mode == .learn ? "Lesson \(model.lessonIndex + 1) of \(model.lessons.count)" : "Examples")
                    Image(systemName: "chevron.down").uiFont(11, weight: .bold)
                }
                .uiFont(14, weight: .medium)
                .foregroundStyle(Theme.dim)
                .uiPadding(.horizontal, 12)
                .uiFrame(height: 34)
                .background(Theme.raised, in: Capsule())
            }
        }
        .uiPadding(.horizontal, 20)
        .uiPadding(.top, 14)
        .padding(.bottom, model.mode == .learn ? 10 : 14)
    }

    private var lessonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.lesson.title)
                .uiFont(26, weight: .bold)
                .foregroundStyle(Theme.text)
            Text(markdown(model.lesson.concept))
                .uiFont(15)
                .foregroundStyle(Theme.dim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "scope")
                    .uiFont(13, weight: .semibold)
                    .foregroundStyle(Theme.accent)
                Text(markdown(model.lesson.goal))
                    .uiFont(15, weight: .medium)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .uiPadding(.all, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if model.showHint {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "lightbulb")
                        .uiFont(13, weight: .semibold)
                        .foregroundStyle(Theme.dim)
                    Text(markdown(model.lesson.hint))
                        .uiFont(14)
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .uiPadding(.horizontal, 12)
                .transition(.opacity)
            }
        }
        .uiPadding(.horizontal, 20)
        .uiPadding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .uiFrame(width: 8, height: 8)
            Text(statusText)
                .uiFont(13, weight: .medium)
                .foregroundStyle(model.error == nil ? Theme.dim : Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if model.mode == .learn {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { model.showHint.toggle() }
                } label: {
                    Label("Hint", systemImage: "lightbulb")
                }
            }
            Button {
                model.resetLesson()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
        }
        .labelStyle(.iconOnly)
        .uiFont(15, weight: .medium)
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(Theme.dim)
        .uiPadding(.horizontal, 20)
        .uiFrame(minHeight: 56)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).uiFrame(height: 1) }
    }

    private var statusColor: Color {
        if model.error != nil { return Theme.bad }
        return model.verdict == .passing ? Theme.good : Theme.faint
    }

    private var statusText: String {
        if let error = model.error { return "Line \(error.line): \(error.message)" }
        guard let net = model.netlist else { return "" }
        let cells = net.gates.count == 1 ? "1 cell" : "\(net.gates.count) cells"
        return "Synthesized · \(cells) · \(net.depth) deep" + (net.isSequential ? " · clocked" : "")
    }

    private func markdown(_ string: String) -> AttributedString {
        var out = (try? AttributedString(markdown: string)) ?? AttributedString(string)
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].font = .system(size: 14, design: .monospaced)
            out[run.range].foregroundColor = Theme.text
        }
        return out
    }
}

// MARK: - Left: the chip and its tools

struct ChipPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ZStack {
                    canvas
                        .opacity(model.error == nil ? 1 : 0.45)
                        .animation(.easeOut(duration: 0.2), value: model.error == nil)
                    VStack(spacing: 0) {
                        header
                        Spacer(minLength: 0)
                        controls
                    }
                    .uiPadding(.horizontal, 20)
                    .uiPadding(.vertical, 14)
                }
                Rectangle().fill(Theme.stroke).uiFrame(height: 1)
                Dock(model: model)
                    .frame(height: min(max(geo.size.height * 0.42, 220), 380))
            }
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private var canvas: some View {
        switch model.mainView {
        case .chip:
            ChipView(layout: model.layout, version: model.layoutVersion, signals: model.signals,
                     highlight: model.highlight, onToggle: { model.toggle($0) }, onSelect: { model.select($0) })
        case .schematic:
            SchematicView(model: model).uiPadding(.top, 84).uiPadding(.bottom, 56)
        case .layout:
            LayoutView(model: model).uiPadding(.top, 84).uiPadding(.bottom, 56)
        case .wafer:
            WaferView(model: model).uiPadding(.top, 84).uiPadding(.horizontal, 20).uiPadding(.bottom, 14)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Chip")
                Text(model.netlist?.name ?? "No design yet")
                    .uiFont(20, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Theme.text)
                if model.error != nil {
                    Text("Showing your last working design")
                        .uiFont(13)
                        .foregroundStyle(Theme.faint)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Segmented(selection: $model.mainView)
                verdictBadge
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.mainView {
        case .chip:
            HStack(spacing: 10) {
                if model.highlight != nil {
                    Button("Clear highlight") {
                        model.overlay = .none
                        model.select(nil)
                    }
                    .uiFont(13, weight: .medium)
                    .foregroundStyle(Theme.text)
                    .uiPadding(.horizontal, 12)
                    .uiFrame(height: 38)
                    .background(Theme.raised, in: Capsule())
                } else {
                    Text("Drag to orbit · pinch to zoom · tap a cell to trace it")
                        .uiFont(13)
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
        case .schematic:
            SchematicControls(model: model)
        case .layout:
            LayoutControls(model: model)
        case .wafer:
            EmptyView()     // the wafer view carries its own controls
        }
    }

    @ViewBuilder
    private var verdictBadge: some View {
        switch model.verdict {
        case .passing:
            HStack(spacing: 10) {
                Label("Verified", systemImage: "checkmark.seal.fill")
                    .uiFont(14, weight: .semibold)
                    .foregroundStyle(Theme.good)
                    .uiPadding(.horizontal, 12)
                    .uiFrame(height: 38)
                    .background(Theme.raised, in: Capsule())
                if model.hasNext {
                    Button {
                        model.open(model.lessonIndex + 1)
                    } label: {
                        Label("Next lesson", systemImage: "arrow.right")
                            .labelStyle(.titleAndIcon)
                            .uiFont(14, weight: .semibold)
                            .foregroundStyle(Color.black)
                            .uiPadding(.horizontal, 14)
                            .uiFrame(height: 38)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .transition(.opacity)
        case .failing(let wrong):
            badge("\(wrong) of \(model.truthRows.isEmpty ? "the" : "\(model.truthRows.count)") rows off")
        case .todo(let what):
            badge(what, symbol: "arrow.turn.down.right")
        case .portsChanged:
            badge("Keep the original ports")
        case .freeBuild, .broken:
            EmptyView()
        }
    }

    private func badge(_ text: String, symbol: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).uiFont(12, weight: .semibold) }
            Text(text)
        }
        .uiFont(14, weight: .medium)
        .foregroundStyle(Theme.dim)
        .uiPadding(.horizontal, 12)
        .uiFrame(height: 38)
        .background(Theme.raised, in: Capsule())
    }
}
