import SwiftUI
import UniformTypeIdentifiers

/// Something brought in from the Files app.
enum ImportedFile {
    case verilog(String)
    case waveform(WaveData)

    /// Reads a Verilog source file or a VCD waveform dump.
    static func read(_ url: URL) throws -> ImportedFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= 8_000_000 else { throw VCD.ParseError(message: "That file is larger than 8 MB.") }
        let text = String(decoding: data, as: UTF8.self)
        let kind = url.pathExtension.lowercased()
        if kind == "vcd" || (kind != "v" && kind != "sv" && text.contains("$enddefinitions")) {
            return .waveform(try VCD.parse(text, title: url.lastPathComponent))
        }
        if ["v", "sv", "vh", "svh"].contains(kind) || text.contains("endmodule") {
            return .verilog(text)
        }
        throw VCD.ParseError(message: "Tapeout opens Verilog source (.v, .sv) and waveform dumps (.vcd).")
    }
}

/// The first screen: pick guided lessons or the open editor, or bring in a file.
struct HomeView: View {
    let open: (Mode) -> Void
    let importFile: (ImportedFile) -> Void

    @State private var picking = false
    @State private var problem: String?

    var body: some View {
        ZStack {
            // A soft gray falloff gives the glass something to bend.
            RadialGradient(colors: [Color(hex: 0x2A2A2A), .black], center: .center, startRadius: 0, endRadius: 520)
                .ignoresSafeArea()

            VStack(spacing: 40) {
                VStack(spacing: 8) {
                    Text("Tapeout")
                        .uiFont(40, weight: .bold)
                        .foregroundStyle(Theme.text)
                    Text("Write Verilog. Watch the chip take shape.")
                        .uiFont(17)
                        .foregroundStyle(Theme.dim)
                }
                HStack(alignment: .top, spacing: 36) {
                    tile("Learn", caption: "Guided lessons, one gate at a time", symbol: "graduationcap", mode: .learn)
                    tile("Editor", caption: "An open bench for your own designs", symbol: "chevron.left.forwardslash.chevron.right", mode: .editor)
                }
                VStack(spacing: 8) {
                    Button {
                        picking = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .uiFont(16, weight: .semibold)
                            .foregroundStyle(Theme.text)
                            .uiPadding(.horizontal, 22)
                            .uiFrame(height: 48)
                            .contentShape(Capsule())
                            .glass(cornerRadius: 24, interactive: true)
                    }
                    .buttonStyle(.plain)
                    Text("Verilog source or a .vcd waveform")
                        .uiFont(13)
                        .foregroundStyle(Theme.faint)
                }
            }
            .uiPadding(.all, 32)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            do {
                importFile(try ImportedFile.read(try result.get()))
            } catch let error as VCD.ParseError {
                problem = error.message
            } catch {
                problem = "That file couldn't be opened."
            }
        }
        .alert("Couldn't import", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func tile(_ title: String, caption: String, symbol: String, mode: Mode) -> some View {
        Button {
            open(mode)
        } label: {
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .uiFont(54, weight: .light)
                    .foregroundStyle(Theme.text)
                    .uiFrame(width: 190, height: 190)
                    .contentShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                    .glass(cornerRadius: 44, interactive: true)
                VStack(spacing: 4) {
                    Text(title)
                        .uiFont(20, weight: .semibold)
                        .foregroundStyle(Theme.text)
                    Text(caption)
                        .uiFont(14)
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .uiFrame(width: 190)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(caption)")
    }
}

/// A full-screen viewer for an imported waveform file.
struct WaveformScreen: View {
    let data: WaveData
    let goHome: () -> Void

    @State private var radix: Radix = .hex
    @State private var cursor: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button(action: goHome) {
                    Image(systemName: "chevron.left")
                        .uiFont(15, weight: .semibold)
                        .foregroundStyle(Theme.text)
                        .uiFrame(width: 44, height: 44)
                        .background(Theme.raised, in: Circle())
                }
                .accessibilityLabel("Home")
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.title)
                        .uiFont(20, weight: .semibold, design: .monospaced)
                        .foregroundStyle(Theme.text)
                    Text("\(data.rows.count) signals" + (data.unit.isEmpty ? "" : " · timescale \(data.unit)"))
                        .uiFont(13)
                        .foregroundStyle(Theme.faint)
                }
            }
            WavesView(data: data, radix: $radix, cursor: cursor, onCursor: { cursor = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .uiPadding(.all, 20)
        .background(Theme.panel.ignoresSafeArea())
    }
}
