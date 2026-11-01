import SwiftUI

private struct SubagentsKey: EnvironmentKey {
    static let defaultValue: [String: Subagent] = [:]
}

extension EnvironmentValues {
    var subagents: [String: Subagent] {
        get { self[SubagentsKey.self] }
        set { self[SubagentsKey.self] = newValue }
    }
}

private extension Subagent {
    var started: Date? { startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
}

/// The Task call in a chat, shown as the subagent it spawned.
struct SubagentCard: View {
    @Environment(\.subagents) private var all
    var id: String
    var task: Item

    private var sub: Subagent? { all[id] }
    private var status: Subagent.Status { sub?.status ?? (task.tool?.status == "running" ? .running : .done) }
    private var running: Bool { status == .running }
    private var title: String { sub?.name ?? task.tool?.args?["description"]?.string ?? "Subagent" }
    private var brief: String? {
        let raw = task.tool?.args?["prompt"]?.string ?? sub?.brief
        return raw.map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
    }
    /// Cursor's live one-liner, unless it's just an echo of the brief.
    private var activity: String? {
        guard let a = sub?.activity, !a.isEmpty else { return nil }
        let stem = a.replacingOccurrences(of: "…", with: "")
        if let brief, brief.hasPrefix(stem) { return nil }
        return a
    }

    var body: some View {
        NavigationLink(value: Route.subagent(id, title)) {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.inter(15, .semibold)).tight(15)
                        .foregroundStyle(BUI.ink)
                        .lineLimit(2)
                    if let brief {
                        Text(brief)
                            .font(.inter(13.5)).tight(13.5).lineSpacing(1.5)
                            .foregroundStyle(BUI.ink2)
                            .lineLimit(2)
                    }
                    outcome
                }
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
            .elevation(.card, radius: BUI.Radius.card)
            .overlay(
                RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous)
                    .strokeBorder(BUI.accent.opacity(running ? 0.4 : 0), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
            .animation(BUI.easeOutStrong, value: status)
            .animation(BUI.easeOutStrong, value: sub?.activity)
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(sub?.type ?? "subagent"), \(sub?.label ?? "")")
        .accessibilityHint("Opens the subagent's conversation")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(running ? BUI.accentInk : BUI.ink2)
                .frame(width: 20, height: 20)
                .background(running ? BUI.accentTint : BUI.inset, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(sub?.type.map { "\($0.capitalized) subagent" } ?? "Subagent")
                .font(.inter(12.5, .medium)).foregroundStyle(BUI.ink2)
            Spacer(minLength: 8)
            statusPill
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .overlay(alignment: .bottom) {
            ZStack {
                Rectangle().fill(BUI.line)
                if running { SweepLine().transition(.opacity) }
            }
            .frame(height: 1)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            switch status {
            case .running:
                StatusDot(status: .running, size: 6).frame(width: 10, height: 10)
                Text("Working")
                if let since = sub?.startedAt.map({ Date(timeIntervalSince1970: $0 / 1000) }) {
                    Text(since, style: .timer).font(.jbMono(11, .medium)).monospacedDigit()
                }
            case .done:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("Done")
            case .stopped:
                Image(systemName: "stop.fill").font(.system(size: 7.5, weight: .bold))
                Text("Stopped")
            case .failed:
                Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold))
                Text("Failed")
            }
        }
        .font(.inter(12, .medium))
        .foregroundStyle(tone.fg)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(tone.bg, in: Capsule())
        .contentTransition(.opacity)
    }

    @ViewBuilder private var outcome: some View {
        if running {
            HStack(spacing: 8) {
                PixelLoader(pattern: .drive, cell: 3.5, color: BUI.accentInk)
                ShimmerText(text: activity ?? "Getting started", font: .jbMono(11.5))
                    .lineLimit(1)
                    .id(activity)
                    .transition(.asymmetric(insertion: .fadeUp, removal: .opacity))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            .padding(.top, 4)
            .transition(.fadeUp)
        } else if let result = sub?.result {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(tone.fg.opacity(0.5)).frame(width: 2)
                Text(result)
                    .font(.inter(13)).tight(13).lineSpacing(1.5)
                    .foregroundStyle(BUI.ink2)
                    .lineLimit(3)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            .transition(.fadeUp)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let steps = sub?.steps, steps > 0 {
                Text(steps == 1 ? "1 step" : "\(steps) steps").contentTransition(.numericText())
            }
            if !running, let took = took {
                Text("·").foregroundStyle(BUI.ink3)
                Text(took)
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                Text(running ? "Watch" : "Open")
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
            }
            .font(.inter(12.5, .medium))
            .foregroundStyle(BUI.accentInk)
        }
        .font(.inter(12))
        .foregroundStyle(BUI.ink3)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(BUI.inset.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(BUI.line).frame(height: 1) }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: BUI.Radius.card, bottomTrailingRadius: BUI.Radius.card, style: .continuous))
    }

    private var took: String? {
        guard let a = sub?.startedAt, let b = sub?.updatedAt, b > a else { return nil }
        let s = Int((b - a) / 1000)
        return s < 60 ? "\(max(s, 1))s" : String(format: "%dm %02ds", s / 60, s % 60)
    }

    private var tone: Tone {
        switch status {
        case .running: return .accent
        case .done: return .green
        case .failed: return .red
        case .stopped: return .neutral
        }
    }
}

