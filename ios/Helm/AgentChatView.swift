import SwiftUI
import PhotosUI

/// How the transcript is drawn: consecutive tool calls collapse into one ToolChips run;
/// every thought stands on its own as a thinking trace so it's easy to find and open.
enum ChatSegment: Identifiable {
    case item(Item)
    case thought(Item, end: Double?)
    case run([Item])

    var id: String {
        switch self {
        case .item(let i): return i.id
        case .thought(let i, _): return i.id
        case .run(let items): return items.first?.id ?? "run"
        }
    }

    static func build(_ items: [Item]) -> [ChatSegment] {
        var out: [ChatSegment] = []
        var run: [Item] = []
        var nextTs: [String: Double] = [:]
        for (i, it) in items.enumerated() where i + 1 < items.count { nextTs[it.id] = items[i + 1].ts }
        func flush() {
            guard !run.isEmpty else { return }
            out.append(.run(run))
            run = []
        }
        for it in items {
            switch it.kind {
            case .tool where it.tool?.meta?.subagentId != nil || it.tool?.meta?.waitRange != nil:
                flush()
                out.append(.item(it))
            case .tool: run.append(it)
            case .thinking:
                flush()
                out.append(.thought(it, end: nextTs[it.id]))
            default:
                flush()
                out.append(.item(it))
            }
        }
        flush()
        return out
    }
}

struct AgentChatView: View {
    @AppStorage("showThinking") private var showThinking = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var agentId: String

    @State private var renaming = false
    @State private var newName = ""
    @State private var pickingTarget = false
    @State private var relayTarget: TalkTarget?
    @State private var confirmDelete = false

    var body: some View {
        if let agent = model.agent(agentId) {
            chat(agent)
        } else {
            ContentUnavailableView("Agent removed", systemImage: "person.crop.circle.badge.xmark").foregroundStyle(BUI.ink2)
        }
    }

