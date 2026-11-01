import SwiftUI
import AVFoundation

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var scanning = false
    @State private var pasting = false
    @State private var pasted = ""
    @State private var busy = false
    @State private var error: String?
    @State private var spin = false
    @State private var celebrate = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .strokeBorder(Theme.accent.opacity(0.06 - Double(i) * 0.015), lineWidth: 1)
                        .frame(width: 150 + CGFloat(i) * 70, height: 150 + CGFloat(i) * 70)
                }
                HelmMark(size: 76)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 40).repeatForever(autoreverses: false), value: spin)
            }
            .frame(height: 300)
            .overlay { ConfettiBurst(trigger: celebrate) }

            VStack(spacing: 10) {
                Text("Helm")
                    .font(.inter(40, .semibold))
                    .foregroundStyle(Theme.text)
                Text("Your Cursor agents, from anywhere.\nScan the code your Mac shows to pair.")
                    .font(.inter(16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 32)

            Spacer()

            if let error {
                Text(error)
                    .font(.inter(14))
                    .foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            VStack(spacing: 12) {
                Button {
                    error = nil
                    scanning = true
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(Theme.bg) } else { Image(systemName: "qrcode.viewfinder") }
                        Text(busy ? "Connecting…" : "Scan pairing code")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy)

                Button("Paste link instead") { pasting = true }
                    .font(.inter(15, .medium))
                    .foregroundStyle(Theme.text2)
                    .padding(.vertical, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Text("On the Mac: cd hub && npm run pair")
                .font(.monoSmall)
                .foregroundStyle(Theme.text3)
                .padding(.bottom, 20)
        }
        .animation(Theme.ease, value: error)
        .onAppear { spin = true }
        .sheet(isPresented: $scanning) {
            ScannerSheet { code in
                scanning = false
                handle(code)
            }
            .presentationDetents([.fraction(0.72)])
            .presentationCornerRadius(28)
            .presentationBackground(Theme.bg)
        }
        .sheet(isPresented: $pasting) {
            VStack(alignment: .leading, spacing: 16) {
                SheetHeader(title: "Paste pairing link", subtitle: "It starts with helm://pair", onClose: { pasting = false })
                TextField("helm://pair?url=…", text: $pasted, axis: .vertical)
                    .font(.mono)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(3...5)
                    .field()
                    .padding(.horizontal, 20)
                HStack(spacing: 12) {
                    Button("Paste") { pasted = UIPasteboard.general.string ?? "" }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Connect") {
                        pasting = false
                        handle(pasted)
                    }
                    .buttonStyle(PrimaryButtonStyle(enabled: Pairing.parse(pasted) != nil))
                    .disabled(Pairing.parse(pasted) == nil)
                }
                .padding(.horizontal, 20)
                Spacer()
            }
            .presentationDetents([.height(330)])
            .presentationCornerRadius(28)
            .presentationBackground(Theme.bg)
        }
    }

    private func handle(_ code: String) {
        guard let p = Pairing.parse(code) else {
            error = "That isn't a Helm pairing code."
            return
        }
        busy = true
        Task {
            do {
                let verified = try await model.verify(p)
                celebrate += 1
                try? await Task.sleep(for: .seconds(1.1))
                model.commit(verified)
                AppDelegate.requestPush()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct ScannerSheet: View {
    var onCode: (String) -> Void
    @State private var authorized: Bool?
    @State private var sweep = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Point at the code in your Mac's terminal")
                .font(.inter(15, .medium))
                .foregroundStyle(Theme.text2)
                .padding(.top, 26)
            ZStack {
                if authorized == true {
                    QRScanner(onCode: onCode)
                } else if authorized == false {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.fill").font(.system(size: 28)).foregroundStyle(Theme.text3)
                        Text("Camera access is off. Enable it in Settings, or paste the link instead.")
                            .font(.inter(14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                }
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1.5)
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Theme.accent.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 2)
                    .offset(y: sweep ? 140 : -140)
                    .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: sweep)
            }
            .frame(width: 300, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
            default: authorized = false
            }
            sweep = true
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.onCode = onCode
        return c
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            DispatchQueue.global().async { [session] in session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let s = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, s.hasPrefix("helm://") else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(s)
        }
    }
}

struct ConfettiBurst: View {
    var trigger: Int
    @State private var particles: [Particle] = []

    struct Particle: Identifiable {
        let id = UUID()
        var angle: Double
        var distance: CGFloat
        var size: CGFloat
        var color: Color
        var spin: Double
    }

    var body: some View {
        ZStack {
            ForEach(particles) { p in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(p.color)
                    .frame(width: p.size, height: p.size * 2.2)
                    .modifier(BurstModifier(p: p))
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            let colors = [Theme.accent, Theme.running, Theme.waiting, Theme.done, Theme.sprite]
            particles = (0..<46).map { _ in
                Particle(angle: .random(in: 0..<(2 * .pi)), distance: .random(in: 90...220), size: .random(in: 4...7), color: colors.randomElement()!, spin: .random(in: -540...540))
            }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                particles = []
            }
        }
        .sensoryFeedback(.success, trigger: trigger)
    }

    struct BurstModifier: ViewModifier {
        var p: Particle
        @State private var go = false
        func body(content: Content) -> some View {
            content
                .rotationEffect(.degrees(go ? p.spin : 0))
                .offset(x: go ? cos(p.angle) * p.distance : 0, y: go ? sin(p.angle) * p.distance + 60 : 0)
                .opacity(go ? 0 : 1)
                .onAppear {
                    withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 1.4)) { go = true }
                }
        }
    }
}
