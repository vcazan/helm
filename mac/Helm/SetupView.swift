import SwiftUI
import UserNotifications

struct SetupView: View {
    enum Step: Int, CaseIterable { case welcome, checks, cursor, pair, done }

    @Environment(Hub.self) private var hub
    @Environment(CursorLink.self) private var cursor
    @Environment(\.dismissWindow) private var dismissWindow
    #if DEBUG
    @State private var step: Step = Step(rawValue: UserDefaults.standard.integer(forKey: "setupStep")) ?? .welcome
    #else
    @State private var step: Step = .welcome
    #endif
    @State private var direction = 1
    @State private var openAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 18)
            ZStack {
                content
                    .id(step)
                    .transition(.step(direction))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: 480, height: 560)
        .background(BUI.page)
        .task {
            while !Task.isCancelled {
                await hub.refresh()
                await cursor.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func go(_ next: Step) {
        direction = next.rawValue > step.rawValue ? 1 : -1
        withAnimation(BUI.enter) { step = next }
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.dropLast(), id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? BUI.ink : BUI.lineStrong)
                    .frame(width: s == step ? 20 : 6, height: 6)
            }
        }
        .animation(BUI.enter, value: step)
        .opacity(step == .welcome || step == .done ? 0 : 1)
        .animation(BUI.enter, value: step == .welcome || step == .done)
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(Step(rawValue: step.rawValue - 1)!) }
                    .buttonStyle(.bui(.quiet))
                    .transition(.opacity)
            }
            Spacer()
            if let skip = skipLabel {
                Button(skip) { go(Step(rawValue: step.rawValue + 1)!) }
                    .buttonStyle(.bui(.quiet))
                    .transition(.opacity)
            }
            Button(primaryLabel) { primary() }
                .buttonStyle(.bui(.primary, .md))
                .disabled(!canContinue)
                .keyboardShortcut(.defaultAction)
        }
        .animation(BUI.enter, value: step)
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome: return "Get started"
        case .done: return "Done"
        default: return "Continue"
        }
    }

    private var skipLabel: String? {
        switch step {
        case .checks where !ready && requirementsMetExceptTailscale: return "Skip Tailscale for now"
        case .cursor where cursor.state != .connected: return "Later"
        case .pair: return "Later"
        default: return nil
        }
    }

    private var requirementsMetExceptTailscale: Bool {
        cursor.state != .notInstalled && hub.status?.cursorLoggedIn == true && hub.state == .running
    }
    private var ready: Bool { requirementsMetExceptTailscale && hub.status?.tailscale.ip != nil }

    private var canContinue: Bool {
        switch step {
        case .checks: return ready
        case .cursor: return cursor.state == .connected
        default: return true
        }
    }

    private func primary() {
        switch step {
        case .done:
            LoginItem.set(openAtLogin)
            UserDefaults.standard.set(true, forKey: "onboarded")
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            dismissWindow(id: "setup")
        default:
            go(Step(rawValue: step.rawValue + 1)!)
        }
    }

    // MARK: Steps

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .checks: checks
        case .cursor: connectCursor
        case .pair: pair
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            WheelIntro()
            VStack(spacing: 8) {
                Text("Your Cursor agents, in your pocket")
                    .font(.inter(22, .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(BUI.ink)
                Text("Helm runs a small hub on this Mac. The Helm app on your iPhone uses it to follow your Cursor chats, answer agents' questions and start new work.")
                    .font(.inter(13.5))
                    .foregroundStyle(BUI.ink2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 360)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private var checks: some View {
        StepBody(title: "Check this Mac", subtitle: "Helm needs these. Each one updates as you fix it.") {
            VStack(spacing: 8) {
                CheckRow(index: 0, done: cursor.state != .notInstalled, title: "Cursor", detail: cursor.state == .notInstalled ? "Install Cursor in Applications." : "Installed") {
                    if cursor.state == .notInstalled {
                        Button("Download") { NSWorkspace.shared.open(URL(string: "https://cursor.com/download")!) }.buttonStyle(.bui(.secondary, .sm))
                    }
                }
                CheckRow(index: 1, done: hub.status?.cursorLoggedIn == true, busy: hub.signingIn, title: "Cursor account",
                         detail: hub.status?.cursorLoggedIn == true ? (hub.status?.cursorEmail ?? "Signed in") : (hub.signInError ?? "Helm creates its own key from the Cursor app's sign-in.")) {
                    if hub.status?.cursorLoggedIn == false {
                        Button(hub.signingIn ? "Signing in…" : "Sign in") { Task { await hub.signIn() } }
                            .buttonStyle(.bui(.secondary, .sm))
                            .disabled(hub.signingIn)
                    }
                }
                CheckRow(index: 2, done: hub.status?.tailscale.ip != nil, title: "Tailscale",
                         detail: tailscaleDetail) {
                    if let s = hub.status, s.tailscale.ip == nil {
                        Button(s.tailscaleInstalled ? "Open" : "Download") {
                            if s.tailscaleInstalled { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app")) }
                            else { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
                        }
                        .buttonStyle(.bui(.secondary, .sm))
                    }
                }
                CheckRow(index: 3, done: hub.state == .running, busy: hub.state == .starting, title: "Helm hub", detail: hubDetail) {
                    if case .conflict(true) = hub.state {
                        Button("Switch") { Task { await hub.adoptLegacyService() } }.buttonStyle(.bui(.secondary, .sm))
                    } else if case .crashed = hub.state {
                        Button("Restart") { hub.restart() }.buttonStyle(.bui(.secondary, .sm))
                    }
                }
            }
        }
    }

    private var tailscaleDetail: String {
        guard let s = hub.status else { return "Checking…" }
        if let dns = s.tailscale.dns { return dns }
        if let ip = s.tailscale.ip { return ip }
        return s.tailscaleInstalled ? "Open Tailscale and connect. Use the same account on your iPhone." : "Your phone reaches this Mac through Tailscale."
    }

    private var hubDetail: String {
        switch hub.state {
        case .running: return "Running on port \(hub.port)"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .crashed(let why): return why
        case .conflict(let legacy): return legacy ? "Running from the command line. Switch so the app manages it." : "Port \(hub.port) is in use by another program."
        case .missingRuntime: return "This copy of Helm is missing its Node runtime."
        }
    }

    private var connectCursor: some View {
        StepBody(title: "Connect Cursor", subtitle: "Helm drives Cursor through a debugging port that Cursor only opens at launch.") {
            VStack(spacing: 16) {
                CursorDiagram(connected: cursor.state == .connected)
                    .padding(.vertical, 8)
                Group {
                    switch cursor.state {
                    case .connected:
                        Label("Cursor is connected", systemImage: "checkmark.circle.fill")
                            .font(.inter(13.5, .medium))
                            .foregroundStyle(BUI.green)
                    case .notRunning:
                        Button("Open Cursor with Helm") { Task { await cursor.open() } }.buttonStyle(.bui(.accent, .md))
                    case .needsRestart:
                        VStack(spacing: 10) {
                            Button("Reopen Cursor with Helm") { Task { await cursor.restart() } }.buttonStyle(.bui(.accent, .md))
                            Text("Cursor quits like ⌘Q, asks about anything unsaved, then reopens with your windows.")
                                .font(.inter(12)).foregroundStyle(BUI.ink3).multilineTextAlignment(.center)
                        }
                    case .restarting:
                        HStack(spacing: 8) { MiniSpinner(); Text("Reopening Cursor…").font(.inter(13)).foregroundStyle(BUI.ink2) }
                    case .quitBlocked:
                        VStack(spacing: 10) {
                            Text("Cursor didn't quit. It may be asking you to save something.")
                                .font(.inter(12.5)).foregroundStyle(BUI.orange)
                            Button("Try again") { Task { await cursor.restart() } }.buttonStyle(.bui(.accent, .md))
                        }
                    case .notInstalled:
                        Text("Install Cursor first.").font(.inter(13)).foregroundStyle(BUI.ink2)
                    }
                }
                .transition(.fadeUp)
                .animation(BUI.enter, value: cursor.state)
                Text("From now on, Helm tells you if Cursor gets opened without it.")
                    .font(.inter(12))
                    .foregroundStyle(BUI.ink3)
            }
        }
    }

    private var pair: some View {
        StepBody(title: "Pair your iPhone", subtitle: nil) {
            PairCard { _ in
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    if step == .pair { go(.done) }
                }
            }
        }
    }

    private var done: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Burst()
                    .frame(width: 260, height: 220)
                HelmMark(size: 64)
                    .transition(.popIn)
            }
            .frame(height: 150)
            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.inter(22, .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(BUI.ink)
                Text("Helm lives in your menu bar. Quitting it disconnects your phone, so let it open when you log in.")
                    .font(.inter(13.5))
                    .foregroundStyle(BUI.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            Toggle(isOn: $openAtLogin) { Text("Open Helm at login").font(.inter(13)).foregroundStyle(BUI.ink) }
                .toggleStyle(.checkbox)
            Spacer()
        }
        .padding(.horizontal, 32)
        .onAppear { NSSound(named: "Hero")?.play() }
    }
}

// MARK: - Pieces

private struct StepBody<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.inter(20, .semibold)).tracking(-0.3).foregroundStyle(BUI.ink)
                if let subtitle {
                    Text(subtitle).font(.inter(13)).foregroundStyle(BUI.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
    }
}

private struct CheckRow<Trailing: View>: View {
    var index: Int
    var done: Bool
    var busy = false
    var title: String
    var detail: String
    @ViewBuilder var trailing: Trailing
    @State private var shown = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if done {
                    ResultBadge(tone: .green, symbol: "checkmark", size: 22).transition(.popIn)
                } else if busy {
                    MiniSpinner(size: 16).transition(.opacity)
                } else {
                    Circle().strokeBorder(BUI.lineStrong, lineWidth: 1.5).frame(width: 22, height: 22).transition(.opacity)
                }
            }
            .frame(width: 22, height: 22)
            .animation(.spring(response: 0.38, dampingFraction: 0.62), value: done)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.inter(13.5, .medium)).foregroundStyle(BUI.ink)
                Text(detail)
                    .font(.inter(12))
                    .foregroundStyle(BUI.ink2)
                    .lineLimit(2)
                    .contentTransition(.interpolate)
                    .animation(BUI.enter, value: detail)
            }
            Spacer(minLength: 8)
            trailing
        }
        .card(padding: 12)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 8)
        .onAppear {
            withAnimation(BUI.enter.delay(0.05 + Double(index) * 0.05)) { shown = true }
        }
    }
}

