#if DEBUG
import SwiftUI

/// Debug-only: the real queue drawer and composer under a chat, driven by a script, to review its motion on video.
struct QueueMotionLab: View {
    @State private var queue: [QueuedMessage] = [
        QueuedMessage(id: "a", text: "After that, run the full test suite"),
        QueuedMessage(id: "b", text: "More"),
        QueuedMessage(id: "c", text: "Then open a PR with a short summary"),
    ]
    @State private var chat: [Item] = [
        Item(id: "u0", ts: 0, kind: .user, text: "Can you rerun the migration on staging?"),
        Item(id: "a0", ts: 1, kind: .assistant, text: "Running it now. The schema diff is small: two new columns and an index on `created_at`."),
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(chat) { item in
                    DesktopItemView(item: item).transition(.asymmetric(insertion: .fadeUp, removal: .opacity))
                }
            }
            .padding(16)
            .padding(.top, 60)
        }
        .defaultScrollAnchor(.bottom)
        .background(BUI.page)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                QueuedStack(items: queue) { id in
                    guard let q = queue.first(where: { $0.id == id }) else { return false }
                    withAnimation(BUI.easeOutStrong) {
                        queue.removeAll { $0.id == id }
                        chat.append(Item(id: "s-\(id)", ts: 2, kind: .user, text: q.text))
                    }
                    return true
                } edit: { _, _ in true } remove: { id in
                    withAnimation(BUI.easeOutStrong) { queue.removeAll { $0.id == id } }
                    return true
                } move: { id, to in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let i = queue.firstIndex(where: { $0.id == id }) else { return false }
                    let q = queue.remove(at: i)
                    queue.insert(q, at: min(to, queue.count))
                    return true
                }
                .padding(.horizontal, 12)
                DesktopComposer(placeholder: "Message", busy: true, sending: false, onSend: { _, _ in true }, onStop: {})
            }
        }
        .task { if UserDefaults.standard.string(forKey: "queueLabScript") == "reorder" { await reorderScript() } else { await script() } }
    }

    /// What the chat view does: remove the middle one, send the first, queue a new one, then clear the rest.
    private func script() async {
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        await wait(2)
        tap("b", "remove")
        await wait(2)
        tap("a", "send")
        await wait(2)
        withAnimation(BUI.easeOutStrong) { queue.append(QueuedMessage(id: "out-d", text: "Also bump the version")) }
        await wait(0.6)
        withAnimation(BUI.easeOutStrong) {
            queue.removeAll { $0.id == "out-d" }
            queue.append(QueuedMessage(id: "d", text: "Also bump the version", key: "out-d"))
        }
        await wait(2)
        tap("c", "remove")
        await wait(1.2)
        tap("d", "send")
    }

    /// Holds the first message and drags it below the third, the way a finger would.
    private func reorderScript() async {
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        await wait(2.5)
        NotificationCenter.default.post(name: .queueLabTap, object: nil, userInfo: ["id": "a", "action": "lift"])
        await wait(0.4)
        for step in 1...40 {
            NotificationCenter.default.post(name: .queueLabTap, object: nil, userInfo: ["id": "a", "action": "drag", "dy": CGFloat(step) * 2.2])
            await wait(0.025)
        }
        await wait(3)
        NotificationCenter.default.post(name: .queueLabTap, object: nil, userInfo: ["id": "a", "action": "drop"])
    }

    private func tap(_ id: String, _ action: String, _ extra: [String: Any] = [:]) {
        NotificationCenter.default.post(name: .queueLabTap, object: nil, userInfo: ["id": id, "action": action].merging(extra) { a, _ in a })
    }
}

extension Notification.Name {
    static let queueLabTap = Notification.Name("queueLabTap")
}
#endif
