import SwiftUI
import UserNotifications

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var asSheet = false

    var body: some View {
        VStack(spacing: 0) {
            if asSheet { SheetHeader(title: "Needs you", subtitle: "Questions from your agents") { dismiss() } }
            ScrollView {
                VStack(spacing: 14) {
                    if model.decisions.isEmpty {
                        VStack(spacing: 12) {
                            ResultBadge(tone: .green, symbol: "checkmark", size: 44)
                                .symbolEffect(.bounce, value: model.decisions.isEmpty)
                            Text("All clear").font(.inter(17, .semibold)).foregroundStyle(Theme.text)
                            Text("Nothing is waiting on you.").font(.inter(14)).foregroundStyle(Theme.text2)
                        }
                        .padding(.top, 60)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    ForEach(model.decisions.sorted { $0.createdAt > $1.createdAt }) { d in
                        VStack(alignment: .leading, spacing: 6) {
                            ApprovalCard(decisionId: d.id, fallbackQuestion: d.question, showAgent: true)
                            Button {
                                dismiss()
                                model.open(agentId: d.agentId)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("Open conversation")
                                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                                }
                                .font(.inter(12.5, .medium)).foregroundStyle(BUI.ink3)
                            }
                            .buttonStyle(.bui(.quiet, .xs))
                        }
                        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.92).combined(with: .opacity)))
                    }
                }
                .padding(16)
                .animation(Theme.spring, value: model.decisions.map(\.id))
            }
        }
        .background(Theme.bg)
        .navigationTitle(asSheet ? "" : "Needs you")
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sprites: SpritesResponse?
    @State private var spritesError: String?
    @State private var newSprite = ""
    @State private var creating = false
    @State private var confirmUnpair = false
    @State private var destroying: SpriteInfo?
    @State private var pushStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage("showThinking") private var showThinking = false
    @State private var wheel = 0.0
    @State private var wheelTaps = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    HelmMark(size: 54)
                        .rotationEffect(.degrees(wheel))
                        .onLongPressGesture(minimumDuration: 0.4) {
                            wheelTaps += 1
                            withAnimation(.spring(response: 1.6, dampingFraction: 0.55)) { wheel += 720 }
                        }
                        .sensoryFeedback(.impact(weight: .heavy), trigger: wheelTaps)
                    Text(wheelTaps >= 3 ? "Steady as she goes, captain." : "Helm").font(.inter(15, .semibold)).foregroundStyle(Theme.text2)
                        .contentTransition(.opacity)
                        .animation(Theme.ease, value: wheelTaps)
                }
                .padding(.top, 8)

                group("Hub") {
                    row("Mac", model.hub?.name ?? model.pairing?.name ?? "—")
                    row("Address", model.baseURL ?? "—", mono: true)
                    row("Status", model.connection == .online ? "Connected" : model.connection == .connecting ? "Connecting" : "Offline")
                    row("Cursor", model.hub?.cursorLoggedIn == true ? (model.hub?.cursorEmail ?? "Signed in") : "Not signed in — run npm run login")
                    row("Cursor app", model.hub?.cursorRunning == true ? "Running" : "Not running")
                }

                group("Notifications") {
                    row("This iPhone", pushLabel)
                    row("Hub push", model.hub?.push == true ? "Ready" : "Needs APNs key")
                    if model.hub?.push != true {
                        Text("To get pushes when the app is closed, create an APNs key at developer.apple.com → Keys (enable Apple Push Notifications service), then save the .p8 file into ~/.helm on the Mac and restart the hub.")
                            .font(.inter(12.5)).foregroundStyle(Theme.text2).padding(.horizontal, 14).padding(.bottom, 12)
                    }
                    HStack(spacing: 8) {
                        if pushStatus != .authorized {
                            Button("Allow notifications") { AppDelegate.requestPush(); Task { await refreshPush() } }.buttonStyle(.bui(.primary, .sm))
                        }
                        Button("Send test push") { Task { await model.testPush() } }.buttonStyle(.bui(.secondary, .sm))
                            .disabled(model.hub?.push != true)
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }

                group("Chats") {
                    Toggle(isOn: $showThinking) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show thinking").font(.inter(14, .medium)).foregroundStyle(BUI.ink)
                            Text("Open every thought by default. You can always tap one to expand it.").font(.inter(12.5)).foregroundStyle(BUI.ink2)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                }

                group("Fly sprites") {
                    if let s = sprites {
                        if !s.loggedIn {
                            Text("Sprites isn't signed in on the Mac. Run `sprite login` there, then pull to refresh.")
                                .font(.inter(13.5)).foregroundStyle(Theme.text2).padding(14)
                        } else {
                            if s.sprites.isEmpty {
                                Text("No sprites yet. Create one here or when starting a remote agent.").font(.inter(13.5)).foregroundStyle(Theme.text2).padding(14)
                            }
                            ForEach(s.sprites) { sp in
                                HStack(spacing: 10) {
                                    Image(systemName: "cloud.fill").font(.system(size: 12)).foregroundStyle(BUI.accentInk)
                                        .frame(width: 28, height: 28).background(BUI.accentTint, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(sp.name).font(.inter(15, .medium)).foregroundStyle(Theme.text)
                                        let n = model.agents.filter { $0.runtime.sprite == sp.name }.count
                                        Text(n > 0 ? "\(n) agent\(n == 1 ? "" : "s")" : "No agents")
                                            .font(.inter(12)).foregroundStyle(Theme.text2)
                                    }
                                    Spacer()
                                    if let st = sp.status { StatusPill(tone: st == "running" || st == "warm" ? .green : .neutral, text: st) }
                                    Button(role: .destructive) { destroying = sp } label: { Image(systemName: "trash") }
                                        .buttonStyle(IconButtonStyle(size: 30, tint: BUI.red))
                                        .accessibilityLabel("Destroy \(sp.name)")
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                            }
                            HStack(spacing: 8) {
                                TextField("new-sprite-name", text: $newSprite)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .field().font(.mono)
                                Button {
                                    creating = true
                                    Task {
                                        do { try await model.createSprite(newSprite); newSprite = "" } catch { spritesError = error.localizedDescription }
                                        await loadSprites()
                                        creating = false
                                    }
                                } label: {
                                    if creating { ProgressView().tint(Theme.text) } else { Text("Create") }
                                }
                                .buttonStyle(.bui(.primary, .md))
                                .disabled(newSprite.isEmpty || creating)
                            }
                            .padding(14)
                        }
                    } else {
                        ProgressView().tint(Theme.text2).frame(maxWidth: .infinity).padding(20)
                    }
                    if let spritesError { Text(spritesError).font(.inter(12.5)).foregroundStyle(Theme.error).padding([.horizontal, .bottom], 14) }
                }
                .animation(Theme.ease, value: sprites?.sprites.map(\.name))

                Button("Unpair this iPhone", role: .destructive) { confirmUnpair = true }
                    .buttonStyle(.bui(.danger, .md))
                    .padding(.top, 6)
            }
            .padding(16)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadSprites() }
        .task {
            await refreshPush()
            await loadSprites()
        }
        .confirmationDialog("Unpair from \(model.hub?.name ?? "this Mac")?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.unpair() }
        }
        .confirmationDialog("Destroy \(destroying?.name ?? "")?", isPresented: Binding(get: { destroying != nil }, set: { if !$0 { destroying = nil } }), titleVisibility: .visible) {
            Button("Destroy sprite", role: .destructive) {
                guard let sp = destroying else { return }
                Task {
                    do { try await model.destroySprite(sp.name) } catch { spritesError = error.localizedDescription }
                    await loadSprites()
                }
            }
        } message: {
            Text("This permanently deletes the sprite, its files and any agents running in it.")
        }
    }

    private var pushLabel: String {
        switch pushStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Off in iOS Settings"
        default: return "Not asked yet"
        }
    }

    private func refreshPush() async {
        pushStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func loadSprites() async {
        do {
            sprites = try await model.sprites()
            spritesError = nil
        } catch {
            spritesError = error.localizedDescription
            if sprites == nil { sprites = SpritesResponse(loggedIn: false, error: error.localizedDescription, sprites: []) }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
                .elevation(.card, radius: BUI.Radius.window)
        }
    }

    private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.inter(14)).foregroundStyle(BUI.ink2)
            Spacer(minLength: 16)
            Text(v).font(mono ? .monoSmall : .inter(14, .medium)).foregroundStyle(BUI.ink).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(BUI.line).frame(height: 1).padding(.leading, 14) }
    }
}
