import PhotosUI
import SwiftUI

// Chats running in the Cursor desktop app, driven through the hub's CDP bridge.

extension DesktopChatStatus {
    var tone: Tone {
        switch self {
        case .working: return .accent
        case .attention: return .orange
        case .done: return .green
        case .idle: return .neutral
        }
    }
    var label: String {
        switch self {
        case .working: return "Working"
        case .attention: return "Needs you"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
}

// MARK: Home section

/// Shown when the hub can't reach Cursor, so projects can't be driven from the phone.
struct DesktopNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.connection == .online, !model.desktop.available {
            HStack(alignment: .top, spacing: 12) {
                ResultBadge(tone: .neutral, symbol: "laptopcomputer", size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cursor chats aren't connected").font(.inter(14, .semibold)).foregroundStyle(BUI.ink)
                    Text("Quit Cursor on the Mac and reopen it with **Cursor (Helm)** so Helm can drive its chats.")
                        .font(.inter(13)).foregroundStyle(BUI.ink2)
                }
                Spacer(minLength: 0)
            }
            .card(padding: 14)
            .transition(.fadeUp)
        }
    }
}

// MARK: Window: its chats, plus a composer that starts a new one

struct DesktopWindowView: View {
    @Environment(AppModel.self) private var model
    var windowId: String
    @State private var starting = false
    @State private var backgroundAgent = false
    @State private var actions = ThreadActions()

    var body: some View {
        if let w = model.desktopWindow(windowId) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(w.workspace).font(.inter(30, .semibold)).tracking(-0.8).foregroundStyle(BUI.ink)
                        HStack(spacing: 8) {
                            StatusPill(tone: .green, text: "Open in Cursor")
                            Text(w.title).font(.inter(12.5)).foregroundStyle(BUI.ink3).lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.horizontal, 4)
                    .bareRow()

                    if let q = w.question {
                        DesktopQuestionCard(ref: DesktopRef(window: w.id, chat: q.chat), question: q, showChat: true)
                            .bareRow()
                    }
                    if let p = w.pending {
                        DesktopApprovalCard(ref: DesktopRef(window: w.id, chat: p.chat), pending: p, showChat: true)
                            .bareRow()
                    }
                }

                ThreadSections(workspace: model.workspace(for: w), window: w, actions: actions)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .listSectionSpacing(14)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .contentMargins(.top, 0, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 0)
            .animation(BUI.easeOutStrong, value: w.pending)
            .animation(BUI.easeOutStrong, value: w.question)
            .animation(BUI.easeOutStrong, value: model.threads(model.workspace(for: w), w))
            .animation(BUI.easeOutStrong, value: model.archivedThreads(model.workspace(for: w), w))
            .threadDialogs(actions, model: model)
            .background(BUI.page)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                DesktopComposer(placeholder: "New Cursor chat in \(w.workspace)", busy: false, sending: starting) { text, images in
                    await startChat(w, text, images)
                } onStop: {}
            }
            .toolbar {
                if let ws = model.workspace(for: w) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("New Helm agent…", systemImage: "sparkles") { backgroundAgent = true }
                            let key = model.projectKey(ws, w)
                            if model.chatOrder[key] != nil {
                                Button("Sort by recent", systemImage: "arrow.up.arrow.down") {
                                    withAnimation(BUI.easeOutStrong) { model.setOrder(nil, for: key) }
                                }
                            }
                            Button(ws.pinned ? "Unpin" : "Pin", systemImage: ws.pinned ? "pin.slash" : "pin") {
                                Task { await model.updateWorkspace(ws.id, pinned: !ws.pinned) }
                            }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(Theme.text)
                        }
                    }
                }
            }
            .sheet(isPresented: $backgroundAgent) {
                if let ws = model.workspace(for: w) {
                    NewAgentSheet(workspace: ws) { a in
                        backgroundAgent = false
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            model.route.append(.agent(a.id))
                        }
                    }
                    .presentationDetents([.large])
                    .presentationCornerRadius(28)
                    .presentationBackground(Theme.bg)
                }
            }
        } else {
            ContentUnavailableView("Window closed", systemImage: "macwindow.badge.plus", description: Text("That Cursor window isn't open anymore."))
                .foregroundStyle(BUI.ink2)
        }
    }

    private func startChat(_ w: DesktopWindow, _ text: String, _ images: [OutgoingImage]) async -> Bool {
        starting = true
        defer { starting = false }
        guard let ref = await model.startCursorAgent(in: nil, window: w.id, text: text, images: images) else { return false }
        if !ref.chat.isEmpty { model.route.append(.desktopChat(ref.window, ref.chat)) }
        return true
    }
}

/// "Show N more" / "Show fewer" at the foot of a folded list.
struct FoldToggle: View {
    var open: Bool
    var hidden: Int
    var toggle: () -> Void

