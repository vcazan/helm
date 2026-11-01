import AppKit
import Observation
import UserNotifications

/// Whether Cursor is running with the debugging port Helm drives it through, and the fix when it isn't.
@MainActor @Observable
final class CursorLink {
    static let shared = CursorLink()
    nonisolated static let bundleID = "com.todesktop.230313mzl4w4u92"
    nonisolated static let cdpPort = 9222

    enum State: Equatable { case notInstalled, notRunning, needsRestart, connected, restarting, quitBlocked }

    private(set) var state: State = .notRunning
    private var observers: [NSObjectProtocol] = []

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) }
    private var running: [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID) }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == CursorLink.bundleID else { return }
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                Task { @MainActor in await CursorLink.shared.cursorChanged(launched: launched) }
            })
        }
    }

    func refresh() async {
        guard state != .restarting else { return }
        let next: State
        if appURL == nil { next = .notInstalled }
        else if await cdpUp() { next = .connected }
        else if running.isEmpty { next = .notRunning }
        else { next = state == .quitBlocked ? .quitBlocked : .needsRestart }
        if next != state { state = next }
    }

    private func cursorChanged(launched: Bool) async {
        guard state != .restarting else { return }
        if launched {
            // Cursor opens its debugging port a moment after launch.
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(500))
                if await cdpUp() { break }
            }
            await refresh()
            if state == .needsRestart { notifyOpenedWithoutHelm() }
        } else {
            await refresh()
        }
    }

    /// Opens Cursor with the debugging port on, or brings it forward when it already has it.
    func open() async {
        guard let url = appURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["--remote-debugging-port=\(Self.cdpPort)"]
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<40 {
            if await cdpUp() { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        state = .notRunning
        await refresh()
    }

    /// Quits Cursor like ⌘Q (it still asks about unsaved work) and reopens it so Helm can see its chats.
    func restart() async {
        state = .restarting
        running.forEach { $0.terminate() }
        for _ in 0..<60 where !running.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if !running.isEmpty {
            state = .quitBlocked
            return
        }
        try? await Task.sleep(for: .milliseconds(600))
        await open()
    }

    private func cdpUp() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(Self.cdpPort)/json/version") else { return false }
        guard let (_, res) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 1)) else { return false }
        return (res as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: Notifications

    nonisolated static let reconnectAction = "RECONNECT"
    nonisolated static let category = "CURSOR_WITHOUT_HELM"

    static func registerNotifications() {
        let center = UNUserNotificationCenter.current()
        let reconnect = UNNotificationAction(identifier: reconnectAction, title: "Reopen with Helm")
        center.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [reconnect], intentIdentifiers: [])])
    }

    private func notifyOpenedWithoutHelm() {
        guard UserDefaults.standard.bool(forKey: "onboarded") else { return }
        let content = UNMutableNotificationContent()
        content.title = "Cursor opened without Helm"
        content.body = "Your phone can't see these chats. Reopen Cursor with Helm to connect it."
        content.categoryIdentifier = Self.category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "cursor-without-helm", content: content, trigger: nil))
    }
}
