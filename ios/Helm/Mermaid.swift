import SwiftUI
import WebKit

/// Draws Mermaid diagrams to images with one shared, off-screen web view running the bundled mermaid.js,
/// so a chat full of diagrams costs one web view rather than one each.
@MainActor
final class MermaidRenderer {
    static let shared = MermaidRenderer()

    struct Failure: LocalizedError { var message: String; var errorDescription: String? { message } }

    private var web: WKWebView?
    private var loading: Task<Void, Error>?
    private var chain: Task<Void, Never>?
    private let cache = NSCache<NSString, UIImage>()
    /// The page lays out at exactly this many points so nothing gets scaled; diagrams larger than it are clipped.
    private static let canvas = CGSize(width: 2400, height: 4000)

    func cached(_ code: String, dark: Bool) -> UIImage? { cache.object(forKey: Self.key(code, dark)) }

    private static func key(_ code: String, _ dark: Bool) -> NSString { "\(dark ? "d" : "l")|\(code)" as NSString }

    /// Renders one diagram at a time; mermaid keeps global state, so overlapping renders would trip over each other.
    func render(_ code: String, dark: Bool) async throws -> UIImage {
        if let hit = cached(code, dark: dark) { return hit }
        let previous = chain
        let job = Task { () -> Result<UIImage, Error> in
            await previous?.value
            if let hit = cached(code, dark: dark) { return .success(hit) }
            do { return .success(try await draw(code, dark: dark)) } catch { return .failure(error) }
        }
        chain = Task { _ = await job.value }
        let image = try await job.value.get()
        cache.setObject(image, forKey: Self.key(code, dark))
        return image
    }

    private func page() async throws -> WKWebView {
        if let web, loading == nil { return web }
        if let loading { try await loading.value; return web! }
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        // Entirely below the screen: anywhere overlapping the window, the safe area would shift what the snapshot captures.
        let w = WKWebView(frame: CGRect(x: 0, y: 20_000, width: Self.canvas.width, height: Self.canvas.height), configuration: config)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.isUserInteractionEnabled = false
        // Snapshots need the view in a window.
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.insertSubview(w, at: 0)
        web = w
        let task = Task {
            guard let js = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") else { throw Failure(message: "Diagrams aren't bundled in this build") }
            let html = """
            <!doctype html><html><head><meta name="viewport" content="width=\(Int(Self.canvas.width)),initial-scale=1,user-scalable=no">
            <style>html,body{margin:0;padding:0;background:transparent}#out{display:inline-block;padding:16px}#out svg{display:block}</style>
            <script src="\(js.lastPathComponent)"></script></head><body><div id="out"></div></body></html>
            """
            // The page has to sit beside the script for loadFileURL's read access, so both go in a temp folder.
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("mermaid", isDirectory: true)
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: js, to: dir.appendingPathComponent(js.lastPathComponent))
            let file = dir.appendingPathComponent("host.html")
            try html.write(to: file, atomically: true, encoding: .utf8)
            w.loadFileURL(file, allowingReadAccessTo: dir)
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(50))
                if (try? await w.callAsyncJavaScript("return typeof mermaid", contentWorld: .page)) as? String == "object" { return }
            }
            throw Failure(message: "Couldn't start the diagram renderer")
        }
        loading = task
        do {
            try await task.value
            loading = nil
            return w
        } catch {
            loading = nil
            web?.removeFromSuperview()
            web = nil
            throw error
        }
    }

    private func draw(_ code: String, dark: Bool) async throws -> UIImage {
        let w = try await page()
        let script = """
        mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: dark ? "dark" : "neutral",
          fontFamily: "-apple-system, system-ui, sans-serif", flowchart: { useMaxWidth: false, htmlLabels: true },
          sequence: { useMaxWidth: false }, gantt: { useMaxWidth: false }, themeVariables: { background: bg, edgeLabelBackground: bg },
                themeCSS: `.edgeLabel, .edgeLabel p, .edgeLabel rect, .labelBkg { background-color: ${bg} !important; fill: ${bg} !important; }` });
        const out = document.getElementById("out");
        document.body.style.background = bg;
        out.innerHTML = "";
        try { await mermaid.parse(code); } catch (e) { return { error: String(e && e.message || e).split("\\n").slice(0, 3).join(" ") }; }
        const { svg } = await mermaid.render("d" + Date.now(), code);
        out.innerHTML = svg;
        const el = out.querySelector("svg");
        const vb = el.viewBox && el.viewBox.baseVal;
        el.style.maxWidth = "none";
        if (vb && vb.width > 0) { el.setAttribute("width", vb.width); el.setAttribute("height", vb.height); el.style.width = vb.width + "px"; el.style.height = vb.height + "px"; }
        const r = out.getBoundingClientRect();
        return { w: Math.ceil(r.width), h: Math.ceil(r.height) };
        """
        let result = try await w.callAsyncJavaScript(script, arguments: ["code": code, "dark": dark, "bg": dark ? "#232427" : "#FFFFFF"], contentWorld: .page) as? [String: Any]
        if let error = result?["error"] as? String { throw Failure(message: error) }
        guard let width = result?["w"] as? Double, let height = result?["h"] as? Double, width > 0, height > 0 else {
            throw Failure(message: "The diagram came out empty")
        }
        let size = CGSize(width: min(width, Self.canvas.width), height: min(height, Self.canvas.height))
        try await Task.sleep(for: .milliseconds(30))
        let snap = WKSnapshotConfiguration()
        snap.rect = CGRect(origin: .zero, size: size)
        snap.afterScreenUpdates = true
        let img = try await w.takeSnapshot(configuration: snap)
        return img
    }
}

