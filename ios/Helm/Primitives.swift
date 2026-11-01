import SwiftUI

// Agent primitives ported from Beautiful UI (beautifului.dev): ThinkingState, ToolChips,
// ApprovalCard and TaskRows, wired to Helm's transcript items instead of demo data.

// MARK: - Thinking trace

struct ThinkingTrace: View {
    var text: String
    var working: Bool
    var duration: TimeInterval?
    @State private var manual: Bool?
    @AppStorage("showThinking") private var showThinking = false

    private var expanded: Bool { manual ?? (working || showThinking) }
    private var body_: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Button {
            withAnimation(BUI.easeOutStrong) { manual = !expanded }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Sparkle().fill(working ? BUI.accent : BUI.ink3).frame(width: 13, height: 13)
                    ZStack(alignment: .leading) {
                        if working {
                            ShimmerText(text: "Thinking").transition(.opacity)
                        } else {
                            Text(Self.doneLabel(duration)).font(.inter(12.5, .medium)).foregroundStyle(BUI.ink2).transition(.opacity)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(expanded ? "Hide" : "Read").font(.inter(12, .medium)).foregroundStyle(BUI.ink3).contentTransition(.opacity)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(BUI.ink3)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                Text(expanded ? body_ : body_.replacingOccurrences(of: "\n", with: " "))
                    .font(.inter(13.5))
                    .lineSpacing(3)
                    .foregroundStyle(expanded ? BUI.ink2 : BUI.ink3)
                    .lineLimit(expanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(BUI.inset.opacity(expanded ? 1 : 0.6), in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
            .overlay(alignment: .leading) {
                Capsule().fill(working ? BUI.accent.opacity(0.6) : BUI.lineStrong).frame(width: 2.5).padding(.vertical, 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows the agent's reasoning")
        .animation(BUI.easeOutStrong, value: working)
        .animation(BUI.easeOutStrong, value: expanded)
    }

    static func doneLabel(_ d: TimeInterval?) -> String {
        guard let d, d >= 1 else { return "Thought briefly" }
        if d < 60 { return "Thought for \(Int(d.rounded())) second\(Int(d.rounded()) == 1 ? "" : "s")" }
        return "Thought for \(Int(d) / 60)m \(Int(d) % 60)s"
    }
}

/// Header buttons in traces: a quiet pill that shows hover-2 under the finger.
struct TraceHeaderStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(configuration.isPressed ? BUI.hover2 : .clear, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
            .animation(BUI.press, value: configuration.isPressed)
    }
}

// MARK: - Tool chips

/// What a tool call looks like as a ToolChips row.
struct ToolPresentation {
    var icon: String
    var label: String
    var chip: String
    var mono: Bool
    var added: Int?
    var removed: Int?
    var file: String?

    init(_ t: ToolInfo) {
        let n = t.name.lowercased()
        let a = t.args?["args"] ?? t.args?["arguments"] ?? t.args
        func s(_ keys: String...) -> String? {
            for k in keys { if let v = a?[k]?.string ?? t.args?[k]?.string, !v.isEmpty { return v } }
            return nil
        }
        let path = s("path", "file_path", "target_file", "filePath")
        let fileName = path.map { ($0 as NSString).lastPathComponent }
        added = t.meta?.added
        removed = t.meta?.removed
        file = nil
        mono = true

        if let call = MCPCall(t) {
            icon = "puzzlepiece.extension"
            label = call.serverName
            chip = call.summary
            mono = false
            return
        }

        switch true {
        case n == "read" || n.hasPrefix("read"):
            icon = "doc.text"
            label = t.meta?.lines.map { "Read \($0) lines" } ?? "Read"
            chip = fileName ?? "file"
        case n == "edit" || n.contains("replace") || n.contains("str_replace") || n == "multiedit":
            icon = "pencil"
            label = "Edit"
            chip = fileName ?? "file"
            file = path
        case n == "write" || n.hasPrefix("write") || n.contains("create_file"):
            icon = "square.and.pencil"
            label = added.map { "Write \($0) lines" } ?? "Write"
            chip = fileName ?? "file"
            file = path
        case n == "shell" || n.contains("terminal") || n.contains("command") || n == "bash":
            icon = "terminal"
            label = "Run"
            chip = (s("command", "cmd") ?? "command").components(separatedBy: "\n").first ?? ""
        case n == "grep" || n.contains("search_files") || n == "codebase_search":
            icon = "magnifyingglass"
            label = t.meta?.files.map { "Search · \($0) file\($0 == 1 ? "" : "s")" } ?? "Search"
            chip = s("pattern", "query") ?? "…"
        case n == "glob" || n.contains("find"):
            icon = "doc.viewfinder"
            label = "Find files"
            chip = s("glob_pattern", "pattern", "globPattern") ?? "…"
        case n == "ls" || n == "list_dir" || n == "listdir":
            icon = "folder"
            label = "List"
            chip = path.map { ($0 as NSString).lastPathComponent } ?? "folder"
        case n.contains("delete"):
            icon = "trash"
            label = "Delete"
            chip = fileName ?? "file"
        case n.contains("web") && n.contains("search"):
            icon = "globe"
            label = "Search the web"
            chip = s("search_term", "query") ?? "…"
            mono = false
        case n.contains("fetch"):
            icon = "globe"
            label = "Fetch"
            chip = s("url").flatMap { URL(string: $0)?.host } ?? s("url") ?? "page"
        case n.contains("todo"):
            icon = "checklist"
            label = "Plan"
            chip = "Updated the task list"
            mono = false
        case n == "ask_user":
            icon = "hand.raised"
            label = "Asked you"
            chip = s("question") ?? ""
            mono = false
        case n == "message_agent":
            icon = "arrow.turn.up.right"
            label = "Messaged"
            chip = s("agent").map { $0.hasPrefix("chat:") ? "Cursor chat" : $0 } ?? "agent"
            mono = false
        case n == "spawn_agent":
            icon = "person.badge.plus"
            label = "Started agent"
            chip = s("name", "workspace") ?? "new agent"
            mono = false
        case n == "list_agents":
            icon = "person.2"
            label = "Listed agents"
            chip = "All workspaces"
            mono = false
        case n == "notify_user":
            icon = "bell"
            label = "Notified you"
            chip = s("message", "title") ?? ""
            mono = false
        default:
            icon = "puzzlepiece.extension"
            label = t.name.prefix(1).uppercased() + t.name.dropFirst()
            chip = s("command", "path", "query", "url", "description", "name") ?? ""
        }
    }
}

// MARK: - MCP calls

/// An MCP call, as the hub normalizes them: `{server, tool, description?, arguments?}`.
struct MCPCall {
    enum Kind { case call, discover, resource }
    var kind: Kind
    var server: String
    var tool: String
    var description: String?
    var arguments: [(key: String, value: JSONValue)]

    init?(_ t: ToolInfo) {
        switch t.name {
        case "mcp": kind = .call
        case "mcp_discover": kind = .discover
        case "mcp_resource": kind = .resource
        default: return nil
        }
        server = t.args?["server"]?.string ?? ""
        tool = t.args?["tool"]?.string ?? t.args?["uri"]?.string ?? ""
        description = t.args?["description"]?.string?.nilIfEmpty
        if case .object(let o)? = t.args?["arguments"] {
            arguments = o.sorted { Self.rank($0.key) == Self.rank($1.key) ? $0.key < $1.key : Self.rank($0.key) < Self.rank($1.key) }.map { ($0.key, $0.value) }
        } else {
            arguments = []
        }
    }

    /// What the call was for, in one line: the agent's own description, else the tool and its key argument.
    var summary: String {
        switch kind {
        case .discover: return tool.isEmpty ? "Listed its tools" : "Checked the \(title) tool"
        case .resource: return "Read \(tool.isEmpty ? "a resource" : tool)"
        case .call:
            if let description { return description }
            return [title, keyArgument].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var serverName: String { Self.serverName(server) }
    var title: String { Self.toolTitle(tool, server: server) }

    /// The argument that says the most about a call, short enough for a chip.
    var keyArgument: String? {
        arguments.lazy.compactMap { a -> String? in
            guard Self.rank(a.key) < Self.preferred.count, let v = a.value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            if v.hasPrefix("chat:") { return "Cursor chat" }
            return v.components(separatedBy: "\n").first.map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 }
        }.first
    }

    private static let preferred = ["query", "jql", "cql", "q", "search", "pattern", "name", "title", "message", "text", "url", "uri", "path", "id", "key", "issueIdOrKey", "task_id", "taskId", "channel", "channel_id", "fileKey", "nodeId"]
    private static func rank(_ k: String) -> Int { preferred.firstIndex(of: k) ?? preferred.count }

    private static let brands: [String: String] = [
        "clickup": "ClickUp", "posthog": "PostHog", "github": "GitHub", "gitlab": "GitLab", "newrelic": "New Relic", "figma": "Figma",
        "slack": "Slack", "atlassian": "Atlassian", "jira": "Jira", "confluence": "Confluence", "shopify": "Shopify", "linear": "Linear",
        "notion": "Notion", "sentry": "Sentry", "stripe": "Stripe", "supabase": "Supabase", "vercel": "Vercel", "kicad": "KiCad",
        "openscad": "OpenSCAD", "outlook": "Outlook", "gmail": "Gmail", "cursor-origin": "Cursor Origin", "portskill": "Portskill",
        "pencil": "Pencil", "sprites": "Sprites",
        "custom-user-tools": "Helm", "helm": "Helm",
    ]

    /// "user-Atlassian-MCP-Server" → "Atlassian", "plugin-figma-figma" → "Figma".
    static func serverName(_ id: String) -> String {
        var s = id.replacingOccurrences(of: #"^(user|project|plugin)-"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-_]?mcp[-_]?server$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[-_]mcp$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^mcp[-_]"#, with: "", options: [.regularExpression, .caseInsensitive])
        if id.hasPrefix("plugin-"), let last = s.split(separator: "-").last { s = String(last) }
        if let b = brands[s.lowercased()] { return b }
        if s.isEmpty { return "MCP" }
        return s.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { w in
            brands[w.lowercased()] ?? w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }

    private static let acronyms: Set<String> = ["jql", "cql", "sql", "url", "api", "id", "ids", "pr", "prs", "ui", "csv", "json", "html", "pdf", "svg", "dns", "ip", "ssh", "mcp", "llm", "bom", "drc", "erc", "pcb", "3d", "2d"]

    /// "searchJiraIssuesUsingJql" → "Search Jira issues using JQL", "clickup_get_task" → "Get task".
    static func toolTitle(_ tool: String, server: String) -> String {
        var t = tool
        let prefix = server.replacingOccurrences(of: #"^(user|project|plugin)-"#, with: "", options: .regularExpression).split(separator: "-").last.map { $0.lowercased() } ?? ""
        if !prefix.isEmpty, t.lowercased().hasPrefix(prefix + "_") { t = String(t.dropFirst(prefix.count + 1)) }
        let spaced = t.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"[_\-]+"#, with: " ", options: .regularExpression)
        let words = spaced.split(separator: " ").enumerated().map { i, w -> String in
            let l = w.lowercased()
            if acronyms.contains(l) { return l.uppercased() }
            if i > 0, w.first?.isUppercase == true, let b = brands[l] { return b }
            if i == 0 { return l.prefix(1).uppercased() + l.dropFirst() }
            return w.count > 1 && w.allSatisfy(\.isUppercase) ? String(w) : l
        }
        return words.isEmpty ? tool : words.joined(separator: " ")
    }

    /// A steady color per server, so the same service always looks the same in a trace.
    var tint: Color {
        let known: [String: UInt32] = [
            "ClickUp": 0x7B68EE, "PostHog": 0xF54E00, "GitHub": 0x24292F, "New Relic": 0x00AC69, "Figma": 0xA259FF,
            "Slack": 0x611F69, "Atlassian": 0x0C66E4, "Jira": 0x0C66E4, "Confluence": 0x0C66E4, "Shopify": 0x5E8E3E,
            "Linear": 0x5E6AD2, "Notion": 0x2F2F2F, "Sentry": 0x362D59, "Stripe": 0x635BFF, "Supabase": 0x3ECF8E,
            "Vercel": 0x111111, "Outlook": 0x0F6CBD, "Cursor Origin": 0x26251E, "Helm": 0x26251E,
        ]
        let palette: [UInt32] = [0x2F6F8F, 0x8A5A2B, 0x5B6B2F, 0x7A3E6B, 0x3D5A99, 0x8F3B3B, 0x2E7D6B, 0x6B5B95]
        let hex = known[serverName] ?? palette[Int(serverName.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value } % UInt32(palette.count))]
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    var monogram: String {
        let words = serverName.split(separator: " ")
        if words.count > 1, let a = words.first?.first, let b = words.dropFirst().first?.first { return "\(a)\(b)".uppercased() }
        return serverName.prefix(1).uppercased()
    }
}

/// A server's monogram in the tool icon slot.
struct MCPBadge: View {
    var call: MCPCall
    var body: some View {
        Text(call.monogram)
            .font(.system(size: call.monogram.count > 1 ? 7 : 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(call.tint, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// An MCP call opened up: which tool, what it was asked, and what came back.
struct MCPDetail: View {
    var call: MCPCall
    var tool: ToolInfo
    @State private var full = false

    private var output: String? { tool.meta?.output?.nilIfEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(call.kind == .call ? call.title : call.summary).font(.inter(12.5, .medium)).foregroundStyle(BUI.ink)
                Text(call.tool).font(.jbMono(10.5)).foregroundStyle(BUI.ink3).lineLimit(1).truncationMode(.middle)
            }
            if !call.arguments.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(call.arguments.prefix(10), id: \.key) { a in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(a.key).foregroundStyle(BUI.ink3).lineLimit(1).frame(width: 84, alignment: .leading)
                            Text(Self.compact(a.value)).foregroundStyle(BUI.ink2).lineLimit(3).truncationMode(.tail)
                        }
                        .font(.jbMono(11))
                    }
                    if call.arguments.count > 10 {
                        Text("+\(call.arguments.count - 10) more").font(.inter(11)).foregroundStyle(BUI.ink3)
                    }
                }
            }
            result
        }
    }

    @ViewBuilder
    private var result: some View {
        if let err = tool.meta?.error?.nilIfEmpty {
            Text(err).font(.jbMono(11.5)).foregroundStyle(BUI.red).lineLimit(8)
        } else if tool.status == "running" {
            Text("Waiting for \(call.serverName)…").font(.inter(12)).foregroundStyle(BUI.ink3)
        } else if let output {
            let r = Self.format(output)
            VStack(alignment: .leading, spacing: 4) {
                if let lead = r.lead { Text(lead).font(.inter(12.5)).foregroundStyle(BUI.ink).lineSpacing(2) }
                if !r.body.isEmpty {
                    let lines = r.body.components(separatedBy: "\n")
                    let cap = full ? 400 : 14
                    Text(lines.prefix(cap).joined(separator: "\n"))
                        .font(.jbMono(11))
                        .lineSpacing(2)
                        .foregroundStyle(BUI.ink2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(BUI.field, in: RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
                    if lines.count > 14 {
                        Button(full ? "Show less" : "Show all \(min(lines.count, 400)) lines") {
                            withAnimation(BUI.easeOutStrong) { full.toggle() }
                        }
                        .font(.inter(11.5, .medium))
                        .foregroundStyle(BUI.ink2)
                        .buttonStyle(TraceHeaderStyle())
                    }
                }
            }
        } else if call.kind == .call {
            Text("Cursor doesn't keep results for older calls").font(.inter(11.5)).foregroundStyle(BUI.ink3)
        }
    }

    static func compact(_ v: JSONValue) -> String {
        if let s = v.string { return s }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// A readable result: a leading sentence stays prose, JSON gets indented, and a file pointer says so.
    static func format(_ out: String) -> (lead: String?, body: String) {
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: "Output has been written to", options: .caseInsensitive) != nil || text.range(of: "written to:", options: .caseInsensitive) != nil {
            return ("The result was too large to show here; Cursor saved it to a file on your Mac.", "")
        }
        if let json = pretty(text) { return (nil, json) }
        if let nl = text.firstIndex(of: "\n") {
            let first = String(text[..<nl]).trimmingCharacters(in: .whitespaces)
            let rest = String(text[text.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let json = pretty(rest) { return (first, json) }
        }
        if !text.contains("\n"), text.count < 240 { return (text, "") }
        return (nil, text)
    }

    private static func pretty(_ s: String) -> String? {
        guard let f = s.first, f == "{" || f == "[", let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: out, as: UTF8.self).replacingOccurrences(of: "    ", with: "  ").replacingOccurrences(of: "\" : ", with: "\": ")
    }
}

struct DiffLine: Hashable {
    enum Kind { case add, del, ctx, hunk }
    var kind: Kind
    var text: String

    static func parse(_ diff: String, limit: Int = 60) -> [DiffLine] {
        var out: [DiffLine] = []
        for raw in diff.components(separatedBy: "\n") {
            if raw.hasPrefix("+++") || raw.hasPrefix("---") { continue }
            if raw.hasPrefix("@@") { out.append(.init(kind: .hunk, text: raw)); continue }
            if raw.hasPrefix("+") { out.append(.init(kind: .add, text: String(raw.dropFirst()))) }
            else if raw.hasPrefix("-") { out.append(.init(kind: .del, text: String(raw.dropFirst()))) }
            else { out.append(.init(kind: .ctx, text: raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw)) }
            if out.count >= limit { break }
        }
        return out
    }
}

struct DiffLinesView: View {
    var lines: [DiffLine]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                HStack(spacing: 8) {
                    Text(l.kind == .add ? "+" : l.kind == .del ? "−" : " ").frame(width: 10)
                    Text(l.text.isEmpty ? " " : l.text).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(.jbMono(11))
                .foregroundStyle(l.kind == .add ? BUI.green : l.kind == .del ? BUI.red : l.kind == .hunk ? BUI.ink3 : BUI.ink2)
                .padding(.horizontal, 10)
                .frame(minHeight: 19)
                .background(l.kind == .add ? BUI.greenTint : l.kind == .del ? BUI.redTint : .clear)
            }
        }
    }
}

/// A run of tool calls (and the thinking between them) as compact rows, then file-diff chips.
struct ToolChipsRun: View {
    var items: [Item]
    var live: Bool
    @State private var manualOpen: Bool?
    @State private var openRows: Set<String> = []
    @State private var closedRows: Set<String> = []
    @AppStorage("showThinking") private var showThinking = false

    private func isOpen(_ item: Item) -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "openTools"), item.kind == .tool, !closedRows.contains(item.id) { return true }
        #endif
        return openRows.contains(item.id) || (showThinking && item.kind == .thinking && !closedRows.contains(item.id))
    }
    @State private var previewFile: String?

    private var tools: [Item] { items.filter { $0.kind == .tool } }
    private var open: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "openTools") { return manualOpen ?? true }
        #endif
        return manualOpen ?? (live || tools.count <= 4)
    }

    private struct FileDiff: Identifiable {
        var path: String
        var added: Int
        var removed: Int
        var lines: [DiffLine]
        var id: String { path }
    }

    private var diffs: [FileDiff] {
        var order: [String] = []
        var map: [String: FileDiff] = [:]
        for item in tools {
            guard let t = item.tool, t.status != "error" else { continue }
            let p = ToolPresentation(t)
            guard let path = p.file, !DocumentRef.isDocument(path) else { continue }
            var d = map[path] ?? FileDiff(path: path, added: 0, removed: 0, lines: [])
            d.added += t.meta?.added ?? 0
            d.removed += t.meta?.removed ?? 0
            if let diff = t.meta?.diff { d.lines += DiffLine.parse(diff, limit: 40) }
            if map[path] == nil { order.append(path) }
            map[path] = d
        }
        return order.compactMap { map[$0] }
    }

    /// One call per MCP server in the run, so a collapsed run still says which services it touched.
    private var servers: [MCPCall] {
        var seen = Set<String>()
        return tools.compactMap { $0.tool.flatMap(MCPCall.init) }.filter { seen.insert($0.serverName).inserted }
    }

    /// Screenshots and other images the run made or looked at, newest last.
    private var images: [ImageRef] {
        var seen = Set<String>()
        let all = tools.flatMap { $0.tool?.meta?.images ?? [] }.filter { seen.insert($0).inserted }
        return all.suffix(12).map { ImageRef(path: $0) }
    }

    /// Markdown files the run wrote or edited, with what happened to each.
    private var documents: [(path: String, caption: String)] {
        var order: [String] = []
        var wrote: [String: Int] = [:]
        var edits: [String: (Int, Int)] = [:]
        for item in tools {
            guard let t = item.tool, t.status != "error", let path = ToolPresentation(t).file, DocumentRef.isDocument(path) else { continue }
            if !order.contains(path) { order.append(path) }
            if t.name.lowercased().hasPrefix("write") || t.name.lowercased().contains("create_file") {
                wrote[path] = t.meta?.lines ?? t.meta?.added ?? 0
                edits[path] = nil
            } else {
                let e = edits[path] ?? (0, 0)
                edits[path] = (e.0 + (t.meta?.added ?? 0), e.1 + (t.meta?.removed ?? 0))
            }
        }
        return order.map { path in
            let w = wrote[path], e = edits[path]
            var parts: [String] = []
            if let w { parts.append(w > 0 ? "Wrote \(w) line\(w == 1 ? "" : "s")" : "Written") }
            if let e { parts.append(w == nil ? "Edited · +\(e.0) −\(e.1)" : "then edited") }
            return (path, parts.joined(separator: ", "))
        }
    }

    private var header: String {
        let n = tools.count
        let thoughts = items.count - n
        var s = "\(n) tool call\(n == 1 ? "" : "s")"
        if thoughts > 0 { s += ", \(thoughts) thought\(thoughts == 1 ? "" : "s")" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(BUI.easeOutStrong) { manualOpen = !open }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                    if live {
                        ShimmerText(text: header, font: .inter(12.5))
                    } else {
                        Text(header).font(.inter(12.5)).monospacedDigit().contentTransition(.numericText())
                    }
                    if !open, !servers.isEmpty {
                        HStack(spacing: -3) {
                            ForEach(servers.prefix(4), id: \.serverName) { MCPBadge(call: $0).overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(BUI.page, lineWidth: 1.5)) }
                        }
                        .padding(.leading, 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .accessibilityLabel("Used \(servers.map(\.serverName).joined(separator: ", "))")
                    }
                }
                .foregroundStyle(BUI.ink2)
            }
            .buttonStyle(TraceHeaderStyle())

            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { item in
                        row(item).transition(.fadeUp)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }

            if !images.isEmpty {
                ImageStrip(images: images)
                    .padding(.top, 10)
                    .transition(.fadeUp)
            }

            if !live, !documents.isEmpty {
                VStack(spacing: 6) {
                    ForEach(documents, id: \.path) { d in DocumentCard(path: d.path, caption: d.caption) }
                }
                .padding(.top, 10)
                .transition(.fadeUp)
            }

            if !live, !diffs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        let files = Set(diffs.map(\.path)).count + documents.count
                        Text("\(files) file\(files == 1 ? "" : "s") changed").font(.inter(12.5, .medium)).foregroundStyle(BUI.ink2)
                        LineCounts(added: diffs.reduce(0) { $0 + $1.added }, removed: diffs.reduce(0) { $0 + $1.removed })
                    }
                    FlowLayout(spacing: 6) {
                        ForEach(Array(diffs.enumerated()), id: \.element.id) { i, d in
                            diffChip(d, index: i)
                        }
                    }
                    if let f = previewFile, let d = diffs.first(where: { $0.path == f }) {
                        diffPreview(d).transition(.popIn)
                    }
                }
                .padding(.top, 10)
                .overlay(alignment: .top) { Rectangle().fill(BUI.line).frame(height: 1) }
                .padding(.top, 10)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(BUI.easeOutStrong, value: items.count)
        .animation(BUI.easeOutStrong, value: live)
        .animation(BUI.easeOutStrong, value: previewFile)
        .animation(BUI.easeOutStrong, value: documents.map(\.path))
        .animation(BUI.easeOutStrong, value: images)
        // A run that was open while it streamed stays open once the agent moves on; collapsing it would yank the chat.
        .onChange(of: live) { was, now in if was && !now && manualOpen == nil { manualOpen = true } }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        let rowOpen = isOpen(item)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(BUI.easeOutStrong) {
                    if rowOpen { openRows.remove(item.id); closedRows.insert(item.id) } else { openRows.insert(item.id); closedRows.remove(item.id) }
                }
            } label: {
                rowLabel(item, open: rowOpen)
            }
            .buttonStyle(RowPressStyle())

            if rowOpen {
                detail(item)
                    .padding(.leading, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .clipped()
    }

    static func thoughtLabel(_ ms: Double?) -> String {
        guard let ms, ms >= 1000 else { return "Thought" }
        let s = Int((ms / 1000).rounded())
        return s < 60 ? "Thought \(s)s" : "Thought \(s / 60)m \(s % 60)s"
    }

    private func rowLabel(_ item: Item, open: Bool) -> some View {
        let thinking = item.kind == .thinking
        let t = item.tool
        let p = t.map(ToolPresentation.init)
        let running = thinking ? item.streaming == true : t?.status == "running"
        let failed = t?.status == "error"
        let label = thinking ? (running ? "Thinking" : Self.thoughtLabel(item.durationMs)) : (p?.label ?? "")
        let chip = thinking ? firstLine(item.text ?? "") : (p?.chip ?? "")

        return HStack(spacing: 8) {
            ZStack {
                if open {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(BUI.ink3).transition(.opacity)
                } else if running {
                    MiniSpinner().transition(.opacity)
                } else if failed {
                    Image(systemName: "xmark").font(.system(size: 10.5, weight: .bold)).foregroundStyle(BUI.red).transition(.opacity)
                } else if thinking {
                    Sparkle().fill(BUI.ink3).frame(width: 12, height: 12).transition(.opacity)
                } else if let call = t.flatMap(MCPCall.init) {
                    MCPBadge(call: call).transition(.opacity)
                } else {
                    Image(systemName: p?.icon ?? "circle").font(.system(size: 11.5, weight: .medium)).foregroundStyle(BUI.ink3).transition(.opacity)
                }
            }
            .frame(width: 16, height: 16)
            .animation(BUI.easeOutFast, value: open)
            .animation(BUI.easeOutFast, value: running)

            Group {
                if running { ShimmerText(text: label, font: .inter(13, .medium)) }
                else { Text(label).font(.inter(13, .medium)).foregroundStyle(BUI.ink) }
            }
            .fixedSize()

            if !chip.isEmpty {
                HStack(spacing: 6) {
                    Text(chip)
                        .font((thinking || p?.mono == false) ? .inter(11.5) : .jbMono(11.5))
                        .foregroundStyle(failed ? BUI.red : BUI.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let a = p?.added, let r = p?.removed, a + r > 0 {
                        HStack(spacing: 4) {
                            Text("+\(a)").foregroundStyle(BUI.green)
                            if r > 0 { Text("−\(r)").foregroundStyle(BUI.red) }
                        }
                        .font(.jbMono(11))
                        .monospacedDigit()
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(failed ? BUI.redTint : BUI.field, in: RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
                .elevation(.hairline, radius: BUI.Radius.chip)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(height: 30)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func detail(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if item.kind == .thinking {
                Text(item.text ?? "").font(.inter(12.5)).lineSpacing(3).foregroundStyle(BUI.ink2)
            } else if let t = item.tool, let call = MCPCall(t) {
                MCPDetail(call: call, tool: t)
            } else if let t = item.tool {
                if t.status != "error", let path = ToolPresentation(t).file, DocumentRef.isDocument(path) {
                    DocumentCard(path: path, caption: "Open the document").padding(.bottom, 4)
                }
                if let err = t.meta?.error, !err.isEmpty {
                    Text(err).font(.jbMono(11.5)).foregroundStyle(BUI.red)
                }
                if let diff = t.meta?.diff {
                    DiffLinesView(lines: DiffLine.parse(diff, limit: 40))
                        .clipShape(RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
                } else if let out = t.meta?.output {
                    if let cmd = ToolPresentation(t).chip.nilIfEmpty, t.name.lowercased().contains("shell") {
                        Text("$ \(cmd)").font(.jbMono(11.5)).foregroundStyle(BUI.ink)
                    }
                    let lines = out.components(separatedBy: "\n").suffix(30)
                    Text(lines.joined(separator: "\n").nilIfEmpty ?? "(no output)").font(.jbMono(11.5)).lineSpacing(2).foregroundStyle(BUI.ink2)
                    if let code = t.meta?.exitCode, code != 0 {
                        Text("exit \(code)").font(.jbMono(11.5, .medium)).foregroundStyle(BUI.red)
                    }
                } else {
                    if let args = t.args?.compactSummary { Text(args).font(.jbMono(11.5)).foregroundStyle(BUI.ink2).lineLimit(12) }
                    if let r = t.result?.nilIfEmpty, t.meta == nil {
                        Text(r.components(separatedBy: "\n").prefix(16).joined(separator: "\n")).font(.jbMono(11.5)).foregroundStyle(BUI.ink3).lineLimit(16)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 14)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) { Rectangle().fill(BUI.line).frame(width: 1) }
    }

    private func diffChip(_ d: FileDiff, index: Int) -> some View {
        let selected = previewFile == d.path
        return Button {
            withAnimation(BUI.easeOutStrong) { previewFile = selected ? nil : d.path }
        } label: {
            HStack(spacing: 8) {
                Text((d.path as NSString).lastPathComponent).foregroundStyle(BUI.ink).lineLimit(1)
                Text("+\(d.added)").foregroundStyle(BUI.green)
                if d.removed > 0 { Text("−\(d.removed)").foregroundStyle(BUI.red) }
            }
            .font(.jbMono(11.5))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? BUI.hover : BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
            .elevation(.btn, radius: BUI.Radius.chip)
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityLabel("Show diff for \((d.path as NSString).lastPathComponent)")
    }

    private func diffPreview(_ d: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(d.path.abbreviatedPath).foregroundStyle(BUI.ink2).lineLimit(1).truncationMode(.head)
                Spacer()
                Text("+\(d.added)").foregroundStyle(BUI.green)
                if d.removed > 0 { Text("−\(d.removed)").foregroundStyle(BUI.red) }
            }
            .font(.jbMono(11))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .overlay(alignment: .bottom) { Rectangle().fill(BUI.line).frame(height: 1) }
            if d.lines.isEmpty {
                Text("No diff captured").font(.inter(12)).foregroundStyle(BUI.ink3).padding(10)
            } else {
                DiffLinesView(lines: d.lines).padding(.vertical, 4)
            }
        }
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .elevation(.overlay, radius: BUI.Radius.card)
    }

    private func firstLine(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.components(separatedBy: "\n").first.map { $0.count > 80 ? String($0.prefix(80)) + "…" : $0 } ?? ""
    }
}

struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 3)
            .background(configuration.isPressed ? BUI.hover2 : .clear, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            .padding(.horizontal, -3)
            .animation(BUI.press, value: configuration.isPressed)
    }
}

/// Wraps children onto new lines, left-aligned.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Approval card (human-in-the-loop)

struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    var decisionId: String
    var fallbackQuestion: String
    var showAgent = false

    @State private var picked: String?
    @State private var custom = ""
    @State private var sending = false
    @State private var advance: Task<Void, Never>?
    @FocusState private var customFocused: Bool

    static let skipAnswer = "No preference — use your best judgment."

    var body: some View {
        let d = model.decision(decisionId)
        let answered = d == nil || d?.answeredAt != nil
        ZStack(alignment: .topLeading) {
            if answered {
                answeredView(d).transition(.popIn)
            } else if let d {
                pending(d).transition(.fadeUp)
            }
        }
        .animation(BUI.easeOutStrong, value: answered)
        .sensoryFeedback(.success, trigger: answered)
    }

    private func pending(_ d: Decision) -> some View {
        let hasAnswer = picked != nil || !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if showAgent, let a = model.agent(d.agentId) {
                    HStack(spacing: 6) {
                        StatusDot(status: a.status, size: 6)
                        Text(a.name).font(.inter(12, .medium)).foregroundStyle(BUI.ink2)
                    }
                }
                Text(d.question).font(.inter(15, .medium)).tight(15).foregroundStyle(BUI.ink).fixedSize(horizontal: false, vertical: true)
                if let ctx = d.context, !ctx.isEmpty {
                    MarkdownText(text: ctx, size: 13.5, color: BUI.ink2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(d.options, id: \.self) { opt in option(opt) }
                    HStack(spacing: 8) {
                        Image(systemName: "text.cursor").font(.system(size: 11, weight: .medium)).foregroundStyle(BUI.ink3).frame(width: 18)
                        TextField(d.options.isEmpty ? "Your answer" : "Something else…", text: $custom, axis: .vertical)
                            .font(.inter(15))
                            .foregroundStyle(BUI.ink)
                            .lineLimit(1...5)
                            .focused($customFocused)
                            .submitLabel(.send)
                            .onChange(of: custom) { _, v in if !v.isEmpty { advance?.cancel(); picked = nil } }
                            .onSubmit { send() }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 9)
                    .background(customFocused ? BUI.hover : .clear, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
                }
                .padding(.horizontal, -6)
            }
            .padding(14)

            HStack(spacing: 8) {
                Text("Asked \(relativeTime(d.createdAt)) ago".replacingOccurrences(of: "now ago", with: "just now"))
                    .font(.inter(12, .medium))
                    .monospacedDigit()
                    .foregroundStyle(BUI.ink3)
                Spacer()
                Button("Skip") { send(Self.skipAnswer) }
                    .buttonStyle(.bui(.ghost, .sm))
                    .disabled(sending)
                Button {
                    send()
                } label: {
                    HStack(spacing: 6) {
                        if sending { ProgressView().controlSize(.mini).tint(.white) }
                        Text("Send")
                    }
                }
                .buttonStyle(.bui(.accent, .sm))
                .disabled(!hasAnswer || sending)
            }
            .padding(10)
            .padding(.leading, 4)
        }
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .elevation(.card, radius: BUI.Radius.card)
        .animation(BUI.easeOutFast, value: customFocused)
    }

    private func option(_ opt: String) -> some View {
        let on = picked == opt
        return Button {
            custom = ""
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)) { picked = opt }
            advance?.cancel()
            advance = Task {
                try? await Task.sleep(for: .milliseconds(480))
                if !Task.isCancelled { send(opt) }
            }
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(on ? BUI.ink : .clear)
                    Circle().strokeBorder(on ? .clear : BUI.lineStrong, lineWidth: 1.5)
                    Circle().fill(BUI.canvas).frame(width: 6, height: 6).scaleEffect(on ? 1 : 0)
                }
                .frame(width: 18, height: 18)
                Text(opt)
                    .font(.inter(15))
                    .foregroundStyle(on ? BUI.ink : BUI.ink2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(OptionPressStyle(selected: on))
        .disabled(sending)
        .sensoryFeedback(.selection, trigger: on)
    }

    private func answeredView(_ d: Decision?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(d?.question ?? fallbackQuestion).font(.inter(13.5)).foregroundStyle(BUI.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(BUI.green, in: Circle())
                    Text(d?.answer == Self.skipAnswer ? "Left to the agent" : "Answered").font(.inter(12.5, .medium)).foregroundStyle(BUI.green)
                }
                .padding(.leading, 3)
                .padding(.trailing, 10)
                .frame(height: 24)
                .background(BUI.greenTint, in: Capsule())
                if let a = d?.answer, a != Self.skipAnswer {
                    Text(a).font(.inter(13.5, .medium)).foregroundStyle(BUI.ink).lineLimit(3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func send(_ value: String? = nil) {
        let t = (value ?? (custom.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? picked ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        advance?.cancel()
        sending = true
        Task {
            let ok = await model.answer(decisionId, t)
            sending = false
            if ok { custom = "" } else { picked = nil }
        }
    }
}

struct OptionPressStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || selected ? BUI.hover : .clear, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            .animation(BUI.press, value: configuration.isPressed)
    }
}

// MARK: - Task rows (agents)

/// A TaskRows capsule for one agent: status badge, name, time, status pill, and a
/// chevron that drops down the detail lines.
struct AgentTaskRow: View {
    @Environment(AppModel.self) private var model
    var agent: Agent
    var onOpen: () -> Void
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onOpen) {
                    HStack(spacing: 10) {
                        badge.frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(agent.name).font(.inter(15, .medium)).tight(15).foregroundStyle(BUI.ink).lineLimit(1)
                            Text(subtitle).font(.inter(12.5)).foregroundStyle(agent.status == .waiting ? BUI.orange : BUI.ink2).lineLimit(1).contentTransition(.opacity)
                        }
                        Spacer(minLength: 6)
                        pill
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.985))

                Button {
                    withAnimation(BUI.easeOutStrong) { open.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .accessibilityLabel(open ? "Hide details" : "Show details")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(minHeight: 58)

            if open {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle().fill(BUI.line).frame(width: 1).frame(maxHeight: .infinity).frame(width: 24)
                    VStack(alignment: .leading, spacing: 8) {
                        if let t = agent.lastText, !t.isEmpty {
                            Text(t).font(.inter(13)).lineSpacing(2).foregroundStyle(BUI.ink2).lineLimit(4)
                        }
                        detailRow("Runs on") { RuntimeBadge(runtime: agent.runtime) }
                        if agent.runtime.isSprite, let repo = agent.runtime.repo {
                            detailRow("Repo") { Text("\(repo)\(agent.runtime.branch.map { "@\($0)" } ?? "")").font(.jbMono(11.5)).foregroundStyle(BUI.ink3).lineLimit(1) }
                        }
                        detailRow("Model") { Text(modelName).font(.jbMono(11.5)).foregroundStyle(BUI.ink3) }
                        if agent.queue > 0 {
                            detailRow("Queued") { Text("\(agent.queue)").font(.jbMono(11.5)).monospacedDigit().foregroundStyle(BUI.ink3).contentTransition(.numericText()) }
                        }
                        detailRow("Updated") { Text(relativeTime(agent.updatedAt)).font(.jbMono(11.5)).foregroundStyle(BUI.ink3) }
                    }
                    .padding(.trailing, 14)
                }
                .padding(.leading, 12)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: open ? 14 : 29, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: open ? 14 : 29, style: .continuous))
        .elevation(.card, RoundedRectangle(cornerRadius: open ? 14 : 29, style: .continuous))
        .animation(BUI.easeOutStrong, value: agent.status)
        .animation(BUI.easeOutStrong, value: agent.unread)
    }

    @ViewBuilder
    private var badge: some View {
        switch agent.status {
        case .running, .starting:
            SpinnerRing(active: true) { if agent.queue > 0 { Text("\(agent.queue)") } }
        case .waiting:
            ResultBadge(tone: .orange, symbol: "questionmark")
        case .error:
            ResultBadge(tone: .red, symbol: "xmark")
        case .idle:
            if agent.lastText?.isEmpty == false {
                ResultBadge(tone: .green, symbol: "checkmark")
            } else {
                SpinnerRing(active: false) { Text(String(agent.name.prefix(1)).uppercased()) }
            }
        }
    }

    @ViewBuilder
    private var pill: some View {
        switch agent.status {
        case .waiting: StatusPill(tone: .orange, text: "Needs you")
        case .error: StatusPill(tone: .red, text: "Failed")
        case .running, .starting:
            Text(relativeTime(agent.updatedAt)).font(.inter(12.5)).monospacedDigit().foregroundStyle(BUI.ink3)
        case .idle:
            if agent.unread > 0 { StatusPill(tone: .accent, text: "\(agent.unread) new").transition(.popIn) }
            else { Text(relativeTime(agent.updatedAt)).font(.inter(12.5)).monospacedDigit().foregroundStyle(BUI.ink3) }
        }
    }

    private func detailRow<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack {
            Text(label).font(.inter(12)).foregroundStyle(BUI.ink2)
            Spacer()
            value()
        }
    }

    private var modelName: String { model.models.first { $0.id == agent.model }?.label ?? agent.model }

    private var subtitle: String {
        switch agent.status {
        case .waiting: return agent.statusDetail ?? "Waiting for you"
        case .starting: return agent.statusDetail ?? "Starting…"
        case .error: return agent.statusDetail ?? "Something went wrong"
        case .running: return agent.queue > 0 ? "Working · \(agent.queue) queued" : "Working"
        case .idle: return agent.lastText?.isEmpty == false ? agent.lastText!.replacingOccurrences(of: "\n", with: " ") : "Ready for a task"
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension JSONValue {
    /// `key: value` lines for flat argument objects; falls back to pretty JSON.
    var compactSummary: String? {
        guard case .object(let o) = self, !o.isEmpty else { return nil }
        let lines = o.keys.sorted().compactMap { k -> String? in
            guard let v = o[k] else { return nil }
            if let s = v.string { return "\(k): \(s.count > 160 ? String(s.prefix(160)) + "…" : s)" }
            return "\(k): \(v.pretty.replacingOccurrences(of: "\n", with: " "))"
        }
        return lines.joined(separator: "\n")
    }
}

/// Toolbar switch that opens every thought in the chat at once.
struct ThinkingToggle: View {
    @AppStorage("showThinking") private var showThinking = false

    var body: some View {
        Button {
            withAnimation(BUI.easeOutStrong) { showThinking.toggle() }
        } label: {
            Sparkle().fill(showThinking ? BUI.accentInk : BUI.ink2).frame(width: 14, height: 14)
                .rotationEffect(.degrees(showThinking ? 45 : 0))
                .frame(width: 32, height: 32)
                .background(showThinking ? BUI.accentTint : .clear, in: Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.92))
        .sensoryFeedback(.selection, trigger: showThinking)
        .accessibilityLabel(showThinking ? "Collapse all thinking" : "Expand all thinking")
    }
}

/// Floating "jump to latest" button for chat scroll views: shows once you've scrolled up,
/// lights up when something new arrives below, and glides back to the bottom on tap.
struct JumpToLatest: ViewModifier {
    /// The newest item's id. When set, only a change here counts as "new", so older pages loading above don't.
    var latest: String?
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var away = false
    @State private var fresh = false
    @State private var lastHeight: CGFloat = 0
    @State private var debugGeo = ""

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { g in
                g.contentSize.height - (g.visibleRect.maxY - g.contentInsets.bottom)
            } action: { _, distance in
                let isAway = distance > 160
                if isAway != away { withAnimation(BUI.easeOutStrong) { away = isAway } }
                if !isAway, fresh { withAnimation(BUI.easeOutStrong) { fresh = false } }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                if latest == nil, away, new > old + 4, !fresh { withAnimation(BUI.easeOutStrong) { fresh = true } }
            }
            .onChange(of: latest) { old, new in
                if old != nil, new != old, away, !fresh { withAnimation(BUI.easeOutStrong) { fresh = true } }
            }
            #if DEBUG
            .onScrollGeometryChange(for: String.self) { g in
                "c\(Int(g.contentSize.height)) o\(Int(g.contentOffset.y)) h\(Int(g.containerSize.height)) i\(Int(g.contentInsets.top))/\(Int(g.contentInsets.bottom)) v\(Int(g.visibleRect.minY))-\(Int(g.visibleRect.maxY))"
            } action: { _, s in
                debugGeo = s
                if UserDefaults.standard.bool(forKey: "scrollLog") { print("[scroll] \(Date().timeIntervalSince1970) geo \(s) away:\(away)") }
            }
            .overlay(alignment: .top) {
                if UserDefaults.standard.bool(forKey: "geoDebug") {
                    Text(debugGeo + " away:\(away)").font(.jbMono(10)).padding(4).background(.yellow).padding(.top, 4)
                }
            }
            .task {
                if UserDefaults.standard.bool(forKey: "startTop") {
                    try? await Task.sleep(for: .seconds(3))
                    position.scrollTo(edge: .top)
                    if UserDefaults.standard.bool(forKey: "thenBottom") {
                        try? await Task.sleep(for: .seconds(4))
                        position.scrollTo(edge: .bottom)
                    }
                }
            }
            #endif
            .overlay(alignment: .bottom) {
                if away {
                    Button {
                        withAnimation(BUI.easeOutStrong) { position.scrollTo(edge: .bottom) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold))
                                .symbolEffect(.bounce, value: fresh)
                            if fresh {
                                Text("New").font(.inter(13, .semibold)).transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                            }
                        }
                        .foregroundStyle(fresh ? BUI.surface : BUI.ink)
                        .padding(.horizontal, fresh ? 14 : 0)
                        .frame(minWidth: 38, minHeight: 38)
                        .background(fresh ? AnyShapeStyle(BUI.ink) : AnyShapeStyle(BUI.surface), in: Capsule())
                        .elevation(.overlay, Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                    .sensoryFeedback(.impact(weight: .light), trigger: away)
                    .accessibilityLabel(fresh ? "Jump to new messages" : "Scroll to bottom")
                    .padding(.bottom, 10)
                    .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity).combined(with: .offset(y: 12)),
                                            removal: .opacity.combined(with: .scale(scale: 0.8))))
                }
            }
    }
}

extension View {
    func jumpToLatest(latest: String? = nil) -> some View { modifier(JumpToLatest(latest: latest)) }
}

#if DEBUG
/// `-mcpGallery YES`: every state an MCP call row can be in.
struct MCPGallery: View {
    private static func item(_ id: String, _ status: String, _ args: [String: JSONValue], output: String? = nil, error: String? = nil, name: String = "mcp") -> Item {
        var it = Item(id: id, ts: 0, kind: .tool)
        it.tool = ToolInfo(name: name, status: status, args: .object(args), meta: (output ?? error) == nil ? nil : ToolMeta(output: output, error: error))
        return it
    }
    private let docItems: [Item] = {
        var w = Item(id: "w", ts: 0, kind: .tool)
        w.tool = ToolInfo(name: "write", status: "completed", args: .object(["path": .string("/Users/me/Projects/storefront/README.md")]), meta: ToolMeta(added: 64, lines: 64))
        var e = Item(id: "e2", ts: 0, kind: .tool)
        e.tool = ToolInfo(name: "edit", status: "completed", args: .object(["path": .string("/Users/me/Projects/docs-site/PLAN.md")]), meta: ToolMeta(added: 12, removed: 4))
        return [w, e]
    }()
    private let items: [Item] = [
        item("d", "completed", ["server": .string("user-clickup"), "tool": .string("clickup_search")], name: "mcp_discover"),
        item("a", "completed", ["server": .string("user-linear"), "tool": .string("list_issues"), "arguments": .object(["state": .string("overdue"), "limit": .number(20)])],
             output: "1 matching work item; showing 1.\n{\"total\":1,\"items\":[{\"id\":\"17tn9e9mnbj\",\"ref\":\"234\",\"title\":\"Checkout retries\",\"due\":\"2026-10-29\"}]}"),
        item("b", "completed", ["server": .string("user-Atlassian-MCP-Server"), "tool": .string("searchJiraIssuesUsingJql"), "description": .string("Find open checkout bugs in Jira"), "arguments": .object(["jql": .string("project = SHOP AND status = Open"), "cloudId": .string("abc")])]),
        item("c", "error", ["server": .string("user-posthog"), "tool": .string("execute-sql"), "arguments": .object(["query": .string("SELECT count() FROM events")])], error: "Permission denied for project 2"),
        item("e", "running", ["server": .string("plugin-figma-figma"), "tool": .string("get_design_context"), "arguments": .object(["fileKey": .string("Xy12"), "nodeId": .string("1:2")])]),
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ToolChipsRun(items: items, live: false)
                ToolChipsRun(items: Array(items.prefix(4)), live: false)
                ToolChipsRun(items: docItems, live: false)
            }
            .padding(16)
            .padding(.top, 60)
        }
        .background(BUI.page)
    }
}
#endif

// MARK: - Working tree changes

/// "+12 −4" in green and red, with digits that roll when the counts move.
struct LineCounts: View {
    var added: Int
    var removed: Int
    var size: CGFloat = 11.5
    var body: some View {
        HStack(spacing: 4) {
            Text("+\(added)").foregroundStyle(BUI.green).contentTransition(.numericText(value: Double(added)))
            Text("−\(removed)").foregroundStyle(BUI.red).contentTransition(.numericText(value: Double(removed)))
        }
        .font(.jbMono(size, .medium))
        .monospacedDigit()
        .animation(BUI.easeOutStrong, value: added)
        .animation(BUI.easeOutStrong, value: removed)
    }
}

/// Five blocks split green/red by how much of a change is additions, like a pull request's file list.
struct ChangeBlocks: View {
    var added: Int
    var removed: Int
    var body: some View {
        let total = max(1, added + removed)
        let green = added + removed == 0 ? 0 : max(added > 0 ? 1 : 0, Int((Double(added) / Double(total) * 5).rounded()))
        let red = added + removed == 0 ? 0 : min(5 - green, max(removed > 0 ? 1 : 0, 5 - green))
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i < green ? BUI.green : i < green + red ? BUI.red : BUI.lineStrong)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The workspace's uncommitted changes, as a toolbar pill that opens the full list.
struct ChangesButton: View {
    var root: String?
    @Environment(AppModel.self) private var model
    @State private var changes: WorkingChanges?
    @State private var open = false

    var body: some View {
        Group {
            if let c = changes, c.git, !c.files.isEmpty {
                Button { open = true } label: {
                    LineCounts(added: c.added, removed: c.removed, size: 11)
                        .padding(.horizontal, 2)
                }
                .accessibilityLabel("\(c.files.count) changed files, \(c.added) lines added, \(c.removed) removed")
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .animation(BUI.easeOutStrong, value: changes?.files.isEmpty)
        .task(id: root) {
            guard let root else { return }
            while !Task.isCancelled {
                if let c = try? await model.changes(in: root), c != changes { changes = c }
                try? await Task.sleep(for: .seconds(open ? 30 : 6))
            }
        }
        .sheet(isPresented: $open) {
            if let root { ChangesSheet(root: root, initial: changes) }
        }
    }
}

struct ChangesSheet: View {
    var root: String
    var initial: WorkingChanges?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var changes: WorkingChanges?
    @State private var error: String?
    @State private var stack: [ChangedFile] = []

    var body: some View {
        NavigationStack(path: $stack) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let c = changes ?? initial {
                        summary(c)
                        if c.files.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.seal").font(.system(size: 28, weight: .light)).foregroundStyle(BUI.green)
                                    .symbolEffect(.bounce, value: c.files.isEmpty)
                                Text("Nothing uncommitted. Everything's in a commit.").font(.inter(14)).foregroundStyle(BUI.ink2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                            .transition(.fadeUp)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(c.files.enumerated()), id: \.element.id) { i, f in
                                    NavigationLink(value: f) { fileRow(f) }
                                        .buttonStyle(RowPressStyle())
                                    if i < c.files.count - 1 { Rectangle().fill(BUI.line).frame(height: 1).padding(.leading, 40) }
                                }
                            }
                            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
                            .elevation(.card, radius: BUI.Radius.card)
                            if let more = c.more, more > 0 {
                                Text("And \(more) more files").font(.inter(12)).foregroundStyle(BUI.ink3)
                            }
                        }
                    } else if let error {
                        Text(error).font(.inter(14)).foregroundStyle(BUI.ink2).frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(16)
                .animation(BUI.easeOutStrong, value: changes)
            }
            .background(BUI.page)
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ChangedFile.self) { FileDiffPage(root: root, file: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
            }
            .refreshable { await load() }
            .task {
                #if DEBUG
                if let f = UserDefaults.standard.string(forKey: "openChangesFile") { stack = [ChangedFile(path: f, status: "M", added: 0, removed: 0)] }
                #endif
                while !Task.isCancelled {
                    await load()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(BUI.Radius.card + 12)
    }

    private func load() async {
        do {
            let c = try await model.changes(in: root)
            if c != changes { changes = c }
            error = nil
        } catch {
            if changes == nil { self.error = (error as? APIError)?.message ?? error.localizedDescription }
        }
    }

    private func summary(_ c: WorkingChanges) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(c.files.count) file\(c.files.count == 1 ? "" : "s") changed")
                    .font(.inter(20, .semibold)).tracking(-0.3).foregroundStyle(BUI.ink)
                    .contentTransition(.numericText(value: Double(c.files.count)))
                Spacer()
                LineCounts(added: c.added, removed: c.removed, size: 14)
            }
            GeometryReader { g in
                let total = max(1, c.added + c.removed)
                HStack(spacing: 2) {
                    Capsule().fill(BUI.green).frame(width: max(c.added > 0 ? 3 : 0, (g.size.width - 2) * CGFloat(c.added) / CGFloat(total)))
                    Capsule().fill(BUI.red).frame(width: max(c.removed > 0 ? 3 : 0, (g.size.width - 2) * CGFloat(c.removed) / CGFloat(total)))
                }
                .animation(BUI.easeOutStrong, value: c.added)
                .animation(BUI.easeOutStrong, value: c.removed)
            }
            .frame(height: 5)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5, weight: .semibold))
                Text(c.branch ?? "detached")
                Text("·")
                Text((c.root ?? root).abbreviatedPath).lineLimit(1).truncationMode(.head)
            }
            .font(.jbMono(11.5))
            .foregroundStyle(BUI.ink3)
            Text("Since the last commit, including files git isn't tracking yet.").font(.inter(12)).foregroundStyle(BUI.ink3)
        }
    }

    private func fileRow(_ f: ChangedFile) -> some View {
        HStack(spacing: 10) {
            StatusLetter(status: f.status)
            VStack(alignment: .leading, spacing: 1) {
                Text((f.path as NSString).lastPathComponent).font(.inter(14, .medium)).foregroundStyle(BUI.ink).lineLimit(1).truncationMode(.middle)
                let dir = (f.path as NSString).deletingLastPathComponent
                if !dir.isEmpty { Text(dir).font(.jbMono(10.5)).foregroundStyle(BUI.ink3).lineLimit(1).truncationMode(.head) }
            }
            Spacer(minLength: 8)
            if f.binary == true {
                Text("binary").font(.inter(11.5)).foregroundStyle(BUI.ink3)
            } else {
                LineCounts(added: f.added, removed: f.removed, size: 11)
                ChangeBlocks(added: f.added, removed: f.removed)
            }
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(BUI.ink3)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }
}

/// A file's git status as a small colored letter: what happened to it at a glance.
struct StatusLetter: View {
    var status: String
    var body: some View {
        let (letter, tint): (String, Color) = switch status {
        case "A", "U": ("A", BUI.green)
        case "D": ("D", BUI.red)
        case "R": ("R", BUI.accentInk)
        default: ("M", Color(red: 0.78, green: 0.55, blue: 0.12))
        }
        Text(letter)
            .font(.jbMono(10.5, .bold))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(status == "U" ? "New, untracked" : status == "A" ? "Added" : status == "D" ? "Deleted" : status == "R" ? "Renamed" : "Modified")
    }
}

/// One file's diff since the last commit, with old and new line numbers.
private struct FileDiffPage: View {
    var root: String
    var file: ChangedFile
    @Environment(AppModel.self) private var model
    @State private var diff: ChangedFileDiff?
    @State private var error: String?

    private struct Row: Identifiable {
        var id: Int
        var kind: DiffLine.Kind
        var old: Int?
        var new: Int?
        var text: String
    }

    private static func rows(_ diff: String) -> [Row] {
        var out: [Row] = []
        var o = 0, n = 0
        for (i, raw) in diff.components(separatedBy: "\n").enumerated() {
            if raw.hasPrefix("@@") {
                if let m = raw.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/) { o = Int(m.1) ?? 0; n = Int(m.2) ?? 0 }
                out.append(.init(id: i, kind: .hunk, text: raw))
            } else if raw.hasPrefix("+") {
                out.append(.init(id: i, kind: .add, new: n, text: String(raw.dropFirst()))); n += 1
            } else if raw.hasPrefix("-") {
                out.append(.init(id: i, kind: .del, old: o, text: String(raw.dropFirst()))); o += 1
            } else if raw.hasPrefix(" ") {
                out.append(.init(id: i, kind: .ctx, old: o, new: n, text: String(raw.dropFirst()))); o += 1; n += 1
            } else if raw == "…" {
                out.append(.init(id: i, kind: .hunk, text: "… diff too long to show in full"))
            }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusLetter(status: file.status)
                    Text(file.path).font(.jbMono(11.5)).foregroundStyle(BUI.ink2).lineLimit(2).truncationMode(.head)
                    Spacer(minLength: 0)
                    LineCounts(added: diff?.added ?? file.added, removed: diff?.removed ?? file.removed)
                }
                .padding(.horizontal, 16)
                if let diff {
                    if diff.binary == true {
                        Text("Binary file; there's nothing to show line by line.").font(.inter(13)).foregroundStyle(BUI.ink3).padding(.horizontal, 16)
                    } else {
                        let rows = Self.rows(diff.diff)
                        ScrollView(.horizontal) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(rows) { r in line(r) }
                            }
                            .padding(.vertical, 6)
                        }
                        .scrollIndicators(.hidden)
                        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
                        .elevation(.card, radius: BUI.Radius.card)
                        .padding(.horizontal, 12)
                        .transition(.opacity)
                    }
                } else if let error {
                    Text(error).font(.inter(13)).foregroundStyle(BUI.ink2).padding(.horizontal, 16)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .padding(.vertical, 12)
            .animation(BUI.easeOutStrong, value: diff)
        }
        .background(BUI.page)
        .navigationTitle((file.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func line(_ r: Row) -> some View {
        HStack(spacing: 0) {
            Text(r.old.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(BUI.ink3)
            Text(r.new.map(String.init) ?? "").frame(width: 34, alignment: .trailing).foregroundStyle(BUI.ink3)
            Text(r.kind == .add ? "+" : r.kind == .del ? "−" : " ").frame(width: 18)
            Text(r.text.isEmpty ? " " : r.text).fixedSize().padding(.trailing, 14)
        }
        .font(.jbMono(11.5))
        .foregroundStyle(r.kind == .add ? BUI.green : r.kind == .del ? BUI.red : r.kind == .hunk ? BUI.ink3 : BUI.ink2)
        .frame(minHeight: 20, alignment: .leading)
        .frame(minWidth: UIScreen.main.bounds.width - 24, alignment: .leading)
        .background(r.kind == .add ? BUI.greenTint : r.kind == .del ? BUI.redTint : r.kind == .hunk ? BUI.inset : .clear)
    }

    private func load() async {
        do {
            diff = try await model.fileChange(in: root, path: file.path)
            error = nil
        } catch {
            self.error = (error as? APIError)?.message ?? error.localizedDescription
        }
    }
}
