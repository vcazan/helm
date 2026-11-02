import Foundation

enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    var pretty: String {
        guard let data = try? JSONEncoder.pretty.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

struct HubInfo: Codable, Hashable {
    var name: String
    var version: String
    var push: Bool
    var cursorLoggedIn: Bool
    var cursorEmail: String?
    var cursorRunning: Bool
    var defaultModel: String
}

struct Workspace: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var folders: [String]
    var source: String
    var pinned: Bool
    var hidden: Bool
    var createdAt: Double
    var lastActiveAt: Double
    var openOnLaptop: Bool?
}

struct Runtime: Codable, Hashable {
    var kind: String
    var sprite: String?
    var repo: String?
    var branch: String?
    var dir: String?

    var isSprite: Bool { kind == "sprite" }
    static let local = Runtime(kind: "local")
}

enum AgentStatus: String, Codable {
    case idle, starting, running, waiting, error
}

struct Agent: Codable, Identifiable, Hashable {
    var id: String
    var workspaceId: String
    var name: String
    var model: String
    var runtime: Runtime
    var sdkAgentId: String?
    var status: AgentStatus
    var statusDetail: String?
    var lastText: String?
    var unread: Int
    var queue: Int
    var queued: [QueuedMessage]?
    var archived: Bool?
    var createdAt: Double
    var updatedAt: Double

    var isBusy: Bool { status == .running || status == .waiting || status == .starting }
}

struct Decision: Codable, Identifiable, Hashable {
    var id: String
    var agentId: String
    var question: String
    var options: [String]
    var context: String?
    var createdAt: Double
    var answeredAt: Double?
    var answer: String?
}

struct ToolMeta: Codable, Hashable {
    var added: Int?
    var removed: Int?
    var diff: String?
    var lines: Int?
    var exitCode: Int?
    var output: String?
    var files: Int?
    var error: String?
    var subagentId: String?
    var waitSince: Double?
    var waitUntil: Double?
    var waitLabel: String?
    var images: [String]?
    /// The terminal a background shell call left running, and how it's doing.
    var terminal: String?
    var terminalStatus: String?
    var terminalTitle: String?
}

/// A terminal an agent started. `next` is where the following read picks up; `append` says
/// whether `output` continues the last read or replaces it.
struct TerminalOutput: Codable, Hashable {
    var id: String
    var title: String?
    var command: String?
    var cwd: String?
    var status: String
    var exitCode: Int?
    var startedAt: Double?
    var endedAt: Double?
    var elapsedMs: Double?
    var output: String
    var append: Bool
    var truncated: Bool
    var next: Int

    var running: Bool { status == "running" }
    var failed: Bool { !running && (status == "failed" || (exitCode ?? 0) != 0) }
}

struct ToolInfo: Codable, Hashable {
    var name: String
    var status: String
    var args: JSONValue?
    var result: String?
    var callId: String?
    var meta: ToolMeta?
}

/// What's changed in a workspace's git checkout since the last commit.
struct WorkingChanges: Codable, Hashable {
    var git: Bool
    var root: String?
    var branch: String?
    var files: [ChangedFile]
    var more: Int?
    var added: Int
    var removed: Int
}

struct ChangedFile: Codable, Hashable, Identifiable {
    var path: String
    /// M modified, A added, D deleted, R renamed, U untracked.
    var status: String
    var added: Int
    var removed: Int
    var binary: Bool?
    var id: String { path }
}

struct ChangedFileDiff: Codable, Hashable {
    var path: String
    var added: Int
    var removed: Int
    var diff: String
    var binary: Bool?
}

/// A document an agent wrote, read from the Mac.
struct DocumentFile: Codable, Hashable {
    var path: String
    var name: String
    var size: Int
    var modifiedAt: Double
    var text: String
    var truncated: Bool
}

/// Which document to open: a path, and the folder a relative path is in.
struct DocumentRef: Identifiable, Hashable {
    var path: String
    var root: String?
    /// The chat it came from (`composerId` or `agent:<id>`), so the Mac can resolve a loose name like "decisions.md".
    var chat: String? = nil
    var id: String { (root ?? "") + "|" + path }

    static func isDocument(_ path: String) -> Bool {
        guard !path.contains("*"), !path.contains("?") else { return false }
        let ext = (path.components(separatedBy: "#").first.map { ($0 as NSString).pathExtension.lowercased() }) ?? ""
        return ["md", "markdown", "mdx"].contains(ext)
    }
}

/// Someone a chat can talk to through Helm: a Helm agent, or a Cursor chat (`chat:<composerId>`).
struct TalkTarget: Hashable, Identifiable {
    var id: String
    var name: String
    var isChat: Bool
    var workspace: String?

    /// What a Cursor chat is asked to do; it reaches the other side with Helm's `message_agent` tool.
    func prompt(_ instruction: String) -> String {
        let who = isChat ? "the Cursor chat \"\(name)\"" : "the Helm agent \"\(name)\""
        let ws = workspace.map { ", workspace \"\($0)\"" } ?? ""
        return "Use Helm's message_agent tool to talk to \(who) (id \(id)\(ws)). \(instruction)"
    }
}

struct FromInfo: Codable, Hashable {
    var agentId: String
    var name: String
    var workspace: String
}

enum ItemKind: String, Codable {
    case user, assistant, thinking, tool, agent_message, decision, system, error
}

