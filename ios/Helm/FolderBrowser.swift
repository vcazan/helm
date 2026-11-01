import SwiftUI

struct NewWorkspaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folders: [String] = []
    @State private var openOnLaptop = true
    @State private var browsing = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "New workspace", subtitle: "A set of folders on your Mac") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Name")
                        TextField(folders.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "My project", text: $name).field()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Folders")
                        VStack(spacing: 0) {
                            ForEach(folders, id: \.self) { f in
                                HStack {
                                    Image(systemName: "folder.fill").foregroundStyle(Theme.text3)
                                    Text(f.abbreviatedPath).font(.mono).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.head)
                                    Spacer()
                                    Button { folders.removeAll { $0 == f } } label: {
                                        Image(systemName: "minus.circle.fill").foregroundStyle(Theme.text3)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .transition(.move(edge: .top).combined(with: .opacity))
                                Divider().overlay(Theme.stroke)
                            }
                            Button { browsing = true } label: {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text(folders.isEmpty ? "Choose folders from your Mac" : "Add another folder")
                                    Spacer()
                                }
                                .font(.inter(15, .medium))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 14).padding(.vertical, 13)
                            }
                        }
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
                        .animation(Theme.ease, value: folders)
                    }
                    Toggle(isOn: $openOnLaptop) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open in Cursor on the Mac").font(.inter(15, .medium)).foregroundStyle(Theme.text)
                            Text("Opens a new Cursor window with these folders").font(.inter(12.5)).foregroundStyle(Theme.text2)
                        }
                    }
                    .tint(Theme.done)
                    .card()
                    if let error { Text(error).font(.inter(13)).foregroundStyle(Theme.error) }
                }
                .padding(20)
            }
            Button {
                busy = true
                Task {
                    do {
                        let w = try await model.createWorkspace(name: name, folders: folders, openOnLaptop: openOnLaptop)
                        dismiss()
                        try? await Task.sleep(for: .milliseconds(350))
                        model.route = [.workspace(w.id)]
                    } catch {
                        self.error = error.localizedDescription
                    }
                    busy = false
                }
            } label: {
                if busy { ProgressView().tint(Theme.bg) } else { Text("Create workspace") }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !folders.isEmpty))
            .disabled(folders.isEmpty || busy)
            .padding(20)
        }
        .sheet(isPresented: $browsing) {
            FolderBrowser(title: "Choose folders", initialSelection: folders) { picked in
                folders = picked
                browsing = false
            }
            .presentationDetents([.fraction(0.88)])
            .presentationCornerRadius(28)
            .presentationBackground(Theme.bg)
        }
    }
}
