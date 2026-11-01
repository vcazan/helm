import ActivityKit
import Foundation

/// Runs the lock-screen activity: starts it when agents get busy, keeps it current while
/// the app is alive, and hands its push tokens to the hub so updates keep flowing after.
@MainActor
final class LiveActivityController {
    typealias State = HelmActivityAttributes.ContentState

    private weak var model: AppModel?
    private var watching = Set<String>()
    private var lastState: State?

    init(model: AppModel) {
        self.model = model
        Task { await observeStartTokens() }
        let live = Activity<HelmActivityAttributes>.activities
        for a in live { watch(a) }
        if live.isEmpty { Task { await model.sendActivityToken(token: "") } }
    }

    func apply(_ state: State) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, state != lastState else { return }
        lastState = state
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30 * 60))
        let live = Activity<HelmActivityAttributes>.activities
        if state.rows.isEmpty {
            for a in live { await a.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4 * 60))) }
            return
        }
        if let a = live.first {
            for extra in live.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
            await a.update(content)
        } else if let a = try? Activity.request(attributes: HelmActivityAttributes(hub: "Helm"), content: content, pushType: .token) {
            watch(a)
        }
    }

    private func watch(_ a: Activity<HelmActivityAttributes>) {
        guard watching.insert(a.id).inserted else { return }
        Task { [weak self] in
            for await t in a.pushTokenUpdates {
                await self?.model?.sendActivityToken(token: Self.hex(t))
            }
        }
        Task { [weak self] in
            for await s in a.activityStateUpdates where s == .ended || s == .dismissed {
                self?.watching.remove(a.id)
                await self?.model?.sendActivityToken(token: "")
            }
        }
    }

    private func observeStartTokens() async {
        Task { [weak self] in
            for await a in Activity<HelmActivityAttributes>.activityUpdates { self?.watch(a) }
        }
        for await t in Activity<HelmActivityAttributes>.pushToStartTokenUpdates {
            await model?.sendActivityStartToken(Self.hex(t))
        }
    }

    private static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
}