    var body: some View {
        Button {
            withAnimation(BUI.easeOutStrong) { toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(open ? "Show fewer" : "Show \(hidden) more")
                    .contentTransition(.numericText())
                Image(systemName: "chevron.down")
                    .font(.system(size: 10.5, weight: .bold))
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(.inter(13.5, .medium))
            .foregroundStyle(BUI.ink2)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
    }
}

struct ArchivedChatRow: View {
    var title: String
    var age: String
    var helm = false
    var restore: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ResultBadge(tone: .neutral, symbol: "archivebox", size: 24).frame(width: 26, height: 26).opacity(0.7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.inter(15, .medium)).tight(15).foregroundStyle(BUI.ink2).lineLimit(1)
                Text([age, helm ? "Helm" : "Cursor"].filter { !$0.isEmpty }.joined(separator: " · ")).font(.inter(12.5)).foregroundStyle(BUI.ink3)
            }
            Spacer(minLength: 8)
            Button(action: restore) {
                Text("Restore")
                    .font(.inter(12.5, .semibold))
                    .foregroundStyle(BUI.ink)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(BUI.page, in: Capsule())
                    .overlay(Capsule().strokeBorder(BUI.line, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle(scale: 0.94))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

extension View {
    /// A row on the page background, outside any card.
    func bareRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
    }

    /// A row inside a section's card, separators lined up with the title.
    func cardRow() -> some View {
        listRowBackground(BUI.surface)
            .listRowInsets(EdgeInsets())
            .listRowSeparatorTint(BUI.line)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 50 }
    }

    func sectionHeader() -> some View {
        textCase(nil).padding(.leading, -16).padding(.bottom, 2)
    }
}

struct DesktopChatRow: View {
    var chat: DesktopChat

    var body: some View {
        HStack(spacing: 12) {
            badge.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).font(.inter(15, .medium)).tight(15).foregroundStyle(BUI.ink).lineLimit(1)
                Text(chat.selected ? "\(chat.age) · open on the Mac" : chat.age).font(.inter(12.5)).foregroundStyle(BUI.ink3)
            }
            Spacer(minLength: 8)
            if chat.status == .attention { StatusPill(tone: .orange, text: "Needs you").transition(.popIn) }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(BUI.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(BUI.easeOutStrong, value: chat.status)
    }

    @ViewBuilder private var badge: some View {
        switch chat.status {
        case .working: SpinnerRing(active: true, size: 24) { Sparkle().fill(BUI.accent).frame(width: 10, height: 10) }
        case .attention: ResultBadge(tone: .orange, symbol: "questionmark", size: 24)
        case .done: ResultBadge(tone: .green, symbol: "checkmark", size: 24)
        case .idle: ResultBadge(tone: .neutral, symbol: "bubble.left", size: 24)
        }
    }
}

// MARK: Chat

struct DesktopChatView: View {
    @AppStorage("showThinking") private var showThinking = false
    @Environment(AppModel.self) private var model
    var ref: DesktopRef

    @State private var items: [Item]?
    @State private var live: [DesktopLiveRow] = []
    @State private var liveTurn = false
    @State private var composerId: String?
    @State private var talkTarget: TalkTarget?
    @State private var pickingTalk = false
    @State private var outgoing: [Item] = []
    @State private var queued: [QueuedMessage] = []
    @State private var subagents: [Subagent] = []
    @State private var loadError: String?
    @State private var sending = false
    /// From tapping send until Cursor visibly starts: the chat counts as working so there's no dead air.
    @State private var startingSince: Date?
    @State private var delivered: Set<String> = []
    /// Sent while the agent was busy and still on its way to Cursor (ids start with `out-`).
    @State private var pendingQueued: [QueuedMessage] = []
    /// Queue entries the hub confirmed on send that a poll hasn't listed yet, with when they were added.
    @State private var localQueued: [(QueuedMessage, Date)] = []
    /// Removed or sent from the phone: kept out of view even if an older poll still lists them.
    @State private var hiddenQueued: [String: Date] = [:]
    /// Edited from the phone: shown with the new text until Cursor's copy catches up.
    @State private var editedQueued: [String: String] = [:]
    /// Cursor's queue id → the phone's temporary id, so a row keeps its identity once Cursor confirms it.
    @State private var queueKeys: [String: String] = [:]
    /// How many user messages with the same text the chat already had when each outgoing bubble was sent.
    @State private var outgoingBase: [String: Int] = [:]
    /// Cursor's id for a message → the bubble id it was sent under, so the bubble stays put instead of being swapped.
    @State private var sentIds: [String: String] = [:]
    /// How many of the newest items to fetch; grows a page at a time as you scroll up.
    @State private var tail = DesktopChatView.page
    @State private var total = 0
    @State private var loadingOlder = false
    @State private var loaderVisible = false
    /// Off until the chat has opened at the bottom; otherwise the first layout pass (scrolled to the top
    /// for an instant) would count as "scrolled up" and page in history.
    @State private var canPage = false
    /// Just opened: stay pinned to the newest message while lazy rows measure their real heights.
    @State private var settling = false
    /// Hides the first page until it's pinned to the bottom, so opening a chat doesn't scroll through it.
    @State private var revealed = false
    static let page = 80
    static let bottomId = "chat-bottom"

    private var window: DesktopWindow? { model.desktopWindow(ref.window) }
    private var chat: DesktopChat? { window?.chats.first { $0.title == ref.chat } }
    private var status: DesktopChatStatus { chat?.status ?? .idle }
    private var cursorWorking: Bool { status == .working || (chat?.selected == true && window?.working == true) }
    private var starting: Bool { startingSince.map { Date().timeIntervalSince($0) < 20 } ?? false }
    private var working: Bool { cursorWorking || starting }
    private var question: DesktopQuestion? {
        guard let q = window?.question, q.chat == ref.chat || (q.chat.isEmpty && chat?.selected == true) else { return nil }
        return q
    }
    private var pending: DesktopPending? {
        guard let p = window?.pending, p.chat == ref.chat || (p.chat.isEmpty && chat?.selected == true) else { return nil }
        return p
    }

    var body: some View {
        let all = (items ?? []).map { it in sentIds[it.id].map { var c = it; c.id = $0; return c } ?? it } + outgoing
        let segments = ChatSegment.build(all)
        let lastSent = outgoing.last?.id ?? all.last(where: { $0.kind == .user && sentIds.values.contains($0.id) })?.id
        ScrollViewReader { reader in
        ScrollView {
            // Eager on purpose: lazy rows guess their heights, and pinning to the bottom of a long chat
            // keeps realizing rows that change the content size, so the pin never lands. Paging keeps this bounded.
            VStack(alignment: .leading, spacing: 16) {
                if items == nil {
                    if let loadError {
                        ContentUnavailableView("Couldn't open this chat", systemImage: "exclamationmark.bubble", description: Text(loadError))
                            .foregroundStyle(BUI.ink2)
                            .padding(.top, 80)
                    } else {
                        LoadingState(label: "Opening on your Mac", pattern: .orbit)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 100)
                    }
                } else {
                    if let items, items.count < total {
                        OlderPageLoader(loading: loadingOlder)
                            .onScrollVisibilityChange(threshold: 0.05) { visible in
                                loaderVisible = visible
                                slog("loader visible:\(visible) canPage:\(canPage)")
                                if visible, canPage { Task { await loadOlder(reader) } }
                            }
                    } else if !(items ?? []).isEmpty {
                        ChatStartMarker(title: ref.chat)
                    }
                    ForEach(Array(segments.enumerated()), id: \.element.id) { i, seg in
                        VStack(alignment: .leading, spacing: 6) {
                            DesktopSegmentView(segment: seg, live: working && i == segments.count - 1)
                            // "Sending…" then "Delivered" under the latest message, until the agent's reply starts below it.
                            if seg.id == lastSent, i == segments.count - 1 {
                                SendStatus(delivered: !outgoing.contains { $0.id == seg.id } || delivered.contains(seg.id))
                                    .transition(.opacity)
                            }
                        }
                        .id(seg.id)
                        .transition(.asymmetric(insertion: .fadeUp, removal: .opacity))
                    }
                    if !liveTurn, let tail = unsyncedReply(all) {
                        MarkdownText(text: tail).frame(maxWidth: .infinity, alignment: .leading).transition(.fadeUp)
                    }
                    if working {
                        if cursorWorking && !liveTurn {
                            DesktopLiveCard(rows: liveActivity).transition(.fadeUp)
                        } else {
                            // One persistent row: it only fades while the last item animates on its own,
                            // so the chat doesn't shift each time a tool starts or ends.
                            WorkingTail(label: cursorWorking ? "Working" : sending ? "Sending to Cursor" : "Starting")
                                .opacity(cursorWorking && Self.showsProgress(all.last) ? 0 : 1)
                                .animation(BUI.easeOutStrong, value: Self.showsProgress(all.last))
                                .transition(.fadeUp)
                        }
                    }
                }
                Color.clear.frame(height: 1).id(Self.bottomId)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .opacity(items == nil || revealed ? 1 : 0)
            .animation(BUI.easeOutStrong, value: all.count)
            .animation(BUI.easeOutStrong, value: working)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .jumpToLatest(latest: all.last?.id)
        .onChange(of: items == nil) { _, empty in
            guard !empty else { return }
            settling = true
            // The first items aren't laid out yet when this fires, so keep pinning over the next frames.
            Task {
                for wait in [0, 30, 120, 300, 600] {
                    try? await Task.sleep(for: .milliseconds(wait))
                    guard settling else { return }
                    pinToBottom(reader)
                    if wait == 120 { withAnimation(.easeOut(duration: 0.2)) { revealed = true } }
                }
                try? await Task.sleep(for: .milliseconds(900))
                endSettling()
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, _ in
            if settling { pinToBottom(reader) }
        }
        .onScrollPhaseChange { _, phase in
            slog("phase \(phase)")
            if phase == .interacting { endSettling() }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(BUI.page)
        .environment(\.subagents, Dictionary(subagents.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        .sensoryFeedback(.impact(weight: .light), trigger: subagents.filter { $0.status == .running }.count) { old, new in new > old }
        .sensoryFeedback(.impact(weight: .medium), trigger: outgoing.count + pendingQueued.count) { old, new in new > old }
        .onChange(of: cursorWorking) { _, now in if now { withAnimation(BUI.easeOutStrong) { startingSince = nil } } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if let q = question {
                    DesktopQuestionCard(ref: ref, question: q, showChat: false)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let p = pending {
                    DesktopApprovalCard(ref: ref, pending: p, showChat: false)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                QueuedStack(items: shownQueue) { id in
                    await sendQueuedNow(id)
                } edit: { id, text in
                    guard !id.hasPrefix("out-") else { return false }
                    let before = editedQueued[id]
                    withAnimation(BUI.easeOutStrong) { editedQueued[id] = text }
                    let ok = await model.editQueued(desktop: ref, id: id, text: text)
                    if !ok { withAnimation(BUI.easeOutStrong) { editedQueued[id] = before } }
                    return ok
                } remove: { id in
                    guard !id.hasPrefix("out-") else { return false }
                    withAnimation(BUI.easeOutStrong) { hiddenQueued[id] = .now }
                    let ok = await model.removeQueued(desktop: ref, id: id)
                    if !ok { withAnimation(BUI.easeOutStrong) { _ = hiddenQueued.removeValue(forKey: id) } }
                    return ok
                } move: { id, to in
                    await model.moveQueued(desktop: ref, id: id, to: to)
                }
                .padding(.horizontal, 12)
                DesktopComposer(placeholder: "Message \(ref.chat)", busy: working, sending: sending, onSend: { text, images in
                    guard let t = talkTarget, !text.isEmpty else { return await send(text, images) }
                    let ok = await send(t.prompt(text), images)
                    if ok { withAnimation(Theme.spring) { talkTarget = nil } }
                    return ok
                }, onStop: {
                    Task { await model.desktopStop(ref) }
                }, target: talkTarget, onPickTarget: { pickingTalk = true }, onClearTarget: { talkTarget = nil })
            }
            .animation(BUI.easeOutStrong, value: pending)
            .animation(BUI.easeOutStrong, value: question)
        }
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.docRoot, window.flatMap { model.workspace(for: $0)?.folders.first })
        .environment(\.docChat, composerId)
        #if DEBUG
        .onAppear {
            if UserDefaults.standard.bool(forKey: "openTalk") { Task { try? await Task.sleep(for: .seconds(2)); pickingTalk = true } }
            if let n = UserDefaults.standard.string(forKey: "talkTo"), !n.isEmpty { talkTarget = TalkTarget(id: "chat:debug", name: n, isChat: true, workspace: "storefront") }
        }
        #endif
        .sheet(isPresented: $pickingTalk) {
            TalkPicker(excluding: composerId.map { "chat:\($0)" } ?? "") { t in
                pickingTalk = false
                withAnimation(Theme.spring) { talkTarget = t }
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(24)
            .presentationBackground(BUI.page)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(ref.chat).font(.inter(15.5, .semibold)).tight(15.5).foregroundStyle(BUI.ink).lineLimit(1)
                    HStack(spacing: 4) {
                        Circle().fill(status.tone.dot).frame(width: 6, height: 6)
                        Text("\(window?.workspace ?? "Cursor") · \(working ? "Working" : status.label)")
                            .font(.inter(11.5)).foregroundStyle(BUI.ink2).contentTransition(.opacity)
                    }
                    .animation(BUI.easeOutStrong, value: working)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { ChangesButton(root: window.flatMap { model.workspace(for: $0)?.folders.first }) }
            ToolbarItem(placement: .topBarTrailing) { ThinkingToggle() }
        }
        .task(id: ref) { await poll() }
        .onAppear { model.activeDesktopChat = ref }
        .onDisappear { if model.activeDesktopChat == ref { model.activeDesktopChat = nil } }
        }
    }

    private func poll() async {
        composerId = chat?.composerId
        while !Task.isCancelled {
            do {
                let began = Date()
                let asked = tail
                let t = try await model.desktopTranscript(ref, composerId: composerId, tail: asked)
                // A page loaded while this was in flight; this answer is smaller and would cut it off.
                guard asked == tail else { continue }
                composerId = t.composerId
                total = t.total ?? t.items.count
                slog("poll items:\(t.items.count) total:\(total) last:\(t.items.last?.id ?? "-")")
                withAnimation(items == nil ? nil : BUI.easeOutStrong) {
                    items = t.items
                    live = t.live ?? []
                    liveTurn = t.liveTurn ?? false
                    let q = t.queued ?? []
                    queued = q
                    subagents = t.subagents ?? []
                    let ids = Set(q.map(\.id))
                    // Listed now, or missing from a poll that started after it was added (Cursor already ran it).
                    localQueued.removeAll { ids.contains($0.0.id) || began > $0.1 }
                    hiddenQueued = hiddenQueued.filter { ids.contains($0.key) && Date().timeIntervalSince($0.value) < 20 }
                    queueKeys = queueKeys.filter { k in ids.contains(k.key) || localQueued.contains { $0.0.id == k.key } }
                    editedQueued = editedQueued.filter { e in q.contains { $0.id == e.key && $0.text != e.value } }
                    for o in outgoing where userCount(o.text, in: t.items) > (outgoingBase[o.id] ?? 0) {
                        let text = (o.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if let real = t.items.last(where: { $0.kind == .user && ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == text && sentIds[$0.id] == nil }) {
                            sentIds[real.id] = o.id
                        }
                    }
                    outgoing.removeAll { o in sentIds.values.contains(o.id) || userCount(o.text, in: t.items) > (outgoingBase[o.id] ?? 0) }
                }
                loadError = nil
            } catch {
                if items == nil { loadError = error.localizedDescription }
            }
            let busy = working || subagents.contains { $0.status == .running }
            try? await Task.sleep(for: .milliseconds(busy ? 1200 : 2500))
        }
    }

    private func slog(_ m: String) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "scrollLog") { print("[scroll] \(Date().timeIntervalSince1970) \(m)") }
        #endif
    }

    private func pinToBottom(_ reader: ScrollViewProxy) {
        slog("pin settling:\(settling)")
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { reader.scrollTo(Self.bottomId, anchor: .bottom) }
    }

    private func endSettling() {
        settling = false
        if !revealed { withAnimation(.easeOut(duration: 0.2)) { revealed = true } }
        canPage = true
    }

    /// Fetches the next page of older messages. They land above what's on screen, which stays put.
    private func loadOlder(_ reader: ScrollViewProxy) async {
        guard canPage, !loadingOlder, let have = items, have.count < total else { return }
        slog("loadOlder tail:\(tail) have:\(have.count) total:\(total)")
        loadingOlder = true
        defer { loadingOlder = false }
        let want = tail + Self.page
        guard let t = try? await model.desktopTranscript(ref, composerId: composerId, tail: want) else { return }
        // The message at the top of the screen before the page lands goes back to the top after.
        let anchor = ChatSegment.build(have).first?.id
        tail = want
        total = t.total ?? t.items.count
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            items = t.items
            if let anchor { reader.scrollTo(anchor, anchor: .top) }
        }
        // Still at the top (a short page, or a fast flick): keep going.
        try? await Task.sleep(for: .milliseconds(250))
        if loaderVisible { loadingOlder = false; await loadOlder(reader) }
    }

    private var shownQueue: [QueuedMessage] {
        let local = localQueued.map(\.0).filter { l in !queued.contains { $0.id == l.id } }
        return (queued + local)
            .filter { hiddenQueued[$0.id] == nil }
            .map { q in QueuedMessage(id: q.id, text: editedQueued[q.id] ?? q.text, key: queueKeys[q.id]) }
            + pendingQueued
    }

    private func userCount(_ text: String?, in list: [Item]) -> Int {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return list.reduce(0) { $0 + ($1.kind == .user && ($1.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == t ? 1 : 0) }
    }

    /// Shows a message as sent in the chat until Cursor's copy of it arrives.
    private func addOutgoing(_ text: String, shown: String? = nil) -> Item {
        let item = Item(id: "out-\(UUID().uuidString)", ts: Date().timeIntervalSince1970 * 1000, kind: .user, text: shown ?? text)
        outgoingBase[item.id] = userCount(item.text, in: items ?? [])
        withAnimation(BUI.easeOutStrong) {
            outgoing.append(item)
            startingSince = .now
        }
        return item
    }

    /// Cursor stops the current run and starts this message, so it moves from the queue into the chat.
    private func sendQueuedNow(_ id: String) async -> Bool {
        guard !id.hasPrefix("out-"), let q = shownQueue.first(where: { $0.id == id }) else { return false }
        withAnimation(BUI.easeOutStrong) { hiddenQueued[id] = .now }
        let item = addOutgoing(q.text)
        let ok = await model.sendQueuedNow(desktop: ref, id: id)
        withAnimation(BUI.easeOutStrong) {
            if ok {
                _ = delivered.insert(item.id)
            } else {
                hiddenQueued.removeValue(forKey: id)
                outgoing.removeAll { $0.id == item.id }
                startingSince = nil
            }
        }
        return ok
    }

    private func send(_ text: String, _ images: [OutgoingImage]) async -> Bool {
        if cursorWorking, images.isEmpty, !text.isEmpty { return await enqueue(text) }
        sending = true
        defer { sending = false }
        let note = images.isEmpty ? "" : (images.count == 1 ? "📎 1 photo" : "📎 \(images.count) photos")
        let shown = [text, note].filter { !$0.isEmpty }.joined(separator: "\n")
        let item = addOutgoing(text, shown: text.isEmpty ? shown : text)
        guard let r = await model.desktopSend(window: ref.window, chat: ref.chat, text: text, images: images) else {
            withAnimation(BUI.easeOutStrong) {
                outgoing.removeAll { $0.id == item.id }
                startingSince = nil
            }
            return false
        }
        withAnimation(BUI.easeOutStrong) {
            if let qid = r.queued {
                // Cursor was busy after all and queued it.
                outgoing.removeAll { $0.id == item.id }
                startingSince = nil
                localQueued.append((QueuedMessage(id: qid, text: text), .now))
            } else {
                _ = delivered.insert(item.id)
            }
        }
        return true
    }

    /// What Cursor is rendering right now that the transcript file hasn't caught up with.
    private var liveActivity: [DesktopLiveRow] {
        Array(live.filter { $0.role == "ai" }.suffix(3))
    }

    /// The agent is busy, so Cursor will queue this: put it in the queue now instead of the chat.
    private func enqueue(_ text: String) async -> Bool {
        let q = QueuedMessage(id: "out-\(UUID().uuidString)", text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        withAnimation(BUI.easeOutStrong) { pendingQueued.append(q) }
        guard let r = await model.desktopSend(window: ref.window, chat: ref.chat, text: text) else {
            withAnimation(BUI.easeOutStrong) { pendingQueued.removeAll { $0.id == q.id } }
            return false
        }
        if let qid = r.queued {
            withAnimation(BUI.easeOutStrong) {
                pendingQueued.removeAll { $0.id == q.id }
                queueKeys[qid] = q.id
                localQueued.append((QueuedMessage(id: qid, text: q.text), .now))
            }
        } else {
            // The agent finished in the meantime, so Cursor started it as a new turn.
            withAnimation(BUI.easeOutStrong) { pendingQueued.removeAll { $0.id == q.id } }
            let item = addOutgoing(q.text)
            withAnimation(BUI.easeOutStrong) { _ = delivered.insert(item.id) }
        }
        return true
    }

    /// Whether the last item already animates on its own (a running tool, a streaming thought, a timer).
    private static func showsProgress(_ last: Item?) -> Bool {
        guard let last else { return false }
        if last.kind == .thinking { return last.streaming == true }
        return last.kind == .tool && last.tool?.status == "running"
    }

    private func unsyncedReply(_ all: [Item]) -> String? {
        guard !working, let last = live.last, last.role == "ai", last.kind == "assistant" else { return nil }
        let key = Self.fingerprint(last.text)
        guard key.count >= 12 else { return nil }
        let known = all.suffix(12).filter { $0.kind == .assistant || $0.kind == .thinking }.map { Self.fingerprint($0.text ?? "") }
        return known.contains { $0.hasPrefix(key) || key.hasPrefix($0.prefix(key.count)) } ? nil : last.text
    }

    private static func fingerprint(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(48))
    }
}

struct DesktopSegmentView: View {
    var segment: ChatSegment
    var live: Bool

    var body: some View {
        switch segment {
        case .item(let item): DesktopItemView(item: item)
        case .thought(let item, let end):
            ThinkingTrace(text: item.text ?? "", working: item.streaming == true, duration: item.durationMs.map { $0 / 1000 } ?? end.map { ($0 - item.ts) / 1000 })
        case .run(let items): ToolChipsRun(items: items, live: live)
        }
    }
}

struct DesktopItemView: View {
    var item: Item

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(item.text ?? "")
                    .font(.inter(15.5)).tight(15.5).lineSpacing(2)
                    .foregroundStyle(BUI.ink)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(BUI.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .textSelection(.enabled)
            }
        case .assistant:
            MarkdownText(text: item.text ?? "").frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            ThinkingTrace(text: item.text ?? "", working: false, duration: item.durationMs.map { $0 / 1000 })
        case .tool:
            if let id = item.tool?.meta?.subagentId {
                SubagentCard(id: id, task: item)
            } else if let r = item.tool?.meta?.waitRange {
                WaitCard(item: item, range: r)
            } else {
                ToolChipsRun(items: [item], live: false)
            }
        case .agent_message:
            AgentMessageCard(item: item)
        case .system:
            SystemNotice(text: item.text ?? "")
        case .error:
            HStack(alignment: .top, spacing: 10) {
                ResultBadge(tone: .red, symbol: "exclamationmark", size: 20)
                Text(item.text ?? "Error").font(.inter(14)).foregroundStyle(BUI.ink)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(BUI.redTint, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        default:
            EmptyView()
        }
    }
}

/// The desktop's own in-flight rows, shown while the agent works.
/// Something Cursor reported on its own, like a background job finishing: a quiet divider, not a message.
struct SystemNotice: View {
    var text: String

    private var symbol: (String, Color) {
        if text.contains(" failed") { return ("xmark.circle.fill", BUI.red) }
        if text.contains(" stopped") { return ("stop.circle.fill", BUI.ink3) }
        return ("checkmark.circle.fill", BUI.green)
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(BUI.line).frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: symbol.0).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(symbol.1)
                Text(text).font(.inter(12)).foregroundStyle(BUI.ink3).lineLimit(1).truncationMode(.middle)
            }
            .layoutPriority(1)
            Rectangle().fill(BUI.line).frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Under a message you just sent: "Sending…" until Cursor has it, then a quiet check.
struct SendStatus: View {
    var delivered: Bool

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            ZStack {
                if delivered {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(BUI.accentInk)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    MiniSpinner(size: 9).transition(.opacity)
                }
            }
            .frame(width: 11, height: 11)
            Text(delivered ? "Delivered" : "Sending…")
                .font(.inter(11.5)).foregroundStyle(BUI.ink3)
                .contentTransition(.opacity)
        }
        .padding(.top, -10)
        .animation(BUI.easeOutStrong, value: delivered)
        .accessibilityElement(children: .combine)
    }
}

/// The agent is between steps: a quiet line at the end of the chat, where the next step will appear.
/// Sits above the oldest loaded message; scrolling it into view fetches the page before.
struct OlderPageLoader: View {
    var loading: Bool

    var body: some View {
        HStack(spacing: 8) {
            MiniSpinner(size: 11)
            Text("Loading earlier messages").font(.inter(12.5, .medium)).foregroundStyle(BUI.ink3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .opacity(loading ? 1 : 0.7)
        .animation(BUI.easeOutStrong, value: loading)
        .accessibilityLabel("Loading earlier messages")
    }
}

/// The top of a chat once everything has loaded.
struct ChatStartMarker: View {
    var title: String
    @State private var shown = false

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(BUI.line).frame(height: 1)
            HStack(spacing: 6) {
                Sparkle().fill(BUI.ink3).frame(width: 9, height: 9)
                    .rotationEffect(.degrees(shown ? 90 : 0))
                Text("Start of \(title)").font(.inter(11.5, .medium)).foregroundStyle(BUI.ink3).lineLimit(1)
            }
            .fixedSize()
            Rectangle().fill(BUI.line).frame(height: 1)
        }
        .padding(.vertical, 12)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.3)) { shown = true } }
        .accessibilityElement(children: .combine)
    }
}

struct WorkingTail: View {
    var label = "Working"

    var body: some View {
        HStack(spacing: 8) {
            Sparkle().fill(BUI.accent).frame(width: 12, height: 12)
                .phaseAnimator([0.0, 1.0]) { v, p in v.rotationEffect(.degrees(p * 90)).scaleEffect(0.85 + p * 0.15) } animation: { _ in .easeInOut(duration: 0.9) }
            ShimmerText(text: label, font: .inter(13, .medium))
                .id(label)
                .transition(.opacity)
        }
        .animation(BUI.easeOutStrong, value: label)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Agent is working")
    }
}

struct DesktopLiveCard: View {
    var rows: [DesktopLiveRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LoadingState(label: "Working on your Mac")
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(r.kind))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(BUI.ink3)
                        .frame(width: 16, height: 18)
                    Text(r.text.split(separator: "\n").prefix(3).joined(separator: " · "))
                        .font(r.kind == "tool" ? .jbMono(12) : .inter(13))
                        .foregroundStyle(BUI.ink2)
                        .lineLimit(3)
                        .contentTransition(.opacity)
                }
                .transition(.fadeUp)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous).strokeBorder(BUI.line))
        .animation(BUI.easeOutStrong, value: rows)
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "tool": return "wrench.and.screwdriver"
        case "thinking": return "sparkle"
        default: return "text.bubble"
        }
    }
}

