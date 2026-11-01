import SwiftUI

struct MenuPanel: View {
    @Environment(Hub.self) private var hub
    @Environment(CursorLink.self) private var cursor
    @Environment(\.openWindow) private var openWindow
    @State private var openAtLogin = LoginItem.enabled

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                ForEach(issues) { issue in
                    IssueCard(issue: issue).transition(.fadeUp)
                }
                rows
                Button {
                    showWindow("pair", openWindow)
                } label: {
                    Label("Pair an iPhone", systemImage: "qrcode")
                }
                .buttonStyle(.bui(issues.isEmpty ? .primary : .secondary, .md, fullWidth: true))
                .disabled(hub.state != .running)
            }
            .padding(12)
            .animation(BUI.enter, value: issues.map(\.id))
            footer
        }
        .frame(width: 320)
        .background(BUI.page)
        .task {
            while !Task.isCancelled {
                await hub.refresh()
                await cursor.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            HelmMark(size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Helm").font(.inter(14, .semibold)).foregroundStyle(BUI.ink)
                Text(subtitle)
                    .font(.inter(11.5))
                    .foregroundStyle(BUI.ink2)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
                    .animation(BUI.enter, value: subtitle)
            }
            Spacer()
            StatusPill(tone: hubTone.0, text: hubTone.1, pulsing: hub.state == .starting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(BUI.line).frame(height: 1) }
    }

    private var subtitle: String {
        guard hub.state == .running, let live = hub.live else { return hub.status?.hubName ?? "This Mac" }
        switch live.phonesConnected {
        case 0: return "No phone connected"
        case 1: return "1 phone connected"
        default: return "\(live.phonesConnected) phones connected"
        }
    }

    private var hubTone: (Tone, String) {
        switch hub.state {
        case .running: return (.green, "Running")
        case .starting: return (.accent, "Starting")
        case .stopped: return (.neutral, "Stopped")
        case .crashed: return (.red, "Stopped")
        case .conflict(let legacy): return (.orange, legacy ? "Command line" : "Port taken")
        case .missingRuntime: return (.red, "Broken")
        }
    }

    // MARK: Issues — only what needs fixing, one action each

    private var issues: [Issue] {
        var out: [Issue] = []
        switch hub.state {
        case .crashed(let why):
            out.append(Issue(id: "crashed", tone: .red, symbol: "exclamationmark.triangle.fill", title: "The hub stopped", detail: why, action: "Restart") { hub.restart() })
        case .conflict(let legacy):
            if legacy {
                out.append(Issue(id: "legacy", tone: .orange, symbol: "arrow.triangle.swap", title: "Helm is running from the command line",
                                 detail: "The hub you installed with setup.sh is still running. Switch to the app so it can manage the hub for you.",
                                 action: "Switch to the app") { Task { await hub.adoptLegacyService() } })
            } else {
                out.append(Issue(id: "port", tone: .orange, symbol: "exclamationmark.triangle.fill", title: "Port \(hub.port) is taken",
                                 detail: "Another program is using the hub's port. Quit it, then try again.", action: "Try again") { Task { await hub.start() } })
            }
        case .missingRuntime:
            out.append(Issue(id: "runtime", tone: .red, symbol: "exclamationmark.triangle.fill", title: "This copy of Helm is incomplete",
                             detail: "It's missing its built-in Node runtime. Rebuild the app or download it again.", action: nil, run: {}))
        default: break
        }
        if let s = hub.status, !s.cursorLoggedIn {
            out.append(Issue(id: "signin", tone: .orange, symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in to Cursor",
                             detail: hub.signInError ?? "Helm uses your Cursor account to run agents.",
                             action: hub.signingIn ? "Signing in…" : "Sign in", busy: hub.signingIn) { Task { await hub.signIn() } })
        }
        switch cursor.state {
        case .needsRestart:
            out.append(Issue(id: "cursor", tone: .orange, symbol: "bolt.horizontal.circle", title: "Cursor isn't connected",
                             detail: "It was opened without Helm, so your phone can't see its chats. Cursor will ask about anything unsaved.",
                             action: "Reopen Cursor") { Task { await cursor.restart() } })
        case .restarting:
            out.append(Issue(id: "cursor", tone: .accent, symbol: "arrow.clockwise", title: "Reopening Cursor",
                             detail: "Waiting for Cursor to quit…", action: nil, busy: true, run: {}))
        case .quitBlocked:
            out.append(Issue(id: "cursor", tone: .orange, symbol: "hand.raised", title: "Cursor didn't quit",
                             detail: "It may be asking you to save something. Answer it, then try again.",
                             action: "Try again") { Task { await cursor.restart() } })
        default: break
        }
        if let s = hub.status, s.tailscale.ip == nil {
            out.append(Issue(id: "tailscale", tone: .orange, symbol: "network.slash", title: s.tailscaleInstalled ? "Tailscale is off" : "Get Tailscale",
                             detail: "Your phone reaches this Mac through Tailscale.",
                             action: s.tailscaleInstalled ? "Open Tailscale" : "Download") {
                if s.tailscaleInstalled { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app")) }
                else { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
            })
        }
        return out
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 0) {
            StatusRow(symbol: "cursorarrow.rays", title: "Cursor", value: cursorValue, tone: cursor.state == .connected ? .green : .neutral) {
                if cursor.state == .notRunning {
                    Button("Open") { Task { await cursor.open() } }.buttonStyle(.bui(.ghost, .sm))
                }
            }
            divider
            StatusRow(symbol: "network", title: "Tailscale", value: hub.status?.tailscale.dns?.components(separatedBy: ".").first ?? (hub.status?.tailscale.ip ?? "Off"),
                      tone: hub.status?.tailscale.ip != nil ? .green : .neutral) { EmptyView() }
            divider
            StatusRow(symbol: "bell.badge", title: "Push", value: hub.status?.push == true ? "On" : "Off", tone: hub.status?.push == true ? .green : .neutral) {
                Button(hub.status?.push == true ? "Edit" : "Set up") { showWindow("push", openWindow) }.buttonStyle(.bui(.ghost, .sm))
            }
        }
        .padding(.horizontal, 12)
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .elevation(.card)
    }

    private var divider: some View { Rectangle().fill(BUI.line).frame(height: 1) }

    private var cursorValue: String {
        switch cursor.state {
        case .connected: return "Connected"
        case .notRunning: return "Not open"
        case .notInstalled: return "Not installed"
        case .restarting: return "Reopening…"
        case .needsRestart, .quitBlocked: return "Not connected"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $openAtLogin) { Text("Open at login").font(.inter(12)).foregroundStyle(BUI.ink2) }
                .toggleStyle(.checkbox)
                .onChange(of: openAtLogin) { _, on in LoginItem.set(on) }
            Spacer()
            Button { NSWorkspace.shared.open(hub.logURL) } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(IconButtonStyle())
                .help("Show hub logs")
            Button { showWindow("setup", openWindow) } label: { Image(systemName: "wand.and.stars") }
                .buttonStyle(IconButtonStyle())
                .help("Run setup again")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(IconButtonStyle())
                .help("Quit Helm. Your phone can't reach this Mac until you open it again.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(BUI.line).frame(height: 1) }
    }
}

struct Issue: Identifiable {
    var id: String
    var tone: Tone
    var symbol: String
    var title: String
    var detail: String
    var action: String?
    var busy = false
    var run: () -> Void
}

struct IssueCard: View {
    var issue: Issue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(issue.tone.fg)
                .frame(width: 26, height: 26)
                .background(issue.tone.bg, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).font(.inter(13, .semibold)).foregroundStyle(BUI.ink)
                Text(issue.detail)
                    .font(.inter(12))
                    .foregroundStyle(BUI.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
                if let action = issue.action {
                    Button(action: issue.run) {
                        HStack(spacing: 6) {
                            if issue.busy { MiniSpinner(size: 10).transition(.popIn) }
                            Text(action).contentTransition(.interpolate)
                        }
                    }
                    .buttonStyle(.bui(.accent, .sm))
                    .disabled(issue.busy)
                    .padding(.top, 4)
                } else if issue.busy {
                    MiniSpinner(size: 12).padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 12)
        .animation(BUI.enter, value: issue.detail)
        .animation(BUI.enter, value: issue.busy)
    }
}

struct StatusRow<Trailing: View>: View {
    var symbol: String
    var title: String
    var value: String
    var tone: Tone
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BUI.ink2)
                .frame(width: 16)
            Text(title).font(.inter(13, .medium)).foregroundStyle(BUI.ink)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if tone == .green { Circle().fill(BUI.green).frame(width: 6, height: 6).transition(.popIn) }
                Text(value)
                    .font(.inter(12.5))
                    .foregroundStyle(BUI.ink2)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
            }
            .animation(BUI.enter, value: value)
            trailing
        }
        .frame(height: 40)
    }
}
