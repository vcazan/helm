import SwiftUI
import AppKit

// The iPhone app's Beautiful UI tokens (ios/Helm/Theme.swift), resolved against macOS appearances.

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

enum BUI {
    static let page = Color.dynamic(0xFAFAFB, 0x17181A)
    static let canvas = Color.dynamic(0xF1F2F3, 0x1C1D1F)
    static let surface = Color.dynamic(0xFFFFFF, 0x232427)
    static let inset = Color.dynamic(0xF7F8F9, 0x1F2022)
    static let hover = Color.dynamic(0xF4F5F6, 0x2A2B2E)
    static let hover2 = Color.dynamic(0xE7E9EB, 0x313236)
    static let field = Color.dynamic(0xF2F2F3, 0x2B2C2F)

    static let ink = Color.dynamic(0x1F2124, 0xF2F3F4)
    static let ink2 = Color.dynamic(0x62656B, 0xA5A8AD)
    static let ink3 = Color.dynamic(0x9A9DA3, 0x6C6F75)

    static let line = Color.dynamic(0xECEDEF, 0x2E3033)
    static let lineStrong = Color.dynamic(0xE0E2E5, 0x3A3C40)

    static let accent = Color.dynamic(0x0285FF, 0x3D9AFF)
    static let accentInk = Color.dynamic(0x0070DD, 0x7EC0FF)
    static let accentTint = Color.dynamic(0xE9F3FF, 0x3D9AFF, darkAlpha: 0.16)

    static let green = Color.dynamic(0x199A4D, 0x3CBB72)
    static let greenTint = Color.dynamic(0xE8F5ED, 0x3CBB72, darkAlpha: 0.14)
    static let orange = Color.dynamic(0xEF720D, 0xF68F3C)
    static let orangeTint = Color.dynamic(0xFDF1E5, 0xF68F3C, darkAlpha: 0.14)
    static let red = Color.dynamic(0xE3474C, 0xEE5C61)
    static let redTint = Color.dynamic(0xFCECEC, 0xEE5C61, darkAlpha: 0.14)

    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 10
        static let window: CGFloat = 14
    }

    static let enter = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.4)
    static let enterFast = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.25)
    static let exit = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.2)
    static let press = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.15)
}

extension Font {
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium: name = "Inter-Medium"
        case .semibold: name = "Inter-SemiBold"
        case .bold, .heavy, .black: name = "Inter-Bold"
        default: name = "Inter-Regular"
        }
        return .custom(name, size: size)
    }

    static func jbMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "JetBrainsMono-Regular" : "JetBrainsMono-Medium", size: size)
    }
}

// MARK: - Elevation

enum Elevation { case hairline, btn, card, raised }

extension View {
    func elevation(_ level: Elevation, radius: CGFloat = BUI.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let ring: Color = switch level {
        case .hairline: BUI.line
        case .btn: Color.dynamic(0xE0E2E5, 0xFFFFFF, darkAlpha: 0.10)
        case .card: Color.dynamic(0xECEDEF, 0xFFFFFF, darkAlpha: 0.11)
        case .raised: Color.dynamic(0xECEDEF, 0xFFFFFF, darkAlpha: 0.13)
        }
        let far: CGFloat = level == .raised ? 0.07 : level == .card ? 0.04 : 0
        return self
            .overlay(shape.strokeBorder(ring, lineWidth: 1))
            .shadow(color: .black.opacity(level == .hairline ? 0 : 0.04), radius: 1, y: 1)
            .shadow(color: .black.opacity(far), radius: level == .raised ? 10 : 4, y: level == .raised ? 4 : 2)
    }

    func card(padding: CGFloat = 12, radius: CGFloat = BUI.Radius.card, level: Elevation = .card) -> some View {
        self.padding(padding)
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .elevation(level, radius: radius)
    }
}

extension AnyTransition {
    static var fadeUp: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)).animation(BUI.enter),
                    removal: .opacity.combined(with: .offset(y: -4)).animation(BUI.exit))
    }
    static var popIn: AnyTransition { .opacity.combined(with: .scale(scale: 0.92)) }
    static func step(_ direction: Int) -> AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(x: CGFloat(direction) * 28)),
                    removal: .opacity.combined(with: .offset(x: CGFloat(-direction) * 28)))
    }
}

// MARK: - Buttons — pill-shaped, press scales to 0.96

struct BButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost, accent, quiet }
    enum Size { case sm, md, lg }

    var variant: Variant = .secondary
    var size: Size = .md
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .lg ? .inter(14, .semibold) : size == .md ? .inter(13, .medium) : .inter(12, .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .lg ? 18 : size == .md ? 14 : 10)
            .frame(height: size == .lg ? 40 : size == .md ? 30 : 26)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background(pressed: configuration.isPressed), in: Capsule())
            .overlay {
                if variant == .primary || variant == .accent {
                    Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
            }
            .overlay { if variant == .secondary { Capsule().strokeBorder(BUI.lineStrong, lineWidth: 1) } }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { h in withAnimation(BUI.press) { hovering = h } }
            .animation(BUI.press, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .primary: return BUI.canvas
        case .accent: return .white
        default: return BUI.ink
        }
    }

    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary: return BUI.ink.opacity(pressed ? 0.85 : hovering ? 0.92 : 1)
        case .accent: return pressed ? BUI.accentInk : BUI.accent.opacity(hovering ? 0.92 : 1)
        case .secondary: return pressed ? BUI.inset : hovering ? BUI.hover : BUI.surface
        case .ghost: return pressed ? BUI.lineStrong : hovering ? BUI.hover2 : BUI.hover
        case .quiet: return pressed ? BUI.hover2 : hovering ? BUI.hover : .clear
        }
    }
}

