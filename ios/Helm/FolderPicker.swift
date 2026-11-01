import SwiftUI

/// Browse folders on the Mac, search them, make new ones, or clone a GitHub repo into place.
struct FolderBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var title: String
    var initialSelection: [String]
    var onDone: ([String]) -> Void

    @State private var listing: DirListing?
    @State private var selection: [String] = []
    @State private var error: String?
    @State private var direction: Edge = .trailing

    @State private var query = ""
    @State private var results: [DirListing.Entry]?
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    @State private var naming = false
    @State private var newName = ""
    @State private var nameError: String?
    @FocusState private var nameFocused: Bool
    @State private var justMade: String?

    @State private var cloning = false
    @State private var cloneIds: [String] = []

    private let shortcuts: [(String, String, String)] = [("Projects", "~/Projects", "hammer"), ("Home", "~", "house"), ("Desktop", "~/Desktop", "menubar.dock.rectangle"), ("Documents", "~/Documents", "doc")]
    private var isSearching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }
    private var jobs: [CloneJob] { cloneIds.compactMap { model.clones[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: title, subtitle: "Folders on \(model.hub?.name ?? "your Mac")") { dismiss() }

            searchField
                .padding(.horizontal, 20)
                .padding(.bottom, 10)

            if !isSearching {
                shortcutsRow.transition(.opacity.combined(with: .move(edge: .top)))
                if let listing { pathBar(listing).transition(.opacity) }
            }

            ZStack {
                if isSearching {
                    searchResults
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)), removal: .opacity))
                } else if let listing {
                    folderList(listing)
                        .id(listing.path)
                        .transition(.asymmetric(insertion: .move(edge: direction).combined(with: .opacity), removal: .move(edge: direction == .trailing ? .leading : .trailing).combined(with: .opacity)))
                } else if let error {
                    Text(error).font(.inter(14)).foregroundStyle(BUI.red).padding()
                } else {
                    LoadingState(label: "Reading folders", pattern: .orbit).frame(maxHeight: .infinity)
                }
            }
            .animation(BUI.easeOutStrong, value: listing?.path)
            .animation(BUI.easeOutStrong, value: isSearching)
            .frame(maxHeight: .infinity)

            footer
        }
        .animation(BUI.easeOutStrong, value: isSearching)
        .task {
            selection = initialSelection
            await load("~/Projects")
        }
        .task(id: query) { await runSearch() }
        .onChange(of: jobs) { _, now in handleClones(now) }
        .sheet(isPresented: $cloning) {
            CloneRepoSheet(destination: listing?.path ?? "~/Projects") { repo in
                cloning = false
                Task { await startClone(repo) }
            }
            .presentationDetents([.fraction(0.7), .large])
            .presentationCornerRadius(28)
            .presentationBackground(BUI.page)
        }
    }

    // MARK: pieces

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(BUI.ink3)
            TextField("Search folders on your Mac", text: $query)
                .font(.inter(15))
                .foregroundStyle(BUI.ink)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if searching { MiniSpinner(size: 12).transition(.opacity) }
            if !query.isEmpty {
                Button { query = ""; searchFocused = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(BUI.ink3)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.control + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BUI.Radius.control + 2, style: .continuous).strokeBorder(searchFocused ? BUI.lineStrong : BUI.line))
        .animation(BUI.easeOutFast, value: query.isEmpty)
        .animation(BUI.easeOutFast, value: searching)
        .animation(BUI.easeOutFast, value: searchFocused)
    }

    private var shortcutsRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(shortcuts, id: \.1) { s in
                    Button {
                        direction = .trailing
                        Task { await load(s.1) }
                    } label: {
                        Label(s.0, systemImage: s.2)
                    }
                    .buttonStyle(.bui(.secondary, .sm))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 10)
    }

    private func pathBar(_ listing: DirListing) -> some View {
        HStack(spacing: 8) {
            Button {
                guard let parent = listing.parent else { return }
                direction = .leading
                Task { await load(parent) }
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(IconButtonStyle(size: 30, tint: BUI.ink2))
            .disabled(listing.parent == nil)
            .opacity(listing.parent == nil ? 0.3 : 1)

            Text(listing.path.abbreviatedPath)
                .font(.jbMono(12)).foregroundStyle(BUI.ink2).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 6)
            Button { toggle(listing.path) } label: {
                Text(selection.contains(listing.path) ? "Selected" : "Select this").contentTransition(.opacity)
            }
            .buttonStyle(.bui(selection.contains(listing.path) ? .success : .quiet, .xs))
            Menu {
                Button("New folder here", systemImage: "folder.badge.plus") { beginNaming() }
                Button("Clone a GitHub repo here", systemImage: "arrow.down.circle") { cloning = true }
            } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BUI.surface)
                    .frame(width: 30, height: 30)
                    .background(BUI.ink, in: Circle())
            }
            .accessibilityLabel("Add a folder")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func folderList(_ listing: DirListing) -> some View {
        List {
            if !jobs.isEmpty {
                ForEach(jobs) { job in
                    CloneProgressRow(job: job) { cloneIds.removeAll { $0 == job.id } }
                        .listRowBackground(BUI.surface)
                        .listRowSeparatorTint(BUI.line)
                        .transition(.fadeUp)
                }
            }
            if naming {
                newFolderRow
                    .listRowBackground(BUI.surface)
                    .listRowSeparatorTint(BUI.line)
                    .transition(.fadeUp)
            }
            ForEach(listing.entries) { e in
                row(e)
                    .listRowBackground(justMade == e.path ? BUI.accentTint : BUI.surface)
                    .listRowSeparatorTint(BUI.line)
            }
            if listing.entries.isEmpty && !naming {
                VStack(spacing: 10) {
                    Image(systemName: "folder").font(.system(size: 24, weight: .light)).foregroundStyle(BUI.ink3)
                    Text("Nothing inside yet").font(.inter(14, .medium)).foregroundStyle(BUI.ink2)
                    Button("New folder here") { beginNaming() }.buttonStyle(.bui(.secondary, .sm))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.insetGrouped)
        .animation(BUI.easeOutStrong, value: naming)
        .animation(BUI.easeOutStrong, value: jobs.map(\.id))
    }

    private var newFolderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus").font(.system(size: 15)).foregroundStyle(BUI.accentInk).frame(width: 22)
                TextField("Folder name", text: $newName)
                    .font(.inter(15))
                    .focused($nameFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { Task { await createFolder() } }
                Button("Cancel") { withAnimation(BUI.easeOutStrong) { naming = false } }
                    .buttonStyle(.bui(.ghost, .xs))
                Button("Create") { Task { await createFolder() } }
                    .buttonStyle(.bui(.accent, .xs))
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let nameError {
                Text(nameError).font(.inter(12.5)).foregroundStyle(BUI.red).padding(.leading, 34).transition(.opacity)
            }
        }
        .animation(BUI.easeOutFast, value: nameError)
    }

    @ViewBuilder private var searchResults: some View {
        if let results, results.isEmpty, !searching {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .light)).foregroundStyle(BUI.ink3)
                Text("No folders called “\(query)”").font(.inter(14, .medium)).foregroundStyle(BUI.ink2)
                Button("Clone “\(query)” from GitHub instead") { cloning = true }.buttonStyle(.bui(.secondary, .sm))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(results ?? []) { e in
                    row(e, showPath: true)
                        .listRowBackground(BUI.surface)
                        .listRowSeparatorTint(BUI.line)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .animation(BUI.easeOutStrong, value: results?.map(\.path))
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if !selection.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(selection, id: \.self) { s in
                            Button { toggle(s) } label: {
                                HStack(spacing: 5) {
                                    Text(URL(fileURLWithPath: s).lastPathComponent).font(.inter(12.5, .medium))
                                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(BUI.ink3)
                                }
                                .foregroundStyle(BUI.ink)
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(BUI.surface, in: Capsule())
                                .elevation(.btn, Capsule())
                            }
                            .buttonStyle(PressableStyle(scale: 0.94))
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 3)
                }
                .scrollIndicators(.hidden)
            }
            Button {
                onDone(selection)
            } label: {
                HStack(spacing: 6) {
                    Text(selection.isEmpty ? "Select folders" : "Add")
                    if !selection.isEmpty {
                        Text("\(selection.count) folder\(selection.count == 1 ? "" : "s")").contentTransition(.numericText())
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !selection.isEmpty))
            .disabled(selection.isEmpty)
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 12)
        .animation(Theme.spring, value: selection)
    }

    private func row(_ e: DirListing.Entry, showPath: Bool = false) -> some View {
        let picked = selection.contains(e.path)
        return HStack(spacing: 12) {
            Button { toggle(e.path) } label: {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(picked ? BUI.green : BUI.ink3)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: picked)
            Image(systemName: e.git ? "arrow.triangle.branch" : "folder")
                .font(.system(size: 14))
                .foregroundStyle(e.git ? BUI.accentInk : BUI.ink2)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).font(.inter(15)).foregroundStyle(BUI.ink).lineLimit(1)
                if showPath {
                    Text((e.path as NSString).deletingLastPathComponent.abbreviatedPath)
                        .font(.jbMono(11)).foregroundStyle(BUI.ink3).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer()
            if e.hasChildren {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(BUI.ink3)
                    .frame(width: 30, height: 30)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if e.hasChildren {
                direction = .trailing
                if isSearching { query = ""; searchFocused = false }
                Task { await load(e.path) }
            } else {
                toggle(e.path)
            }
        }
    }

    // MARK: actions

    private func toggle(_ p: String) {
        if let i = selection.firstIndex(of: p) { selection.remove(at: i) } else { selection.append(p) }
    }

    private func load(_ path: String) async {
        do {
            let l = try await model.listDir(path)
            error = nil
            withAnimation(BUI.easeOutStrong) { listing = l }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func runSearch() async {
        guard isSearching else { results = nil; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searching = true
        let found = try? await model.searchDirs(query)
        guard !Task.isCancelled else { return }
        searching = false
        withAnimation(BUI.easeOutStrong) { results = found ?? [] }
    }

    private func beginNaming() {
        newName = ""
        nameError = nil
        withAnimation(BUI.easeOutStrong) { naming = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { nameFocused = true }
    }

    private func createFolder() async {
        guard let parent = listing?.path, !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let made = try await model.makeDir(in: parent, name: newName)
            await load(parent)
            withAnimation(BUI.easeOutStrong) {
                naming = false
                if !selection.contains(made.path) { selection.append(made.path) }
                justMade = made.path
            }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(BUI.easeOutStrong) { if justMade == made.path { justMade = nil } }
        } catch {
            withAnimation { nameError = error.localizedDescription }
        }
    }

    private func startClone(_ repo: String) async {
        do {
            let job = try await model.clone(repo, into: listing?.path ?? "~/Projects")
            withAnimation(BUI.easeOutStrong) { cloneIds.insert(job.id, at: 0) }
        } catch {
            model.showBanner(Banner(title: "Couldn't clone", body: error.localizedDescription, agentId: nil, isDecision: false))
        }
    }

    private func handleClones(_ now: [CloneJob]) {
        for job in now where job.state == .done && !selection.contains(job.path) {
            withAnimation(BUI.easeOutStrong) { selection.append(job.path) }
            Task {
                if let p = listing?.path { await load(p) }
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(BUI.easeOutStrong) { cloneIds.removeAll { $0 == job.id } }
            }
        }
    }
}

struct CloneProgressRow: View {
    var job: CloneJob
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Group {
                    switch job.state {
                    case .running: SpinnerRing(active: true, size: 22) { Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold)).foregroundStyle(BUI.accentInk) }
                    case .done: ResultBadge(tone: .green, symbol: "checkmark", size: 22)
                    case .error: ResultBadge(tone: .red, symbol: "xmark", size: 22)
                    }
                }
                .transition(.popIn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.repo).font(.inter(14.5, .medium)).foregroundStyle(BUI.ink).lineLimit(1)
                    Text(subtitle).font(.inter(12)).foregroundStyle(job.state == .error ? BUI.red : BUI.ink2).lineLimit(2).contentTransition(.opacity)
                }
                Spacer(minLength: 0)
                if job.state == .error {
                    Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(IconButtonStyle(size: 24))
                } else if let p = job.percent, job.state == .running {
                    Text("\(Int(p))%").font(.jbMono(11.5, .medium)).foregroundStyle(BUI.ink2).contentTransition(.numericText())
                }
            }
            if job.state == .running {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(BUI.hover2)
                        Capsule().fill(BUI.accent).frame(width: max(6, g.size.width * (job.percent ?? 2) / 100))
                    }
                }
                .frame(height: 4)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 4)
        .animation(BUI.easeOutStrong, value: job)
        .sensoryFeedback(.success, trigger: job.state == .done)
    }

    private var subtitle: String {
        switch job.state {
        case .running: return "\(job.phase) into \((job.path as NSString).deletingLastPathComponent.abbreviatedPath)"
        case .done: return "Cloned and selected"
        case .error: return job.error ?? "Clone failed"
        }
    }
}