#if DEBUG
/// Every card state on one screen, for design review in the simulator.
struct SubagentCardGallery: View {
    private static let now = Date().timeIntervalSince1970 * 1000
    private let subs: [Subagent] = [
        Subagent(id: "a", name: "Audit hub route list", type: "explore", status: .running, activity: "Read server.ts, cursorui.ts",
                 startedAt: now - 42_000, brief: "List every HTTP route registered in hub/src/server.ts with its method, path and a one-line description.", steps: 6),
        Subagent(id: "b", name: "Count hub source lines", type: "explore", status: .done, startedAt: now - 90_000, updatedAt: now - 25_000,
                 brief: "Read each .ts file in hub/src one at a time and report its approximate line count and a one-line purpose.", steps: 17,
                 result: "There are 13 .ts files in hub/src, about 3,350 lines in total. The largest are cursorui.ts (953 lines), agents.ts (654) and server.ts (391)."),
    ]

    private let waitItem: Item = {
        var it = Item(id: "w", ts: 0, kind: .tool)
        it.tool = ToolInfo(name: "wait", status: "running", meta: ToolMeta(waitSince: now - 70_000, waitUntil: now + 170_000, waitLabel: "Waiting for “gateway done”"))
        return it
    }()
    private let doneItem: Item = {
        var it = Item(id: "w2", ts: 0, kind: .tool)
        it.tool = ToolInfo(name: "wait", status: "completed", meta: ToolMeta(waitSince: now - 40_000, waitUntil: now - 28_000, waitLabel: "Demo timer for the countdown card"))
        return it
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    ForEach([waitItem, doneItem], id: \.id) { it in
                        if let r = it.tool?.meta?.waitRange { WaitCard(item: it, range: r) }
                    }
                }
                .padding(.top, 8)
                VStack(alignment: .leading, spacing: 16) {
                    QueuedStack(items: [
                        QueuedMessage(id: "q1", text: "After that, run the full test suite"),
                        QueuedMessage(id: "out-2", text: "More"),
                    ]) { _ in true } edit: { _, _ in true } remove: { _ in true }
                    DesktopItemView(item: Item(id: "out-1", ts: 0, kind: .user, text: "Can you rerun the migration on staging?"))
                    SendStatus(delivered: true)
                    WorkingTail(label: "Starting")
                }
                .padding(.top, 16)
                Spacer()
                SubagentCard(id: "a", task: Item(id: "a", ts: 0, kind: .tool)).padding(.bottom, 12)
                SubagentCard(id: "b", task: Item(id: "b", ts: 0, kind: .tool))
            }
            .padding(16)
            .environment(\.subagents, Dictionary(uniqueKeysWithValues: subs.map { ($0.id, $0) }))
            .background(BUI.page.ignoresSafeArea())
        }
    }
}
#endif

/// A band of accent light that travels along the card's header rule while the subagent works.
private struct SweepLine: View {
    @State private var phase = false

    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [BUI.accent.opacity(0), BUI.accent, BUI.accent.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: g.size.width * 0.35)
                .offset(x: phase ? g.size.width : -g.size.width * 0.35)
        }
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { phase = true }
        }
        .accessibilityHidden(true)
    }
}

struct SubagentGlyph: View {
    var status: AgentStatus

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(status == .running ? BUI.accentInk : BUI.ink2)
                .frame(width: 34, height: 34)
                .background(status == .running ? BUI.accentTint : BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
            StatusDot(status: status, size: 7)
                .background(Circle().fill(BUI.surface).frame(width: 11, height: 11))
                .offset(x: 6, y: 6)
        }
        .animation(BUI.easeOutStrong, value: status)
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(BUI.press, value: configuration.isPressed)
    }
}

