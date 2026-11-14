import SwiftUI

/// Black and dark gray. White is the only highlight; red appears only on errors.
enum Theme {
    static let background = Color.black
    static let panel = Color(hex: 0x0F0F0F)
    static let raised = Color(hex: 0x1E1E1E)
    static let stroke = Color.white.opacity(0.09)
    static let accent = Color.white.opacity(0.94)
    static let good = Color.white.opacity(0.94)
    static let bad = Color(hex: 0xE5675A)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.32)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Small all-caps section label.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .uiFont(11, weight: .semibold)
            .tracking(1.2)
            .foregroundStyle(Theme.faint)
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later, a frosted material before that.
    @ViewBuilder
    func glass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.stroke))
        }
    }
}

// MARK: - Sizing for different screens

private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    /// How much larger or smaller than an 11-inch iPad the window is. Text, buttons and spacing follow it.
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

enum Sizing {
    /// 1.0 on an 11-inch iPad in full screen; smaller in Split View or on an iPad mini, larger on a 13-inch.
    static func scale(for size: CGSize) -> CGFloat {
        let area = max(size.width, 1) * max(size.height, 1)
        return min(max((area / (1194 * 834)).squareRoot(), 0.8), 1.3)
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat, weight: Font.Weight, design: Font.Design
    func body(content: Content) -> some View { content.font(.system(size: (size * scale).rounded(), weight: weight, design: design)) }
}

private struct ScaledFrame: ViewModifier {
    @Environment(\.uiScale) private var scale
    let width: CGFloat?, height: CGFloat?, minWidth: CGFloat?, minHeight: CGFloat?, alignment: Alignment
    func body(content: Content) -> some View {
        content
            .frame(width: width.map { $0 * scale }, height: height.map { $0 * scale }, alignment: alignment)
            .frame(minWidth: minWidth.map { $0 * scale }, minHeight: minHeight.map { $0 * scale }, alignment: alignment)
    }
}

private struct ScaledPadding: ViewModifier {
    @Environment(\.uiScale) private var scale
    let edges: Edge.Set, length: CGFloat
    func body(content: Content) -> some View { content.padding(edges, length * scale) }
}

private struct FitsScreen: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width, height: geo.size.height)
                .environment(\.uiScale, Sizing.scale(for: geo.size))
        }
    }
}

extension View {
    /// Measures the window and sets the scale everything inside it is drawn at.
    func fitsScreen() -> some View { modifier(FitsScreen()) }

    /// A system font whose size follows the screen.
    func uiFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }

    /// A fixed or minimum size that follows the screen.
    func uiFrame(width: CGFloat? = nil, height: CGFloat? = nil, minWidth: CGFloat? = nil, minHeight: CGFloat? = nil,
                 alignment: Alignment = .center) -> some View {
        modifier(ScaledFrame(width: width, height: height, minWidth: minWidth, minHeight: minHeight, alignment: alignment))
    }

    func uiPadding(_ edges: Edge.Set = .all, _ length: CGFloat) -> some View {
        modifier(ScaledPadding(edges: edges, length: length))
    }
}