/// Welcome mark: the wheel turns into place.
private struct WheelIntro: View {
    @State private var settled = false
    var body: some View {
        HelmMark(size: 72)
            .rotationEffect(.degrees(settled ? 0 : -120))
            .scaleEffect(settled ? 1 : 0.7)
            .opacity(settled ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.62).delay(0.1)) { settled = true } }
            .onHover { _ in withAnimation(.spring(response: 0.7, dampingFraction: 0.5)) { spins += 45 } }
            .rotationEffect(.degrees(spins))
    }
    @State private var spins: Double = 0
}

/// Phone → this Mac → Cursor, with the last link lighting up once Cursor is connected.
private struct CursorDiagram: View {
    var connected: Bool
    @State private var flow = false

    var body: some View {
        HStack(spacing: 0) {
            node("iphone", "iPhone", lit: true)
            link(lit: true)
            node("desktopcomputer", "Helm", lit: true)
            link(lit: connected)
            node("cursorarrow.rays", "Cursor", lit: connected)
        }
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { flow = true } }
    }

    private func node(_ symbol: String, _ label: String, lit: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(lit ? BUI.ink : BUI.ink3)
                .frame(width: 52, height: 52)
                .background(BUI.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .elevation(.card, radius: 14)
            Text(label).font(.inter(11.5, .medium)).foregroundStyle(BUI.ink2)
        }
        .animation(BUI.enter, value: lit)
    }

    private func link(lit: Bool) -> some View {
        ZStack {
            Capsule().fill(BUI.lineStrong).frame(height: 2)
            if lit {
                GeometryReader { g in
                    Capsule().fill(BUI.accent).frame(width: 14, height: 2)
                        .offset(x: flow ? g.size.width : -14)
                }
                .frame(height: 2)
                .clipped()
                .transition(.opacity)
            }
        }
        .frame(width: 64)
        .padding(.bottom, 18)
        .animation(BUI.enter, value: lit)
    }
}