/// One subagent's own conversation, read-only, live while it works.
struct SubagentView: View {
    @AppStorage("showThinking") private var showThinking = false
    @Environment(AppModel.self) private var model
    var id: String
    var name: String

    @State private var sub: Subagent?
    @State private var loadError: String?
    @State private var briefOpen = false

    private var running: Bool { sub?.status == .running }

    var body: some View {
        let items = sub?.items ?? []
        let brief = items.first { $0.kind == .user }
        let rest = items.filter { $0.id != brief?.id }
        let segments = ChatSegment.build(rest)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let sub {
                    header(sub)
                    if let brief { briefCard(brief.text ?? "") }
                    ForEach(Array(segments.enumerated()), id: \.element.id) { i, seg in
                        DesktopSegmentView(segment: seg, live: running && i == segments.count - 1)
                            .id(seg.id)
                            .transition(.asymmetric(insertion: .fadeUp, removal: .opacity))
                    }
                    if running {
                        LoadingState(label: sub.activity ?? "Working", since: sub.started)
                            .transition(.fadeUp)
                    } else {
                        finished(sub).transition(.fadeUp)
                    }
                } else if let loadError {
                    ContentUnavailableView("Couldn't open this subagent", systemImage: "exclamationmark.bubble", description: Text(loadError))
                        .foregroundStyle(BUI.ink2)
                        .padding(.top, 80)
                } else {
                    LoadingState(label: "Opening subagent", pattern: .orbit)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 100)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .animation(BUI.easeOutStrong, value: items.count)
            .animation(BUI.easeOutStrong, value: running)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .jumpToLatest()
        .background(BUI.page)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(sub?.name ?? name).font(.inter(15.5, .semibold)).tight(15.5).foregroundStyle(BUI.ink).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(Theme.statusColor(sub?.dot ?? .idle)).frame(width: 6, height: 6)
                        Text("Subagent · \(sub?.label ?? "…")")
                            .font(.inter(11.5)).foregroundStyle(BUI.ink2).contentTransition(.opacity)
                    }
                    .animation(BUI.easeOutStrong, value: sub?.status)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { ThinkingToggle() }
        }
        .task(id: id) { await poll() }
    }

    private func header(_ s: Subagent) -> some View {
        HStack(spacing: 12) {
            SubagentGlyph(status: s.dot)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.type.map { $0.capitalized } ?? "Subagent")
                    .font(.inter(13, .semibold)).foregroundStyle(BUI.ink)
                if let started = s.started {
                    Text("Started \(started.formatted(.relative(presentation: .named)))")
                        .font(.inter(12)).foregroundStyle(BUI.ink2)
                }
            }
            Spacer(minLength: 0)
            Text(s.label)
                .font(.inter(12, .medium))
                .foregroundStyle(tone(s).fg)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(tone(s).bg, in: Capsule())
                .contentTransition(.opacity)
        }
        .animation(BUI.easeOutStrong, value: s.status)
    }

    private func briefCard(_ text: String) -> some View {
        Button {
            withAnimation(BUI.easeOutStrong) { briefOpen.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Brief from the main chat").font(.inter(12, .semibold)).foregroundStyle(BUI.ink2)
                    Spacer()
                    Text(briefOpen ? "Less" : "All").font(.inter(12, .medium)).foregroundStyle(BUI.accentInk)
                        .contentTransition(.opacity)
                }
                Text(text)
                    .font(.inter(14)).tight(14).lineSpacing(2)
                    .foregroundStyle(BUI.ink)
                    .lineLimit(briefOpen ? nil : 4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func finished(_ s: Subagent) -> some View {
        HStack(spacing: 10) {
            ResultBadge(tone: tone(s), symbol: s.status == .done ? "checkmark" : s.status == .failed ? "exclamationmark" : "stop.fill", size: 20)
            Text(s.status == .done ? "Finished. Its report went back to the main chat." : s.status == .failed ? "This subagent hit an error." : "Stopped before it finished.")
                .font(.inter(13.5)).foregroundStyle(BUI.ink2)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func tone(_ s: Subagent) -> Tone {
        switch s.status {
        case .running: return .accent
        case .done: return .green
        case .failed: return .red
        case .stopped: return .neutral
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                let s = try await model.subagent(id)
                withAnimation(BUI.easeOutStrong) { sub = s }
                loadError = nil
            } catch {
                if sub == nil { loadError = error.localizedDescription }
            }
            try? await Task.sleep(for: .milliseconds(running ? 1500 : 5000))
        }
    }
}
