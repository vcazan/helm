import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

#if WIDGET_EXT
@main
#endif
struct HelmWidgets: WidgetBundle {
    var body: some Widget {
        HelmLiveActivity()
    }
}

private enum Palette {
    static let accent = Color(red: 0x3D / 255, green: 0x9A / 255, blue: 1)
    static let amber = Color(red: 0xF5 / 255, green: 0xA5 / 255, blue: 0x24 / 255)
}

private extension Font {
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .medium: "Inter-Medium"
        case .semibold: "Inter-SemiBold"
        case .bold: "Inter-Bold"
        default: "Inter-Regular"
        }
        return .custom(name, size: size)
    }
    static func mono(_ size: CGFloat) -> Font { .custom("JetBrainsMono-Medium", size: size) }
}

private typealias Row = HelmActivityAttributes.Row
private typealias State = HelmActivityAttributes.ContentState

struct HelmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HelmActivityAttributes.self) { ctx in
            ActivitySurface(state: ctx.state, stale: ctx.isStale)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { ctx in
            let s = ctx.state
            let lead = s.ask ?? s.busy.first
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        WheelMark(waiting: s.waiting > 0).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(lead?.name ?? "Helm").font(.inter(14, .semibold)).lineLimit(1)
                            Text(lead?.place ?? "").font(.inter(11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let lead { Elapsed(row: lead, size: 13).padding(.trailing, 4) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandBottom(state: s).padding(.horizontal, 4).padding(.top, 4)
                }
            } compactLeading: {
                WheelMark(waiting: s.waiting > 0).frame(width: 18, height: 18)
            } compactTrailing: {
                CompactTrailing(state: s)
            } minimal: {
                if s.waiting == 0, let w = s.busy.first?.wait {
                    ProgressView(timerInterval: w, countsDown: true) { EmptyView() } currentValueLabel: {
                        Image(systemName: "hourglass").font(.system(size: 9, weight: .bold))
                    }
                    .progressViewStyle(.circular)
                    .tint(Palette.accent)
                } else {
                    WheelMark(waiting: s.waiting > 0).frame(width: 16, height: 16)
                }
            }
            .widgetURL(lead?.url)
            .keylineTint(s.waiting > 0 ? Palette.amber : Palette.accent)
        }
        .supplementalActivityFamilies([.small, .medium])
    }
}

// MARK: - Surfaces

/// Picks the layout for where the activity is showing: lock screen, StandBy, Apple Watch or CarPlay.
private struct ActivitySurface: View {
    @Environment(\.activityFamily) private var family
    @Environment(\.isActivityFullscreen) private var fullscreen
    @Environment(\.levelOfDetail) private var detail
    var state: State
    var stale: Bool

    var body: some View {
        if family == .small {
            WristView(state: state)
        } else if fullscreen {
            StandByView(state: state, stale: stale)
        } else {
            LockScreenView(state: state, stale: stale, simplified: detail == .simplified)
        }
    }
}

private struct LockScreenView: View {
    var state: State
    var stale: Bool
    var simplified = false

    /// Header, padding and rows all have to fit the lock screen's 160pt, or iOS cuts the bottom off.
    private var dense: Bool { !simplified && state.busy.count > 2 }
    private var shown: [Row] { Array(state.busy.prefix(simplified ? 2 : 3)) }

    var body: some View {
        if let ask = state.ask {
            AskCard(row: ask, state: state, stale: stale, simplified: simplified)
                .padding(10)
        } else {
            VStack(alignment: .leading, spacing: dense ? 9 : 11) {
                Header(state: state, stale: stale, hidden: Array(state.busy.dropFirst(shown.count)), extra: max(0, state.working - shown.count))
                if state.rows.isEmpty {
                    Text("Nothing running. You're free.").font(.inter(13)).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: dense ? 7 : 9) {
                        ForEach(shown) { row in
                            Link(destination: row.url) {
                                if dense { DenseRow(row: row) } else { BusyRow(row: row, showPlace: !simplified) }
                            }
                            .tint(.primary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, dense ? 13 : 14)
        }
    }
}

/// StandBy: the phone on its side across the desk becomes a status board.
private struct StandByView: View {
    var state: State
    var stale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                WheelMark(waiting: state.waiting > 0).frame(width: 44, height: 44)
                Text(state.headline).font(.inter(22, .semibold)).lineLimit(2).contentTransition(.numericText())
                if stale { Text("Hub offline").font(.inter(13, .medium)).foregroundStyle(.tertiary) }
            }
            .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                if let ask = state.ask { AskCard(row: ask, simplified: false) }
                ForEach(state.busy.prefix(state.ask == nil ? 4 : 2)) { BusyRow(row: $0, showPlace: true) }
            }
        }
        .padding(20)
    }
}

