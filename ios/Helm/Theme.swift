import SwiftUI
import UIKit

// Design primitives ported from Beautiful UI (beautifului.dev, MIT): the token layer in
// app/globals.css plus its atoms. Colors are its OKLCH tokens converted to sRGB, themed for
// light and dark from the same source.

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    static func dynamic(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(UIColor { t in
            t.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: darkAlpha) : UIColor(hex: light, alpha: lightAlpha)
        })
    }
}

enum BUI {
    // surfaces — cool, blue-tinted neutrals
    static let page = Color.dynamic(0xFAFAFB, 0x17181A)
    static let canvas = Color.dynamic(0xF1F2F3, 0x1C1D1F)
    static let surface = Color.dynamic(0xFFFFFF, 0x232427)
    static let inset = Color.dynamic(0xF7F8F9, 0x1F2022)
    static let hover = Color.dynamic(0xF4F5F6, 0x2A2B2E)
    static let hover2 = Color.dynamic(0xE7E9EB, 0x313236)
    static let field = Color.dynamic(0xF2F2F3, 0x2B2C2F)

    // ink ramp
    static let ink = Color.dynamic(0x1F2124, 0xF2F3F4)
    static let ink2 = Color.dynamic(0x62656B, 0xA5A8AD)
    static let ink3 = Color.dynamic(0x9A9DA3, 0x6C6F75)

    // borders — solid and crisp, not alpha
    static let line = Color.dynamic(0xECEDEF, 0x2E3033)
    static let lineStrong = Color.dynamic(0xE0E2E5, 0x3A3C40)

    // one accent
    static let accent = Color.dynamic(0x0285FF, 0x3D9AFF)
    static let accentInk = Color.dynamic(0x0070DD, 0x7EC0FF)
    static let accentTint = Color.dynamic(0xE9F3FF, 0x3D9AFF, darkAlpha: 0.16)

    // semantic color, used sparingly
    static let green = Color.dynamic(0x199A4D, 0x3CBB72)
    static let greenTint = Color.dynamic(0xE8F5ED, 0x3CBB72, darkAlpha: 0.14)
    static let orange = Color.dynamic(0xEF720D, 0xF68F3C)
    static let orangeTint = Color.dynamic(0xFDF1E5, 0xF68F3C, darkAlpha: 0.14)
    static let red = Color.dynamic(0xE3474C, 0xEE5C61)
    static let redTint = Color.dynamic(0xFCECEC, 0xEE5C61, darkAlpha: 0.14)

    static let tooltipBg = Color.dynamic(0x25272B, 0x111214)
    static let tooltipFg = Color.dynamic(0xF6F7F8, 0xF2F3F4)

    /// chip 6 · control 8 · card 10 · window 14 · pill
    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 10
        static let window: CGFloat = 14
    }

    static let easeOutStrong = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.4)
    static let easeOutFast = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.25)
    static let easeInOutStrong = Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.4)
    static let easeLink = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.4)
    static let slide = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.36)
    static let press = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.15)
}

/// Older call sites speak in roles; they resolve to Beautiful UI tokens.
enum Theme {
    static let bg = BUI.page
    static let surface = BUI.surface
    static let surfaceHi = BUI.field
    static let stroke = BUI.line
    static let strokeHi = BUI.lineStrong
    static let text = BUI.ink
    static let text2 = BUI.ink2
    static let text3 = BUI.ink3
    /// the primary fill: ink, with canvas-colored content on top
    static let accent = BUI.ink
    static let running = BUI.accent
    static let waiting = BUI.orange
    static let error = BUI.red
    static let done = BUI.green
    static let sprite = BUI.accentInk

    static let ease = BUI.easeOutStrong
    static let easeFast = BUI.easeOutFast
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)

    static func statusColor(_ s: AgentStatus) -> Color {
        switch s {
        case .running, .starting: return BUI.accent
        case .waiting: return BUI.orange
        case .error: return BUI.red
        case .idle: return BUI.ink3
        }
    }
}

// MARK: - Type: Inter (tight tracking, tabular numerals) + JetBrains Mono

