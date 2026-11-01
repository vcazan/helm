import SwiftUI
import UniformTypeIdentifiers

struct PushView: View {
    @Environment(Hub.self) private var hub
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var key: URL?
    @State private var existingKey: String?
    @State private var teamId = ""
    @State private var bundleId = ""
    @State private var error: String?
    @State private var saved = false
    @State private var testing = false
    @State private var testResult: Bool?
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowHeader(title: "Push notifications", subtitle: "Push uses your own Apple key, because you build the iPhone app with your Apple team.") {
                dismissWindow(id: "push")
            }
            VStack(alignment: .leading, spacing: 14) {
                field("APNs key", hint: "Certificates, IDs & Profiles → Keys → +, with Apple Push Notifications service on.") { keyPicker }
                field("Team ID", hint: "The DEVELOPMENT_TEAM in ios/Config/Local.xcconfig.") {
                    TextField("ABCDE12345", text: $teamId).field()
                }
                field("iPhone app bundle ID", hint: "Your HELM_BUNDLE_PREFIX followed by .helm.") {
                    TextField("com.yourname.helm", text: $bundleId).field()
                }
                if let error {
                    Text(error).font(.inter(12)).foregroundStyle(BUI.red).transition(.fadeUp)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .animation(BUI.enter, value: error)

            HStack {
                if hub.status?.push == true {
                    Button {
                        testing = true
                        testResult = nil
                        Task {
                            testResult = await hub.sendTestPush()
                            testing = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if testing { MiniSpinner(size: 10) }
                            Text(testLabel).contentTransition(.interpolate)
                        }
                    }
                    .buttonStyle(.bui(.quiet))
                    .disabled(testing)
                    .transition(.opacity)
                }
                Spacer()
                Button {
                    save()
                } label: {
                    Label(saved ? "Saved" : "Save", systemImage: saved ? "checkmark" : "tray.and.arrow.down")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.bui(.primary))
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .animation(BUI.enter, value: testLabel)
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 20)
        }
        .frame(width: 440)
        .background(BUI.page)
        .onAppear {
            let s = hub.pushSettings
            teamId = s.teamId
            bundleId = s.bundleId
            existingKey = s.keyName
        }
    }

    private var canSave: Bool {
        (key != nil || existingKey != nil) && teamId.trimmingCharacters(in: .whitespaces).count == 10 && bundleId.contains(".")
    }

    private var testLabel: String {
        if testing { return "Sending…" }
        switch testResult {
        case .some(true): return "Sent. Check your phone"
        case .some(false): return "No phone has push turned on yet"
        case .none: return "Send a test push"
        }
    }

    private func save() {
        do {
            try hub.savePush(key: key, teamId: teamId, bundleId: bundleId)
            error = nil
            withAnimation(BUI.enter) { saved = true }
            existingKey = key?.lastPathComponent ?? existingKey
            key = nil
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                withAnimation(BUI.enter) { saved = false }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var keyPicker: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
            panel.allowsMultipleSelection = false
            panel.message = "Choose the AuthKey_XXXXXXXXXX.p8 file you downloaded from Apple"
            if panel.runModal() == .OK { key = panel.url }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: keyName == nil ? "key" : "key.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(keyName == nil ? BUI.ink3 : BUI.green)
                Text(keyName ?? "Choose or drop the .p8 file")
                    .font(keyName == nil ? .inter(13) : .jbMono(12))
                    .foregroundStyle(keyName == nil ? BUI.ink3 : BUI.ink)
                    .contentTransition(.interpolate)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(dropTargeted ? BUI.accentTint : BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BUI.Radius.control, style: .continuous)
                .strokeBorder(dropTargeted ? BUI.accent : BUI.lineStrong, style: StrokeStyle(lineWidth: 1, dash: keyName == nil ? [4, 3] : [])))
            .contentShape(Rectangle())
            .animation(BUI.enterFast, value: dropTargeted)
            .animation(BUI.enter, value: keyName)
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { $0.pathExtension == "p8" }) else { return false }
            key = u
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var keyName: String? { key?.lastPathComponent ?? existingKey }

    private func field<C: View>(_ label: String, hint: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.inter(12.5, .medium)).foregroundStyle(BUI.ink)
            content()
            Text(hint).font(.inter(11.5)).foregroundStyle(BUI.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
