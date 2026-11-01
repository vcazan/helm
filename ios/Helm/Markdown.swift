import SwiftUI

/// Where a chat's relative file paths live: the workspace folder, or the open document's folder.
private struct DocRootKey: EnvironmentKey { static let defaultValue: String? = nil }
/// Opens a linked document; inside the reader it pushes onto its own stack instead of opening a new sheet.
struct DocLinkAction { var open: (DocumentRef) -> Void }
private struct DocLinkKey: EnvironmentKey { static let defaultValue: DocLinkAction? = nil }
private struct DocChatKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    var docRoot: String? {
        get { self[DocRootKey.self] }
        set { self[DocRootKey.self] = newValue }
    }
    var docLink: DocLinkAction? {
        get { self[DocLinkKey.self] }
        set { self[DocLinkKey.self] = newValue }
    }
    /// The chat a document link appears in.
    var docChat: String? {
        get { self[DocChatKey.self] }
        set { self[DocChatKey.self] = newValue }
    }
}

struct MarkdownText: View {
    var text: String
    var streaming = false
    var size: CGFloat = 15.5
    var color: Color = BUI.ink
    /// Markdown files wrap lines in the source; joining them is how Markdown reads them. Chat text keeps its line breaks.
    var softBreaks = false
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.docRoot) private var docRoot
    @Environment(\.docLink) private var docLink
    @Environment(\.docChat) private var docChat

    enum Block: Hashable {
        case paragraph(String)
        case heading(Int, String)
        case bullet(String, ordered: String?, depth: Int, done: Bool?)
        case code(lang: String, body: String)
        case quote(String)
        case table(header: [String], rows: [[String]])
        case rule
        case images([String])
    }

    private static let imageSyntax = /!\[[^\]]*\]\(<?([^)\s>]+)>?(?:\s+"[^"]*")?\)/

    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func parse(_ s: String, softBreaks: Bool = false) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var quote: [String] = []
        let joiner = softBreaks ? " " : "\n"
        var inCode = false
        var codeLang = ""
        var code: [String] = []
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.map { softBreaks ? $0.trimmingCharacters(in: .whitespaces) : $0 }.joined(separator: joiner))); para = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: joiner))); quote = [] }
        }
        let lines = s.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(lang: codeLang, body: code.joined(separator: "\n")))
                    code = []
                    inCode = false
                } else {
                    flush()
                    inCode = true
                    codeLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode { code.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" { flush(); blocks.append(.rule); continue }
            if trimmed.hasPrefix("|"), i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).firstMatch(of: /^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$/) != nil {
                flush()
                let header = cells(trimmed)
                i += 1
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var r = cells(lines[i])
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(Array(r.prefix(header.count)))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            if let m = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush(); blocks.append(.heading(m.1.count, String(m.2))); continue
            }
            let depth = min(3, (line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }) / 2)
            if let m = trimmed.firstMatch(of: /^[-*+•]\s+\[([ xX])\]\s+(.*)$/) {
                flush(); blocks.append(.bullet(String(m.2), ordered: nil, depth: depth, done: m.1 != " ")); continue
            }
            if let m = trimmed.firstMatch(of: /^[-*+•]\s+(.*)$/) {
                flush(); blocks.append(.bullet(String(m.1), ordered: nil, depth: depth, done: nil)); continue
            }
            if let m = trimmed.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                flush(); blocks.append(.bullet(String(m.2), ordered: String(m.1), depth: depth, done: nil)); continue
            }
            if trimmed.hasPrefix(">") {
                if !para.isEmpty { let q = quote; quote = []; flush(); quote = q }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if !quote.isEmpty { flush() }
            let imgs = trimmed.matches(of: imageSyntax).map { String($0.1) }
            if !imgs.isEmpty {
                let rest = trimmed.replacing(imageSyntax, with: "").trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { para.append(rest) }
                flush()
                if case .images(let prev)? = blocks.last { blocks[blocks.count - 1] = .images(prev + imgs) } else { blocks.append(.images(imgs)) }
                continue
            }
            if softBreaks, para.isEmpty, line.first == " " || line.first == "\t", case .bullet(let t, let o, let d, let done)? = blocks.last {
                blocks[blocks.count - 1] = .bullet(t + " " + trimmed, ordered: o, depth: d, done: done)
                continue
            }
            para.append(line)
        }
        if inCode { blocks.append(.code(lang: codeLang, body: code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    var body: some View {
        let blocks = Self.parse(text, softBreaks: softBreaks)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { idx, b in
                switch b {
                case .paragraph(let p):
                    inline(p).font(.inter(size)).tight(size).lineSpacing(size * 0.22).foregroundStyle(color)
                case .heading(let level, let h):
                    inline(h).font(.inter(level == 1 ? size + 5 : level == 2 ? size + 3 : size + 1, .semibold)).tracking(-0.3).foregroundStyle(color).padding(.top, 4)
                case .bullet(let t, let ordered, let depth, let done):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let done {
                            Image(systemName: done ? "checkmark.square.fill" : "square")
                                .font(.system(size: size - 2, weight: .medium))
                                .foregroundStyle(done ? BUI.green : BUI.ink3)
                                .frame(minWidth: 14, alignment: .trailing)
                        } else {
                            Text(ordered.map { "\($0)." } ?? (depth > 0 ? "◦" : "•")).font(.inter(size - 1, .medium)).monospacedDigit().foregroundStyle(BUI.ink3)
                                .frame(minWidth: 14, alignment: .trailing)
                        }
                        inline(t).font(.inter(size)).tight(size).lineSpacing(size * 0.2)
                            .foregroundStyle(done == true ? BUI.ink3 : color)
                            .strikethrough(done == true, color: BUI.ink3)
                    }
                    .padding(.leading, CGFloat(depth) * 18)
                case .code(let lang, let body):
                    if lang.lowercased() == "mermaid" { MermaidBlock(code: body, streaming: streaming && idx == blocks.count - 1) } else { CodeBlock(lang: lang, code: body) }
                case .quote(let q):
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1).fill(BUI.lineStrong).frame(width: 2)
                        inline(q).font(.inter(size - 0.5)).foregroundStyle(BUI.ink2)
                    }
                case .table(let header, let rows): table(header, rows)
                case .rule: Rectangle().fill(BUI.line).frame(height: 1)
                case .images(let srcs): ImageStrip(images: srcs.map(imageRef))
                }
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            if let img = image(url) {
                model?.openImages = ImageGallery(images: [img], index: 0)
                return .handled
            }
            guard let ref = document(url) else { return .systemAction }
            if let docLink { docLink.open(ref) } else { model?.openDocument = ref }
            return .handled
        })
    }

    private func table(_ header: [String], _ rows: [[String]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(header.indices, id: \.self) { c in
                        inline(header[c]).font(.inter(size - 2, .semibold)).foregroundStyle(BUI.ink)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(minWidth: 60, maxWidth: 260, maxHeight: .infinity, alignment: .leading)
                            .background(BUI.inset)
                    }
                }
                ForEach(rows.indices, id: \.self) { r in
                    Divider().overlay(BUI.line)
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            inline(rows[r][c]).font(.inter(size - 2)).foregroundStyle(BUI.ink2)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .frame(minWidth: 60, maxWidth: 260, alignment: .leading)
                        }
                    }
                }
            }
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous).stroke(BUI.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
        }
        .scrollIndicators(.hidden)
    }

    private func imageRef(_ src: String) -> ImageRef {
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return ImageRef(path: src) }
        var p = src.hasPrefix("file://") ? String(src.dropFirst("file://".count)) : src
        p = p.removingPercentEncoding ?? p
        return ImageRef(path: p, root: p.hasPrefix("/") || p.hasPrefix("~") ? nil : docRoot)
    }

    /// A link or `shot.png` code span that points at an image on the Mac.
    private func image(_ url: URL) -> ImageRef? {
        let raw: String
        if url.scheme == "helm-doc" {
            raw = String(url.absoluteString.dropFirst("helm-doc:".count)).removingPercentEncoding ?? ""
        } else if url.scheme == nil || url.scheme == "file" {
            raw = url.scheme == "file" ? url.path : (url.relativeString.removingPercentEncoding ?? url.relativeString)
        } else {
            return nil
        }
        guard !raw.isEmpty, ImageRef.isImage(raw) else { return nil }
        return imageRef(raw)
    }

    /// A link or `path.md` code span that points at a Markdown file on the Mac.
    private func document(_ url: URL) -> DocumentRef? {
        let raw: String
        if url.scheme == "helm-doc" {
            raw = String(url.absoluteString.dropFirst("helm-doc:".count)).removingPercentEncoding ?? ""
        } else if url.scheme == nil || url.scheme == "file" {
            raw = url.scheme == "file" ? url.path : (url.relativeString.removingPercentEncoding ?? url.relativeString)
        } else {
            return nil
        }
        let path = raw.components(separatedBy: "#").first ?? raw
        guard !path.isEmpty, DocumentRef.isDocument(path) else { return nil }
        return DocumentRef(path: path, root: path.hasPrefix("/") || path.hasPrefix("~") ? nil : docRoot, chat: docChat)
    }

    private func inline(_ s: String) -> Text {
        var attr = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attr[run.range].font = .jbMono(size - 2)
            attr[run.range].foregroundColor = BUI.ink2
            attr[run.range].backgroundColor = BUI.inset
            let code = String(attr[run.range].characters)
            if run.link == nil, !code.contains(" "), DocumentRef.isDocument(code) || ImageRef.isImage(code),
               let enc = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "helm-doc:" + enc) {
                attr[run.range].link = url
                attr[run.range].foregroundColor = BUI.accentInk
            }
        }
        for run in attr.runs where run.link != nil {
            attr[run.range].foregroundColor = BUI.accentInk
        }
        return Text(attr)
    }
}

