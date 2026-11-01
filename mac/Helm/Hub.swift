import AppKit
import Foundation
import Observation

struct HubStatus: Decodable, Equatable {
    struct Tailscale: Decodable, Equatable { var ip: String?; var dns: String? }
    struct Pairing: Decodable, Equatable { var url: String; var link: String }
    var cursorLoggedIn: Bool
    var cursorEmail: String?
    var tailscale: Tailscale
    var tailscaleInstalled: Bool
    var push: Bool
    var hubName: String
    var port: Int
    var pairing: Pairing
}

struct HubLive: Decodable, Equatable {
    struct Device: Decodable, Equatable { var name: String; var lastSeenAt: Double; var push: Bool }
    var name: String
    var phonesConnected: Int
    var devices: [Device]
    var push: Bool
}

enum HubState: Equatable {
    case stopped, starting, running
    case crashed(String)
    /// Something else already answers on the hub's port; `legacy` means it's the command-line service from setup.sh.
    case conflict(legacy: Bool)
    case missingRuntime
}

/// Runs the bundled hub as a child process and keeps it alive while the app runs.
@MainActor @Observable
final class Hub {
    static let shared = Hub()

    private(set) var state: HubState = .stopped
    private(set) var status: HubStatus?
    private(set) var live: HubLive?
    private(set) var signingIn = false
    var signInError: String?

    private var process: Process?
    private var stopping = false
    private var restartWhenStopped = false
    private var crashes = 0
    private var startedAt = Date.distantPast
    private var shellPath: String?

    static let legacyLabel = "ca.vcazan.helm.hub"
    let home = FileManager.default.homeDirectoryForCurrentUser
    var dataDir: URL { home.appending(path: ".helm") }
    var logURL: URL { dataDir.appending(path: "logs/hub.log") }
    private var nodeURL: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/node") }
    private var hubDir: URL { Bundle.main.resourceURL!.appending(path: "hub") }
    private var legacyPlist: URL { home.appending(path: "Library/LaunchAgents/\(Self.legacyLabel).plist") }
    var port: Int { status?.port ?? 7878 }

    // MARK: Lifecycle