/// A one-time confetti burst in the app's palette.
private struct Burst: View {
    @State private var start = Date()
    private static let colors: [Color] = [BUI.accent, BUI.green, BUI.orange, BUI.ink3]

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { g, size in
                let t = ctx.date.timeIntervalSince(start)
                guard t < 1.8 else { return }
                let p = min(t / 1.6, 1)
                let e = 1 - pow(1 - p, 3)
                for i in 0..<34 {
                    let a = Double(i) / 34 * 2 * .pi + Double(i % 3) * 0.07
                    let dist = (70 + Double((i * 37) % 60)) * e
                    let x = size.width / 2 + cos(a) * dist
                    let y = size.height / 2 + sin(a) * dist + 50 * p * p
                    let s = (i % 2 == 0 ? 6.0 : 4.0) * (1 - p * 0.5)
                    let rect = CGRect(x: x - s / 2, y: y - s / 2, width: s, height: i % 3 == 0 ? s * 1.8 : s)
                    var piece = g
                    piece.opacity = 1 - p
                    piece.translateBy(x: rect.midX, y: rect.midY)
                    piece.rotate(by: .radians(a + p * 6))
                    piece.fill(Path(roundedRect: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height), cornerRadius: 1.2),
                               with: .color(Self.colors[i % Self.colors.count]))
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { start = Date() }
    }
}
