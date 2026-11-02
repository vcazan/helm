import SwiftUI

/// A terminal an agent left running, under its shell call: tap to watch the output live.
struct TerminalCard: View {
    var id: String
    var title: String?
    var status: String?
    @State private var open = false

    private var running: Bool { status == "running" }
    private var failed: Bool { status == "failed" || status == "error" }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 12) {
                TerminalGlyph(live: running)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title?.nilIfEmpty ?? "Terminal").font(.inter(14, .semibold)).foregroundStyle(BUI.ink).lineLimit(1)
                    Text(caption).font(.inter(12)).foregroundStyle(failed ? BUI.red : BUI.ink3).lineLimit(1).contentTransition(.interpolate)
                }
                Spacer(minLength: 8)
                Text(running ? "Watch" : "View").font(.inter(12.5, .medium)).foregroundStyle(BUI.ink2).contentTransition(.interpolate)
                Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .bold)).foregroundStyle(BUI.ink3)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 54)
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
            .elevation(.btn, radius: BUI.Radius.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .sensoryFeedback(.impact(weight: .light), trigger: open)
        .animation(BUI.easeOutStrong, value: status)
        .accessibilityLabel("\(running ? "Watch" : "View") terminal \(title ?? "")")
        .sheet(isPresented: $open) {
            TerminalSheet(id: id, title: title)
                .presentationDetents([.fraction(0.62), .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(BUI.page)
        }
    }

    private var caption: String {
        switch status {
        case "running": return "Running · output streams live"
        case "succeeded": return "Finished"
        case "failed": return "Failed"
        case let s?: return s.capitalized
        case nil: return "Output"
        }
    }
}

/// A tiny terminal window: a prompt and, while the command runs, a blinking cursor.
struct TerminalGlyph: View {
    var live: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(TerminalPalette.bg)
            .frame(width: 30, height: 30)
            .overlay(alignment: .leading) {
                HStack(spacing: 1.5) {
                    Text("›").font(.jbMono(13, .medium)).foregroundStyle(TerminalPalette.prompt)
                    BlinkingCursor(on: live).frame(width: 5, height: 10)
                }
                .padding(.leading, 7)
            }
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 1))
    }
}

struct BlinkingCursor: View {
    var on: Bool
    var body: some View {
        if on {
            TimelineView(.periodic(from: .now, by: 0.55)) { ctx in
                let lit = Int(ctx.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
                RoundedRectangle(cornerRadius: 1).fill(TerminalPalette.text).opacity(lit ? 0.9 : 0.15)
                    .animation(.easeInOut(duration: 0.18), value: lit)
            }
        } else {
            RoundedRectangle(cornerRadius: 1).fill(TerminalPalette.dim).opacity(0.5)
        }
    }
}

/// Marks a shell call whose command is still running in the background.
struct TerminalLiveDot: View {
    @State private var breathe = false
    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(BUI.green.opacity(0.35)).frame(width: 12, height: 12)
                    .scaleEffect(breathe ? 1 : 0.4).opacity(breathe ? 0 : 0.9)
                Circle().fill(BUI.green).frame(width: 6, height: 6)
            }
            .frame(width: 12, height: 12)
            Text("live").font(.jbMono(10.5, .medium)).foregroundStyle(BUI.green)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { breathe = true } }
        .accessibilityLabel("Still running")
    }
}

enum TerminalPalette {
    static let bg = Color(red: 0.075, green: 0.08, blue: 0.09)
    static let text = Color(red: 0.86, green: 0.88, blue: 0.9)
    static let dim = Color(red: 0.5, green: 0.53, blue: 0.57)
    static let prompt = Color(red: 0.36, green: 0.84, blue: 0.55)
}

/// One terminal's output, following new lines while the command runs.
struct TerminalSheet: View {
    var id: String
    var title: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var info: TerminalOutput?
    @State private var lines: [Line] = []
    @State private var next = 0
    @State private var gone = false
    @State private var pinned = true
    @State private var copied = false
    @State private var finished = 0
    @State private var toBottom = Jump(n: 0, animated: false)

    struct Line: Identifiable, Hashable { var id: Int; var text: String }
    struct Jump: Equatable { var n: Int; var animated: Bool }
    private static let end = "end"
    private static let block = 60

