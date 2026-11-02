import SwiftUI
import UserNotifications
import ActivityKit

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        HelmIntents.handler = { a in await AppModel.shared.liveAnswer(a) }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let answer = UNTextInputNotificationAction(identifier: "ANSWER", title: "Answer", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Type an answer or option number")
        let reply = UNTextInputNotificationAction(identifier: "REPLY", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Message the agent")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "DECISION", actions: [answer], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "AGENT", actions: [reply], intentIdentifiers: [], options: []),
        ])
        Task { @MainActor in
            if AppModel.shared.pairing != nil { Self.requestPush() }
        }
        return true
    }

    @MainActor
    static func requestPush() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "noPush") { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in AppModel.shared.setDeviceToken(deviceToken) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        if let id = userInfo["pushId"] as? String { await AppModel.shared.ackPush(id, how: "background") }
        return .noData
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        if let id = info["pushId"] as? String { await AppModel.shared.ackPush(id, how: "foreground") }
        let agentId = info["agentId"] as? String
        let (active, desktop) = await MainActor.run { (AppModel.shared.activeAgentId, AppModel.shared.activeDesktopChat) }
        if let agentId, agentId == active { return [] }
        if let w = info["desktopWindow"] as? String, let c = info["chat"] as? String, desktop == DesktopRef(window: w, chat: c) { return [] }
        return [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let agentId = info["agentId"] as? String
        let decisionId = info["decisionId"] as? String
        let model = await MainActor.run { AppModel.shared }
        if let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if response.actionIdentifier == "ANSWER", let decisionId {
                _ = await model.answer(decisionId, text)
            } else if response.actionIdentifier == "REPLY", let agentId {
                _ = await model.send(agentId, text: text, images: [])
            }
            return
        }
        if let agentId { await MainActor.run { model.open(agentId: agentId) } }
        else if let win = info["desktopWindow"] as? String, let chat = info["chat"] as? String {
            await MainActor.run { model.open(desktop: DesktopRef(window: win, chat: chat)) }
        }
    }
}