/// Cursor is blocked on a tool approval (usually a shell command). Same choices as the desktop.
struct DesktopApprovalCard: View {
    @Environment(AppModel.self) private var model
    var ref: DesktopRef
    var pending: DesktopPending
    var showChat: Bool
    @State private var busy: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ResultBadge(tone: .orange, symbol: "hand.raised.fill", size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Waiting for approval").font(.inter(14, .semibold)).foregroundStyle(BUI.ink)
                    if showChat, !pending.chat.isEmpty {
                        Text(pending.chat).font(.inter(12)).foregroundStyle(BUI.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            Text(pending.label)
                .font(.jbMono(12))
                .foregroundStyle(BUI.ink)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            HStack(spacing: 8) {
                Spacer()
                Button {
                    act(false)
                } label: {
                    HStack(spacing: 6) {
                        if busy == false { MiniSpinner(size: 11) }
                        Text(pending.reject ?? "Skip")
                    }
                }
                .buttonStyle(.bui(.ghost, .sm))
                Button {
                    act(true)
                } label: {
                    HStack(spacing: 6) {
                        if busy == true { MiniSpinner(size: 11) }
                        Text(pending.approve)
                    }
                }
                .buttonStyle(.bui(.accent, .sm))
            }
            .disabled(busy != nil)
        }
        .padding(14)
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
        .elevation(.raised, radius: BUI.Radius.window)
        .sensoryFeedback(.impact(weight: .light), trigger: busy)
    }

    private func act(_ approve: Bool) {
        busy = approve
        Task {
            _ = await model.desktopRespond(ref, approve: approve)
            busy = nil
        }
    }
}

/// PromptBar-style composer for desktop chats: text in, square send, stop while working.
struct DesktopComposer: View {
    var placeholder: String
    var busy: Bool
    var sending: Bool
    var onSend: (String, [OutgoingImage]) async -> Bool
    var onStop: () -> Void
    /// Who the next message is aimed at, when this chat is talking to another chat or agent.
    var target: TalkTarget? = nil
    var onPickTarget: (() -> Void)? = nil
    var onClearTarget: (() -> Void)? = nil