    private func chat(_ agent: Agent) -> some View {
        let items = model.transcripts[agentId]
        let segments = items.map(ChatSegment.build) ?? []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let items {
                    if items.isEmpty { ChatEmpty(agent: agent).transition(.fadeUp) }
                    ForEach(Array(segments.enumerated()), id: \.element.id) { i, seg in
                        SegmentView(segment: seg, agent: agent, live: agent.isBusy && i == segments.count - 1)
                            .id(seg.id)
                            .transition(.asymmetric(insertion: .fadeUp, removal: .opacity))
                    }
                    if let label = loadingLabel(agent, items) {
                        LoadingState(label: label, since: runStart(items))
                            .padding(.vertical, 2)
                            .transition(.fadeUp)
                    }
                } else {
                    LoadingState(label: "Loading conversation")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 100)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .animation(BUI.easeOutStrong, value: items?.count)
            .animation(BUI.easeOutStrong, value: agent.status)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .jumpToLatest()
        .scrollDismissesKeyboard(.interactively)
        .background(BUI.page)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                QueuedStack(items: agent.queued ?? []) { id in
                    await model.sendQueuedNow(agent: agent.id, id: id)
                } edit: { id, text in
                    await model.editQueued(agent: agent.id, id: id, text: text)
                } remove: { id in
                    await model.removeQueued(agent: agent.id, id: id)
                } move: { id, to in
                    await model.moveQueued(agent: agent.id, id: id, to: to)
                }
                    .padding(.horizontal, 12)
                Composer(agent: agent, relayTarget: $relayTarget, pickTarget: { pickingTarget = true })
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.docRoot, agent.runtime.isSprite ? nil : model.workspaces.first { $0.id == agent.workspaceId }?.folders.first)
        .environment(\.docChat, "agent:\(agent.id)")
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(agent.name).font(.inter(15.5, .semibold)).tight(15.5).foregroundStyle(BUI.ink)
                    HStack(spacing: 4) {
                        StatusDot(status: agent.status, size: 6)
                        Text(statusText(agent)).font(.inter(11.5)).foregroundStyle(BUI.ink2).contentTransition(.opacity)
                    }
                    .frame(height: 14)
                    .animation(BUI.easeOutStrong, value: agent.status)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { ChangesButton(root: agent.runtime.isSprite ? nil : model.workspaces.first { $0.id == agent.workspaceId }?.folders.first) }
            ToolbarItem(placement: .topBarTrailing) { ThinkingToggle() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Talk to another agent", systemImage: "arrow.triangle.branch") { pickingTarget = true }
                    Menu("Model") {
                        Picker("Model", selection: Binding(get: { agent.model }, set: { m in Task { await model.updateAgent(agent.id, model: m) } })) {
                            ForEach(model.models) { m in Text(m.label).tag(m.id) }
                        }
                    }
                    Button("Rename", systemImage: "pencil") { newName = agent.name; renaming = true }
                    if let w = model.workspace(agent.workspaceId), !agent.runtime.isSprite {
                        Button("Open workspace on laptop", systemImage: "laptopcomputer") { Task { await model.openOnLaptop(w.id) } }
                    }
                    Divider()
                    Button("Delete agent", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(BUI.ink)
                }
            }
        }
        .task(id: agentId) {
            model.activeAgentId = agentId
            await model.loadTranscript(agentId)
            await model.markRead(agentId)
            await model.loadModels()
        }
        .onDisappear { if model.activeAgentId == agentId { model.activeAgentId = nil } }
        .alert("Rename agent", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { Task { await model.updateAgent(agent.id, name: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(agent.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete agent", role: .destructive) {
                Task {
                    await model.deleteAgent(agent.id)
                    dismiss()
                }
            }
        } message: {
            Text("Its conversation is removed from Helm. Files it changed stay as they are.")
        }
        .sheet(isPresented: $pickingTarget) {
            TalkPicker(excluding: agent.id) { target in
                pickingTarget = false
                withAnimation(Theme.spring) { relayTarget = target }
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(24)
            .presentationBackground(BUI.page)
        }
    }

    /// The pixel loader fills the gaps: while busy, but nothing on screen is visibly moving.
    private func loadingLabel(_ a: Agent, _ items: [Item]) -> String? {
        guard a.isBusy else { return nil }
        if let last = items.last {
            if last.streaming == true { return nil }
            if last.kind == .tool, last.tool?.status == "running" { return nil }
            if last.kind == .decision, model.decision(last.decisionId ?? "")?.answeredAt == nil { return nil }
        }
        switch a.status {
        case .starting: return a.statusDetail ?? "Starting"
        case .waiting: return a.statusDetail ?? "Waiting"
        default: return "Working"
        }
    }

    private func runStart(_ items: [Item]) -> Date? {
        guard let ts = items.last(where: { $0.kind == .user || $0.kind == .agent_message })?.ts else { return nil }
        return Date(timeIntervalSince1970: ts / 1000)
    }

    private func statusText(_ a: Agent) -> String {
        switch a.status {
        case .running: return a.queue > 0 ? "Working · \(a.queue) queued" : "Working"
        case .waiting: return a.statusDetail ?? "Waiting"
        case .starting: return a.statusDetail ?? "Starting"
        case .error: return "Error"
        case .idle: return a.runtime.isSprite ? "Idle · \(a.runtime.sprite ?? "sprite")" : "Idle"
        }
    }
}

struct SegmentView: View {
    var segment: ChatSegment
    var agent: Agent
    var live: Bool

    var body: some View {
        switch segment {
        case .item(let item): ItemView(item: item, agent: agent)
        case .thought(let item, let end):
            ThinkingTrace(
                text: item.text ?? "",
                working: item.streaming == true,
                duration: end.map { ($0 - item.ts) / 1000 }
            )
        case .run(let items): ToolChipsRun(items: items, live: live)
        }
    }
}

struct ChatEmpty: View {
    var agent: Agent
    @State private var float = false
    var body: some View {
        VStack(spacing: 12) {
            HelmMark(size: 34, color: BUI.ink3)
                .rotationEffect(.degrees(float ? 8 : -8))
                .offset(y: float ? -4 : 2)
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: float)
            Text("Tell \(agent.name) what to do").font(.inter(16, .semibold)).tight(16).foregroundStyle(BUI.ink)
            Text(agent.runtime.isSprite
                 ? "It runs in \(agent.runtime.sprite ?? "a sprite") on a clone of \(agent.runtime.repo ?? "your repo")."
                 : "It works directly in this workspace's folders on your Mac.")
                .font(.inter(14)).foregroundStyle(BUI.ink2).multilineTextAlignment(.center)
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BUI.ink3)
                .offset(y: float ? 5 : -2)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: float)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
        .padding(.horizontal, 24)
        .onAppear { float = true }
    }
}