/// Line-numbered listing in a card, with a filename bar and a copy action.
struct CodeBlock: View {
    var lang: String
    var code: String
    @State private var copied = false

    private var lines: [String] {
        var l = code.components(separatedBy: "\n")
        while l.last?.trimmingCharacters(in: .whitespaces).isEmpty == true, l.count > 1 { l.removeLast() }
        return l
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(BUI.ink3)
                Text(lang.isEmpty ? "code" : lang).font(.jbMono(12)).foregroundStyle(BUI.ink)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    withAnimation(BUI.easeOutFast) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(BUI.easeOutFast) { copied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                        Text(copied ? "Copied" : "Copy").contentTransition(.interpolate)
                    }
                    .font(.inter(12, .medium))
                    .foregroundStyle(copied ? BUI.green : BUI.ink3)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                }
                .buttonStyle(RowPressStyle())
                .sensoryFeedback(.success, trigger: copied)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(BUI.line).frame(height: 1) }

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .center, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { i in
                            Text("\(i + 1)").font(.jbMono(10.5)).foregroundStyle(BUI.ink3).frame(height: 20)
                        }
                    }
                    .frame(width: 28)
                    .overlay(alignment: .trailing) { Rectangle().fill(BUI.line).frame(width: 1) }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { i in
                            Text(lines[i].isEmpty ? " " : lines[i]).font(.jbMono(12)).foregroundStyle(BUI.ink2).frame(height: 20, alignment: .leading)
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 14)
                }
                .padding(.vertical, 10)
                .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)
        }
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .elevation(.card, radius: BUI.Radius.card)
    }
}