/// A ```mermaid block: the drawn diagram, with its source a tap away and a full-screen view to zoom around in.
struct MermaidBlock: View {
    var code: String
    /// The block may still be arriving; wait for it to settle before drawing.
    var streaming = false
    @Environment(\.colorScheme) private var scheme
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var showSource = false
    @State private var viewing = false
    @Namespace private var zoom

    private var kind: String {
        let first = code.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let word = first.split(separator: " ").first.map(String.init) ?? ""
        let names = ["graph": "Flowchart", "flowchart": "Flowchart", "sequenceDiagram": "Sequence", "classDiagram": "Classes", "stateDiagram": "States",
                     "stateDiagram-v2": "States", "erDiagram": "Entities", "gantt": "Gantt", "pie": "Pie chart", "journey": "Journey", "gitGraph": "Git graph",
                     "mindmap": "Mind map", "timeline": "Timeline", "quadrantChart": "Quadrant", "xychart-beta": "Chart", "sankey-beta": "Sankey", "block-beta": "Blocks"]
        return names[word] ?? "Diagram"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 11, weight: .semibold)).foregroundStyle(BUI.ink3)
                Text(kind).font(.inter(12.5, .medium)).foregroundStyle(BUI.ink)
                Spacer()
                Button {
                    withAnimation(BUI.easeOutStrong) { showSource.toggle() }
                } label: {
                    Text(showSource ? "Diagram" : "Source").font(.inter(12, .medium)).foregroundStyle(BUI.ink3)
                        .contentTransition(.interpolate)
                        .padding(.horizontal, 6).frame(height: 24)
                }
                .buttonStyle(RowPressStyle())
                .disabled(image == nil && failure == nil)
                .sensoryFeedback(.selection, trigger: showSource)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(BUI.line).frame(height: 1) }

            Group {
                if showSource || failure != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        if let failure, !showSource {
                            Label("Couldn't draw this diagram: \(failure)", systemImage: "exclamationmark.triangle")
                                .font(.inter(12)).foregroundStyle(BUI.ink3)
                        }
                        ScrollView(.horizontal) {
                            Text(code).font(.jbMono(12)).foregroundStyle(BUI.ink2).textSelection(.enabled).fixedSize()
                        }
                        .scrollIndicators(.hidden)
                    }
                    .padding(14)
                    .transition(.opacity)
                } else if let image {
                    Button { viewing = true } label: {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: min(image.size.width, .infinity), maxHeight: 460)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.99))
                    .matchedTransitionSource(id: "diagram", in: zoom)
                    .accessibilityLabel("\(kind) diagram. Opens full screen.")
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    HStack(spacing: 8) {
                        MiniSpinner(size: 11)
                        ShimmerText(text: streaming ? "Writing the diagram" : "Drawing the diagram", font: .inter(12.5))
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .transition(.opacity)
                }
            }
            .animation(BUI.easeOutStrong, value: image != nil)
            .animation(BUI.easeOutStrong, value: failure)
        }
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.card, style: .continuous))
        .elevation(.card, radius: BUI.Radius.card)
        .task(id: "\(scheme == .dark)|\(streaming)|\(code)") {
            let dark = scheme == .dark
            if let hit = MermaidRenderer.shared.cached(code, dark: dark) { image = hit; failure = nil; return }
            guard !streaming else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                let img = try await MermaidRenderer.shared.render(code, dark: dark)
                image = img
                failure = nil
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "mermaidOpen"), code.hasPrefix("flowchart LR") {
                    try? await Task.sleep(for: .milliseconds(600))
                    viewing = true
                }
                #endif
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
        .fullScreenCover(isPresented: $viewing) {
            if let image {
                DiagramViewer(image: image, title: kind).navigationTransition(.zoom(sourceID: "diagram", in: zoom))
            }
        }
    }
}

/// A drawn diagram full screen: pinch and pan around it, share it as an image.
struct DiagramViewer: View {
    var image: UIImage
    var title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            BUI.surface.ignoresSafeArea()
            ZoomableImage(ref: ImageRef(path: "diagram"), preset: image, onLoad: { _ in }, onTap: {})
                .ignoresSafeArea()
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
                Text(title).font(.inter(14, .semibold)).foregroundStyle(BUI.ink)
                Spacer()
                ShareLink(item: Image(uiImage: image), preview: SharePreview(title, image: Image(uiImage: image))) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            .tint(BUI.ink)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
}

#if DEBUG
/// `-mermaidGallery YES`: a few kinds of diagram, and one that doesn't parse.
struct MermaidGallery: View {
    var body: some View {
        ScrollView {
            MarkdownText(text: """
            Here's how a message gets from the phone to Cursor:

            ```mermaid
            flowchart LR
              Phone -->|Tailscale| Hub
              Hub -->|CDP| Cursor[Cursor window]
              Hub -->|SDK| Agent[Helm agent]
              Cursor -.->|reply| Hub
            ```

            ```mermaid
            sequenceDiagram
              participant P as Phone
              participant H as Hub
              participant C as Cursor
              P->>H: send(text)
              H->>C: type and press Enter
              C-->>H: transcript update
              H-->>P: new items
            ```

            ```mermaid
            flowchart TD
              A --> B --> 
            ```
            """)
            .padding(16)
            .padding(.top, 50)
        }
        .background(BUI.page)
    }
}
#endif