struct ItemView: View {
    @Environment(AppModel.self) private var model
    var item: Item
    var agent: Agent

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(LocalizedStringKey(item.text ?? ""))
                    .font(.inter(15.5))
                    .tight(15.5)
                    .lineSpacing(2)
                    .foregroundStyle(BUI.ink)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(BUI.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .textSelection(.enabled)
            }
        case .assistant:
            MarkdownText(text: item.text ?? "", streaming: item.streaming == true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            ThinkingTrace(text: item.text ?? "", working: item.streaming == true, duration: item.durationMs.map { $0 / 1000 })
        case .tool:
            if let r = item.tool?.meta?.waitRange {
                WaitCard(item: item, range: r)
            } else {
                ToolChipsRun(items: [item], live: item.tool?.status == "running")
            }
        case .agent_message:
            AgentMessageCard(item: item)
        case .decision:
            if let id = item.decisionId { ApprovalCard(decisionId: id, fallbackQuestion: item.text ?? "") }
        case .system:
            HStack(spacing: 10) {
                Rectangle().fill(BUI.line).frame(height: 1)
                Text(LocalizedStringKey(item.text ?? "")).font(.inter(12)).foregroundStyle(BUI.ink3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(BUI.line).frame(height: 1)
            }
            .padding(.vertical, 4)
        case .error:
            HStack(alignment: .top, spacing: 10) {
                ResultBadge(tone: .red, symbol: "exclamationmark", size: 20)
                Text(item.text ?? "Error").font(.inter(14)).foregroundStyle(BUI.ink).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(BUI.redTint, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        }
    }
}

/// A message relayed from another agent, as a ContextCards chunk: titled bar, body, source chip.
struct AgentMessageCard: View {
    @Environment(AppModel.self) private var model
    var item: Item

    /// A Cursor chat that sent this, by its `chat:<composerId>` id.
    private func chatSource(_ from: FromInfo) -> (window: String, title: String)? {
        guard from.agentId.hasPrefix("chat:") else { return nil }
        let cid = String(from.agentId.dropFirst(5))
        for w in model.desktop.windows {
            if let c = w.chats.first(where: { $0.composerId == cid }) { return (w.id, c.title) }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 10.5, weight: .bold)).foregroundStyle(BUI.accentInk)
                Text(item.from.map { "From \($0.name)" } ?? "Relayed message").font(.inter(13, .medium)).foregroundStyle(BUI.ink)
                Spacer()
                if let ws = item.from?.workspace, !ws.isEmpty {
                    Text(ws).font(.inter(12)).foregroundStyle(BUI.ink3).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .overlay(alignment: .bottom) { Rectangle().fill(BUI.line).frame(height: 1) }

            MarkdownText(text: item.text ?? "", size: 14, color: BUI.ink2)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            if let from = item.from, model.agent(from.agentId) != nil || chatSource(from) != nil {
                Button {
                    if let c = chatSource(from) { model.route.append(.desktopChat(c.window, c.title)) } else { model.open(agentId: from.agentId) }
                } label: {
                    HStack(spacing: 5) {
                        Text(String(from.name.prefix(1)).uppercased())
                            .font(.inter(8, .bold)).foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(BUI.accent, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        Text("Open \(from.name)")
                        Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
                    }
                    .font(.inter(12, .medium))
                    .foregroundStyle(BUI.ink2)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(BUI.inset, in: Capsule())
                    .elevation(.btn, Capsule())
                }
                .buttonStyle(PressableStyle(scale: 0.95))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .elevation(.card, radius: BUI.Radius.card)
    }
}

/// Composer in the PromptBar grammar: surface card, attach and @ on the left, a model chip,
/// and a square send button that turns from line-strong to ink when there's something to send.
struct Composer: View {
    @Environment(AppModel.self) private var model
    var agent: Agent
    @Binding var relayTarget: TalkTarget?
    var pickTarget: () -> Void

    @State private var text = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var images: [(UIImage, OutgoingImage)] = []
    @State private var sendTick = 0
    @FocusState private var focused: Bool

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!images.isEmpty && relayTarget == nil) }
    private var showStop: Bool { agent.isBusy && !canSend }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let target = relayTarget {
                TalkChip(from: agent.name, target: target) { withAnimation(Theme.spring) { relayTarget = nil } }
            }
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                            Image(uiImage: img.0).resizable().scaledToFill().frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
                                .elevation(.hairline, radius: BUI.Radius.control)
                                .overlay(alignment: .topTrailing) {
                                    Button { images.remove(at: i) } label: {
                                        Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                                            .frame(width: 18, height: 18).background(BUI.tooltipBg, in: Circle())
                                    }
                                    .offset(x: 5, y: -5)
                                    .accessibilityLabel("Remove image")
                                }
                                .transition(.popIn)
                        }
                    }
                    .padding(.top, 6).padding(.trailing, 6)
                }
                .scrollIndicators(.hidden)
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...7)
                .font(.inter(15.5))
                .tight(15.5)
                .foregroundStyle(BUI.ink)
                .focused($focused)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            HStack(spacing: 2) {
                PhotosPicker(selection: $photos, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(BUI.ink3)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Attach images")
                Button(action: pickTarget) { Image(systemName: "at") }
                    .buttonStyle(IconButtonStyle(size: 30, tint: relayTarget == nil ? BUI.ink3 : BUI.accentInk))
                    .accessibilityLabel("Talk to another chat or agent")
                ModelMenu(selection: Binding(get: { agent.model }, set: { m in Task { await model.updateAgent(agent.id, model: m) } })) {
                    HStack(spacing: 4) {
                        Text(model.models.first { $0.id == agent.model }?.label ?? agent.model).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold)).foregroundStyle(BUI.ink3)
                    }
                    .font(.inter(12.5, .medium))
                    .foregroundStyle(BUI.ink2)
                    .padding(.horizontal, 7)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                Spacer()
                if agent.isBusy && canSend {
                    Text("Queues next").font(.inter(11.5, .medium)).foregroundStyle(BUI.ink3).padding(.trailing, 6).transition(.opacity)
                }
                Button(action: primary) {
                    ZStack {
                        if showStop {
                            RoundedRectangle(cornerRadius: 2.5).fill(BUI.surface).frame(width: 10, height: 10).transition(.popIn)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).transition(.popIn)
                        }
                    }
                    .foregroundStyle(canSend ? BUI.surface : BUI.ink2)
                    .frame(width: 32, height: 32)
                    .background(canSend || showStop ? BUI.ink : BUI.lineStrong, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
                }
                .buttonStyle(PressableStyle(scale: 0.94))
                .disabled(!canSend && !showStop)
                .sensoryFeedback(.impact(weight: .light), trigger: sendTick)
                .accessibilityLabel(showStop ? "Stop" : "Send")
            }
        }
        .padding(10)
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous).strokeBorder(focused ? BUI.lineStrong : BUI.line))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        .animation(BUI.easeOutFast, value: focused)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 6)
        .background(
            LinearGradient(colors: [BUI.page.opacity(0), BUI.page], startPoint: .top, endPoint: .init(x: 0.5, y: 0.3))
                .ignoresSafeArea()
        )
        .animation(Theme.spring, value: images.count)
        .animation(BUI.easeOutStrong, value: showStop)
        .animation(BUI.easeOutStrong, value: canSend)
        .onChange(of: photos) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        let scaled = img.downscaled(maxSide: 1600)
                        if let jpg = scaled.jpegData(compressionQuality: 0.8) {
                            images.append((scaled, OutgoingImage(data: jpg.base64EncodedString(), mimeType: "image/jpeg")))
                        }
                    }
                }
                photos = []
            }
        }
    }

    private var placeholder: String {
        if let t = relayTarget { return "What should \(agent.name) discuss with \(t.name)?" }
        return agent.isBusy ? "Queue a follow-up…" : "Message \(agent.name)…"
    }

    private func primary() {
        if showStop {
            sendTick += 1
            Task { await model.cancel(agent.id) }
            return
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = images.map(\.1)
        let target = relayTarget
        text = ""
        images = []
        sendTick += 1
        Task {
            var ok: Bool
            if let target {
                ok = await model.relay(from: agent.id, to: target.id, instruction: t)
                if ok { withAnimation(Theme.spring) { relayTarget = nil } }
            } else {
                ok = await model.send(agent.id, text: t, images: imgs)
            }
            if !ok { text = t }
        }
    }
}