/// Apple Watch Smart Stack and CarPlay: one thing, one tap.
private struct WristView: View {
    var state: State

    var body: some View {
        if let ask = state.ask {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    WheelMark(waiting: true).frame(width: 16, height: 16)
                    Text(ask.name).font(.inter(13, .semibold)).lineLimit(1)
                }
                Text(ask.detail ?? "Needs you").font(.inter(12)).foregroundStyle(.secondary).lineLimit(2)
                if ask.ask == "approve" {
                    HStack(spacing: 6) {
                        AnswerButton(row: ask, action: "approve", label: ask.approve ?? "Run", icon: "checkmark", prominent: true)
                        AnswerButton(row: ask, action: "reject", label: ask.reject ?? "Skip", icon: nil, prominent: false)
                    }
                } else if let o = ask.options?.first, ask.ask == "choose" {
                    AnswerButton(row: ask, action: "choose", label: o, icon: nil, prominent: true, option: o)
                }
            }
            .padding(10)
        } else {
            HStack(spacing: 10) {
                WheelMark(waiting: false).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.headline).font(.inter(13, .semibold)).lineLimit(1)
                    if let r = state.busy.first {
                        Text(r.detail ?? r.name).font(.mono(10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let w = state.busy.first?.wait {
                    Text(timerInterval: w, countsDown: true)
                        .font(.mono(13)).monospacedDigit().foregroundStyle(Palette.accent)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 56, alignment: .trailing)
                } else if let r = state.busy.first { Elapsed(row: r, size: 11.5) }
            }
            .padding(10)
        }
    }
}

// MARK: - Pieces

private struct Header: View {
    var state: State
    var stale: Bool
    var hidden: [Row] = []
    var extra = 0

    var body: some View {
        HStack(spacing: 8) {
            WheelMark(waiting: state.waiting > 0).frame(width: 20, height: 20)
            Text(state.waiting > 0 ? (state.waiting == 1 ? "Needs you" : "\(state.waiting) need you") : state.headline)
                .font(.inter(13.5, .semibold))
                .foregroundStyle(state.waiting > 0 ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(.secondary))
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            if stale {
                Label("Hub offline", systemImage: "wifi.slash").font(.inter(11.5, .medium)).foregroundStyle(.tertiary)
            } else if state.waiting > 0, state.working > 0 {
                HStack(spacing: 5) {
                    Circle().fill(Palette.accent).frame(width: 6, height: 6)
                    Text("\(state.working) working")
                }
                .font(.inter(11.5, .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(height: 22)
                .glassEffect(.regular, in: .capsule)
            } else if extra > 0 {
                MoreStack(rows: hidden, count: extra)
            }
        }
    }
}

/// The agents that didn't fit: their monograms fanned out, then the count.
private struct MoreStack: View {
    var rows: [Row]
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -6) {
                ForEach(rows.prefix(3)) { Monogram(row: $0, size: 18) }
            }
            Text("+\(count)").font(.mono(11.5)).foregroundStyle(.secondary).contentTransition(.numericText())
        }
        .padding(.leading, rows.isEmpty ? 8 : 3).padding(.trailing, 8).frame(height: 24)
        .glassEffect(.regular, in: .capsule)
    }
}

/// The thing waiting on you, answerable without unlocking.
private struct AskCard: View {
    var row: Row
    /// On the lock screen the card is the whole activity, so it carries the header too.
    var state: State? = nil
    var stale = false
    var simplified: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Link(destination: row.url) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        if state != nil { WheelMark(waiting: true).frame(width: 18, height: 18) }
                        Text(row.name).font(.inter(15, .semibold)).lineLimit(1)
                        if !simplified, state == nil { Text(row.place).font(.inter(12)).foregroundStyle(.tertiary).lineLimit(1) }
                        if let state, state.waiting > 1 {
                            Text("+\(state.waiting - 1)")
                                .font(.mono(11)).foregroundStyle(Palette.amber)
                                .padding(.horizontal, 6).frame(height: 18)
                                .background(Palette.amber.opacity(0.18), in: .capsule)
                        }
                        Spacer(minLength: 4)
                        if stale {
                            Image(systemName: "wifi.slash").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        } else if let state, state.working > 0 {
                            HStack(spacing: 4) {
                                Circle().fill(Palette.accent).frame(width: 5, height: 5)
                                Text("\(state.working) working")
                            }
                            .font(.inter(11, .medium)).foregroundStyle(.secondary)
                        } else {
                            Elapsed(row: row, size: 12)
                        }
                    }
                    Text(row.detail ?? "Waiting for you")
                        .font(row.ask == "approve" ? .mono(12.5) : .inter(13.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(simplified ? 1 : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tint(.primary)
            Answers(row: row, compact: simplified)
        }
        .padding(12)
        .glassEffect(.regular.tint(Palette.amber.opacity(0.16)), in: .rect(cornerRadius: 18))
    }
}

