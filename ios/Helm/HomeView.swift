import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    @State private var newWorkspace = false
    @State private var showInbox = false
    @State private var showAll = false
    /// Your arrangement, as project keys: pinned ones, then everything else. Projects you haven't placed slot in by activity.
    @AppStorage("pinnedOrder") private var pinnedOrder = ""
    @AppStorage("projectOrder") private var projectOrder = ""
    @State private var dragging: ProjectDrag?
    @Namespace private var rowSpace

    private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Every project by activity: open in Cursor first (needs you, then working), then Helm agents, then recent.
    private var projects: [Project] {
        let q = query
        let windows = model.desktop.available ? model.desktop.windows : []
        let open = windows
            .filter { q.isEmpty || $0.workspace.lowercased().contains(q) }
            .enumerated()
            .sorted { a, b in
                let ra = a.element.needsYou ? 0 : a.element.busy ? 1 : 2, rb = b.element.needsYou ? 0 : b.element.busy ? 1 : 2
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map { Project(window: $0.element, workspace: model.workspace(for: $0.element)) }
        let taken = Set(open.compactMap(\.workspace?.id))
        let others = model.workspaces.filter { w in
            !taken.contains(w.id) && (q.isEmpty || w.name.lowercased().contains(q) || w.folders.contains { $0.lowercased().contains(q) })
        }
        let hasAgents = { (w: Workspace) in model.agents.contains { $0.workspaceId == w.id } }
        let active = others.filter(hasAgents).sorted { $0.lastActiveAt > $1.lastActiveAt }
        let rest = others.filter { !hasAgents($0) }.sorted { $0.lastActiveAt > $1.lastActiveAt }
        return open + (active + rest).map { Project(window: nil, workspace: $0) }
    }

    /// Pinned projects in the order you dragged them; new pins go last. The rest follow your order, with new projects on top.
    private var sections: (pinned: [Project], rest: [Project]) {
        let all = projects
        return (Self.arrange(all.filter(\.isPinned), by: Self.keys(pinnedOrder), newFirst: false),
                Self.arrange(all.filter { !$0.isPinned }, by: Self.keys(projectOrder), newFirst: true))
    }

    private static func keys(_ raw: String) -> [String] { raw.split(separator: "\n").map(String.init) }

    private static func arrange(_ items: [Project], by order: [String], newFirst: Bool) -> [Project] {
        guard !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let unplaced = newFirst ? -1 : Int.max
        return items.enumerated().sorted { a, b in
            let ra = rank[a.element.key] ?? unplaced, rb = rank[b.element.key] ?? unplaced
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    /// Moves the dragged project into `target`'s slot and saves the section's new order right away.
    private func reorder(onto target: String, pinned: Bool) {
        guard let d = dragging, d.pinned == pinned, d.key != target, query.isEmpty else { return }
        var order = (pinned ? sections.pinned : sections.rest).map(\.key)
        guard let from = order.firstIndex(of: d.key), let to = order.firstIndex(of: target) else { return }
        order.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        withAnimation(BUI.easeOutStrong) {
            if pinned { pinnedOrder = order.joined(separator: "\n") } else { projectOrder = order.joined(separator: "\n") }
        }
    }

    private func setPinned(_ w: Workspace, _ pin: Bool) {
        if pin {
            let key = "s-\(w.id)"
            pinnedOrder = (Self.keys(pinnedOrder).filter { $0 != key } + [key]).joined(separator: "\n")
        }
        Task { await model.updateWorkspace(w.id, pinned: pin) }
    }

    /// Recent projects past these stay folded until asked for.
    private static let folded = 4

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.route) {
            ScrollView {
                LazyVStack(spacing: 22) {
                    header
                    if !model.decisions.isEmpty {
                        InboxCard { showInbox = true }
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.96))))
                    }
                    if model.hub?.cursorLoggedIn == false {
                        notice(icon: "person.crop.circle.badge.exclamationmark", color: Theme.waiting, title: "Cursor isn't signed in on the Mac", body: "Run `npm run login` in the hub folder so agents can start.")
                    }
                    if model.workspaces.isEmpty && model.connection == .online {
                        EmptyWorkspaces { newWorkspace = true }
                    }
                    if search.isEmpty { DesktopNotice() }
                    projectsSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
                .animation(Theme.ease, value: model.decisions.count)
                .animation(Theme.ease, value: model.workspaces.map(\.id))
            }
            .scrollIndicators(.hidden)
            .background(Theme.bg)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search projects")
            .refreshable { model.connect() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: Route.settings) {
                        Image(systemName: "gearshape").foregroundStyle(Theme.text2)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newWorkspace = true } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    .accessibilityLabel("New workspace")
                }
            }
            .navigationDestination(for: Route.self) { r in
                switch r {
                case .workspace(let id): WorkspaceView(workspaceId: id)
                case .agent(let id): AgentChatView(agentId: id)
                case .desktopWindow(let id): DesktopWindowView(windowId: id)
                case .desktopChat(let w, let chat): DesktopChatView(ref: DesktopRef(window: w, chat: chat))
                case .subagent(let id, let name): SubagentView(id: id, name: name)
                case .settings: SettingsView()
                case .inbox: InboxView()
                }
            }
            .toolbarBackground(Theme.bg, for: .navigationBar)
        }
        .sheet(isPresented: $newWorkspace) {
            NewWorkspaceSheet()
                .presentationDetents([.large])
                .presentationCornerRadius(28)
                .presentationBackground(Theme.bg)
        }
        .sheet(isPresented: $showInbox) {
            InboxView(asSheet: true)
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(28)
                .presentationBackground(Theme.bg)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            HelmMark(size: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text("Helm").font(.display).tracking(-0.8).foregroundStyle(BUI.ink)
                StatusPill(tone: model.connection == .online ? .green : model.connection == .connecting ? .orange : .red, text: connectionText)
                    .animation(BUI.easeOutStrong, value: model.connection)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private var connectionText: String {
        let name = model.hub?.name ?? model.pairing?.name ?? "Mac"
        switch model.connection {
        case .online:
            let running = model.agents.filter(\.isBusy).count
            return running > 0 ? "\(name) · \(running) working" : name
        case .connecting: return "Connecting to \(name)…"
        case .offline: return "\(name) is unreachable · retrying"
        }
    }

    @ViewBuilder private var projectsSection: some View {
        let (pinned, rest) = sections
        let hasAgents = { (p: Project) in p.workspace.map { w in model.agents.contains { $0.workspaceId == w.id } } ?? false }
        // Open and working projects always show; plain recent ones past the last of those fold away.
        let keep = (rest.lastIndex { $0.window != nil || hasAgents($0) } ?? -1) + 1
        let limit = showAll || !query.isEmpty ? rest.count : min(rest.count, keep + Self.folded)
        let folds = rest.count > keep + Self.folded && query.isEmpty
        VStack(spacing: 22) {
            if !pinned.isEmpty {
                projectList(title: "Pinned", items: pinned, pinned: true, fold: nil)
                    .transition(.fadeUp)
            }
            if !rest.isEmpty {
                projectList(title: "Projects", items: Array(rest.prefix(limit)), pinned: false,
                            fold: folds ? (rest.count - limit) : nil)
                    .transition(.fadeUp)
            }
        }
        .animation(BUI.easeOutStrong, value: pinned.map(\.id))
        .animation(BUI.easeOutStrong, value: rest.prefix(limit).map(\.id))
        .sensoryFeedback(.selection, trigger: pinnedOrder + projectOrder)
    }

    private func projectList(title: String, items: [Project], pinned: Bool, fold hidden: Int?) -> some View {
        VStack(spacing: 8) {
            SectionLabel(text: title, count: items.count + (hidden ?? 0))
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, p in
                    NavigationLink(value: p.route) { ProjectRow(project: p) }
                        .buttonStyle(PressableStyle(scale: 0.985))
                        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
                        .contextMenu { menu(p) }
                        .onDrag {
                            dragging = ProjectDrag(key: p.key, pinned: pinned)
                            return NSItemProvider(object: p.key as NSString)
                        }
                        .onDrop(of: [.text], delegate: ProjectDrop { reorder(onto: p.key, pinned: pinned) } done: { dragging = nil })
                        .matchedGeometryEffect(id: p.key, in: rowSpace)
                        .transition(.asymmetric(insertion: .fadeUp, removal: .opacity))
                        .accessibilityActions {
                            if i > 0 { Button("Move up") { move(p, by: -1, in: items, pinned: pinned) } }
                            if i < items.count - 1 { Button("Move down") { move(p, by: 1, in: items, pinned: pinned) } }
                        }
                    if i < items.count - 1 || hidden != nil {
                        Rectangle().fill(BUI.line).frame(height: 1).padding(.leading, 62)
                    }
                }
                if let hidden {
                    FoldToggle(open: showAll, hidden: hidden) { showAll.toggle() }
                }
            }
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
            .elevation(.card, radius: BUI.Radius.window)
        }
    }

    private func move(_ p: Project, by step: Int, in items: [Project], pinned: Bool) {
        guard let i = items.firstIndex(of: p), items.indices.contains(i + step) else { return }
        dragging = ProjectDrag(key: p.key, pinned: pinned)
        reorder(onto: items[i + step].key, pinned: pinned)
        dragging = nil
    }

    @ViewBuilder private func menu(_ p: Project) -> some View {
        if let w = p.workspace {
            Button(w.pinned ? "Unpin" : "Pin", systemImage: w.pinned ? "pin.slash" : "pin") { setPinned(w, !w.pinned) }
            if p.window == nil {
                Button("Open in Cursor", systemImage: "laptopcomputer") { Task { await model.openOnLaptop(w.id) } }
            }
            Button("Remove from Helm", systemImage: "eye.slash", role: .destructive) { Task { await model.deleteWorkspace(w.id) } }
        }
    }

    private func notice(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ResultBadge(tone: .orange, symbol: "exclamationmark", size: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.inter(14, .semibold)).foregroundStyle(BUI.ink)
                Text(LocalizedStringKey(body)).font(.inter(13)).foregroundStyle(BUI.ink2)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }
}