    func start() async {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path) else { state = .missingRuntime; return }
        state = .starting
        if shellPath == nil { shellPath = await Self.loginShellPath() }
        if await healthy(), await killOrphanedHub() {
            for _ in 0..<20 {
                if !(await healthy()) { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        if await healthy() {
            state = .conflict(legacy: FileManager.default.fileExists(atPath: legacyPlist.path))
            await refresh()
            return
        }
        launch()
    }

    func restart() {
        guard process != nil else { Task { await start() }; return }
        restartWhenStopped = true
        stopping = true
        state = .starting
        process?.terminate()
    }

    /// Stops the hub before the app quits, giving it a moment to save its state.
    func stopForQuit() {
        guard let p = process else { return }
        stopping = true
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    /// Replaces the command-line hub service from setup.sh with this app's hub.
    func adoptLegacyService() async {
        state = .starting
        _ = await Self.run(URL(fileURLWithPath: "/bin/launchctl"), ["bootout", "gui/\(getuid())/\(Self.legacyLabel)"])
        try? FileManager.default.removeItem(at: legacyPlist)
        for _ in 0..<40 {
            if !(await healthy()) { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        await start()
    }

    /// A hub left behind by a copy of this app that was killed instead of quit. Returns whether it stopped one.
    private func killOrphanedHub() async -> Bool {
        let (_, out) = await Self.run(URL(fileURLWithPath: "/usr/sbin/lsof"), ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeout: 3)
        var killed = false
        for pid in out.split(separator: "\n").compactMap({ pid_t($0.trimmingCharacters(in: .whitespaces)) }) {
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { continue }
            let path = String(cString: buf)
            var info = proc_bsdinfo()
            let orphaned = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 && info.pbi_ppid == 1
            if orphaned && path.hasSuffix(".app/Contents/Helpers/node") {
                kill(pid, SIGTERM)
                killed = true
            }
        }
        return killed
    }

    private func launch() {
        let p = Process()
        p.executableURL = nodeURL
        p.arguments = ["--disable-warning=ExperimentalWarning", hubDir.appending(path: "src/main.ts").path, "start"]
        p.currentDirectoryURL = hubDir
        p.environment = environment
        let log = logHandle()
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in Hub.shared.exited(code) }
        }
        do {
            try p.run()
            process = p
            startedAt = .now
            stopping = false
            Task { await waitUntilUp() }
        } catch {
            state = .crashed(error.localizedDescription)
        }
    }

    private func exited(_ code: Int32) {
        process = nil
        if restartWhenStopped {
            restartWhenStopped = false
            launch()
            return
        }
        if stopping { state = .stopped; return }
        if Date().timeIntervalSince(startedAt) > 60 { crashes = 0 }
        crashes += 1
        state = .crashed(lastLogLine() ?? "The hub exited with code \(code).")
        let delay = min(pow(2, Double(crashes)), 30)
        Task {
            try? await Task.sleep(for: .seconds(delay))
            if case .crashed = state, process == nil { launch() }
        }
    }

    private func waitUntilUp() async {
        for _ in 0..<60 {
            if process == nil { return }
            if await healthy() {
                state = .running
                await refresh()
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", home.appending(path: ".local/bin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let parts = (shellPath?.split(separator: ":").map(String.init) ?? []) + fallback
        var seen = Set<String>()
        env["PATH"] = parts.filter { seen.insert($0).inserted }.joined(separator: ":")
        env["HOME"] = home.path
        env["HELM_PARENT_PID"] = String(getpid())
        return env
    }

    private func logHandle() -> FileHandle {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let h = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        _ = try? h.seekToEnd()
        return h
    }

    private func lastLogLine() -> String? {
        guard let s = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        return s.split(separator: "\n").last(where: { $0.localizedCaseInsensitiveContains("error") }).map(String.init)
    }

    // MARK: Status

    /// Re-reads sign-in, Tailscale, push and the pairing link from the hub's own `status` command.
    func refresh() async {
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path) else { return }
        if case .conflict = state, !(await healthy()) {
            state = .stopped
            await start()
        }
        let (code, out) = await Self.run(nodeURL, ["--disable-warning=ExperimentalWarning", hubDir.appending(path: "src/main.ts").path, "status"], cwd: hubDir, env: environment)
        guard code == 0, let start = out.firstIndex(of: "{"), let end = out.lastIndex(of: "}") else { return }
        if let s = try? JSONDecoder().decode(HubStatus.self, from: Data(out[start...end].utf8)), s != status { status = s }
        await refreshLive()
    }

    /// Phones connected right now, from the running hub.
    func refreshLive() async {
        guard let token = config()["token"] as? String, let url = URL(string: "http://127.0.0.1:\(port)/hub") else { return }
        var req = URLRequest(url: url, timeoutInterval: 1.5)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, res) = try? await URLSession.shared.data(for: req), (res as? HTTPURLResponse)?.statusCode == 200,
              let l = try? JSONDecoder().decode(HubLive.self, from: data) else { return }
        if l != live { live = l }
    }

    private func healthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        let req = URLRequest(url: url, timeoutInterval: 1)
        guard let (_, res) = try? await URLSession.shared.data(for: req) else { return false }
        return (res as? HTTPURLResponse)?.statusCode == 200
    }

    func sendTestPush() async -> Bool {
        guard let token = config()["token"] as? String, let url = URL(string: "http://127.0.0.1:\(port)/api/test-push") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (j["enabled"] as? Bool) == true && ((j["devices"] as? Int) ?? 0) > 0
    }

    // MARK: Cursor sign-in

    func signIn() async {
        signingIn = true
        signInError = nil
        let (code, out) = await Self.run(nodeURL, ["--disable-warning=ExperimentalWarning", hubDir.appending(path: "src/main.ts").path, "login"], cwd: hubDir, env: environment) { line in
            if line.hasPrefix("Opening "), let url = URL(string: String(line.dropFirst("Opening ".count)).trimmingCharacters(in: .whitespaces)) {
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
        }
        signingIn = false
        if code != 0 { signInError = out.split(separator: "\n").last.map(String.init) ?? "Sign-in failed." }
        await refresh()
        if status?.cursorLoggedIn == true, process != nil { restart() }
    }

    // MARK: Push

    var pushSettings: (teamId: String, bundleId: String, keyName: String?) {
        let c = config()
        let apns = c["apns"] as? [String: Any]
        let key = (try? FileManager.default.contentsOfDirectory(atPath: dataDir.path))?.first { $0.range(of: #"^AuthKey_[A-Z0-9]+\.p8$"#, options: .regularExpression) != nil }
        return (c["appleTeamId"] as? String ?? apns?["teamId"] as? String ?? "", c["bundleId"] as? String ?? apns?["bundleId"] as? String ?? "", key)
    }

    /// Copies the APNs key into ~/.helm and points the hub at the team and bundle ID, then restarts it.
    func savePush(key: URL?, teamId: String, bundleId: String) throws {
        let fm = FileManager.default
        if let key {
            let name = key.lastPathComponent
            guard name.range(of: #"^AuthKey_[A-Z0-9]+\.p8$"#, options: .regularExpression) != nil else {
                throw PushError.badKeyName
            }
            let old = dataDir.appending(path: "old-keys")
            for f in (try? fm.contentsOfDirectory(atPath: dataDir.path)) ?? [] where f.hasPrefix("AuthKey_") && f.hasSuffix(".p8") && f != name {
                try? fm.createDirectory(at: old, withIntermediateDirectories: true)
                try? fm.moveItem(at: dataDir.appending(path: f), to: old.appending(path: f))
            }
            let dest = dataDir.appending(path: name)
            if dest.standardizedFileURL != key.standardizedFileURL {
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: key, to: dest)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        }
        var c = config()
        c["appleTeamId"] = teamId.trimmingCharacters(in: .whitespaces)
        c["bundleId"] = bundleId.trimmingCharacters(in: .whitespaces)
        c.removeValue(forKey: "apns")
        let data = try JSONSerialization.data(withJSONObject: c, options: [.prettyPrinted, .sortedKeys])
        let url = dataDir.appending(path: "config.json")
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        restart()
    }

    enum PushError: LocalizedError {
        case badKeyName
        var errorDescription: String? { "Choose the key file exactly as Apple named it, like AuthKey_ABC123DEFG.p8. Its name carries the key ID." }
    }

    private func config() -> [String: Any] {
        guard let data = try? Data(contentsOf: dataDir.appending(path: "config.json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return j
    }

    // MARK: Processes

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    nonisolated static func run(_ exe: URL, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil, timeout: TimeInterval? = nil, onLine: (@Sendable (String) -> Void)? = nil) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            if let env { p.environment = env }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let buf = Buffer()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                buf.append(d)
                if let onLine { String(decoding: d, as: UTF8.self).split(separator: "\n").forEach { onLine(String($0)) } }
            }
            p.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                buf.append(pipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: (p.terminationStatus, buf.string))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)); return }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            }
        }
    }

    /// The PATH a Terminal would have, so agents find the same tools (git, gh, nvm's node) as on the command line.
    nonisolated static func loginShellPath() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let (code, out) = await run(URL(fileURLWithPath: shell), ["-l", "-c", "printf '%s' \"$PATH\""], timeout: 4)
        let path = out.split(separator: "\n").last.map(String.init) ?? ""
        return code == 0 && path.contains("/") ? path : nil
    }
}