/// Everyone a chat can talk to: Cursor chats open on the Mac, and Helm agents, searchable.
struct TalkPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var excluding: String
    var onPick: (TalkTarget) -> Void
    @State private var query = ""

    private func matches(_ s: String...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || s.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    private struct Row: Identifiable {
        var target: TalkTarget
        var detail: String?
        var status: AgentStatus
        var runtime: Runtime?
        var id: String { target.id }
    }

    private var groups: [(title: String, rows: [Row])] {
        var out: [(String, [Row])] = []
        for w in model.desktop.windows {
            let rows = w.chats.compactMap { c -> Row? in
                guard let cid = c.composerId, "chat:\(cid)" != excluding, matches(c.title, w.workspace) else { return nil }
                let status: AgentStatus = c.status == .working ? .running : c.status == .attention ? .waiting : .idle
                return Row(target: TalkTarget(id: "chat:\(cid)", name: c.title, isChat: true, workspace: w.workspace), detail: c.age, status: status)
            }
            if !rows.isEmpty { out.append(("\(w.workspace) · Cursor", rows)) }
        }
        for w in model.workspaces {
            let rows = model.agents(in: w.id).filter { $0.id != excluding && matches($0.name, w.name) }.map {
                Row(target: TalkTarget(id: $0.id, name: $0.name, isChat: false, workspace: w.name), detail: $0.lastText, status: $0.status, runtime: $0.runtime)
            }
            if !rows.isEmpty { out.append(("\(w.name) · Helm agents", rows)) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Talk to…", subtitle: "A Cursor chat or a Helm agent. Your message tells this chat what to say.") { dismiss() }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(BUI.ink3)
                TextField("Search chats and agents", text: $query).font(.inter(15)).autocorrectionDisabled()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            .elevation(.hairline, radius: BUI.Radius.control)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            let groups = groups
            if groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28, weight: .light)).foregroundStyle(BUI.ink3)
                        .symbolEffect(.bounce, value: query)
                    Text(query.isEmpty ? "Nobody else to talk to yet" : "No chats or agents match").font(.inter(15, .semibold)).foregroundStyle(BUI.ink)
                    Text(query.isEmpty ? "Open a chat in Cursor or start a Helm agent and it shows up here." : "Try a chat title or a workspace name.")
                        .font(.inter(13.5)).foregroundStyle(BUI.ink2).multilineTextAlignment(.center)
                }
                .padding(40)
                .transition(.opacity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(groups, id: \.title) { g in
                            VStack(alignment: .leading, spacing: 8) {
                                SectionLabel(text: g.title, count: g.rows.count)
                                VStack(spacing: 0) {
                                    ForEach(Array(g.rows.enumerated()), id: \.element.id) { i, r in
                                        Button { onPick(r.target) } label: {
                                            HStack(spacing: 10) {
                                                if r.target.isChat {
                                                    Image(systemName: "bubble.left").font(.system(size: 12, weight: .semibold)).foregroundStyle(r.status == .running ? BUI.accentInk : BUI.ink3).frame(width: 14)
                                                } else {
                                                    StatusDot(status: r.status, size: 7).frame(width: 14)
                                                }
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(r.target.name).font(.inter(15, .medium)).foregroundStyle(BUI.ink).lineLimit(1)
                                                    if let t = r.detail, !t.isEmpty { Text(t).font(.inter(12.5)).foregroundStyle(BUI.ink2).lineLimit(1) }
                                                }
                                                Spacer()
                                                if let rt = r.runtime { RuntimeBadge(runtime: rt) }
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 11)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(OptionPressStyle(selected: false))
                                        if i < g.rows.count - 1 { Rectangle().fill(BUI.line).frame(height: 1).padding(.leading, 36) }
                                    }
                                }
                                .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
                                .elevation(.card, radius: BUI.Radius.window)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .animation(BUI.easeOutStrong, value: groups.map(\.rows.count))
    }
}

/// The "This chat → them" chip above a composer while a message is aimed at someone else.
struct TalkChip: View {
    var from: String
    var target: TalkTarget
    var clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: target.isChat ? "bubble.left.and.bubble.right" : "arrow.triangle.branch").font(.system(size: 11, weight: .bold))
            (Text("\(from) → ").foregroundStyle(BUI.ink2) + Text(target.name).foregroundStyle(BUI.accentInk).bold())
                .lineLimit(1).truncationMode(.middle)
            Button(action: clear) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(IconButtonStyle(size: 20, tint: BUI.accentInk))
                .accessibilityLabel("Don't send to \(target.name)")
        }
        .font(.inter(12.5, .medium))
        .foregroundStyle(BUI.accentInk)
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .frame(height: 26)
        .background(BUI.accentTint, in: Capsule())
        .transition(.popIn)
    }
}

extension UIImage {
    func downscaled(maxSide: CGFloat) -> UIImage {
        let m = max(size.width, size.height)
        guard m > maxSide else { return self }
        let s = maxSide / m
        let newSize = CGSize(width: size.width * s, height: size.height * s)
        return UIGraphicsImageRenderer(size: newSize).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