/// A project, whether it's open in Cursor on the Mac, has Helm agents, or both.
struct Project: Identifiable, Hashable {
    var window: DesktopWindow?
    var workspace: Workspace?

    var id: String { window.map { "w-\($0.id)" } ?? "s-\(workspace?.id ?? "")" }
    var name: String { window?.workspace ?? workspace?.name ?? "" }
    var route: Route { window.map { .desktopWindow($0.id) } ?? .workspace(workspace?.id ?? "") }
    /// Stays the same whether or not the project is open in Cursor right now.
    var key: String { workspace.map { "s-\($0.id)" } ?? "c-\(name)" }
    var isPinned: Bool { workspace?.pinned == true }
}

/// Which project is being held, and which section it belongs to; drags don't cross sections.
struct ProjectDrag: Equatable {
    var key: String
    var pinned: Bool
}

/// Hovering a dragged project over a row slides it into that row's slot.
struct ProjectDrop: DropDelegate {
    var entered: () -> Void
    var done: () -> Void

    func dropEntered(info: DropInfo) { entered() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { done(); return true }
}

struct ProjectRow: View {
    @Environment(AppModel.self) private var model
    var project: Project

    var body: some View {
        let agents = project.workspace.map { model.agents(in: $0.id) } ?? []
        let window = project.window
        let busy = window?.busy == true || agents.contains(where: \.isBusy)
        let needsYou = window?.needsYou == true || agents.contains { $0.status == .waiting }
        HStack(spacing: 12) {
            Text(String(project.name.prefix(1)).uppercased())
                .font(.inter(15, .semibold))
                .foregroundStyle(BUI.ink2)
                .frame(width: 36, height: 36)
                .background(BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.control + 1, style: .continuous))
                .elevation(.hairline, radius: BUI.Radius.control + 1)
                .overlay(alignment: .bottomTrailing) {
                    if window != nil {
                        Circle().fill(Theme.done).frame(width: 9, height: 9)
                            .overlay(Circle().stroke(BUI.surface, lineWidth: 2))
                            .offset(x: 3, y: 3)
                            .transition(.popIn)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project.name).font(.inter(15.5, .medium)).tight(15.5).foregroundStyle(BUI.ink).lineLimit(1)
                }
                Text(subtitle(agents))
                    .font(.inter(12.5))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            if needsYou {
                StatusPill(tone: .orange, text: "Needs you").transition(.popIn)
            } else if busy {
                StatusPill(tone: .accent, text: "Working").transition(.popIn)
            }
            let unread = agents.reduce(0) { $0 + $1.unread }
            if unread > 0 {
                Text("\(unread)")
                    .font(.inter(11.5, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(BUI.accent, in: Capsule())
                    .contentTransition(.numericText())
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .animation(BUI.easeOutStrong, value: needsYou)
        .animation(BUI.easeOutStrong, value: busy)
    }

    private func subtitle(_ agents: [Agent]) -> String {
        if let w = project.window {
            let current = w.chats.first(where: \.selected)?.title ?? w.chats.first?.title
            let n = w.chats.count
            return [n == 1 ? "1 chat" : n > 1 ? "\(n) chats" : "Open in Cursor", current].compactMap { $0 }.joined(separator: " · ")
        }
        guard let workspace = project.workspace else { return "" }
        if let busy = agents.first(where: \.isBusy) {
            return busy.status == .waiting ? "\(busy.name) needs you" : "\(busy.name) is working…"
        }
        if !agents.isEmpty { return "\(agents.count) agent\(agents.count == 1 ? "" : "s") · \(relativeTime(workspace.lastActiveAt))" }
        if workspace.folders.count > 1 { return "\(workspace.folders.count) folders · \(relativeTime(workspace.lastActiveAt))" }
        return workspace.folders.first?.abbreviatedPath ?? "No folders"
    }
}

struct InboxCard: View {
    @Environment(AppModel.self) private var model
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ResultBadge(tone: .orange, symbol: "questionmark", size: 26)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("Decisions").font(.inter(14, .semibold)).foregroundStyle(BUI.ink)
                        StatusPill(tone: .orange, text: "\(model.decisions.count) waiting")
                    }
                    if let d = model.decisions.sorted(by: { $0.createdAt > $1.createdAt }).first {
                        Text(d.question).font(.inter(13.5)).foregroundStyle(BUI.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(BUI.ink3)
            }
            .card(padding: 14, radius: BUI.Radius.window)
        }
        .buttonStyle(PressableStyle(scale: 0.985))
    }
}

struct EmptyWorkspaces: View {
    var action: () -> Void
    @State private var float = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.text2)
                .offset(y: float ? -6 : 2)
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: float)
            Text("No workspaces yet").font(.inter(17, .semibold)).foregroundStyle(Theme.text)
            Text("Pick folders from your Mac and put agents to work on them.")
                .font(.inter(14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            Button("Create a workspace", action: action).buttonStyle(.bui(.primary, .md))
        }
        .padding(.vertical, 50)
        .onAppear { float = true }
    }
}