extension Font {
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let name: String
        switch weight {
        case .medium: name = "Inter-Medium"
        case .semibold: name = "Inter-SemiBold"
        case .bold, .heavy, .black: name = "Inter-Bold"
        default: name = "Inter-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }

    static func jbMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular || weight == .light ? "JetBrainsMono-Regular" : "JetBrainsMono-Medium", size: size, relativeTo: .body)
    }

    static let display = Font.inter(30, .semibold, relativeTo: .largeTitle)
    static let title2b = Font.inter(19, .semibold, relativeTo: .title2)
    static let mono = Font.jbMono(13)
    static let monoSmall = Font.jbMono(11.5)
}

extension View {
    /// Beautiful UI body tracking is -0.01em.
    func tight(_ size: CGFloat = 15) -> some View { tracking(-0.01 * size) }
}

// MARK: - Elevation: solid hairline ring + layered single-digit-opacity shadows

enum Elevation { case hairline, btn, card, raised, overlay }

private struct ElevationModifier<S: InsettableShape>: ViewModifier {
    var level: Elevation
    var shape: S

    func body(content: Content) -> some View {
        content
            .overlay(shape.strokeBorder(ring, lineWidth: 1))
            .shadow(color: Color.dynamic(0x000000, 0x000000, lightAlpha: near, darkAlpha: level == .hairline ? 0 : 0.22), radius: 1, y: 1)
            .shadow(color: Color.dynamic(0x000000, 0x000000, lightAlpha: far, darkAlpha: level == .hairline || level == .btn ? 0 : 0.24), radius: farRadius, y: farY)
    }

    private var ring: Color {
        switch level {
        case .hairline: return BUI.line
        case .btn: return Color.dynamic(0xE0E2E5, 0xFFFFFF, darkAlpha: 0.10)
        case .card: return Color.dynamic(0xECEDEF, 0xFFFFFF, darkAlpha: 0.11)
        case .raised: return Color.dynamic(0xECEDEF, 0xFFFFFF, darkAlpha: 0.13)
        case .overlay: return Color.dynamic(0xECEDEF, 0xFFFFFF, darkAlpha: 0.15)
        }
    }
    private var near: CGFloat { level == .hairline ? 0 : 0.04 }
    private var far: CGFloat {
        switch level {
        case .hairline, .btn: return 0
        case .card: return 0.04
        case .raised: return 0.06
        case .overlay: return 0.09
        }
    }
    private var farRadius: CGFloat {
        switch level {
        case .hairline, .btn: return 0
        case .card: return 4
        case .raised: return 8
        case .overlay: return 18
        }
    }
    private var farY: CGFloat {
        switch level {
        case .hairline, .btn: return 0
        case .card: return 2
        case .raised: return 4
        case .overlay: return 10
        }
    }
}

extension View {
    func elevation<S: InsettableShape>(_ level: Elevation, _ shape: S) -> some View {
        modifier(ElevationModifier(level: level, shape: shape))
    }

    func elevation(_ level: Elevation, radius: CGFloat = BUI.Radius.card) -> some View {
        modifier(ElevationModifier(level: level, shape: RoundedRectangle(cornerRadius: radius, style: .continuous)))
    }

    /// A white card on the cool canvas: surface fill, card elevation, 10pt corners.
    func card(padding: CGFloat = 12, radius: CGFloat = BUI.Radius.card, level: Elevation = .card) -> some View {
        self.padding(padding)
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .elevation(level, radius: radius)
    }
}

// MARK: - Motion

extension AnyTransition {
    /// fade-up: opacity 0 → 1, translateY 8 → 0
    static var fadeUp: AnyTransition { .opacity.combined(with: .offset(y: 8)) }
    /// pop-in: opacity 0 → 1, scale 0.95 → 1
    static var popIn: AnyTransition { .opacity.combined(with: .scale(scale: 0.95)) }
}

// MARK: - Buttons — pill-shaped, press scales to 0.96

