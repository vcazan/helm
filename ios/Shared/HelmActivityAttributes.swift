import ActivityKit
import AppIntents
import Foundation

/// Lock-screen summary of every agent that's working or waiting on you.
/// The hub pushes `ContentState` as JSON; keep keys in sync with `hub/src/liveactivity.ts`.
struct HelmActivityAttributes: ActivityAttributes {
    struct Row: Codable, Hashable, Identifiable {
        var id: String
        var name: String
        var place: String
        var state: String
        var since: Double
        var detail: String?
        var ask: String?
        var options: [String]?
        var approve: String?
        var reject: String?
        var decision: String?
        var subagents: Int?
        var waitFrom: Double?
        var waitUntil: Double?

        var waiting: Bool { state == "waiting" }
        var start: Date { Date(timeIntervalSince1970: since) }
        /// A timer the agent is sitting out, while it's still running.
        var wait: ClosedRange<Date>? {
            guard let f = waitFrom, let u = waitUntil, u > f, u > Date().timeIntervalSince1970 else { return nil }
            return Date(timeIntervalSince1970: f)...Date(timeIntervalSince1970: u)
        }
        var canAnswer: Bool { ask == "approve" || (ask == "choose" && !(options ?? []).isEmpty) }
    }

    struct ContentState: Codable, Hashable {
        var working: Int
        var waiting: Int
        var rows: [Row]

        var headline: String {
            switch (working, waiting) {
            case (0, 0): return "All quiet"
            case (_, 0): return working == 1 ? "1 agent working" : "\(working) agents working"
            case (0, _): return waiting == 1 ? "1 needs you" : "\(waiting) need you"
            default: return "\(waiting) need\(waiting == 1 ? "s" : "") you · \(working) working"
            }
        }

        var ask: Row? { rows.first { $0.waiting } }
        var busy: [Row] { rows.filter { !$0.waiting } }
    }

    var hub: String
}

extension HelmActivityAttributes.Row {
    /// Opens the matching chat in Helm. Desktop rows are `<windowId>:<chat title>`.
    var url: URL {
        var c = URLComponents()
        c.scheme = "helm"
        if let i = id.firstIndex(of: ":") {
            c.host = "desktop"
            c.queryItems = [.init(name: "window", value: String(id[..<i])), .init(name: "chat", value: String(id[id.index(after: i)...]))]
        } else {
            c.host = "agent"
            c.queryItems = [.init(name: "id", value: id)]
        }
        return c.url ?? URL(string: "helm://")!
    }
}

/// Answers from the lock screen or Dynamic Island. The system runs it inside the Helm app.
struct HelmAnswerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Answer Helm"
    static var isDiscoverable = false

    @Parameter(title: "Row") var row: String
    @Parameter(title: "Decision") var decision: String
    @Parameter(title: "Action") var action: String
    @Parameter(title: "Option") var option: String

    init() {}

    init(row: String, decision: String?, action: String, option: String = "") {
        self.row = row
        self.decision = decision ?? ""
        self.action = action
        self.option = option
    }

    func perform() async throws -> some IntentResult {
        await HelmIntents.handler?(HelmIntents.Answer(row: row, decision: decision.isEmpty ? nil : decision, action: action, option: option))
        return .result()
    }
}

enum HelmIntents {
    struct Answer: Sendable {
        var row: String
        var decision: String?
        /// "approve", "reject" or "choose"
        var action: String
        var option: String
    }

    nonisolated(unsafe) static var handler: (@Sendable (Answer) async -> Void)?
}