private struct Answers: View {
    var row: Row
    var compact: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if row.ask == "approve" {
                    AnswerButton(row: row, action: "approve", label: row.approve ?? "Run", icon: "checkmark", prominent: true)
                    AnswerButton(row: row, action: "reject", label: row.reject ?? "Skip", icon: compact ? "xmark" : nil, prominent: false)
                } else if row.ask == "choose", let options = row.options, !options.isEmpty {
                    ForEach(Array(options.prefix(compact ? 2 : 3).enumerated()), id: \.offset) { i, o in
                        AnswerButton(row: row, action: "choose", label: o, icon: nil, prominent: i == 0, option: o)
                    }
                } else {
                    Link(destination: row.url) {
                        Label("Answer in Helm", systemImage: "arrow.up.right")
                            .font(.inter(13, .semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.glass)
                    .foregroundStyle(Palette.amber)
                }
            }
        }
    }
}

private struct AnswerButton: View {
    var row: Row
    var action: String
    var label: String
    var icon: String?
    var prominent: Bool
    var option = ""

    var body: some View {
        let intent = HelmAnswerIntent(row: row.id, decision: row.decision, action: action, option: option)
        if prominent {
            Button(intent: intent) { content }
                .buttonStyle(.glassProminent)
                .tint(action == "choose" ? Palette.amber : Palette.accent)
        } else {
            Button(intent: intent) { content }
                .buttonStyle(.glass)
                .tint(.primary)
        }
    }

    private var content: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 11.5, weight: .bold)) }
            Text(label).lineLimit(1)
        }
        .font(.inter(13, .semibold))
        .frame(maxWidth: .infinity, minHeight: 34)
    }
}

/// An agent at work: who it is, what it's doing this second, and how long it's been going.
private struct BusyRow: View {
    var row: Row
    var showPlace: Bool

    var body: some View {
        if let w = row.wait { timerBody(w) } else { workBody }
    }

    private func timerBody(_ w: ClosedRange<Date>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 11) {
                Image(systemName: "hourglass")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.tint(Palette.accent.opacity(0.2)), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.inter(13.5, .semibold)).lineLimit(1)
                    Text(row.detail ?? "Waiting on a timer").font(.inter(12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(timerInterval: w, countsDown: true)
                    .font(.mono(17)).monospacedDigit()
                    .foregroundStyle(Palette.accent)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 76, alignment: .trailing)
            }
            ProgressView(timerInterval: w, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.linear)
                .tint(Palette.accent)
                .padding(.leading, 41)
        }
    }

    private var workBody: some View {
        HStack(spacing: 11) {
            Monogram(row: row)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.inter(13.5, .semibold)).lineLimit(1)
                    if showPlace { Text(row.place).font(.inter(11.5)).foregroundStyle(.tertiary).lineLimit(1) }
                }
                HStack(spacing: 6) {
                    Text(row.detail ?? "Working")
                        .font(.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    if let n = row.subagents, n > 0 {
                        Label("\(n)", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.inter(10.5, .semibold))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 6).frame(height: 17)
                            .glassEffect(.regular.tint(Palette.accent.opacity(0.2)), in: .capsule)
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 6)
            Elapsed(row: row, size: 12)
        }
    }
}

/// One line per agent, for when three of them share the lock screen.
private struct DenseRow: View {
    var row: Row