    /// Lines in runs of `block`, one text view each: a regular stack knows its real height, so the
    /// view can open on the newest line, without a view per line.
    private var blocks: [(Int, String)] {
        var out: [(Int, String)] = []
        var key = Int.min
        var run: [String] = []
        for l in lines {
            let k = l.id / Self.block
            if k != key, !run.isEmpty { out.append((key, run.joined(separator: "\n"))); run = [] }
            key = k
            run.append(l.text)
        }
        if !run.isEmpty { out.append((key, run.joined(separator: "\n"))) }
        return out
    }
    private static let keep = 4000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: info?.title?.nilIfEmpty ?? title?.nilIfEmpty ?? "Terminal", onClose: { dismiss() })
            statusRow.padding(.horizontal, 20).padding(.bottom, 12)
            panel
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .task(id: id) { await follow() }
        .sensoryFeedback(trigger: finished) { _, _ in info?.failed == true ? .error : .success }
    }

    // MARK: Header pieces

    private var statusRow: some View {
        HStack(spacing: 8) {
            if let t = info {
                StatusPill(tone: t.running ? .green : t.failed ? .red : .neutral, text: statusText(t))
                    .transition(.popIn)
                Elapsed(info: t)
            } else if !gone {
                StatusPill(tone: .neutral, text: "Connecting").redacted(reason: .placeholder)
            }
            Spacer()
            if !lines.isEmpty {
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle(size: 30, tint: copied ? BUI.green : BUI.ink3))
                .accessibilityLabel("Copy output")
                .transition(.opacity)
            }
        }
        .animation(BUI.easeOutStrong, value: info?.status)
    }

    private func statusText(_ t: TerminalOutput) -> String {
        if t.running { return "Running" }
        if let code = t.exitCode { return code == 0 ? "Exited 0" : "Failed · exit \(code)" }
        return t.status == "failed" ? "Failed" : "Finished"
    }

    // MARK: Output panel

    private var panel: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let cmd = info?.command {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("$").foregroundStyle(TerminalPalette.prompt)
                            Text(cmd).foregroundStyle(TerminalPalette.text)
                        }
                        .font(.jbMono(12, .medium))
                        .padding(.bottom, 8)
                    }
                    if info?.truncated == true {
                        Text("… earlier output trimmed").font(.jbMono(11)).foregroundStyle(TerminalPalette.dim).padding(.bottom, 4)
                    }
                    ForEach(blocks, id: \.0) { _, text in
                        Text(text)
                            .font(.jbMono(11.5))
                            .lineSpacing(2)
                            .foregroundStyle(TerminalPalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                    footer.padding(.top, 6).id(Self.end)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 40
            } action: { _, atBottom in
                pinned = atBottom
            }
            .onChange(of: toBottom) { _, jump in
                withAnimation(jump.animated ? BUI.easeOutStrong : nil) { proxy.scrollTo(Self.end, anchor: .bottom) }
            }
            }

            if !pinned, info?.running == true {
                Button {
                    toBottom = Jump(n: toBottom.n + 1, animated: true)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down").font(.system(size: 10.5, weight: .bold))
                        Text("Live").font(.inter(12, .semibold))
                    }
                    .foregroundStyle(TerminalPalette.bg)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(TerminalPalette.prompt, in: Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.94))
                .padding(12)
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottomTrailing)))
                .accessibilityLabel("Jump to the newest output")
            }
        }
        .background(TerminalPalette.bg, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous)
                .stroke(info?.failed == true ? BUI.red.opacity(0.55) : .white.opacity(0.06), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .animation(BUI.easeOutStrong, value: pinned)
        .animation(BUI.easeOutFast, value: lines.count)
    }

    @ViewBuilder
    private var footer: some View {
        if gone {
            VStack(alignment: .leading, spacing: 4) {
                Text("This terminal is gone.").foregroundStyle(TerminalPalette.text)
                Text("Cursor cleans up old terminals, so its output wasn't kept.").foregroundStyle(TerminalPalette.dim)
            }
            .font(.jbMono(11.5))
        } else if let t = info, t.running {
            HStack(spacing: 6) {
                BlinkingCursor(on: true).frame(width: 7, height: 13)
                if lines.isEmpty { Text("Waiting for output").font(.jbMono(11.5)).foregroundStyle(TerminalPalette.dim) }
            }
        } else if let t = info {
            Text(t.failed ? "— exited \(t.exitCode.map(String.init) ?? "with an error")" : "— done")
                .font(.jbMono(11.5))
                .foregroundStyle(t.failed ? BUI.red : TerminalPalette.dim)
                .transition(.opacity)
        }
    }

    // MARK: Data

    private func follow() async {
        while !Task.isCancelled {
            do {
                let t = try await model.terminal(id, from: next)
                let wasRunning = info?.running
                apply(t)
                if wasRunning == true, !t.running { finished += 1 }
                if !t.running { return }
            } catch {
                if info == nil {
                    withAnimation(BUI.easeOutStrong) { gone = true }
                    return
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func apply(_ t: TerminalOutput) {
        var text = t.output
        if text.hasSuffix("\n") { text.removeLast() }
        let incoming = t.output.isEmpty ? [] : text.components(separatedBy: "\n")
        withAnimation(BUI.easeOutStrong) {
            if t.append {
                let start = (lines.last?.id ?? -1) + 1
                lines.append(contentsOf: incoming.enumerated().map { Line(id: start + $0.offset, text: $0.element) })
            } else {
                lines = incoming.enumerated().map { Line(id: $0.offset, text: $0.element) }
            }
            if lines.count > Self.keep { lines.removeFirst(lines.count - Self.keep) }
            info = t
        }
        next = t.next
        if (pinned || !t.append), !t.output.isEmpty || !t.running {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                toBottom = Jump(n: toBottom.n + 1, animated: t.append)
            }
        }
    }

    private func copy() {
        UIPasteboard.general.string = lines.map(\.text).joined(separator: "\n")
        withAnimation(BUI.easeOutFast) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(BUI.easeOutFast) { copied = false }
        }
    }
}

/// How long the command has run, ticking while it's live.
private struct Elapsed: View {
    var info: TerminalOutput
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Text(label(now: ctx.date))
                .font(.jbMono(12))
                .foregroundStyle(BUI.ink3)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(BUI.easeOutFast, value: label(now: ctx.date))
        }
    }

    private func label(now: Date) -> String {
        var ms = info.elapsedMs ?? 0
        if info.running, let s = info.startedAt { ms = max(ms, now.timeIntervalSince1970 * 1000 - s) }
        let s = Int(ms / 1000)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }
}
