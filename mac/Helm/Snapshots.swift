#if DEBUG
import AppKit
import SwiftUI

/// `-snapshot <dir>` writes PNGs of the open windows and the menu panel, for docs and visual checks.
enum Snapshots {
    @MainActor static func runIfRequested() {
        guard let dir = UserDefaults.standard.string(forKey: "snapshot"), !dir.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            for w in NSApp.windows where w.isVisible && !w.title.isEmpty {
                if let v = w.contentView { save(v, "\(dir)/\(w.title.replacingOccurrences(of: " ", with: "-")).png") }
            }
            let host = NSHostingView(rootView: MenuPanel().environment(Hub.shared).environment(CursorLink.shared))
            let size = host.fittingSize
            let win = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            win.orderFront(nil)
            try? await Task.sleep(for: .seconds(2.5))
            host.setFrameSize(host.fittingSize)
            win.setContentSize(host.fittingSize)
            try? await Task.sleep(for: .seconds(0.5))
            save(host, "\(dir)/menu.png")
            win.orderOut(nil)
            FileManager.default.createFile(atPath: "\(dir)/done", contents: nil)
        }
    }

    @MainActor private static func save(_ v: NSView, _ path: String) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = v.bounds.size
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