struct BButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost, accent, success, quiet, danger }
    enum Size { case xs, sm, md, lg }

    var variant: Variant = .secondary
    var size: Size = .md
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, hPad)
            .frame(height: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(background(pressed: configuration.isPressed), in: Capsule())
            .overlay {
                if filled { Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center), lineWidth: 1) }
            }
            .modifier(SecondaryRing(active: variant == .secondary))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(BUI.press, value: configuration.isPressed)
    }

    private var filled: Bool { variant == .primary || variant == .accent || variant == .success || variant == .danger }

    private var font: Font {
        switch size {
        case .xs: return .inter(12)
        case .sm: return .inter(13, .medium)
        case .md: return .inter(14, .medium)
        case .lg: return .inter(16, .semibold)
        }
    }
    private var height: CGFloat {
        switch size {
        case .xs: return 28
        case .sm: return 30
        case .md: return 36
        case .lg: return 50
        }
    }
    private var hPad: CGFloat {
        switch size {
        case .xs: return 10
        case .sm: return 12
        case .md: return 16
        case .lg: return 20
        }
    }
    private var foreground: Color {
        switch variant {
        case .primary: return BUI.canvas
        case .accent, .success, .danger: return .white
        default: return BUI.ink
        }
    }
    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary: return BUI.ink.opacity(pressed ? 0.9 : 1)
        case .secondary: return pressed ? BUI.inset : BUI.surface
        case .ghost: return pressed ? BUI.lineStrong : BUI.hover2
        case .accent: return pressed ? BUI.accentInk : BUI.accent
        case .success: return BUI.green
        case .danger: return BUI.red
        case .quiet: return pressed ? BUI.hover : .clear
        }
    }
}

private struct SecondaryRing: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active { content.elevation(.btn, Capsule()) } else { content }
    }
}

extension ButtonStyle where Self == BButtonStyle {
    static func bui(_ variant: BButtonStyle.Variant = .secondary, _ size: BButtonStyle.Size = .md, fullWidth: Bool = false) -> BButtonStyle {
        BButtonStyle(variant: variant, size: size, fullWidth: fullWidth)
    }
}

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(BUI.press, value: configuration.isPressed)
    }
}

/// Full-width dark CTA (Beautiful UI `primary`, sized for thumbs).
struct PrimaryButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        BButtonStyle(variant: .primary, size: .lg, fullWidth: true).makeBody(configuration: configuration)
            .opacity(enabled ? 1 : 0.5)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BButtonStyle(variant: .secondary, size: .md).makeBody(configuration: configuration)
    }
}

/// primitive-icon-button: 28pt square, control radius, ink-3 → ink on press.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var tint: Color = BUI.ink3
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? BUI.ink : tint)
            .frame(width: size, height: size)
            .background(configuration.isPressed ? BUI.hover2 : .clear, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
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

    static func of(_ s: AgentStatus) -> Tone {
        switch s {
        case .running, .starting: return .accent
        case .waiting: return .orange
        case .error: return .red
        case .idle: return .neutral
        }
    }
}

struct StatusPill: View {
    var tone: Tone = .neutral
    var text: String
    var dot = true

    var body: some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(tone.dot).frame(width: 6, height: 6) }
            Text(text).contentTransition(.interpolate)
        }
        .font(.inter(12.5, .medium))
        .foregroundStyle(tone.fg)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(tone.bg, in: Capsule())
        .animation(BUI.easeOutStrong, value: text)
    }
}

/// Monospace token chip.
struct Chip: View {
    var text: String
    var tone: Tone = .neutral
    var body: some View {
        Text(text)
            .font(.jbMono(11.5))
            .foregroundStyle(tone.fg)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(tone.bg, in: RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
    }
}

/// Shimmering label: a bright band sweeps across ink-3 text while the agent works.
struct ShimmerText: View {
    var text: String
    var font: Font = .inter(13, .medium)
    var period: Double = 1.4

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let c = -0.5 + 2 * t
            Text(text)
                .font(font)
                .foregroundStyle(
                    LinearGradient(
                        stops: [.init(color: BUI.ink3, location: 0.35), .init(color: BUI.ink, location: 0.5), .init(color: BUI.ink3, location: 0.65)],
                        startPoint: UnitPoint(x: c - 1, y: 0.5),
                        endPoint: UnitPoint(x: c + 1, y: 0.5)
                    )
                )
        }
        .accessibilityLabel(text)
    }
}

/// Beautiful UI's four-point sparkle glyph.
struct Sparkle: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var path = Path()
        path.move(to: p(12, 2))
        path.addLine(to: p(14.4, 9.2)); path.addLine(to: p(22, 12)); path.addLine(to: p(14.4, 14.8))
        path.addLine(to: p(12, 22)); path.addLine(to: p(9.6, 14.8)); path.addLine(to: p(2, 12)); path.addLine(to: p(9.6, 9.2))
        path.closeSubpath()
        return path
    }
}