struct Item: Codable, Identifiable, Hashable {
    var id: String
    var ts: Double
    var kind: ItemKind
    var text: String?
    var tool: ToolInfo?
    var from: FromInfo?
    var decisionId: String?
    var streaming: Bool?
    var runId: String?
    var durationMs: Double?
}

struct DirListing: Codable {
    struct Entry: Codable, Identifiable, Hashable {
        var name: String
        var path: String
        var git: Bool
        var hasChildren: Bool
        var id: String { path }
    }
    var path: String
    var parent: String?
    var entries: [Entry]
}

struct ModelInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String?
    var description: String?
    var label: String { name ?? id }
}

struct SpriteInfo: Codable, Identifiable, Hashable {
    var name: String
    var status: String?
    var url: String?
    var id: String { name }
}

struct SpritesResponse: Codable {
    var loggedIn: Bool
    var error: String?
    var sprites: [SpriteInfo]
}

struct RepoInfo: Codable {
    var repo: String?
    var branch: String?
}

struct OutgoingImage: Codable, Hashable {
    var data: String
    var mimeType: String
}

extension String {
    var abbreviatedPath: String {
        if let r = range(of: "/Users/"), r.lowerBound == startIndex {
            let rest = self[r.upperBound...]
            if let slash = rest.firstIndex(of: "/") { return "~" + rest[slash...] }
            return "~"
        }
        return self
    }
}

// MARK: Cursor desktop (driven over CDP by the hub)

struct DesktopState: Codable, Hashable {
    var available: Bool
    var windows: [DesktopWindow]
}

struct DesktopWindow: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var workspace: String
    var chats: [DesktopChat]
    var archived: [DesktopArchivedChat]?
    /// The hub can reach Cursor's chat controls here: rename, archive and delete work.
    var manageable: Bool?
    var activeComposerId: String?
    var working: Bool
    var pending: DesktopPending?
    var question: DesktopQuestion?

    var needsYou: Bool { pending != nil || question != nil || chats.contains { $0.status == .attention } }
    var busy: Bool { working || chats.contains { $0.status == .working } }
}

enum DesktopChatStatus: String, Codable, Hashable {
    case working, attention, done, idle
    init(from decoder: Decoder) throws {
        self = DesktopChatStatus(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .idle
    }
}

struct DesktopChat: Codable, Identifiable, Hashable {
    var title: String
    var age: String
    var status: DesktopChatStatus
    var selected: Bool
    var composerId: String?
    var updatedAt: Double?
    var id: String { title }
    /// Stable across renames, for the phone's own chat order.
    var orderKey: String { composerId ?? title }
}

struct DesktopArchivedChat: Codable, Identifiable, Hashable {
    var title: String
    var composerId: String
    var age: String
    var id: String { composerId }
}

struct DesktopPending: Codable, Hashable {
    var chat: String
    var label: String
    var approve: String
    var reject: String?
}

struct DesktopQuestion: Codable, Hashable {
    struct Q: Codable, Hashable, Identifiable {
        var index: Int
        var prompt: String
        var options: [String]
        var freeform: Bool
        var active: Bool
        var id: Int { index }
    }
    var chat: String
    var questions: [Q]
}

struct DesktopLiveRow: Codable, Hashable {
    var role: String
    var kind: String
    var text: String
}

struct DesktopTranscript: Codable {
    var composerId: String
    var items: [Item]
    var updatedAt: Double?
    var live: [DesktopLiveRow]?
    /// The hub is serving the in-flight turn from Cursor's own records, so it's already in `items`.
    var liveTurn: Bool?
    var queued: [QueuedMessage]?
    var subagents: [Subagent]?
    /// Items in the whole chat; `items` is only the newest page of them.
    var total: Int?
}

/// A helper agent a desktop chat spawned to work on part of the task.
struct Subagent: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var type: String?
    var status: Status
    var activity: String?
    var startedAt: Double?
    var updatedAt: Double?
    var brief: String?
    var steps: Int?
    var result: String?
    var items: [Item]?

    enum Status: String, Codable {
        case running, done, stopped, failed
    }

    var dot: AgentStatus {
        switch status {
        case .running: return .running
        case .failed: return .error
        case .done, .stopped: return .idle
        }
    }

    var label: String {
        switch status {
        case .running: return "Working"
        case .done: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }
}

/// A message sent while the agent was busy, waiting its turn.
struct QueuedMessage: Codable, Hashable, Identifiable {
    var id: String
    var text: String
    /// The phone's temporary id while it was still on its way to Cursor; keeps the row stable on screen.
    var key: String? = nil
    var rowKey: String { key ?? id }
}

// MARK: Folders and GitHub

struct GitHubRepo: Codable, Identifiable, Hashable {
    var name: String
    var description: String?
    var `private`: Bool
    var pushedAt: String?
    var id: String { name }
    var owner: String { String(name.split(separator: "/").first ?? "") }
    var shortName: String { String(name.split(separator: "/").last ?? Substring(name)) }
}

struct CloneJob: Codable, Identifiable, Hashable {
    enum State: String, Codable { case running, done, error }
    var id: String
    var repo: String
    var path: String
    var state: State
    var phase: String
    var percent: Double?
    var error: String?
}

struct MadeDir: Codable { var path: String; var name: String }