@main
struct HelmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(BUI.accent)
                .toggleStyle(BSwitchStyle())
                .onOpenURL { url in
                    if let p = Pairing.parse(url.absoluteString) {
                        Task { try? await model.pair(p) }
                        return
                    }
                    let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let v = { (k: String) in q.first(where: { $0.name == k })?.value }
                    if url.host == "desktop", let w = v("window"), let c = v("chat") {
                        model.open(desktop: DesktopRef(window: w, chat: c))
                    } else if url.host == "agent", let id = v("id") {
                        model.open(agentId: id)
                    }
                }
                .onChange(of: phase) { _, p in
                    if p == .active { model.foregrounded() }
                }
                #if DEBUG
                .task {
                    if let demo = UserDefaults.standard.string(forKey: "demoActivity") {
                        let now = Date().timeIntervalSince1970
                        typealias R = HelmActivityAttributes.Row
                        let rows: [R] = demo == "busy" ? [
                            R(id: "w:Remote", name: "Offline sync", place: "mobile-app", state: "working", since: now - 1210, detail: "$ xcodebuild -scheme MobileApp build", subagents: 1),
                            R(id: "w:Docs", name: "API reference refresh", place: "docs-site", state: "working", since: now - 340, detail: "Reading webhooks.mdx"),
                            R(id: "a2", name: "Search indexer", place: "storefront", state: "working", since: now - 64, detail: "Thinking"),
                        ] : demo == "choose" ? [
                            R(id: "a1", name: "Release agent", place: "storefront", state: "waiting", since: now - 30, detail: "Which environment should I deploy the fix to?", ask: "choose", options: ["Staging", "Production", "Both"], decision: "d1"),
                            R(id: "w:Remote", name: "Offline sync", place: "mobile-app", state: "working", since: now - 1210, detail: "Editing SyncEngine.swift"),
                        ] : [
                            R(id: "w:Handoff", name: "Checkout redesign", place: "storefront", state: "waiting", since: now - 95, detail: "Run `pnpm prisma migrate deploy` against staging?", ask: "approve", approve: "Run", reject: "Skip"),
                            R(id: "w:Remote", name: "Offline sync", place: "mobile-app", state: "working", since: now - 1210, detail: "Editing SyncEngine.swift", subagents: 2),
                        ]
                        let st = HelmActivityAttributes.ContentState(working: rows.filter { !$0.waiting }.count, waiting: rows.filter(\.waiting).count, rows: rows)
                        for a in Activity<HelmActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
                        _ = try? Activity.request(attributes: HelmActivityAttributes(hub: "Helm"), content: .init(state: st, staleDate: nil))
                        return
                    }
                    if let s = UserDefaults.standard.string(forKey: "pair"), let p = Pairing.parse(s) {
                        try? await model.pair(p)
                    }
                    if let d = UserDefaults.standard.string(forKey: "openDoc"), !d.isEmpty { model.openDocument = DocumentRef(path: d, chat: UserDefaults.standard.string(forKey: "openDocChat")) }
                    if let p = UserDefaults.standard.string(forKey: "openImage"), !p.isEmpty { model.openImages = ImageGallery(images: p.components(separatedBy: ",").map { ImageRef(path: $0) }, index: 0) }
                    if let w = UserDefaults.standard.string(forKey: "openWindow"), let c = UserDefaults.standard.string(forKey: "openChat"), !w.isEmpty {
                        try? await Task.sleep(for: .seconds(1.5))
                        model.open(desktop: DesktopRef(window: w, chat: c))
                        if let s = UserDefaults.standard.string(forKey: "openSubagent") {
                            try? await Task.sleep(for: .seconds(1.5))
                            model.route.append(.subagent(s, "Subagent"))
                        }
                    } else if let a = UserDefaults.standard.string(forKey: "openAgent"), !a.isEmpty {
                        try? await Task.sleep(for: .seconds(1.5))
                        model.open(agentId: a)
                    } else if let w = UserDefaults.standard.string(forKey: "openWindow"), !w.isEmpty {
                        try? await Task.sleep(for: .seconds(1.5))
                        model.route = [.desktopWindow(w)]
                    }
                }
                #endif
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if model.pairing == nil {
                PairingView()
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 1.04))))
            } else {
                HomeView()
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
            }
        }
        .animation(Theme.ease, value: model.pairing == nil)
        .overlay(alignment: .top) { BannerOverlay() }
        .sheet(item: Binding(get: { model.openDocument }, set: { model.openDocument = $0 })) { DocumentSheet(start: $0) }
        .fullScreenCover(item: Binding(get: { model.openImages }, set: { model.openImages = $0 })) { ImageViewer(gallery: $0) }
        #if DEBUG
        .overlay { if UserDefaults.standard.bool(forKey: "cardGallery") { SubagentCardGallery() } }
        .overlay { if UserDefaults.standard.bool(forKey: "laGallery") { LiveActivityGallery() } }
        .overlay { if UserDefaults.standard.bool(forKey: "queueLab") { QueueMotionLab() } }
        .overlay { if UserDefaults.standard.bool(forKey: "mcpGallery") { MCPGallery() } }
        .overlay { if UserDefaults.standard.bool(forKey: "mermaidGallery") { MermaidGallery() } }
        .overlay { if let r = UserDefaults.standard.string(forKey: "openChanges") { ChangesSheet(root: r) } }
        .overlay { if let t = UserDefaults.standard.string(forKey: "openTerminal") { TerminalSheet(id: t).background(BUI.page) } }
        #endif
        .onAppear { if model.pairing != nil { model.connect() } }
    }
}

struct BannerOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let b = model.banner {
                Button {
                    if let id = b.agentId { model.open(agentId: id) } else if let ref = b.desktop { model.open(desktop: ref) }
                    model.banner = nil
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill((b.isDecision ? Theme.waiting : Theme.error).opacity(0.16)).frame(width: 34, height: 34)
                            Image(systemName: b.isDecision ? "hand.raised.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(b.isDecision ? Theme.waiting : Theme.error)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.title).font(.inter(14, .semibold)).foregroundStyle(Theme.text)
                            Text(b.body).font(.inter(13)).foregroundStyle(Theme.text2).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.window, style: .continuous))
                    .elevation(.overlay, radius: BUI.Radius.window)
                }
                .buttonStyle(PressableStyle())
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .gesture(DragGesture().onEnded { v in if v.translation.height < -10 { model.banner = nil } })
                .sensoryFeedback(.warning, trigger: b.id)
            }
        }
        .animation(Theme.spring, value: model.banner)
    }
}
