import Foundation
import Observation
import Security
import UIKit

struct Pairing: Codable, Equatable {
    var url: String
    var alt: String?
    var token: String
    var name: String

    static func parse(_ raw: String) -> Pairing? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: s), comps.scheme == "helm" else { return nil }
        let q = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let url = q["url"], !url.isEmpty, let token = q["token"], !token.isEmpty else { return nil }
        return Pairing(url: url, alt: q["alt"], token: token, name: q["name"] ?? "Mac")
    }
}

enum Keychain {
    static let service = Bundle.main.bundleIdentifier ?? "helm"

    static func save(_ data: Data, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

struct APIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum ConnectionState: Equatable {
    case offline, connecting, online
}

struct Banner: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var agentId: String?
    var isDecision: Bool
    var desktop: DesktopRef?
}

struct DesktopRef: Equatable, Hashable {
    var window: String
    var chat: String
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var pairing: Pairing?
    var connection: ConnectionState = .offline
    var hub: HubInfo?
    var workspaces: [Workspace] = []
    var agents: [Agent] = []
    var decisions: [Decision] = []
    var transcripts: [String: [Item]] = [:]
    var models: [ModelInfo] = []
    var desktop = DesktopState(available: false, windows: [])
    var activeDesktopChat: DesktopRef?
    var clones: [String: CloneJob] = [:]
    var banner: Banner?
    var route: [Route] = []
    var activeAgentId: String?
    var lastError: String?

    private var socket: URLSessionWebSocketTask?
    private var session = URLSession(configuration: .default)
    private var reconnectDelay: Double = 1
    private var useAlt = false
    private var reconnectTask: Task<Void, Never>?
    private var deviceToken: String?
    private let deviceId: String = {
        if let id = UserDefaults.standard.string(forKey: "deviceId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceId")
        return id
    }()

    init() {
        if let data = Keychain.load(account: "pairing"), let p = try? JSONDecoder().decode(Pairing.self, from: data) {
            pairing = p
        }
    }

    var baseURL: String? {
        guard let p = pairing else { return nil }
        return useAlt ? (p.alt ?? p.url) : p.url
    }

    // MARK: pairing

    func pair(_ p: Pairing) async throws {
        commit(try await verify(p))
    }

    func commit(_ p: Pairing) {
        Keychain.save((try? JSONEncoder().encode(p)) ?? Data(), account: "pairing")
        pairing = p
        useAlt = false
        connect()
    }

    func verify(_ p: Pairing) async throws -> Pairing {
        var lastErr: Error?
        for candidate in [p.url, p.alt].compactMap({ $0 }) {
            do {
                var req = URLRequest(url: URL(string: candidate + "/api/state")!)
                req.timeoutInterval = 8
                req.setValue("Bearer \(p.token)", forHTTPHeaderField: "Authorization")
                let (_, resp) = try await session.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 { throw APIError(message: "The hub rejected this pairing code. Run `npm run pair` on the Mac for a fresh one.") }
                guard code == 200 else { throw APIError(message: "The hub answered with HTTP \(code).") }
                var chosen = p
                chosen.url = candidate
                return chosen
            } catch {
                lastErr = error
            }
        }
        if let e = lastErr as? APIError { throw e }
        throw APIError(message: "Couldn't reach \(p.name). Make sure Tailscale is connected on both devices and the hub is running.")
    }

    func unpair() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        Keychain.delete(account: "pairing")
        pairing = nil
        hub = nil
        workspaces = []
        agents = []
        decisions = []
        transcripts = [:]
        route = []
        connection = .offline
    }

    // MARK: socket

