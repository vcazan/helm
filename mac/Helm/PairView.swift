import CoreImage.CIFilterBuiltins
import SwiftUI

/// The pairing QR code. It turns into a confirmation as soon as a phone connects with it.
struct PairCard: View {
    var onPaired: ((String) -> Void)?
    @Environment(Hub.self) private var hub
    @State private var openedAt = Date().timeIntervalSince1970 * 1000
    @State private var pairedName: String?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                if let link = hub.status?.pairing.link, let qr = QRCode.image(link) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 184, height: 184)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .elevation(.raised, radius: 16)
                        .blur(radius: pairedName == nil ? 0 : 6)
                        .opacity(pairedName == nil ? 1 : 0.25)
                        .scaleEffect(pairedName == nil ? 1 : 0.94)
                        .transition(.popIn)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(BUI.inset)
                        .frame(width: 212, height: 212)
                        .overlay(MiniSpinner(size: 16))
                }
                if pairedName != nil {
                    VStack(spacing: 10) {
                        ResultBadge(tone: .green, symbol: "checkmark", size: 44)
                        Text("Connected").font(.inter(15, .semibold)).foregroundStyle(BUI.ink)
                    }
                    .transition(.popIn.animation(.spring(response: 0.42, dampingFraction: 0.7)))
                }
            }
            .animation(BUI.enter, value: pairedName)

            VStack(spacing: 6) {
                Text(pairedName.map { "\($0) is paired" } ?? "Scan with Helm on your iPhone")
                    .font(.inter(15, .semibold))
                    .foregroundStyle(BUI.ink)
                    .contentTransition(.interpolate)
                Text(detail)
                    .font(.inter(12.5))
                    .foregroundStyle(BUI.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
            }
            .animation(BUI.enter, value: pairedName)

            if pairedName == nil, let link = hub.status?.pairing.link {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    withAnimation(BUI.enterFast) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        withAnimation(BUI.enterFast) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy pairing link", systemImage: copied ? "checkmark" : "link")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.bui(.quiet, .sm))
                .transition(.fadeUp)
            }
        }
        .task {
            await hub.refresh()
            while !Task.isCancelled && pairedName == nil {
                await hub.refreshLive()
                if let d = hub.live?.devices.first(where: { $0.lastSeenAt > openedAt }) {
                    pairedName = d.name
                    NSSound(named: "Glass")?.play()
                    onPaired?(d.name)
                    break
                }
                try? await Task.sleep(for: .milliseconds(1200))
            }
        }
    }

    private var detail: String {
        if pairedName != nil { return "You can close this window. Your chats are on your phone now." }
        guard let s = hub.status else { return "Getting the pairing code ready…" }
        if s.tailscale.ip == nil { return "Tailscale isn't connected on this Mac, so only a simulator on this Mac can pair. Connect Tailscale first." }
        return "Open Helm on your iPhone and point its camera here. The phone needs Tailscale on, signed in to the same account."
    }
}

struct PairWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            WindowHeader(title: "Pair an iPhone", subtitle: nil) { dismissWindow(id: "pair") }
            PairCard()
                .padding(.horizontal, 32)
                .padding(.top, 8)
                .padding(.bottom, 32)
        }
        .frame(width: 400)
        .background(BUI.page)
    }
}

/// Window title row below the traffic lights; Esc closes the window too.
struct WindowHeader: View {
    var title: String
    var subtitle: String?
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.inter(17, .semibold)).tracking(-0.2).foregroundStyle(BUI.ink)
            if let subtitle { Text(subtitle).font(.inter(12.5)).foregroundStyle(BUI.ink2).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 40)
        .padding(.bottom, 10)
        .background {
            Button("Close", action: onClose).keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false)
        }
    }
}

enum QRCode {
    private static let context = CIContext()

    static func image(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage, let cg = context.createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
    }
}
