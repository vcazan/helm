import SwiftUI

struct NewAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var workspace: Workspace
    var onCreated: (Agent) -> Void

    @State private var name = ""
    @State private var prompt = ""
    @State private var remote = false
    @State private var modelId = ""
    @State private var sprites: SpritesResponse?
    @State private var spriteName = ""
    @State private var newSprite = false
    @State private var repo = ""
    @State private var branch = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var promptFocused: Bool

    private var canCreate: Bool {
        if busy { return false }
        if remote { return !spriteName.isEmpty && repo.contains("/") && sprites?.loggedIn == true }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New agent", subtitle: workspace.name) { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    runtimePicker

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "First task")
                        TextField("What should it work on?", text: $prompt, axis: .vertical)
                            .lineLimit(4...10)
                            .focused($promptFocused)
                            .field()
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "Name")
                            TextField(remote ? "Remote agent" : "Agent", text: $name).field()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(text: "Model")
                            ModelMenu(selection: $modelId) {
                                HStack {
                                    Text(model.models.first { $0.id == modelId }?.label ?? (modelId.isEmpty ? "Auto" : modelId))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(Theme.text3)
                                }
                                .field()
                            }
                        }
                    }

                    if remote {
                        spriteConfig
                            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .trailing).combined(with: .opacity)))
                    }

                    if let error {
                        Text(error).font(.inter(13)).foregroundStyle(Theme.error)
                            .transition(.opacity)
                    }
                }
                .padding(20)
                .animation(Theme.ease, value: remote)
                .animation(Theme.ease, value: error)
            }
            .scrollDismissesKeyboard(.interactively)

            Button(action: create) {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(Theme.bg) }
                    Text(busy ? (remote ? "Setting up sprite…" : "Starting…") : (prompt.isEmpty ? "Create agent" : "Start agent"))
                        .contentTransition(.interpolate)
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: canCreate))
            .disabled(!canCreate)
            .padding(20)
        }
        .task {
            await model.loadModels()
            if modelId.isEmpty { modelId = model.hub?.defaultModel ?? "auto" }
            if let first = workspace.folders.first, let info = await model.repoInfo(first) {
                repo = info.repo ?? ""
                branch = info.branch.map { $0 == "main" || $0 == "master" ? "" : $0 } ?? ""
            }
        }
        .onAppear { promptFocused = true }
    }

    private var runtimePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            BSegmented(options: [(false, "Laptop"), (true, "Fly sprite")], selection: $remote)
            Text(remote ? "Runs in a Fly sprite on a fresh clone of the GitHub repo." : "Works directly in this workspace's folders on your Mac.")
                .font(.inter(12.5))
                .foregroundStyle(BUI.ink3)
                .contentTransition(.interpolate)
                .padding(.horizontal, 4)
                .animation(BUI.easeOutStrong, value: remote)
        }
        .onChange(of: remote) { _, r in if r, sprites == nil { Task { await loadSprites() } } }
    }

    @ViewBuilder
    private var spriteConfig: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = sprites, !s.loggedIn {
                HStack(alignment: .top, spacing: 10) {
                    ResultBadge(tone: .orange, symbol: "key.fill", size: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sprites isn't signed in on the Mac").font(.inter(14, .semibold)).foregroundStyle(Theme.text)
                        Text("Run `sprite login` in a terminal on the Mac, then come back.").font(.inter(13)).foregroundStyle(Theme.text2)
                        Button("Check again") { Task { await loadSprites() } }.buttonStyle(.bui(.secondary, .sm)).padding(.top, 4)
                    }
                }
                .card()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Sprite")
                    if sprites == nil {
                        LoadingState(label: "Loading sprites", pattern: .orbit).padding(.vertical, 8)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                chip("New sprite", icon: "plus", selected: newSprite) {
                                    newSprite = true
                                    spriteName = suggestedSpriteName
                                }
                                ForEach(sprites?.sprites ?? []) { s in
                                    chip(s.name, icon: "cloud", selected: !newSprite && spriteName == s.name) {
                                        newSprite = false
                                        spriteName = s.name
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        if newSprite {
                            TextField("sprite-name", text: $spriteName)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .font(.mono).field()
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "GitHub repo")
                    TextField("owner/repo", text: $repo)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.mono).field()
                    TextField("Branch (optional, default branch if empty)", text: $branch)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.mono).field()
                }
                Text("The sprite clones the repo using your GitHub login from the Mac, and the agent pushes its work to a branch.")
                    .font(.inter(12.5)).foregroundStyle(Theme.text3)
            }
        }
        .animation(Theme.ease, value: newSprite)
    }

    private var suggestedSpriteName: String {
        let base = workspace.name.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "helm-\(base.prefix(24))".trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func chip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .bold))
                Text(title).font(.inter(13, .medium))
            }
            .foregroundStyle(selected ? BUI.canvas : BUI.ink)
            .padding(.horizontal, 12).frame(height: 30)
            .background(selected ? BUI.ink : BUI.surface, in: Capsule())
            .modifier(ChipRing(selected: selected))
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .animation(Theme.easeFast, value: selected)
    }

    private func loadSprites() async {
        do {
            let s = try await model.sprites()
            sprites = s
            if spriteName.isEmpty {
                if let first = s.sprites.first { spriteName = first.name; newSprite = false }
                else { newSprite = true; spriteName = suggestedSpriteName }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create() {
        busy = true
        error = nil
        Task {
            do {
                let runtime = remote
                    ? Runtime(kind: "sprite", sprite: spriteName.trimmingCharacters(in: .whitespaces), repo: repo.trimmingCharacters(in: .whitespaces), branch: branch.trimmingCharacters(in: .whitespaces).isEmpty ? nil : branch)
                    : Runtime.local
                let a = try await model.createAgent(.init(workspaceId: workspace.id, name: name.isEmpty ? nil : name, model: modelId.isEmpty ? nil : modelId, runtime: runtime, prompt: prompt.isEmpty ? nil : prompt, createSprite: remote && newSprite))
                onCreated(a)
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct ModelMenu<Label: View>: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Picker("Model", selection: $selection) {
                if !model.models.contains(where: { $0.id == "auto" }) { Text("Auto").tag("auto") }
                ForEach(model.models) { m in Text(m.label).tag(m.id) }
            }
        } label: {
            label()
        }
        .task { await model.loadModels() }
    }
}

private struct ChipRing: ViewModifier {
    var selected: Bool
    func body(content: Content) -> some View {
        if selected { content } else { content.elevation(.btn, Capsule()) }
    }
}