    @State private var text = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var images: [(UIImage, OutgoingImage)] = []
    @State private var pickingLibrary = false
    @State private var takingPhoto = false
    @FocusState private var focused: Bool
    /// Right after a send the button would turn into Stop under the same finger; hold off briefly.
    @State private var justSent = false
    private var canSend: Bool { (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) && !sending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let target {
                TalkChip(from: "This chat", target: target) { withAnimation(Theme.spring) { onClearTarget?() } }
                    .padding(.leading, 6)
                    .padding(.top, 2)
            }
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                            Image(uiImage: img.0).resizable().scaledToFill().frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
                                .elevation(.hairline, radius: BUI.Radius.control)
                                .overlay(alignment: .topTrailing) {
                                    Button { withAnimation(BUI.easeOutStrong) { _ = images.remove(at: i) } } label: {
                                        Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                                            .frame(width: 18, height: 18).background(BUI.tooltipBg, in: Circle())
                                    }
                                    .offset(x: 5, y: -5)
                                    .accessibilityLabel("Remove photo")
                                }
                                .transition(.popIn)
                        }
                    }
                    .padding(.top, 6).padding(.trailing, 6).padding(.leading, 2)
                }
                .scrollIndicators(.hidden)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 6) {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { pickingLibrary = true }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button("Take Photo", systemImage: "camera") { takingPhoto = true }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BUI.ink3)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Attach photos")
                if let onPickTarget {
                    Button(action: onPickTarget) {
                        Image(systemName: "at").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(target == nil ? BUI.ink3 : BUI.accentInk)
                            .frame(width: 28, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .accessibilityLabel("Talk to another chat or agent")
                }
                TextField(target.map { "What should this chat tell \($0.name)?" } ?? (images.isEmpty ? placeholder : "Add a message (optional)"), text: $text, axis: .vertical)
                    .font(.inter(15.5))
                    .foregroundStyle(BUI.ink)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.vertical, 6)
                Button {
                    if canSend {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let imgs = images
                        text = ""
                        withAnimation(BUI.easeOutStrong) { images = []; justSent = true }
                        Task {
                            try? await Task.sleep(for: .milliseconds(1500))
                            withAnimation(BUI.easeOutStrong) { justSent = false }
                        }
                        Task {
                            if !(await onSend(t, imgs.map(\.1))) {
                                text = t
                                withAnimation(BUI.easeOutStrong) { images = imgs }
                            }
                        }
                    } else if busy, !justSent {
                        onStop()
                    }
                } label: {
                    ZStack {
                        if sending { MiniSpinner(size: 13).tint(.white) }
                        else if justSent && !canSend { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(BUI.surface) }
                        else if busy && !canSend { RoundedRectangle(cornerRadius: 2.5).fill(BUI.surface).frame(width: 10, height: 10) }
                        else { Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).foregroundStyle(BUI.surface) }
                    }
                    .frame(width: 32, height: 32)
                    .background(canSend || busy || sending ? BUI.ink : BUI.lineStrong, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressableStyle())
                .disabled(!canSend && !busy)
                .accessibilityLabel(justSent && !canSend ? "Sent" : busy && !canSend ? "Stop" : "Send")
                .sensoryFeedback(.impact(weight: .light), trigger: sending)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .animation(BUI.easeOutStrong, value: images.count)
        .animation(Theme.spring, value: target)
        .photosPicker(isPresented: $pickingLibrary, selection: $photos, maxSelectionCount: 6, matching: .images)
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { img in add(img) }.ignoresSafeArea()
        }
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { add(img) }
                }
                photos = []
            }
        }
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous).strokeBorder(focused ? BUI.lineStrong : BUI.line))
        .elevation(.raised, radius: BUI.Radius.window)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [BUI.page.opacity(0), BUI.page], startPoint: .top, endPoint: .center).ignoresSafeArea())
        .animation(BUI.easeOutFast, value: focused)
        .animation(BUI.easeOutFast, value: canSend)
    }
}