    func connect() {
        guard let base = baseURL, let p = pairing else { return }
        reconnectTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        let wsBase = base.replacingOccurrences(of: "http://", with: "ws://").replacingOccurrences(of: "https://", with: "wss://")
        guard let url = URL(string: "\(wsBase)/ws?token=\(p.token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? p.token)") else { return }
        connection = .connecting
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        socket = task
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let msg):
                    if case .string(let s) = msg { self.handle(Data(s.utf8)) }
                    else if case .data(let d) = msg { self.handle(d) }
                    self.receive(task)
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        connection = .offline
        socket = nil
        guard pairing != nil else { return }
        if pairing?.alt != nil { useAlt.toggle() }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 1.7, 15)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    func foregrounded() {
        if connection != .online { reconnectDelay = 1; connect() }
    }

    private struct Envelope: Decodable {
        var type: String
        var hub: HubInfo?
        var workspaces: [Workspace]?
        var agents: [Agent]?
        var decisions: [Decision]?
        var desktop: DesktopState?
        var available: Bool?
        var windows: [DesktopWindow]?
        var job: CloneJob?
        var workspace: Workspace?
        var agent: Agent?
        var decision: Decision?
        var agentId: String?
        var item: Item?
        var itemId: String?
        var text: String?
        var kind: String?
        var id: String?
    }

    private func handle(_ data: Data) {
        guard let ev = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        if ["snapshot", "agent", "desktop", "removed"].contains(ev.type) { scheduleActivity() }
        switch ev.type {
        case "snapshot":
            connection = .online
            reconnectDelay = 1
            hub = ev.hub
            if let d = ev.desktop { desktop = d }
            workspaces = ev.workspaces ?? []
            agents = ev.agents ?? []
            let all = ev.decisions ?? []
            decisions = all.filter { $0.answeredAt == nil }
            answeredDecisions = Dictionary(all.filter { $0.answeredAt != nil }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for id in transcripts.keys { Task { await loadTranscript(id) } }
            if deviceToken != nil { Task { await registerDevice() } }
        case "workspace":
            guard let w = ev.workspace else { return }
            if w.hidden { workspaces.removeAll { $0.id == w.id }; return }
            if let i = workspaces.firstIndex(where: { $0.id == w.id }) { workspaces[i] = w } else { workspaces.append(w) }
        case "agent":
            guard let a = ev.agent else { return }
            if let i = agents.firstIndex(where: { $0.id == a.id }) { agents[i] = a } else { agents.append(a) }
            if activeAgentId == a.id && a.unread > 0 { Task { await markRead(a.id) } }
        case "item":
            guard let id = ev.agentId, let item = ev.item, transcripts[id] != nil else { return }
            if let i = transcripts[id]!.firstIndex(where: { $0.id == item.id }) { transcripts[id]![i] = item }
            else { transcripts[id]!.append(item) }
        case "append":
            guard let id = ev.agentId, let itemId = ev.itemId, let text = ev.text,
                  let i = transcripts[id]?.firstIndex(where: { $0.id == itemId }) else { return }
            transcripts[id]![i].text = (transcripts[id]![i].text ?? "") + text
        case "decision":
            guard let d = ev.decision else { return }
            if d.answeredAt != nil {
                decisions.removeAll { $0.id == d.id }
            } else if !decisions.contains(where: { $0.id == d.id }) {
                decisions.append(d)
            }
            answeredDecisions[d.id] = d.answeredAt != nil ? d : nil
        case "desktop":
            desktop = DesktopState(available: ev.available ?? false, windows: ev.windows ?? [])
        case "clone":
            if let j = ev.job { clones[j.id] = j }
        case "removed":
            if ev.kind == "agent" { agents.removeAll { $0.id == ev.id }; transcripts[ev.id ?? ""] = nil }
            if ev.kind == "workspace" { workspaces.removeAll { $0.id == ev.id } }
        default: break
        }
    }

    var answeredDecisions: [String: Decision] = [:]

    func desktopWindow(_ id: String) -> DesktopWindow? { desktop.windows.first { $0.id == id } }

    func desktopTranscript(_ ref: DesktopRef, composerId: String?, tail: Int? = nil) async throws -> DesktopTranscript {
        var path = "/api/desktop/\(ref.window)/transcript?chat=\(ref.chat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? "")"
        if let composerId { path += "&composerId=\(composerId)" }
        if let tail { path += "&tail=\(tail)" }
        return try await request("GET", path)
    }

    func terminal(_ id: String, from: Int = 0) async throws -> TerminalOutput {
        try await request("GET", "/api/desktop/terminals/\(id)?from=\(from)")
    }

    func subagent(_ id: String) async throws -> Subagent {
        try await request("GET", "/api/desktop/subagents/\(id)")
    }

    struct DesktopSendResult: Decodable { var ok: Bool?; var composerId: String?; var queued: String? }

    func desktopSend(window: String, chat: String?, text: String, images: [OutgoingImage] = [], banner: Bool = true) async -> DesktopSendResult? {
        struct B: Encodable { var chat: String?; var text: String; var images: [OutgoingImage]? }
        do { return try await request("POST", "/api/desktop/\(window)/send", body: B(chat: chat, text: text, images: images.isEmpty ? nil : images)) }
        catch {
            if banner { showBanner(Banner(title: "Couldn't send to Cursor", body: error.localizedDescription, agentId: nil, isDecision: false)) }
            return nil
        }
    }

    /// A button pressed on the lock-screen Live Activity.
    func liveAnswer(_ a: HelmIntents.Answer) async {
        if pairing == nil { return }
        if let d = a.decision {
            _ = await answer(d, a.option)
        } else if let i = a.row.firstIndex(of: ":") {
            let ref = DesktopRef(window: String(a.row[..<i]), chat: String(a.row[a.row.index(after: i)...]))
            switch a.action {
            case "approve": _ = await desktopRespond(ref, approve: true)
            case "reject": _ = await desktopRespond(ref, approve: false)
            default: _ = await desktopAnswer(ref, [DesktopAnswer(index: 0, option: a.option, text: nil)])
            }
        }
        scheduleActivity()
    }

    func desktopRespond(_ ref: DesktopRef, approve: Bool) async -> Bool {
        struct B: Encodable { var chat: String; var approve: Bool }
        return await run { let _: OK = try await request("POST", "/api/desktop/\(ref.window)/respond", body: B(chat: ref.chat, approve: approve)) }
    }

    struct DesktopAnswer: Encodable { var index: Int; var option: String?; var text: String? }

    func desktopAnswer(_ ref: DesktopRef, _ answers: [DesktopAnswer]) async -> Bool {
        struct B: Encodable { var chat: String; var answers: [DesktopAnswer] }
        struct R: Decodable { var ok: Bool?; var submitted: Bool? }
        do {
            let r: R = try await request("POST", "/api/desktop/\(ref.window)/answer", body: B(chat: ref.chat, answers: answers))
            if r.ok == false { showBanner(Banner(title: "Picked, but not sent", body: "Cursor kept the question open. Finish it on the Mac.", agentId: nil, isDecision: false)) }
            return r.ok != false
        } catch {
            showBanner(Banner(title: "Couldn't answer", body: error.localizedDescription, agentId: nil, isDecision: false))
            return false
        }
    }

    func desktopStop(_ ref: DesktopRef) async {
        struct B: Encodable { var chat: String }
        await run { let _: OK = try await request("POST", "/api/desktop/\(ref.window)/stop", body: B(chat: ref.chat)) }
    }

    // MARK: Desktop chat management

    enum ChatEdit: Equatable { case renamed(String), archived, restored, deleted }
    /// Changes made from the phone, shown right away and dropped once Cursor's state agrees (or they expire).
    private(set) var chatEdits: [String: (edit: ChatEdit, at: Date)] = [:]
    /// The phone's own chat order per project; Cursor only sorts by recency.
    private(set) var chatOrder: [String: [String]] = (UserDefaults.standard.dictionary(forKey: "chatOrder") as? [String: [String]]) ?? [:]

    private func liveEdit(_ id: String) -> ChatEdit? {
        guard let e = chatEdits[id], Date().timeIntervalSince(e.at) < 6 else { return nil }
        return e.edit
    }

    /// A window's chats as the phone shows them, with pending edits applied, in Cursor's order.
    func chats(in w: DesktopWindow) -> [DesktopChat] {
        var list: [DesktopChat] = w.chats.compactMap { c in
            switch c.composerId.flatMap(liveEdit) {
            case .archived, .deleted: return nil
            case .renamed(let name): var c = c; c.title = name; return c
            default: return c
            }
        }
        for a in w.archived ?? [] where liveEdit(a.composerId) == .restored && !list.contains(where: { $0.composerId == a.composerId }) {
            list.insert(DesktopChat(title: a.title, age: "now", status: .idle, selected: false, composerId: a.composerId), at: 0)
        }
        return list
    }

    func archivedChats(in w: DesktopWindow) -> [DesktopArchivedChat] {
        var list = (w.archived ?? []).filter { liveEdit($0.composerId) != .restored && liveEdit($0.composerId) != .deleted }
        for c in w.chats where c.composerId.flatMap(liveEdit) == .archived && !list.contains(where: { $0.composerId == c.composerId }) {
            list.insert(DesktopArchivedChat(title: c.title, composerId: c.composerId!, age: "now"), at: 0)
        }
        return list
    }

    /// Where a project's order is saved: its Helm workspace if it has one, else the Cursor window's name.
    func projectKey(_ ws: Workspace?, _ win: DesktopWindow?) -> String {
        ws.map { "ws:\($0.id)" } ?? "win:\(win?.workspace ?? "")"
    }

    func setOrder(_ keys: [String]?, for key: String) {
        chatOrder[key] = keys
        UserDefaults.standard.set(chatOrder, forKey: "chatOrder")
    }

    /// Everything you've got going in a project, Cursor chats and Helm agents together: most recent
    /// first, then the order you dragged them into (anything new goes on top).
    func threads(_ ws: Workspace?, _ win: DesktopWindow?) -> [ProjectThread] {
        let chats = win.map { w in chats(in: w).map { ProjectThread(chat: $0, window: w.id) } } ?? []
        let helm = (ws.map { agents(in: $0.id) } ?? []).sorted { $0.updatedAt > $1.updatedAt }.map(ProjectThread.init(agent:))
        var merged: [ProjectThread] = []
        var i = 0
        for c in chats {
            while i < helm.count, let t = c.updatedAt, helm[i].updatedAt ?? 0 > t {
                merged.append(helm[i])
                i += 1
            }
            merged.append(c)
        }
        merged += helm[i...]
        guard let order = chatOrder[projectKey(ws, win)], !order.isEmpty else { return merged }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return merged.filter { rank[$0.id] == nil } + merged.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
    }

    func archivedThreads(_ ws: Workspace?, _ win: DesktopWindow?) -> [ThreadRef] {
        let chats = win.map { w in archivedChats(in: w).map { ThreadRef(kind: .chat(window: w.id, composerId: $0.composerId), title: $0.title, age: $0.age) } } ?? []
        let helm = ws.map { w in agents.filter { $0.workspaceId == w.id && $0.archived == true }.sorted { $0.updatedAt > $1.updatedAt }
            .map { ThreadRef(kind: .agent($0.id), title: $0.name, age: relativeTime($0.updatedAt)) } } ?? []
        return chats + helm
    }

    func rename(_ t: ThreadRef, to name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != t.title else { return false }
        switch t.kind {
        case .chat(let win, let id):
            guard let w = desktopWindow(win), let c = w.chats.first(where: { $0.composerId == id }) else { return false }
            return await renameChat(w, c, to: name)
        case .agent(let id):
            if let i = agents.firstIndex(where: { $0.id == id }) { agents[i].name = name }
            return await updateAgent(id, name: name)
        }
    }

    func archive(_ t: ThreadRef, _ archived: Bool = true) async -> Bool {
        switch t.kind {
        case .chat(let win, let id):
            guard let w = desktopWindow(win) else { return false }
            return await archiveChat(w, composerId: id, archived: archived)
        case .agent(let id):
            guard let i = agents.firstIndex(where: { $0.id == id }) else { return false }
            if archived && agents[i].isBusy { await cancel(id) }
            if let i = agents.firstIndex(where: { $0.id == id }) { agents[i].archived = archived }
            return await updateAgent(id, archived: archived)
        }
    }

    func delete(_ t: ThreadRef) async -> Bool {
        switch t.kind {
        case .chat(let win, let id):
            guard let w = desktopWindow(win) else { return false }
            return await deleteChat(w, composerId: id)
        case .agent(let id):
            await deleteAgent(id)
            return !agents.contains { $0.id == id }
        }
    }

    private func manageChat(_ w: DesktopWindow, _ id: String, _ edit: ChatEdit, path: String, body: Encodable? = nil, failure: String) async -> Bool {
        let before = chatEdits[id]
        chatEdits[id] = (edit, Date())
        do {
            let _: OK = try await request("POST", "/api/desktop/\(w.id)/chats/\(id)/\(path)", body: body)
            chatEdits[id] = (edit, Date())
            return true
        } catch {
            chatEdits[id] = before
            showBanner(Banner(title: failure, body: error.localizedDescription, agentId: nil, isDecision: false))
            return false
        }
    }

    func renameChat(_ w: DesktopWindow, _ c: DesktopChat, to name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = c.composerId, !name.isEmpty, name != c.title else { return false }
        return await manageChat(w, id, .renamed(name), path: "rename", body: ["name": name], failure: "Couldn't rename it")
    }

    func archiveChat(_ w: DesktopWindow, composerId id: String, archived: Bool = true) async -> Bool {
        await manageChat(w, id, archived ? .archived : .restored, path: "archive", body: ["archived": archived], failure: archived ? "Couldn't archive it" : "Couldn't restore it")
    }

    func deleteChat(_ w: DesktopWindow, composerId id: String) async -> Bool {
        await manageChat(w, id, .deleted, path: "delete", failure: "Couldn't delete it")
    }

    func refreshDesktop() async {
        if let d: DesktopState = try? await request("GET", "/api/desktop") { desktop = d }
    }

    /// Cursor titles a window after its folder, or its `.code-workspace` file for multi-folder projects.
    func window(for w: Workspace) -> DesktopWindow? {
        let names = Set([w.name.lowercased()] + (w.folders.count == 1 ? [(w.folders[0] as NSString).lastPathComponent.lowercased()] : []))
        return desktop.windows.first { names.contains($0.workspace.lowercased()) }
    }

    func workspace(for window: DesktopWindow) -> Workspace? {
        let open = workspaces.filter { $0.openOnLaptop == true }
        return (open + workspaces).first { self.window(for: $0)?.id == window.id }
    }

    /// Starts a new Cursor chat in a project, opening it on the Mac first if it isn't already.
    /// Returns where the new chat landed so the caller can open it; `chat` is empty if it hasn't shown up yet.
    func startCursorAgent(in w: Workspace?, window: String?, text: String, images: [OutgoingImage]) async -> DesktopRef? {
        var win = window.flatMap(desktopWindow) ?? w.flatMap(self.window(for:))
        if win == nil, let w {
            guard await openOnLaptop(w.id) else { return nil }
            for _ in 0..<40 where win == nil {
                try? await Task.sleep(for: .milliseconds(500))
                await refreshDesktop()
                win = self.window(for: w)
            }
        }
        guard let win else {
            showBanner(Banner(title: "Cursor didn't open it", body: "The window didn't show up on the Mac. Try again in a moment.", agentId: nil, isDecision: false))
            return nil
        }
        let known = Set(win.chats.map(\.title))
        // A window that just opened takes a moment before its composer takes input.
        var sent = false
        for attempt in 0..<4 where !sent {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(1500)) }
            sent = await desktopSend(window: win.id, chat: nil, text: text, images: images, banner: attempt == 3) != nil
        }
        guard sent else { return nil }
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(500))
            await refreshDesktop()
            if let fresh = desktopWindow(win.id)?.chats.first(where: { !known.contains($0.title) }) {
                return DesktopRef(window: win.id, chat: fresh.title)
            }
        }
        // Sent, but the chat hasn't shown up in the list yet.
        return DesktopRef(window: win.id, chat: "")
    }

    func open(desktop ref: DesktopRef) {
        route = [.desktopWindow(ref.window), .desktopChat(ref.window, ref.chat)]
    }

    func showBanner(_ b: Banner) {
        banner = b
        let id = b.id
        Task {
            try? await Task.sleep(for: .seconds(5))
            if banner?.id == id { banner = nil }
        }
    }

    // MARK: REST

    func request<T: Decodable>(_ method: String, _ path: String, body: Encodable? = nil, as: T.Type = T.self) async throws -> T {
        guard let base = baseURL, let p = pairing, let url = URL(string: base + path) else { throw APIError(message: "Not paired") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 300
        req.setValue("Bearer \(p.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "HTTP \(code)"
            throw APIError(message: msg)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct OK: Decodable { var ok: Bool? }

    @discardableResult
    func run(_ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            return true
        } catch {
            lastError = error.localizedDescription
            showBanner(Banner(title: "Something went wrong", body: error.localizedDescription, agentId: nil, isDecision: false))
            return false
        }
    }

    func loadTranscript(_ agentId: String) async {
        do {
            let items: [Item] = try await request("GET", "/api/agents/\(agentId)/transcript")
            let pending = (transcripts[agentId] ?? []).filter { live in !items.contains { $0.id == live.id } && live.ts > (items.last?.ts ?? 0) }
            transcripts[agentId] = items + pending
        } catch {
            if transcripts[agentId] == nil { transcripts[agentId] = [] }
        }
    }

    func send(_ agentId: String, text: String, images: [OutgoingImage]) async -> Bool {
        await run {
            struct B: Encodable { var text: String; var images: [OutgoingImage]? }
            let _: OK = try await request("POST", "/api/agents/\(agentId)/messages", body: B(text: text, images: images.isEmpty ? nil : images))
        }
    }

    func relay(from: String, to: String, instruction: String) async -> Bool {
        await run {
            let _: OK = try await request("POST", "/api/agents/\(from)/relay", body: ["targetId": to, "instruction": instruction])
        }
    }

    func removeQueued(agent agentId: String, id: String) async -> Bool {
        struct B: Encodable { var id: String }
        do { let _: OK = try await request("POST", "/api/agents/\(agentId)/queue/remove", body: B(id: id)); return true }
        catch { showBanner(Banner(title: "Couldn't remove it", body: error.localizedDescription, agentId: nil, isDecision: false)); return false }
    }

    func editQueued(agent agentId: String, id: String, text: String) async -> Bool {
        struct B: Encodable { var id: String; var text: String }
        do { let _: OK = try await request("POST", "/api/agents/\(agentId)/queue/edit", body: B(id: id, text: text)); return true }
        catch { showBanner(Banner(title: "Couldn't save the edit", body: error.localizedDescription, agentId: nil, isDecision: false)); return false }
    }

    func editQueued(desktop ref: DesktopRef, id: String, text: String) async -> Bool {
        struct B: Encodable { var chat: String; var id: String; var text: String }
        do { let _: OK = try await request("POST", "/api/desktop/\(ref.window)/queue/edit", body: B(chat: ref.chat, id: id, text: text)); return true }
        catch { showBanner(Banner(title: "Couldn't save the edit", body: error.localizedDescription, agentId: nil, isDecision: false)); return false }
    }

    func sendQueuedNow(agent agentId: String, id: String) async -> Bool {
        struct B: Encodable { var id: String }
        do { let _: OK = try await request("POST", "/api/agents/\(agentId)/queue/send", body: B(id: id)); return true }
        catch { showBanner(Banner(title: "Couldn't send it now", body: error.localizedDescription, agentId: nil, isDecision: false)); return false }
    }

    func sendQueuedNow(desktop ref: DesktopRef, id: String) async -> Bool {
        struct B: Encodable { var chat: String; var id: String }
        do { let _: OK = try await request("POST", "/api/desktop/\(ref.window)/queue/send", body: B(chat: ref.chat, id: id)); return true }
        catch { showBanner(Banner(title: "Couldn't send it now", body: error.localizedDescription, agentId: nil, isDecision: false)); return false }
    }

    func moveQueued(agent agentId: String, id: String, to: Int) async -> Bool {
        struct B: Encodable { var id: String; var to: Int }
        do { let _: OK = try await request("POST", "/api/agents/\(agentId)/queue/move", body: B(id: id, to: to)); return true }
        catch { showBanner(Banner(title: "Couldn't move it", body: error.localizedDescription, agentId: nil, isDecision: false)); return false }
    }

    func moveQueued(desktop ref: DesktopRef, id: String, to: Int) async -> Bool {
        struct B: Encodable { var chat: String; var id: String; var to: Int }
        do { let _: OK = try await request("POST", "/api/desktop/\(ref.window)/queue/move", body: B(chat: ref.chat, id: id, to: to)); return true }
        catch { showBanner(Banner(title: "Couldn't move it", body: error.localizedDescription, agentId: nil, isDecision: false)); return false }
    }

    func removeQueued(desktop ref: DesktopRef, id: String) async -> Bool {
        struct B: Encodable { var chat: String; var id: String }
        do { let _: OK = try await request("POST", "/api/desktop/\(ref.window)/queue/remove", body: B(chat: ref.chat, id: id)); return true }
        catch { showBanner(Banner(title: "Couldn't remove it", body: error.localizedDescription, agentId: nil, isDecision: false)); return false }
    }

    func cancel(_ agentId: String) async {
        await run { let _: OK = try await request("POST", "/api/agents/\(agentId)/cancel") }
    }

    func markRead(_ agentId: String) async {
        if let i = agents.firstIndex(where: { $0.id == agentId }) { agents[i].unread = 0 }
        _ = try? await request("POST", "/api/agents/\(agentId)/read", as: OK.self)
    }

    func answer(_ decisionId: String, _ answer: String) async -> Bool {
        let ok = await run { let _: Decision = try await request("POST", "/api/decisions/\(decisionId)", body: ["answer": answer]) }
        if ok, var d = decisions.first(where: { $0.id == decisionId }) {
            d.answer = answer
            d.answeredAt = Date().timeIntervalSince1970 * 1000
            answeredDecisions[decisionId] = d
            decisions.removeAll { $0.id == decisionId }
        }
        return ok
    }

    struct NewAgent: Encodable {
        var workspaceId: String
        var name: String?
        var model: String?
        var runtime: Runtime
        var prompt: String?
        var images: [OutgoingImage]?
        var createSprite: Bool?
    }

    func createAgent(_ body: NewAgent) async throws -> Agent {
        let a: Agent = try await request("POST", "/api/agents", body: body)
        if !agents.contains(where: { $0.id == a.id }) { agents.append(a) }
        return a
    }

    @discardableResult
    func updateAgent(_ id: String, name: String? = nil, model: String? = nil, archived: Bool? = nil) async -> Bool {
        struct B: Encodable { var name: String?; var model: String?; var archived: Bool? }
        return await run {
            let a: Agent = try await request("PATCH", "/api/agents/\(id)", body: B(name: name, model: model, archived: archived))
            if let i = agents.firstIndex(where: { $0.id == id }) { agents[i] = a }
        }
    }

    func deleteAgent(_ id: String) async {
        await run { let _: OK = try await request("DELETE", "/api/agents/\(id)") }
        agents.removeAll { $0.id == id }
    }

    func createWorkspace(name: String, folders: [String], openOnLaptop: Bool) async throws -> Workspace {
        struct B: Encodable { var name: String; var folders: [String]; var openOnLaptop: Bool }
        let w: Workspace = try await request("POST", "/api/workspaces", body: B(name: name, folders: folders, openOnLaptop: openOnLaptop))
        if !workspaces.contains(where: { $0.id == w.id }) { workspaces.append(w) }
        return w
    }

    func updateWorkspace(_ id: String, name: String? = nil, folders: [String]? = nil, pinned: Bool? = nil) async {
        await run {
            struct B: Encodable { var name: String?; var folders: [String]?; var pinned: Bool? }
            let w: Workspace = try await request("PATCH", "/api/workspaces/\(id)", body: B(name: name, folders: folders, pinned: pinned))
            if let i = workspaces.firstIndex(where: { $0.id == id }) { workspaces[i] = w }
        }
    }

    func deleteWorkspace(_ id: String) async {
        workspaces.removeAll { $0.id == id }
        await run { let _: OK = try await request("DELETE", "/api/workspaces/\(id)") }
    }

    func openOnLaptop(_ id: String) async -> Bool {
        let ok = await run { let _: OK = try await request("POST", "/api/workspaces/\(id)/open") }
        if ok, let i = workspaces.firstIndex(where: { $0.id == id }) { workspaces[i].openOnLaptop = true }
        return ok
    }

    func searchDirs(_ q: String) async throws -> [DirListing.Entry] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? q
        return try await request("GET", "/api/fs/search?q=\(enc)")
    }

    func makeDir(in parent: String, name: String) async throws -> MadeDir {
        struct B: Encodable { var parent: String; var name: String }
        return try await request("POST", "/api/fs/mkdir", body: B(parent: parent, name: name))
    }

    func githubRepos(_ q: String) async throws -> [GitHubRepo] {
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? q
        return try await request("GET", "/api/github/repos?q=\(enc)")
    }

    func clone(_ repo: String, into parent: String) async throws -> CloneJob {
        struct B: Encodable { var repo: String; var parent: String }
        let job: CloneJob = try await request("POST", "/api/github/clone", body: B(repo: repo, parent: parent))
        clones[job.id] = clones[job.id] ?? job
        return job
    }

    /// The document sheet that's open, wherever it was opened from.
    var openDocument: DocumentRef?

    private static func queryValue(_ v: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
    }

    func changes(in root: String) async throws -> WorkingChanges {
        try await request("GET", "/api/changes?root=\(Self.queryValue(root))")
    }

    func fileChange(in root: String, path: String) async throws -> ChangedFileDiff {
        try await request("GET", "/api/changes/file?root=\(Self.queryValue(root))&path=\(Self.queryValue(path))")
    }

    func readDocument(_ ref: DocumentRef) async throws -> DocumentFile {
        let enc = Self.queryValue
        var q = "path=\(enc(ref.path))"
        if let root = ref.root { q += "&root=\(enc(root))" }
        if let chat = ref.chat { q += "&chat=\(enc(chat))" }
        return try await request("GET", "/api/file?\(q)")
    }

    /// The image sheet opened from a link in text, where there's no thumbnail to zoom out of.
    var openImages: ImageGallery?
    @ObservationIgnored private let images = NSCache<NSString, UIImage>()

    /// An image from the Mac, scaled by the hub to about `pixels` wide; web images load directly.
    func image(_ ref: ImageRef, pixels: CGFloat) async throws -> UIImage {
        let px = Int(min(2400, max(64, (pixels / 100).rounded(.up) * 100)))
        let key = "\(ref.id)|\(px)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        let url: URL
        var req: URLRequest
        if ref.path.hasPrefix("http://") || ref.path.hasPrefix("https://") {
            guard let u = URL(string: ref.path) else { throw APIError(message: "Bad image link") }
            url = u
            req = URLRequest(url: url)
        } else {
            guard let base = baseURL, let p = pairing else { throw APIError(message: "Not paired") }
            var q = "path=\(Self.queryValue(ref.path))&w=\(px)"
            if let root = ref.root { q += "&root=\(Self.queryValue(root))" }
            guard let u = URL(string: base + "/api/image?" + q) else { throw APIError(message: "Bad image path") }
            url = u
            req = URLRequest(url: url)
            req.setValue("Bearer \(p.token)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 60
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Couldn't load the image"
            throw APIError(message: msg)
        }
        guard let img = UIImage(data: data) else { throw APIError(message: "That file isn't an image Helm can show") }
        let ready = await img.byPreparingForDisplay() ?? img
        images.setObject(ready, forKey: key, cost: data.count)
        return ready
    }

    func listDir(_ path: String) async throws -> DirListing {
        let q = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        return try await request("GET", "/api/fs?path=\(q)")
    }

    func repoInfo(_ path: String) async -> RepoInfo? {
        let q = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        return try? await request("GET", "/api/repo-info?path=\(q)")
    }

    func loadModels() async {
        if !models.isEmpty { return }
        if let m: [ModelInfo] = try? await request("GET", "/api/models") { models = m }
    }

    func sprites() async throws -> SpritesResponse { try await request("GET", "/api/sprites") }

    func createSprite(_ name: String) async throws {
        let _: OK = try await request("POST", "/api/sprites", body: ["name": name])
    }

    func destroySprite(_ name: String) async throws {
        let _: OK = try await request("DELETE", "/api/sprites/\(name)")
    }

    func testPush() async {
        await run { let _: OK = try await request("POST", "/api/test-push") }
    }

    // MARK: push

    func setDeviceToken(_ token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
        Task { await registerDevice() }
    }

    // MARK: live activity

    @ObservationIgnored private var _liveActivity: LiveActivityController?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var activityStartToken: String?
    private var liveActivity: LiveActivityController {
        if let l = _liveActivity { return l }
        let l = LiveActivityController(model: self)
        _liveActivity = l
        return l
    }

    private func scheduleActivity() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "noPush") { return }
        #endif
        guard activityTask == nil else { return }
        activityTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            self.activityTask = nil
            if let state: HelmActivityAttributes.ContentState = try? await self.request("GET", "/api/activity") {
                await self.liveActivity.apply(state)
            }
        }
    }

    func sendActivityToken(token: String) async {
        struct B: Encodable { var token: String }
        _ = try? await request("POST", "/api/devices/\(deviceId)/activity", body: B(token: token), as: OK.self)
    }

    func sendActivityStartToken(_ token: String) async {
        activityStartToken = token
        struct B: Encodable { var startToken: String }
        _ = try? await request("POST", "/api/devices/\(deviceId)/activity", body: B(startToken: token), as: OK.self)
    }

    func ackPush(_ id: String, how: String) async {
        struct B: Encodable { var id: String; var how: String }
        _ = try? await request("POST", "/api/push-ack", body: B(id: id, how: how), as: OK.self)
    }

    func registerDevice() async {
        guard pairing != nil else { return }
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        let ns = await UNUserNotificationCenter.current().notificationSettings()
        let notif = [
            "auth": "\(ns.authorizationStatus.rawValue)", "alert": "\(ns.alertSetting.rawValue)", "lock": "\(ns.lockScreenSetting.rawValue)",
            "center": "\(ns.notificationCenterSetting.rawValue)", "sound": "\(ns.soundSetting.rawValue)", "style": "\(ns.alertStyle.rawValue)",
            "timeSensitive": "\(ns.timeSensitiveSetting.rawValue)", "scheduledSummary": "\(ns.scheduledDeliverySetting.rawValue)",
        ]
        struct B: Encodable { var id: String; var name: String; var apnsToken: String?; var apnsEnv: String; var notif: [String: String] }
        _ = try? await request("POST", "/api/devices", body: B(id: deviceId, name: UIDevice.current.name, apnsToken: deviceToken, apnsEnv: env, notif: notif), as: OK.self)
        if let t = activityStartToken { await sendActivityStartToken(t) }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "noPush") { return }
        #endif
        _ = liveActivity
    }

    // MARK: helpers

    func agents(in workspaceId: String) -> [Agent] {
        agents.filter { $0.workspaceId == workspaceId && $0.archived != true }.sorted { $0.createdAt < $1.createdAt }
    }

    func workspace(_ id: String) -> Workspace? { workspaces.first { $0.id == id } }
    func agent(_ id: String) -> Agent? { agents.first { $0.id == id } }
    func decision(_ id: String) -> Decision? { decisions.first { $0.id == id } ?? answeredDecisions[id] }

    func open(agentId: String) {
        guard let a = agent(agentId) else { return }
        route = [.workspace(a.workspaceId), .agent(a.id)]
    }
}

enum Route: Hashable {
    case workspace(String)
    case agent(String)
    case desktopWindow(String)
    case desktopChat(String, String)
    case subagent(String, String)
    case settings
    case inbox
}

struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ v: Encodable) { value = v }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
