import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct HelmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var hub = Hub.shared
    @State private var cursor = CursorLink.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(hub)
                .environment(cursor)
        } label: {
            MenuBarIcon(attention: needsAttention)
        }
        .menuBarExtraStyle(.window)

        Window("Set up Helm", id: "setup") {
            SetupView()
                .environment(hub)
                .environment(cursor)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Pair an iPhone", id: "pair") {
            PairWindow()
                .environment(hub)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Push notifications", id: "push") {
            PushView()
                .environment(hub)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private var needsAttention: Bool {
        switch hub.state {
        case .crashed, .conflict, .missingRuntime: return true
        default: break
        }
        return cursor.state == .needsRestart || cursor.state == .quitBlocked || hub.status?.cursorLoggedIn == false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()
        UNUserNotificationCenter.current().delegate = self
        CursorLink.registerNotifications()
        #if !DEBUG
        // The hub should outlive a reboot from the start; setup lets you turn this off.
        if !UserDefaults.standard.bool(forKey: "loginItemChosen") {
            LoginItem.set(true)
            UserDefaults.standard.set(true, forKey: "loginItemChosen")
        }
        #endif
        Task { @MainActor in
            await Hub.shared.start()
            await CursorLink.shared.refresh()
        }
        #if DEBUG
        Snapshots.runIfRequested()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Hub.shared.stopForQuit() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.actionIdentifier == CursorLink.reconnectAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await CursorLink.shared.restart()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// The menu bar mark: a template image so it follows the menu bar's color, with a dot when something needs you.
struct MenuBarIcon: View {
    var attention: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: Self.image(attention: attention))
            .task {
                if !UserDefaults.standard.bool(forKey: "onboarded") || UserDefaults.standard.integer(forKey: "setupStep") > 0 {
                    try? await Task.sleep(for: .milliseconds(400))
                    showWindow("setup", openWindow)
                }
                #if DEBUG
                if let id = UserDefaults.standard.string(forKey: "openWindow"), !id.isEmpty { showWindow(id, openWindow) }
                #endif
            }
    }

    static func image(attention: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            for (path, style) in HelmMarkPaths.make(in: rect.insetBy(dx: 0.5, dy: 0.5)) {
                ctx.addPath(path.cgPath)
                switch style {
                case .stroke(let w): ctx.setLineWidth(w); ctx.strokePath()
                case .fill: ctx.fillPath()
                }
            }
            if attention {
                let dot = CGRect(x: rect.maxX - 7, y: 0, width: 7, height: 7)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: dot)
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Opens one of the app's windows in front; the app has no Dock icon, so it has to activate itself.
@MainActor
func showWindow(_ id: String, _ openWindow: OpenWindowAction) {
    openWindow(id: id)
    NSApp.activate()
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }
}