/// Pixel-grid loader: a chevron wavefront drives right across a 3×3 grid.
struct PixelLoader: View {
    enum Pattern { case drive, dots, orbit }
    var pattern: Pattern = .drive
    var cell: CGFloat = 4.5
    var color: Color = BUI.ink

    private var delays: [Double?] {
        switch pattern {
        case .drive, .dots:
            return (0..<9).map { (i: Int) -> Double? in
                let step: Int = (i % 3) + abs(i / 3 - 1)
                return Double(step) * 90
            }
        case .orbit:
            let order = [0, 1, 2, 5, 8, 7, 6, 3]
            return (0..<9).map { i in order.firstIndex(of: i).map { Double($0) * 110 } }
        }
    }
    private var duration: Double { pattern == .orbit ? 950 : 650 }

    var body: some View {
        TimelineView(.animation) { ctx in
            let ms = ctx.date.timeIntervalSinceReferenceDate * 1000
            let ds = delays
            Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
                ForEach(0..<3, id: \.self) { r in
                    GridRow {
                        ForEach(0..<3, id: \.self) { c in
                            let d = ds[r * 3 + c]
                            RoundedRectangle(cornerRadius: pattern == .dots ? cell / 2 : 1, style: .continuous)
                                .fill(color)
                                .frame(width: cell, height: cell)
                                .opacity(opacity(ms: ms, delay: d))
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func opacity(ms: Double, delay: Double?) -> Double {
        guard let delay else { return 0.07 }
        let phase = (ms - delay).truncatingRemainder(dividingBy: duration)
        return Self.pixelOn((phase + duration).truncatingRemainder(dividingBy: duration) / duration)
    }

    /// keyframes pixel-on: 0%,100% → .15 · 18%–42% → 1 · 62% → .15, ease-in-out between
    static func pixelOn(_ t: Double) -> Double {
        func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
        if t < 0.18 { return 0.15 + 0.85 * ease(t / 0.18) }
        if t < 0.42 { return 1 }
        if t < 0.62 { return 1 - 0.85 * ease((t - 0.42) / 0.2) }
        return 0.15
    }
}

/// LoadingState: pixel grid + shimmering label + live elapsed timer in mono tabular figures.
struct LoadingState: View {
    var label: String
    var since: Date?
    var pattern: PixelLoader.Pattern = .drive

    var body: some View {
        HStack(spacing: 10) {
            PixelLoader(pattern: pattern)
            ShimmerText(text: label)
            if let since {
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    Text(Self.elapsed(ctx.date.timeIntervalSince(since)))
                        .font(.jbMono(12))
                        .monospacedDigit()
                        .foregroundStyle(BUI.ink3)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func elapsed(_ s: TimeInterval) -> String {
        let t = max(0, s)
        if t < 60 { return String(format: "%.1fs", t) }
        if t < 3600 { return "\(Int(t) / 60)m \(String(format: "%.0f", t.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(t) / 3600)h \((Int(t) % 3600) / 60)m"
    }
}

/// Small 12pt spinner: line-strong ring with an ink-2 head.
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

/// TaskRows spinner ring: 24pt, line track, a 28% ink-3 arc sweeping while active.
struct SpinnerRing<Content: View>: View {
    var active: Bool
    var size: CGFloat = 24
    @ViewBuilder var content: Content
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(BUI.line, lineWidth: 2)
            if active {
                Circle().trim(from: 0, to: 0.28)
                    .stroke(BUI.ink3, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true } }
            }
            content.font(.inter(10.5, .semibold)).monospacedDigit().foregroundStyle(BUI.ink)
        }
        .frame(width: size, height: size)
    }
}

/// Filled round result badge (green check / red cross / orange hand).
struct ResultBadge: View {
    var tone: Tone
    var symbol: String
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tone.fg, in: Circle())
            .transition(.popIn)
    }
}

struct BSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? BUI.ink : BUI.lineStrong)
                    .frame(width: 40, height: 24)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 20, height: 20).padding(2)
                            .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    }
                    .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.2), value: configuration.isOn)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: configuration.isOn)
        }
    }
}