/// Pick one of your GitHub repos (or paste any git URL) to clone with the Mac's own credentials.
struct CloneRepoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var destination: String
    var onPick: (String) -> Void

    @State private var query = ""
    @State private var repos: [GitHubRepo]?
    @State private var error: String?
    @State private var loading = false
    @FocusState private var focused: Bool

    private var direct: String? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix("git@") || q.hasPrefix("https://") || q.hasPrefix("ssh://") { return q }
        if q.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil, !(repos ?? []).contains(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame }) { return q }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Clone a repo", subtitle: "Into \(destination.abbreviatedPath), using the Mac's GitHub login") { dismiss() }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(BUI.ink3)
                TextField("Search your repos or paste a URL", text: $query)
                    .font(.inter(15))
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { if let d = direct { onPick(d) } else if let first = repos?.first { onPick(first.name) } }
                if loading { MiniSpinner(size: 12) }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(BUI.surface, in: RoundedRectangle(cornerRadius: BUI.Radius.control + 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BUI.Radius.control + 2, style: .continuous).strokeBorder(focused ? BUI.lineStrong : BUI.line))
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            if let error {
                VStack(spacing: 10) {
                    ResultBadge(tone: .orange, symbol: "key.fill", size: 34)
                    Text(error).font(.inter(14)).foregroundStyle(BUI.ink2).multilineTextAlignment(.center)
                }
                .padding(30)
                .frame(maxHeight: .infinity)
            } else if repos == nil {
                LoadingState(label: "Loading your repos", pattern: .orbit).frame(maxHeight: .infinity)
            } else {
                List {
                    if let d = direct {
                        Button { onPick(d) } label: {
                            HStack(spacing: 12) {
                                ResultBadge(tone: .accent, symbol: "arrow.down", size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Clone \(d)").font(.inter(15, .medium)).foregroundStyle(BUI.ink).lineLimit(1)
                                    Text(d.hasPrefix("git@") || d.hasPrefix("ssh://") ? "Uses your SSH key" : "Uses your GitHub login").font(.inter(12)).foregroundStyle(BUI.ink3)
                                }
                            }
                        }
                        .listRowBackground(BUI.surface)
                        .transition(.fadeUp)
                    }
                    ForEach(repos ?? []) { r in
                        Button { onPick(r.name) } label: { RepoRow(repo: r) }
                            .listRowBackground(BUI.surface)
                            .listRowSeparatorTint(BUI.line)
                    }
                    if (repos ?? []).isEmpty && direct == nil {
                        Text("No repos match “\(query)”").font(.inter(14)).foregroundStyle(BUI.ink3).listRowBackground(Color.clear)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
                .animation(BUI.easeOutStrong, value: repos?.map(\.id))
                .animation(BUI.easeOutStrong, value: direct)
            }
        }
        .task(id: query) {
            if repos != nil { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            loading = true
            do {
                let found = try await model.githubRepos(query)
                guard !Task.isCancelled else { return }
                withAnimation(BUI.easeOutStrong) { repos = found; error = nil }
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
}

struct RepoRow: View {
    var repo: GitHubRepo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(repo.owner.prefix(1)).uppercased())
                .font(.inter(12, .semibold)).foregroundStyle(BUI.ink2)
                .frame(width: 26, height: 26)
                .background(BUI.inset, in: RoundedRectangle(cornerRadius: BUI.Radius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.shortName).font(.inter(15, .medium)).foregroundStyle(BUI.ink).lineLimit(1)
                    if repo.private { Image(systemName: "lock.fill").font(.system(size: 9.5)).foregroundStyle(BUI.ink3) }
                }
                Text(repo.description?.nilIfEmpty ?? repo.owner).font(.inter(12.5)).foregroundStyle(BUI.ink2).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let pushed = repo.pushedAt, let d = ISO8601DateFormatter().date(from: pushed) {
                Text(relativeTime(d.timeIntervalSince1970 * 1000)).font(.inter(11.5)).foregroundStyle(BUI.ink3)
            }
        }
        .contentShape(Rectangle())
    }
}