extension ButtonStyle where Self == BButtonStyle {
    static func bui(_ variant: BButtonStyle.Variant = .secondary, _ size: BButtonStyle.Size = .md, fullWidth: Bool = false) -> BButtonStyle {
        BButtonStyle(variant: variant, size: size, fullWidth: fullWidth)
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hovering || configuration.isPressed ? BUI.ink : BUI.ink3)
            .frame(width: size, height: size)
            .background(configuration.isPressed ? BUI.hover2 : hovering ? BUI.hover : .clear, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .onHover { h in withAnimation(BUI.press) { hovering = h } }
            .animation(BUI.press, value: configuration.isPressed)
    }
}

// MARK: - Atoms

enum Tone {
    case green, orange, red, accent, neutral

    var fg: Color {
        switch self {
        case .green: return BUI.green
        case .orange: return BUI.orange
        case .red: return BUI.red
        case .accent: return BUI.accentInk
        case .neutral: return BUI.ink2
        }
    }
    var bg: Color {
        switch self {
        case .green: return BUI.greenTint
        case .orange: return BUI.orangeTint
        case .red: return BUI.redTint
        case .accent: return BUI.accentTint
        case .neutral: return BUI.inset
        }
    }
    var dot: Color {
        switch self {
        case .accent: return BUI.accent
        case .neutral: return BUI.ink3
        default: return fg
        }
    }
}

/// A status dot that breathes while something is in progress.
struct PulseDot: View {
    var tone: Tone
    var pulsing = false
    var size: CGFloat = 7
    @State private var breathe = false

    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(tone.dot.opacity(0.35))
                    .frame(width: size * 2.4, height: size * 2.4)
                    .scaleEffect(breathe ? 1 : 0.4)
                    .opacity(breathe ? 0 : 0.9)
            }
            Circle().fill(tone.dot).frame(width: size, height: size)
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .animation(BUI.enter, value: tone.dot.description)
        .onAppear { start() }
        .onChange(of: pulsing) { _, _ in start() }
    }

    private func start() {
        breathe = false
        guard pulsing else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { breathe = true }
    }
}

struct StatusPill: View {
    var tone: Tone
    var text: String
    var pulsing = false

    var body: some View {
        HStack(spacing: 2) {
            PulseDot(tone: tone, pulsing: pulsing, size: 6)
            Text(text).contentTransition(.interpolate)
        }
        .font(.inter(12, .medium))
        .foregroundStyle(tone.fg)
        .padding(.leading, 3)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background(tone.bg, in: Capsule())
        .animation(BUI.enter, value: text)
    }
}

/// Filled round result badge.
struct ResultBadge: View {
    var tone: Tone
    var symbol: String
    var size: CGFloat = 20
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tone.fg, in: Circle())
    }
}

/// Small spinner: line-strong ring with an ink-2 head.
struct MiniSpinner: View {
    var size: CGFloat = 12
    @State private var spin = false
    var body: some View {
        Circle()
            .stroke(BUI.lineStrong, lineWidth: 1.5)
            .overlay(Circle().trim(from: 0, to: 0.25).stroke(BUI.ink2, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).rotationEffect(.degrees(spin ? 360 : 0)))
            .frame(width: size, height: size)
            .onAppear { withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) { spin = true } }
    }
}

/// The ship's-wheel mark from the iPhone app.
struct HelmMark: View {
    var size: CGFloat = 28
    var color: Color = BUI.ink
    var body: some View {
        Canvas { ctx, sz in
            for (path, style) in HelmMarkPaths.make(in: CGRect(origin: .zero, size: sz)) {
                switch style {
                case .stroke(let w): ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round))
                case .fill: ctx.fill(path, with: .color(color))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum HelmMarkPaths {
    enum Style { case stroke(CGFloat), fill }

    static func make(in rect: CGRect) -> [(Path, Style)] {
        let w = rect.width
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = w * 0.30
        let lw = w * 0.075
        var out: [(Path, Style)] = [
            (Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), .stroke(lw)),
            (Path(ellipseIn: CGRect(x: c.x - lw * 1.1, y: c.y - lw * 1.1, width: lw * 2.2, height: lw * 2.2)), .fill),
        ]
        for i in 0..<8 {
            let a = Double(i) * .pi / 4
            var p = Path()
            p.move(to: CGPoint(x: c.x + cos(a) * lw * 1.6, y: c.y + sin(a) * lw * 1.6))
            p.addLine(to: CGPoint(x: c.x + cos(a) * w * 0.47, y: c.y + sin(a) * w * 0.47))
            out.append((p, .stroke(lw * 0.85)))
        }
        return out
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.inter(10.5, .semibold))
            .tracking(0.6)
            .foregroundStyle(BUI.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FieldStyle: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.inter(13))
            .foregroundStyle(BUI.ink)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous).strokeBorder(focused ? BUI.accent.opacity(0.6) : BUI.lineStrong))
            .animation(BUI.enterFast, value: focused)
    }
}

extension View {
    func field() -> some View { modifier(FieldStyle()) }
}