/// Equal-width segments with a sliding thumb.
struct BSegmented<T: Hashable>: View {
    var options: [(T, String)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.25)) { selection = value }
                } label: {
                    Text(label)
                        .font(.inter(13.5, .medium))
                        .foregroundStyle(selection == value ? BUI.ink : BUI.ink3)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background {
                            if selection == value {
                                Capsule().fill(BUI.surface).elevation(.hairline, Capsule())
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(BUI.line.opacity(0.6), in: Capsule())
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: - App-level pieces built on the atoms

struct StatusDot: View {
    var status: AgentStatus
    var size: CGFloat = 8
    @State private var breathe = false

    var body: some View {
        let color = Theme.statusColor(status)
        let active = status == .running || status == .starting || status == .waiting
        ZStack {
            if active {
                Circle()
                    .fill(color.opacity(0.3))
                    .frame(width: size * 2.2, height: size * 2.2)
                    .scaleEffect(breathe ? 1 : 0.45)
                    .opacity(breathe ? 0 : 0.9)
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear { if active { start() } }
        .onChange(of: active) { _, now in if now { start() } else { breathe = false } }
        .animation(Theme.ease, value: status)
    }

    private func start() {
        breathe = false
        withAnimation(.easeOut(duration: status == .waiting ? 1.0 : 1.6).repeatForever(autoreverses: false)) { breathe = true }
    }
}

struct HelmMark: View {
    var size: CGFloat = 28
    var color: Color = BUI.ink
    var body: some View {
        Canvas { ctx, sz in
            let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let r = sz.width * 0.30
            let lw = sz.width * 0.075
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color), lineWidth: lw)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - lw * 1.1, y: c.y - lw * 1.1, width: lw * 2.2, height: lw * 2.2)), with: .color(color))
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                var p = Path()
                p.move(to: CGPoint(x: c.x + cos(a) * lw * 1.6, y: c.y + sin(a) * lw * 1.6))
                p.addLine(to: CGPoint(x: c.x + cos(a) * sz.width * 0.47, y: c.y + sin(a) * sz.width * 0.47))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw * 0.85, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
    }
}

struct RuntimeBadge: View {
    var runtime: Runtime
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: runtime.isSprite ? "cloud" : "laptopcomputer")
                .font(.system(size: 9.5, weight: .semibold))
            Text(runtime.isSprite ? (runtime.sprite ?? "sprite") : "Laptop")
                .font(.inter(11.5, .medium))
                .lineLimit(1)
        }
        .foregroundStyle(runtime.isSprite ? BUI.accentInk : BUI.ink2)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(runtime.isSprite ? BUI.accentTint : BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
        .overlay {
            if !runtime.isSprite { RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous).strokeBorder(BUI.line) }
        }
    }
}

/// Section header: 13pt semibold ink with an optional count chip.
struct SectionLabel: View {
    var text: String
    var count: Int?
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.inter(13, .semibold)).foregroundStyle(BUI.ink)
            if let count {
                Text("\(count)")
                    .font(.inter(11.5, .medium))
                    .monospacedDigit()
                    .foregroundStyle(BUI.ink2)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
                    .elevation(.hairline, radius: BUI.Radius.chip)
                    .contentTransition(.numericText())
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }
}

/// Every sheet gets a title and a dismiss action.
struct SheetHeader: View {
    var title: String
    var subtitle: String?
    var onClose: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2b).tracking(-0.3).foregroundStyle(BUI.ink)
                if let subtitle { Text(subtitle).font(.inter(13)).foregroundStyle(BUI.ink2) }
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(size: 32))
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }
}

struct FieldStyle: ViewModifier {
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content
            .font(.inter(15))
            .foregroundStyle(BUI.ink)
            .focused($focused)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.control + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BUI.Radius.control + 2, style: .continuous).strokeBorder(focused ? BUI.lineStrong : BUI.line))
            .shadow(color: .black.opacity(0.035), radius: 1, y: 1)
            .animation(BUI.easeOutFast, value: focused)
    }
}

extension View {
    func field() -> some View { modifier(FieldStyle()) }
}

func relativeTime(_ ms: Double) -> String {
    let d = Date(timeIntervalSince1970: ms / 1000)
    let s = -d.timeIntervalSinceNow
    if s < 45 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    if s < 86400 * 7 { return "\(Int(s / 86400))d" }
    return d.formatted(.dateTime.month(.abbreviated).day())
}