    var body: some View {
        HStack(spacing: 9) {
            if row.wait != nil {
                Image(systemName: "hourglass")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 24, height: 24)
                    .glassEffect(.regular.tint(Palette.accent.opacity(0.2)), in: .circle)
            } else {
                Monogram(row: row, size: 24)
            }
            NameThenDetail {
                Text(row.name).font(.inter(13, .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(row.detail ?? "Working")
                        .font(.mono(10.5)).foregroundStyle(.secondary).lineLimit(1)
                        .contentTransition(.opacity)
                    if let n = row.subagents, n > 0 {
                        Text("+\(n)").font(.mono(10)).foregroundStyle(Palette.accent).fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let w = row.wait {
                Text(timerInterval: w, countsDown: true)
                    .font(.mono(12.5)).monospacedDigit().foregroundStyle(Palette.accent)
                    .multilineTextAlignment(.trailing).frame(width: 46, alignment: .trailing)
                    .layoutPriority(2)
            } else {
                Elapsed(row: row, size: 11.5, fixed: true).layoutPriority(2)
            }
        }
        .frame(height: 24)
    }
}

/// Name and detail on one line: the name keeps its width but leaves the detail at least 40%.
private struct NameThenDetail: Layout {
    var gap: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (a, b) = widths(proposal.width, subviews)
        let h = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: a + gap + b, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (a, b) = widths(bounds.width, subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .init(width: a, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + a + gap, y: bounds.midY), anchor: .leading, proposal: .init(width: b, height: bounds.height))
    }

    private func widths(_ offered: CGFloat?, _ subviews: Subviews) -> (CGFloat, CGFloat) {
        let name = subviews[0].sizeThatFits(.unspecified).width
        let detail = subviews[1].sizeThatFits(.unspecified).width
        guard let total = offered.map({ $0 - gap }), name + detail > total else { return (name, detail) }
        let a = min(name, max(total * 0.6, total - detail))
        return (a, total - a)
    }
}

/// The workspace's initial on glass, ringed in the agent's state color.
private struct Monogram: View {
    var row: Row
    var size: CGFloat = 30

    var body: some View {
        let tint = row.waiting ? Palette.amber : Palette.accent
        Text(String(row.place.prefix(1)).uppercased())
            .font(.inter(size * 0.42, .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(tint.opacity(0.18)), in: .circle)
            .overlay(Circle().strokeBorder(tint.opacity(0.55), lineWidth: size < 24 ? 1 : 1.2))
    }
}

private struct Elapsed: View {
    var row: Row
    var size: CGFloat
    /// Timer text claims all the width it's offered; pin it so the name gets the rest.
    var fixed = false

    var body: some View {
        Text(row.start, style: .timer)
            .font(.mono(size)).monospacedDigit()
            .foregroundStyle(row.waiting ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(.tertiary))
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: fixed ? nil : size * 5, alignment: .trailing)
            .frame(width: fixed ? size * 3.9 : nil, alignment: .trailing)
    }
}

/// The expanded Dynamic Island; tightens up when iOS 27 gives it less width.
private struct IslandBottom: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var narrow
    var state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let ask = state.ask {
                Text(ask.detail ?? "Waiting for you")
                    .font(ask.ask == "approve" ? .mono(12) : .inter(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(narrow ? 1 : 2)
                Answers(row: ask, compact: narrow)
            } else {
                ForEach(state.busy.prefix(narrow ? 1 : 2)) { BusyRow(row: $0, showPlace: false) }
            }
            if state.ask != nil, state.working > 0, !narrow {
                Text(state.working == 1 ? "1 more working" : "\(state.working) more working")
                    .font(.inter(11.5)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactTrailing: View {
    var state: State

    var body: some View {
        if state.waiting > 0 {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.amber)
        } else if let w = state.busy.first?.wait {
            Text(timerInterval: w, countsDown: true)
                .font(.mono(12)).monospacedDigit()
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: 44)
        } else if state.working == 1, let r = state.busy.first {
            Text(r.start, style: .timer)
                .font(.mono(12)).monospacedDigit()
                .foregroundStyle(Palette.accent)
                .frame(maxWidth: 44)
        } else {
            Text("\(state.working)")
                .font(.mono(13)).foregroundStyle(Palette.accent)
                .contentTransition(.numericText())
        }
    }
}

/// The Helm wheel: amber while something waits on you, blue while agents work.
private struct WheelMark: View {
    var waiting: Bool
    var body: some View {
        let tint = waiting ? Palette.amber : Palette.accent
        ZStack {
            Circle().strokeBorder(tint, lineWidth: 2)
            ForEach(0..<4) { i in
                Capsule().fill(tint).frame(width: 2, height: 22).rotationEffect(.degrees(Double(i) * 45))
            }
            .mask(Circle().padding(-2))
            Circle().fill(tint).frame(width: 6, height: 6)
        }
        .scaleEffect(0.82)
        .shadow(color: tint.opacity(0.5), radius: 5)
    }
}

// MARK: - Samples

private extension HelmActivityAttributes.ContentState {
    static let now = Date().timeIntervalSince1970
    static let asking = Self(working: 2, waiting: 1, rows: [
        Row(id: "w:Handoff", name: "Checkout redesign", place: "storefront", state: "waiting", since: now - 95,
            detail: "pnpm prisma migrate deploy --schema apps/api", ask: "approve", approve: "Run", reject: "Skip"),
        Row(id: "w:Remote", name: "Offline sync", place: "mobile-app", state: "working", since: now - 1210,
            detail: "Editing SyncEngine.swift", subagents: 2),
    ])
    static let choosing = Self(working: 1, waiting: 1, rows: [
        Row(id: "a1", name: "Release agent", place: "storefront", state: "waiting", since: now - 30,
            detail: "Which environment should I deploy the fix to?", ask: "choose", options: ["Staging", "Production", "Both"], decision: "d1"),
        Row(id: "w:Remote", name: "Offline sync", place: "mobile-app", state: "working", since: now - 1210, detail: "Editing SyncEngine.swift"),
    ])
    static let busy = Self(working: 3, waiting: 0, rows: [
        Row(id: "w:Remote", name: "Offline sync", place: "mobile-app", state: "working", since: now - 1210,
            detail: "$ xcodebuild -scheme MobileApp build", subagents: 1),
        Row(id: "w:Docs", name: "API reference refresh", place: "docs-site", state: "working", since: now - 340,
            detail: "Waiting for “gateway done”", waitFrom: now - 70, waitUntil: now + 170),
        Row(id: "a2", name: "Search indexer", place: "storefront", state: "working", since: now - 64, detail: "Thinking"),
    ])
    static let crowd = Self(working: 5, waiting: 0, rows: [
        Row(id: "w:Remote", name: "Offline sync", place: "mobile-app", state: "working", since: now - 1210,
            detail: "$ xcodebuild -scheme MobileApp build", subagents: 2),
        Row(id: "w:Docs", name: "API reference refresh", place: "docs-site", state: "working", since: now - 340,
            detail: "Waiting for “gateway done”", waitFrom: now - 70, waitUntil: now + 170),
        Row(id: "a2", name: "Search indexer", place: "storefront", state: "working", since: now - 64, detail: "Thinking"),
        Row(id: "a3", name: "Invoice export", place: "payments-api", state: "working", since: now - 20, detail: "Reading invoices.ts"),
    ])
    static let askingCrowd = Self(working: 3, waiting: 1, rows: [
        asking.rows[0],
        busy.rows[0], busy.rows[1], busy.rows[2],
    ])
}

#if DEBUG && !WIDGET_EXT
/// The lock-screen and watch layouts with sample states, for design review inside the app.
struct LiveActivityGallery: View {
    var body: some View {
        VStack(spacing: 12) {
            LockScreenView(state: .askingCrowd, stale: false).lockBox()
            LockScreenView(state: .busy, stale: false).lockBox()
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 10) {
                WristView(state: .choosing).surface(radius: 20).frame(width: 190)
                WristView(state: .busy).surface(radius: 20)
            }
            LockScreenView(state: .crowd, stale: false).lockBox()
        }
        .padding(.horizontal, 10)
        .padding(.top, 54)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.62, green: 0.38, blue: 0.48), Color(red: 0.95, green: 0.62, blue: 0.42)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .environment(\.colorScheme, .dark)
    }
}

private extension View {
    /// The lock screen gives an activity at most 160pt and cuts off the rest.
    func lockBox() -> some View {
        frame(maxWidth: .infinity, maxHeight: 160, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) { Rectangle().fill(.red.opacity(0.5)).frame(height: 1).offset(y: 0.5) }
            .surface()
    }

    func surface(radius: CGFloat = 26) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: radius))
    }
}
#endif

#Preview("Lock screen", as: .content, using: HelmActivityAttributes(hub: "Helm")) {
    HelmLiveActivity()
} contentStates: {
    HelmActivityAttributes.ContentState.asking
    HelmActivityAttributes.ContentState.choosing
    HelmActivityAttributes.ContentState.busy
}
