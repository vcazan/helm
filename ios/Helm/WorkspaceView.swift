import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var workspaceId: String
    @State private var newAgent = false
    @State private var addFolder = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var openState: OpenState = .idle
    @State private var starting = false
    @State private var actions = ThreadActions()

    enum OpenState { case idle, opening, opened }

    var body: some View {
        if let w = model.workspace(workspaceId) {
            content(w)
        } else {
            ContentUnavailableView("Workspace removed", systemImage: "folder.badge.minus")
                .foregroundStyle(Theme.text2)
        }
    }

    private func content(_ w: Workspace) -> some View {
        let win = model.window(for: w)
        let empty = model.threads(w, win).isEmpty && model.archivedThreads(w, win).isEmpty
        return List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(w.name).font(.display).tracking(-0.8).foregroundStyle(BUI.ink).lineLimit(2)
                    FlowFolders(folders: w.folders) { addFolder = true }
                    HStack(spacing: 10) {
                        Button {
                            openState = .opening
                            Task {
                                let ok = await model.openOnLaptop(w.id)
                                withAnimation(Theme.ease) { openState = ok ? .opened : .idle }
                                try? await Task.sleep(for: .seconds(2.2))
                                withAnimation(Theme.ease) { openState = .idle }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: openState == .opened ? "checkmark" : "laptopcomputer")
                                    .contentTransition(.symbolEffect(.replace))
                                Text(openState == .opened ? "Opened in Cursor" : win != nil ? "Show on Mac" : "Open in Cursor")
                                    .contentTransition(.interpolate)
                            }
                        }
                        .buttonStyle(.bui(.secondary, .sm))
                        .disabled(w.folders.isEmpty || openState == .opening)
                        .sensoryFeedback(.success, trigger: openState == .opened)
                        if win != nil {
                            StatusPill(tone: .green, text: "Open in Cursor").transition(.popIn)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .padding(.horizontal, 4)
                .bareRow()

                if empty {
                    EmptyAgents(inCursor: win != nil).bareRow()
                }
            }

            ThreadSections(workspace: w, window: win, actions: actions)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(14)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.top, 0, for: .scrollContent)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollIndicators(.hidden)
        .animation(BUI.easeOutStrong, value: model.threads(w, win))
        .animation(BUI.easeOutStrong, value: model.archivedThreads(w, win))
        .animation(BUI.easeOutStrong, value: win == nil)
        .threadDialogs(actions, model: model)
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("New Helm agent…", systemImage: "sparkles") { newAgent = true }
                    let key = model.projectKey(w, model.window(for: w))
                    if model.chatOrder[key] != nil {
                        Button("Sort by recent", systemImage: "arrow.up.arrow.down") {
                            withAnimation(BUI.easeOutStrong) { model.setOrder(nil, for: key) }
                        }
                    }
                    Divider()
                    Button("Rename", systemImage: "pencil") { newName = w.name; renaming = true }
                    Button(w.pinned ? "Unpin" : "Pin", systemImage: w.pinned ? "pin.slash" : "pin") {
                        Task { await model.updateWorkspace(w.id, pinned: !w.pinned) }
                    }
                    Button("Add folder", systemImage: "folder.badge.plus") { addFolder = true }
                    Divider()
                    Button("Remove from Helm", systemImage: "eye.slash", role: .destructive) {
                        Task {
                            await model.deleteWorkspace(w.id)
                            dismiss()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.text)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Open in Cursor: the chat goes there so it's on your Mac too. Otherwise Helm runs it.
            let inCursor = model.window(for: w) != nil
            DesktopComposer(placeholder: inCursor ? "New Cursor chat in \(w.name)" : "New Helm agent in \(w.name)", busy: false, sending: starting) { text, images in
                await start(w, inCursor: inCursor, text, images)
            } onStop: {}
        }
        .sheet(isPresented: $newAgent) {
            NewAgentSheet(workspace: w) { a in
                newAgent = false
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    model.route.append(.agent(a.id))
                }
            }
            .presentationDetents([.large])
            .presentationCornerRadius(28)
            .presentationBackground(Theme.bg)
        }
        .sheet(isPresented: $addFolder) {
            FolderBrowser(title: "Add folders", initialSelection: []) { picked in
                addFolder = false
                let merged = w.folders + picked.filter { !w.folders.contains($0) }
                Task { await model.updateWorkspace(w.id, folders: merged) }
            }
            .presentationDetents([.fraction(0.85)])
            .presentationCornerRadius(28)
            .presentationBackground(Theme.bg)
        }
        .alert("Rename workspace", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { Task { await model.updateWorkspace(w.id, name: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .task { await model.loadModels() }
    }

    /// Starts the work where it makes most sense: a Cursor chat if the project is open there, else a Helm agent.
    private func start(_ w: Workspace, inCursor: Bool, _ text: String, _ images: [OutgoingImage]) async -> Bool {
        starting = true
        defer { starting = false }
        if inCursor {
            guard let ref = await model.startCursorAgent(in: w, window: nil, text: text, images: images) else { return false }
            model.route.append(ref.chat.isEmpty ? .desktopWindow(ref.window) : .desktopChat(ref.window, ref.chat))
            return true
        }
        do {
            let a = try await model.createAgent(.init(workspaceId: w.id, name: nil, model: nil, runtime: .local, prompt: text.isEmpty ? nil : text, images: images.isEmpty ? nil : images, createSprite: nil))
            model.route.append(.agent(a.id))
            return true
        } catch {
            model.showBanner(Banner(title: "Couldn't start the agent", body: error.localizedDescription, agentId: nil, isDecision: false))
            return false
        }
    }
}

struct FlowFolders: View {
    @Environment(AppModel.self) private var model
    var folders: [String]
    var onAdd: () -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(folders, id: \.self) { f in
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(BUI.ink3)
                    Text(f.abbreviatedPath).font(.jbMono(11.5)).foregroundStyle(BUI.ink2).lineLimit(1).truncationMode(.head)
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(BUI.inset, in: Capsule())
                .elevation(.btn, Capsule())
                .transition(.popIn)
            }
            Button(action: onAdd) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(BUI.ink2)
                    .frame(width: 26, height: 26)
                    .background(BUI.surface, in: Circle())
                    .elevation(.btn, Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .accessibilityLabel("Add folder")
        }
        .animation(BUI.easeOutStrong, value: folders)
    }
}

struct EmptyAgents: View {
    var inCursor = false
    @State private var nudge = false
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.text2)
                .symbolEffect(.pulse, options: .repeating)
            Text("Nothing here yet").font(.inter(16, .semibold)).foregroundStyle(Theme.text)
            Text(inCursor ? "Message below to start a chat in Cursor on your Mac." : "Message below and Helm runs an agent on your Mac, even with Cursor closed. Open the project in Cursor to chat there instead.")
                .font(.inter(14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            Image(systemName: "arrow.down")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text3)
                .offset(y: nudge ? 6 : -2)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: nudge)
                .padding(.top, 6)
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
        .onAppear { nudge = true }
    }
}