// MARK: - Documents

/// A Markdown file an agent wrote, read from the Mac and shown formatted. Linked documents push onto the stack.
struct DocumentSheet: View {
    var start: DocumentRef
    @State private var stack: [DocumentRef] = []

    var body: some View {
        NavigationStack(path: $stack) {
            DocumentPage(ref: start, isRoot: true)
                .navigationDestination(for: DocumentRef.self) { DocumentPage(ref: $0, isRoot: false) }
        }
        .environment(\.docLink, DocLinkAction { ref in withAnimation(BUI.easeOutStrong) { stack.append(ref) } })
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(BUI.Radius.card + 12)
    }
}

private struct DocumentPage: View {
    var ref: DocumentRef
    var isRoot: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var file: DocumentFile?
    @State private var error: String?
    @State private var source = false
    @State private var refreshed = 0

    private var title: String {
        guard let file else { return (ref.path as NSString).lastPathComponent }
        let heading = file.text.components(separatedBy: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return heading?.replacingOccurrences(of: "`", with: "").nilIfEmpty ?? file.name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Group {
                    if let file {
                        if source {
                            CodeBlock(lang: "markdown", code: file.text).transition(.opacity)
                        } else {
                            MarkdownText(text: file.text, size: 16, softBreaks: true)
                                .environment(\.docRoot, (file.path as NSString).deletingLastPathComponent)
                                .environment(\.docChat, ref.chat)
                                .transition(.opacity)
                        }
                        if file.truncated {
                            Text("Showing the first 1 MB of this file.").font(.inter(12)).foregroundStyle(BUI.ink3)
                        }
                    } else if let error {
                        failure(error).transition(.fadeUp)
                    } else {
                        MarkdownText(text: Self.placeholder, size: 16)
                            .redacted(reason: .placeholder)
                            .phaseAnimator([1.0, 0.55]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.9) }
                            .transition(.opacity)
                    }
                }
                .animation(BUI.easeOutStrong, value: file?.text)
                .animation(BUI.easeOutStrong, value: source)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BUI.page)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    source.toggle()
                } label: {
                    Image(systemName: source ? "text.alignleft" : "chevron.left.forwardslash.chevron.right")
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(source ? "Show formatted" : "Show Markdown source")
                .disabled(file == nil)
                .sensoryFeedback(.selection, trigger: source)
                if let file {
                    ShareLink(item: file.text, subject: Text(file.name)) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .refreshable { await load() }
        .task(id: ref) {
            await load()
            // Agents often keep writing a document after mentioning it; follow along while it's open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if file != nil { await load(quietly: true) }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: refreshed)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 11, weight: .semibold))
                Text((file?.path ?? ref.path).abbreviatedPath).lineLimit(1).truncationMode(.head)
            }
            .font(.jbMono(11.5))
            .foregroundStyle(BUI.ink2)
            if let file {
                HStack(spacing: 0) {
                    Text("Edited ")
                    Text(Date(timeIntervalSince1970: file.modifiedAt / 1000), format: .relative(presentation: .named))
                    Text(" · \(Int64(file.size).formatted(.byteCount(style: .file)))")
                }
                .font(.inter(12))
                .foregroundStyle(BUI.ink3)
                .contentTransition(.numericText())
                .transition(.opacity)
            }
        }
        .animation(BUI.easeOutStrong, value: file?.modifiedAt)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark").font(.system(size: 30, weight: .light)).foregroundStyle(BUI.ink3)
                .symbolEffect(.bounce, value: refreshed)
            Text(message).font(.inter(14)).foregroundStyle(BUI.ink2).multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .font(.inter(13.5, .medium))
                .buttonStyle(TraceHeaderStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func load(quietly: Bool = false) async {
        do {
            let f = try await model.readDocument(ref)
            if f != file {
                if file != nil, !quietly || f.text != file?.text { refreshed += 1 }
                file = f
            }
            error = nil
        } catch {
            if !quietly || file == nil { self.error = (error as? APIError)?.message ?? error.localizedDescription }
        }
    }

    private static let placeholder = """
    # A document title here

    A first paragraph that runs across a couple of lines, long enough to wrap the way a real one would.

    ## A section

    - One point that matters
    - Another point, a little longer than the first
    - A third

    Another paragraph that closes the section with a sentence or two.
    """
}

/// A document the agent wrote, under its tool run: tap to read it.
struct DocumentCard: View {
    var path: String
    var caption: String
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.docRoot) private var docRoot
    @Environment(\.docChat) private var docChat
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            model?.openDocument = DocumentRef(path: path, root: path.hasPrefix("/") ? nil : docRoot, chat: docChat)
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(BUI.surface)
                        .frame(width: 28, height: 34)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(BUI.lineStrong, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(BUI.ink3).frame(width: 13, height: 2)
                        ForEach(0..<3, id: \.self) { i in Capsule().fill(BUI.lineStrong).frame(width: i == 2 ? 10 : 16, height: 2) }
                    }
                    .frame(width: 28, height: 34)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text((path as NSString).lastPathComponent).font(.inter(14, .semibold)).foregroundStyle(BUI.ink).lineLimit(1).truncationMode(.middle)
                    Text(caption).font(.inter(12)).foregroundStyle(BUI.ink3).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Read").font(.inter(12.5, .medium)).foregroundStyle(BUI.ink2)
                Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .bold)).foregroundStyle(BUI.ink3)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 54)
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
            .elevation(.btn, radius: BUI.Radius.card)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel("Read \((path as NSString).lastPathComponent)")
    }
}