/// Cursor's AskQuestion, answerable from the phone: tap an option or write your own.
struct DesktopQuestionCard: View {
    @Environment(AppModel.self) private var model
    var ref: DesktopRef
    var question: DesktopQuestion
    var showChat: Bool

    @State private var picks: [Int: String] = [:]
    @State private var custom: [Int: String] = [:]
    @State private var writing: Int?
    @State private var sending = false
    @FocusState private var focused: Bool

    private var complete: Bool {
        question.questions.allSatisfy { q in picks[q.index] != nil || !(custom[q.index] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ResultBadge(tone: .accent, symbol: "questionmark", size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(question.questions.count > 1 ? "\(question.questions.count) questions" : "Question").font(.inter(13, .semibold)).foregroundStyle(BUI.ink2)
                    if showChat, !question.chat.isEmpty {
                        Text(question.chat).font(.inter(12)).foregroundStyle(BUI.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            ForEach(question.questions) { q in
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.prompt).font(.inter(15, .medium)).tight(15).foregroundStyle(BUI.ink).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 6) {
                        ForEach(Array(q.options.enumerated()), id: \.offset) { i, opt in
                            option(q: q, letter: String(UnicodeScalar(65 + i).map(Character.init) ?? "•"), label: opt)
                        }
                        if q.freeform { freeform(q) }
                    }
                }
            }
            HStack {
                Spacer()
                Button { Task { await send() } } label: {
                    HStack(spacing: 6) {
                        if sending { MiniSpinner(size: 11) }
                        Text(question.questions.count > 1 ? "Send answers" : "Send")
                    }
                }
                .buttonStyle(.bui(.accent, .sm))
                .disabled(!complete || sending)
            }
        }
        .padding(14)
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
        .elevation(.raised, radius: BUI.Radius.window)
        .animation(BUI.easeOutStrong, value: picks)
        .animation(BUI.easeOutStrong, value: writing)
        .sensoryFeedback(.selection, trigger: picks)
    }

    private func option(q: DesktopQuestion.Q, letter: String, label: String) -> some View {
        let on = picks[q.index] == label
        return Button {
            picks[q.index] = on ? nil : label
            custom[q.index] = nil
            if writing == q.index { writing = nil }
            if !on, question.questions.count == 1 {
                Task {
                    try? await Task.sleep(for: .milliseconds(420))
                    if picks[q.index] == label { await send() }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(letter)
                    .font(.jbMono(11.5, .medium))
                    .foregroundStyle(on ? BUI.surface : BUI.ink2)
                    .frame(width: 22, height: 22)
                    .background(on ? BUI.accent : BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
                Text(label).font(.inter(14.5)).foregroundStyle(BUI.ink).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(BUI.accentInk).transition(.scale.combined(with: .opacity)) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(on ? BUI.accentTint : BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous).strokeBorder(on ? BUI.accent.opacity(0.5) : BUI.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .disabled(sending)
    }

    @ViewBuilder private func freeform(_ q: DesktopQuestion.Q) -> some View {
        if writing == q.index {
            TextField("Your answer", text: Binding(get: { custom[q.index] ?? "" }, set: { custom[q.index] = $0; if !$0.isEmpty { picks[q.index] = nil } }), axis: .vertical)
                .font(.inter(14.5))
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous).strokeBorder(BUI.lineStrong))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                .onAppear { focused = true }
        } else {
            Button { writing = q.index; picks[q.index] = nil } label: {
                HStack(spacing: 8) {
                    Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                    Text("Something else…").font(.inter(14))
                    Spacer()
                }
                .foregroundStyle(BUI.ink2)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.98))
            .transition(.opacity)
        }
    }

    private func send() async {
        guard complete, !sending else { return }
        sending = true
        let answers = question.questions.map { q -> AppModel.DesktopAnswer in
            if let p = picks[q.index] { return .init(index: q.index, option: p, text: nil) }
            return .init(index: q.index, option: nil, text: custom[q.index]?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        _ = await model.desktopAnswer(ref, answers)
        sending = false
    }
}

/// Messages waiting for the agent to finish its current turn. They send themselves in order.
struct QueuedStack: View {
    var items: [QueuedMessage]
    var sendNow: (String) async -> Bool
    var edit: (String, String) async -> Bool
    var remove: (String) async -> Bool
    /// Moves a queued message to a new position; rows can be held and dragged when this is set.
    var move: ((String, Int) async -> Bool)? = nil

    @State private var editingId: String?
    @State private var draft = ""
    @State private var saving = false
    @FocusState private var editorFocused: Bool
    @State private var removing: Set<String> = []
    @State private var sending: Set<String> = []
    @State private var expanded = false
    @AppStorage("queueCollapsed") private var collapsed = false
    /// The order the user dropped rows into, shown until the queue on the Mac catches up.
    @State private var order: [String]?
    @State private var frames: [String: CGRect] = [:]
    @State private var drag: Drag?
    @State private var lifts = 0
    @State private var steps = 0
    @State private var drops = 0

    private struct Drag: Equatable {
        var id: String
        var from: Int
        var to: Int
        var dy: CGFloat
        /// Row frames when the drag began, before anything moved.
        var frames: [String: CGRect]
        var ids: [String]
    }

    private static let shuffle = Animation.spring(duration: 0.32, bounce: 0.12)
    /// How a row is leaving, so it exits in the direction of its action.
    private enum Departure { case sent, removed }
    @State private var departing: [String: Departure] = [:]

    private static let exit = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.16)

    /// Sent rows lift toward the chat where their bubble appears; removed rows slide toward their X.
    private func removal(_ id: String) -> AnyTransition {
        switch departing[id] {
        case .sent: AnyTransition.opacity.combined(with: .offset(y: -14)).combined(with: .scale(scale: 0.97, anchor: .top)).animation(Self.exit)
        case .removed: AnyTransition.opacity.combined(with: .offset(x: 28)).animation(Self.exit)
        case nil: AnyTransition.opacity.animation(Self.exit)
        }
    }

    private func tapSend(_ q: QueuedMessage) {
        sending.insert(q.id)
        depart(q.id, .sent) {
            let ok = await sendNow(q.id)
            sending.remove(q.id)
            return ok
        }
    }

    private func tapRemove(_ q: QueuedMessage) {
        removing.insert(q.id)
        depart(q.id, .removed) {
            let ok = await remove(q.id)
            removing.remove(q.id)
            return ok
        }
    }

    /// Waits a frame so the row picks up its exit before the parent drops it.
    private func depart(_ id: String, _ how: Departure, _ action: @escaping () async -> Bool) {
        departing[id] = how
        Task {
            try? await Task.sleep(for: .milliseconds(20))
            if !(await action()) { departing[id] = nil }
        }
    }

    private var ordered: [QueuedMessage] {
        guard let order else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated()
            .sorted { (rank[$0.element.id] ?? 1000 + $0.offset) < (rank[$1.element.id] ?? 1000 + $1.offset) }
            .map(\.element)
    }

    private var shown: [QueuedMessage] { expanded || items.count <= 2 ? ordered : Array(ordered.prefix(2)) }

    private func canDrag(_ q: QueuedMessage) -> Bool {
        move != nil && editingId == nil && !q.id.hasPrefix("out-") && shown.filter { !$0.id.hasPrefix("out-") }.count > 1
    }

    /// Where a row sits while another is being dragged past it.
    private func offset(_ id: String, at j: Int) -> CGFloat {
        guard let d = drag else { return 0 }
        if id == d.id { return d.dy }
        let h = (d.frames[d.id]?.height ?? 0) + 4
        if d.from < d.to, j > d.from, j <= d.to { return -h }
        if d.to < d.from, j >= d.to, j < d.from { return h }
        return 0
    }

    private func liveIndex(_ id: String, at j: Int) -> Int {
        guard let d = drag else { return j }
        if id == d.id { return d.to }
        if d.from < d.to, j > d.from, j <= d.to { return j - 1 }
        if d.to < d.from, j >= d.to, j < d.from { return j + 1 }
        return j
    }

    private func reorder(_ q: QueuedMessage, at i: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("queue")))
            .onChanged { v in
                guard case .second(true, let d) = v else { return }
                if drag == nil { lift(q, at: i) }
                if let d { dragged(d.translation.height) }
            }
            .onEnded { _ in dropped() }
    }

    private func lift(_ q: QueuedMessage, at i: Int) {
        let ids = shown.map(\.id)
        withAnimation(Self.shuffle) { drag = Drag(id: q.id, from: i, to: i, dy: 0, frames: frames, ids: ids) }
        lifts += 1
    }

    private func dragged(_ dy: CGFloat) {
        guard var d = drag, let me = d.frames[d.id] else { return }
        let movable = d.ids.filter { !$0.hasPrefix("out-") }
        let top = movable.compactMap { d.frames[$0]?.minY }.min() ?? me.minY
        let bottom = movable.compactMap { d.frames[$0]?.maxY }.max() ?? me.maxY
        d.dy = min(bottom - me.maxY + 2, max(top - me.minY - 2, dy))
        let center = me.midY + d.dy
        let others = movable.filter { $0 != d.id }
        let to = others.filter { (d.frames[$0]?.midY ?? .infinity) < center }.count
        if to != d.to {
            steps += 1
            withAnimation(Self.shuffle) { d.to = to; drag = d }
        } else {
            drag = d
        }
    }

    private func dropped() {
        guard let d = drag else { return }
        guard d.to != d.from else {
            withAnimation(Self.shuffle) { drag = nil }
            return
        }
        let passed = d.from < d.to ? Array(d.ids[(d.from + 1)...d.to]) : Array(d.ids[d.to..<d.from])
        let span = passed.reduce(0) { $0 + (d.frames[$1]?.height ?? 0) + 4 }
        withAnimation(Self.shuffle) { drag?.dy = d.from < d.to ? span : -span }
        drops += 1
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            commit(d.id, to: d.to, animated: false)
        }
    }

    /// Shows the new order right away and asks the Mac to match it; puts it back if that fails.
    private func commit(_ id: String, to: Int, animated: Bool) {
        var ids = ordered.map(\.id)
        guard let from = ids.firstIndex(of: id), let move else { return }
        ids.remove(at: from)
        ids.insert(id, at: min(to, ids.count))
        var t = Transaction(animation: animated ? Self.shuffle : nil)
        t.disablesAnimations = !animated
        withTransaction(t) {
            order = ids
            drag = nil
        }
        let target = ids.filter { !$0.hasPrefix("out-") }.firstIndex(of: id) ?? to
        Task {
            let ok = await move(id, target)
            if !ok { withAnimation(Self.shuffle) { order = nil } }
            try? await Task.sleep(for: .seconds(10))
            if order == ids { order = nil }
        }
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: collapsed ? 0 : 6) {
                HStack(spacing: 6) {
                    Button {
                        guard editingId == nil else { return }
                        withAnimation(BUI.easeOutStrong) { collapsed.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .semibold))
                            Text("Queued").font(.inter(12, .semibold))
                            Text("\(items.count)").font(.jbMono(11.5, .medium)).contentTransition(.numericText())
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(collapsed ? -90 : 0))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(items.count) queued")
                    .accessibilityHint(collapsed ? "Shows the queued messages" : "Hides the queued messages")
                    if items.count > 2 && !collapsed {
                        Button { withAnimation(BUI.easeOutStrong) { expanded.toggle() } } label: {
                            HStack(spacing: 3) {
                                Text(expanded ? "Less" : "All").font(.inter(12, .medium))
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 180 : 0))
                            }
                        }
                        .buttonStyle(PressableStyle(scale: 0.96))
                        .transition(.opacity)
                    }
                }
                .foregroundStyle(BUI.ink2)
                .padding(.horizontal, 4)
                .background(BUI.surface)
                .zIndex(1)

                if !collapsed {
                    VStack(spacing: 4) {
                        ForEach(Array(shown.enumerated()), id: \.element.rowKey) { i, q in
                            let lifted = drag?.id == q.id
                            row(q, index: liveIndex(q.id, at: i))
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("queue")) } action: { frames[q.id] = $0 }
                                .scaleEffect(lifted ? 1.015 : 1)
                                .shadow(color: .black.opacity(lifted ? 0.14 : 0), radius: lifted ? 10 : 0, y: lifted ? 4 : 0)
                                .offset(y: offset(q.id, at: i))
                                .zIndex(lifted ? 2 : 0)
                                .gesture(reorder(q, at: i), isEnabled: canDrag(q))
                                .accessibilityAction(named: "Move up") { if canDrag(q), i > 0 { commit(q.id, to: i - 1, animated: true) } }
                                .accessibilityAction(named: "Move down") { if canDrag(q), i < shown.count - 1 { commit(q.id, to: i + 1, animated: true) } }
                                .transition(.asymmetric(
                                    insertion: AnyTransition.opacity.combined(with: .offset(y: 8)).animation(BUI.easeOutStrong.delay(0.12)),
                                    removal: removal(q.id)
                                ))
                        }
                    }
                    .coordinateSpace(.named("queue"))
                    .clipShape(.rect(cornerRadius: 8))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(collapsed ? 8 : 10)
            .clipped()
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
            .elevation(.raised, radius: BUI.Radius.window)
            .animation(BUI.easeOutStrong, value: items)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: items.count) { old, new in new < old }
            .sensoryFeedback(.impact(weight: .medium), trigger: lifts)
            .sensoryFeedback(.selection, trigger: steps)
            .sensoryFeedback(.impact(weight: .light), trigger: drops)
            .onChange(of: items.map(\.id)) { _, ids in
                if let order, order.filter(ids.contains) == ids { self.order = nil }
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .queueLabTap)) { n in
                guard let id = n.userInfo?["id"] as? String, let q = items.first(where: { $0.id == id }) else { return }
                switch n.userInfo?["action"] as? String {
                case "send": tapSend(q)
                case "lift": if let i = shown.firstIndex(of: q) { lift(q, at: i) }
                case "drag": dragged(n.userInfo?["dy"] as? CGFloat ?? 0)
                case "drop": dropped()
                default: tapRemove(q)
                }
            }
            #endif
            .transition(.asymmetric(
                insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)).animation(BUI.easeOutStrong),
                removal: AnyTransition.opacity.combined(with: .scale(scale: 0.97, anchor: .bottom)).animation(.timingCurve(0.4, 0, 1, 1, duration: 0.12))
            ))
        }
    }

    @ViewBuilder private func row(_ q: QueuedMessage, index: Int) -> some View {
        if editingId == q.id { editor(q, index: index) } else { display(q, index: index) }
    }

    private func editor(_ q: QueuedMessage, index: Int) -> some View {
        let changed = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines) != q.text
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index + 1)").font(.jbMono(11, .medium)).foregroundStyle(BUI.accentInk).frame(width: 14)
                TextField("Message", text: $draft, axis: .vertical)
                    .font(.inter(13.5))
                    .foregroundStyle(BUI.ink)
                    .lineLimit(1...8)
                    .focused($editorFocused)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { withAnimation(BUI.easeOutStrong) { editingId = nil } }
                    .buttonStyle(.bui(.ghost, .sm))
                    .disabled(saving)
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    saving = true
                    Task {
                        let ok = await edit(q.id, text)
                        saving = false
                        if ok { withAnimation(BUI.easeOutStrong) { editingId = nil } }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if saving { MiniSpinner(size: 10) }
                        Text("Save")
                    }
                }
                .buttonStyle(.bui(.primary, .sm))
                .disabled(!changed || saving)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous).strokeBorder(BUI.accent.opacity(0.45)))
        .onAppear { editorFocused = true }
    }

    private func display(_ q: QueuedMessage, index: Int) -> some View {
        let arriving = q.id.hasPrefix("out-")
        let lifted = drag?.id == q.id
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack {
                if lifted {
                    Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .bold)).foregroundStyle(BUI.ink2)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                } else {
                    Text("\(index + 1)").font(.jbMono(11, .medium)).foregroundStyle(BUI.ink3)
                        .contentTransition(.numericText(value: Double(index)))
                        .transition(.opacity)
                }
            }
            .frame(width: 14)
            Button {
                draft = q.text
                withAnimation(BUI.easeOutStrong) { editingId = q.id; expanded = true }
            } label: {
                Text(q.text).font(.inter(13.5)).foregroundStyle(arriving ? BUI.ink2 : BUI.ink).lineLimit(expanded ? 6 : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.99))
            .disabled(arriving || drag != nil)
            .accessibilityHint(move == nil ? "Edit this queued message" : "Edit this queued message. Hold and drag to reorder.")
            if arriving {
                HStack(spacing: 5) {
                    MiniSpinner(size: 10)
                    Text("Queuing").font(.inter(11.5, .medium)).foregroundStyle(BUI.ink3)
                }
                .frame(height: 24)
                .transition(.opacity)
                .accessibilityLabel("Adding to Cursor's queue")
            } else {
                actions(q)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(lifted ? BUI.surface : BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous).strokeBorder(BUI.lineStrong.opacity(lifted ? 1 : 0)))
        .animation(BUI.easeOutStrong, value: arriving)
        .animation(BUI.easeOutFast, value: lifted)
    }

    @ViewBuilder private func actions(_ q: QueuedMessage) -> some View {
            Button { tapSend(q) } label: {
                ZStack {
                    Image(systemName: "arrow.up").font(.system(size: 10.5, weight: .bold))
                }
                .foregroundStyle(BUI.surface)
                .frame(width: 24, height: 24)
                .background(BUI.ink, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .disabled(sending.contains(q.id) || removing.contains(q.id))
            .accessibilityLabel("Send now")
            Button { tapRemove(q) } label: {
                ZStack {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(BUI.ink3)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("Remove queued message")
    }
}

extension DesktopComposer {
    fileprivate func add(_ img: UIImage) {
        let scaled = img.downscaled(maxSide: 1600)
        guard let jpg = scaled.jpegData(compressionQuality: 0.8) else { return }
        withAnimation(BUI.easeOutStrong) { images.append((scaled, OutgoingImage(data: jpg.base64EncodedString(), mimeType: "image/jpeg"))) }
    }
}

/// The system camera, for snapping a photo straight into a message.
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onPick(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: Project threads (Cursor chats and Helm agents in one list)

struct ProjectThread: Identifiable, Hashable {
    enum Kind: Hashable { case chat(window: String, DesktopChat), agent(Agent) }
    var kind: Kind
    /// Stable across renames; also the key for the saved order.
    var id: String
    var title: String
    var updatedAt: Double?

    init(chat: DesktopChat, window: String) {
        kind = .chat(window: window, chat)
        id = chat.orderKey
        title = chat.title
        updatedAt = chat.updatedAt
    }

    init(agent: Agent) {
        kind = .agent(agent)
        id = "agent:\(agent.id)"
        title = agent.name
        updatedAt = agent.updatedAt
    }

    var ref: ThreadRef? {
        switch kind {
        case .chat(let w, let c): c.composerId.map { ThreadRef(kind: .chat(window: w, composerId: $0), title: title, age: c.age) }
        case .agent(let a): ThreadRef(kind: .agent(a.id), title: title, age: relativeTime(a.updatedAt))
        }
    }

    var route: Route {
        switch kind {
        case .chat(let w, let c): .desktopChat(w, c.title)
        case .agent(let a): .agent(a.id)
        }
    }
}

/// Something you can rename, archive or delete: a Cursor chat or a Helm agent.
struct ThreadRef: Identifiable, Hashable {
    enum Kind: Hashable { case chat(window: String, composerId: String), agent(String) }
    var kind: Kind
    var title: String
    var age: String
    var id: String {
        switch kind {
        case .chat(_, let c): c
        case .agent(let a): "agent:\(a)"
        }
    }
}

@Observable final class ThreadActions {
    var renaming: ThreadRef?
    var newName = ""
    var deleting: ThreadRef?
    /// Bumped after each change lands, for a haptic.
    var landed = 0
}

/// The chats-and-agents list for a project, as List sections: swipe to archive, delete or rename,
/// hold and drag to reorder, archived ones folded away at the bottom.
struct ThreadSections: View {
    @Environment(AppModel.self) private var model
    var workspace: Workspace?
    var window: DesktopWindow?
    var actions: ThreadActions
    @State private var showAll = false
    @State private var showArchived = false
    @AppStorage("chatGesturesHintSeen") private var hintSeen = false

    private static let folded = 8

    var body: some View {
        let all = model.threads(workspace, window)
        let folds = all.count > Self.folded + 2
        let shown = showAll || !folds ? all : Array(all.prefix(Self.folded))
        let key = model.projectKey(workspace, window)
        if !all.isEmpty {
            Section {
                ForEach(shown) { t in
                    ZStack {
                        NavigationLink(value: t.route) { EmptyView() }.opacity(0)
                        switch t.kind {
                        case .chat(_, let c): DesktopChatRow(chat: c)
                        case .agent(let a): AgentThreadRow(agent: a)
                        }
                    }
                    .cardRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if let r = t.ref, canManage(t) {
                            Button { run { await model.archive(r) } } label: { Label("Archive", systemImage: "archivebox.fill") }
                                .tint(BUI.ink2)
                            Button { actions.deleting = r } label: { Label("Delete", systemImage: "trash.fill") }
                                .tint(.red)
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if let r = t.ref, canManage(t) {
                            Button { actions.newName = r.title; actions.renaming = r } label: { Label("Rename", systemImage: "pencil") }
                                .tint(BUI.accent)
                        }
                    }
                }
                .onMove { from, to in
                    var next = all
                    next.move(fromOffsets: from, toOffset: to)
                    model.setOrder(next.map(\.id), for: key)
                    actions.landed += 1
                }
                if folds {
                    FoldToggle(open: showAll, hidden: all.count - shown.count) { showAll.toggle() }
                        .cardRow()
                        .moveDisabled(true)
                }
            } header: {
                SectionLabel(text: "Chats", count: all.count).sectionHeader()
            } footer: {
                if all.count > 1 && !hintSeen {
                    Text("Swipe to archive, delete or rename. Hold and drag to reorder.")
                        .font(.inter(12.5))
                        .foregroundStyle(BUI.ink3)
                        .padding(.horizontal, 4)
                        .onDisappear { hintSeen = true }
                }
            }
        }
        archivedSection
    }

    private func canManage(_ t: ProjectThread) -> Bool {
        if case .chat(let w, _) = t.kind { return model.desktopWindow(w)?.manageable == true }
        return true
    }

    private func run(_ work: @escaping () async -> Bool) {
        Task { if await work() { actions.landed += 1 } }
    }

    @ViewBuilder private var archivedSection: some View {
        let archived = model.archivedThreads(workspace, window)
        if !archived.isEmpty {
            Section {
                Button {
                    withAnimation(BUI.easeOutStrong) { showArchived.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox").font(.system(size: 13, weight: .semibold)).foregroundStyle(BUI.ink3)
                            .frame(width: 26)
                        Text("Archived").font(.inter(14.5, .medium)).foregroundStyle(BUI.ink2)
                        Text("\(archived.count)").font(.inter(13, .medium)).foregroundStyle(BUI.ink3)
                            .contentTransition(.numericText())
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(BUI.ink3)
                            .rotationEffect(.degrees(showArchived ? 180 : 0))
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.985))
                .cardRow()
                if showArchived {
                    ForEach(archived) { a in
                        ArchivedChatRow(title: a.title, age: a.age, helm: { if case .agent = a.kind { true } else { false } }()) {
                            run { await model.archive(a, false) }
                        }
                        .cardRow()
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { run { await model.archive(a, false) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                                .tint(BUI.accent)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { actions.deleting = a } label: { Label("Delete", systemImage: "trash.fill") }
                                .tint(.red)
                        }
                    }
                }
            }
        }
    }
}

extension View {
    /// Rename and delete prompts for a project's threads, plus the haptic when a change lands.
    func threadDialogs(_ actions: ThreadActions, model: AppModel) -> some View {
        @Bindable var actions = actions
        return self
            .alert(actions.renaming.map { if case .agent = $0.kind { "Rename agent" } else { "Rename chat" } } ?? "Rename", isPresented: Binding(get: { actions.renaming != nil }, set: { if !$0 { actions.renaming = nil } })) {
                TextField("Name", text: $actions.newName)
                    .submitLabel(.done)
                Button("Cancel", role: .cancel) { actions.renaming = nil }
                Button("Rename") {
                    guard let r = actions.renaming else { return }
                    actions.renaming = nil
                    Task { if await model.rename(r, to: actions.newName) { actions.landed += 1 } }
                }
            } message: {
                if case .chat = actions.renaming?.kind { Text("Renames it in Cursor too.") }
            }
            .confirmationDialog(
                "Delete \u{201C}\(actions.deleting?.title ?? "")\u{201D}?",
                isPresented: Binding(get: { actions.deleting != nil }, set: { if !$0 { actions.deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let d = actions.deleting else { return }
                    actions.deleting = nil
                    Task { if await model.delete(d) { actions.landed += 1 } }
                }
                Button("Cancel", role: .cancel) { actions.deleting = nil }
            } message: {
                if case .chat = actions.deleting?.kind { Text("It's removed from Cursor on your Mac. This can't be undone.") }
                else { Text("Its history is removed from Helm. This can't be undone.") }
            }
            .sensoryFeedback(.success, trigger: actions.landed)
    }
}

/// A Helm agent laid out like a Cursor chat row, so the two read as one list.
struct AgentThreadRow: View {
    var agent: Agent

    var body: some View {
        HStack(spacing: 12) {
            badge.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.inter(15, .medium)).tight(15).foregroundStyle(BUI.ink).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: agent.runtime.isSprite ? "cloud" : "bolt.horizontal")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(subtitle).lineLimit(1)
                }
                .font(.inter(12.5))
                .foregroundStyle(agent.status == .waiting ? BUI.orange : BUI.ink3)
                .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            switch agent.status {
            case .waiting: StatusPill(tone: .orange, text: "Needs you").transition(.popIn)
            case .error: StatusPill(tone: .red, text: "Failed").transition(.popIn)
            default:
                if agent.unread > 0 && !agent.isBusy { StatusPill(tone: .accent, text: "\(agent.unread) new").transition(.popIn) }
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(BUI.ink3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(BUI.easeOutStrong, value: agent.status)
    }

    private var subtitle: String {
        let place = agent.runtime.isSprite ? "Helm · cloud" : "Helm"
        switch agent.status {
        case .running: return agent.queue > 0 ? "\(place) · working · \(agent.queue) queued" : "\(place) · working"
        case .starting: return "\(place) · starting"
        case .waiting: return agent.statusDetail ?? "Waiting for you"
        default: return "\(relativeTime(agent.updatedAt)) · \(place)"
        }
    }

    @ViewBuilder private var badge: some View {
        switch agent.status {
        case .running, .starting: SpinnerRing(active: true, size: 24) { Sparkle().fill(BUI.accent).frame(width: 10, height: 10) }
        case .waiting: ResultBadge(tone: .orange, symbol: "questionmark", size: 24)
        case .error: ResultBadge(tone: .red, symbol: "exclamationmark", size: 24)
        case .idle: ResultBadge(tone: agent.unread > 0 ? .green : .neutral, symbol: agent.unread > 0 ? "checkmark" : "sparkles", size: 24)
        }
    }
}
