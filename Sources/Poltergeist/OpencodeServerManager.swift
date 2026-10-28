import Foundation
import Darwin

/// Where the opencode server lives and how to authenticate (HTTP Basic, the
/// username is always `opencode` in v2).
struct OpencodeConnection: Equatable, Sendable {
    let baseURL: URL
    let password: String?
    /// True when this is opencode's shared background service (the same one the
    /// plain `opencode` CLI uses); false when we spawned a private `serve`.
    let isShared: Bool
}

/// Finds (or provides) the opencode v2 server the app talks to.
///
/// Preference order:
/// 1. **The shared background service** opencode registers in
///    `~/.local/state/opencode/service.json` — one server for the app, plain
///    `opencode` runs in any terminal, and attached sessions alike.
/// 2. If it isn't running, `opencode service start`, then re-discover.
/// 3. As a last resort, spawn a private `opencode serve` on a free localhost
///    port with a generated password (auto-restarted if it dies).
///
/// We never stop the shared service; only a private server is torn down on quit.
@MainActor
final class OpencodeServerManager: ObservableObject {
    enum Status: Equatable {
        case unavailable(String)
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    /// The live connection, nil until a healthy server is found.
    @Published private(set) var connection: OpencodeConnection?

    let executablePath: String?

    // Private (fallback) server state.
    private var process: Process?
    private var ownedPort: UInt16?
    private var ownedPassword: String?
    private var isStopping = false
    /// Consecutive auto-restarts since the private server was last healthy.
    private var restartAttempts = 0
    private let maxRestartAttempts = 5
    /// Identifies the current private process so a late termination handler from
    /// a superseded process is ignored.
    private var generation = 0

    private var connectTask: Task<Void, Never>?
    private var lastRevalidate = Date.distantPast

    init() {
        let exe = Self.locateOpencode()
        executablePath = exe
        if exe == nil {
            status = .unavailable("opencode binary not found")
        }
    }

    var statusText: String {
        switch status {
        case let .unavailable(msg): "opencode unavailable — \(msg)"
        case .starting: "connecting to opencode…"
        case .running: "no opencode sessions yet"
        case let .failed(msg): "opencode server error — \(msg)"
        }
    }

    var isReady: Bool {
        if case .running = status { return true }
        return false
    }

    func start() {
        guard executablePath != nil, connectTask == nil, !isStopping else { return }
        status = .starting
        connectTask = Task { [weak self] in
            await self?.connect()
            self?.connectTask = nil
        }
    }

    /// Re-checks the connection after a request failed (e.g. the shared service
    /// restarted on a new port/password). Throttled; a no-op while connecting.
    func revalidate() {
        guard executablePath != nil, connectTask == nil, !isStopping,
              Date().timeIntervalSince(lastRevalidate) > 10 else { return }
        lastRevalidate = Date()
        connectTask = Task { [weak self] in
            guard let self else { return }
            if let current = self.connection, await Self.isHealthy(current) {
                self.connectTask = nil
                return
            }
            // A private server has its own restart path; only re-discover shared.
            if self.connection?.isShared == false, self.process != nil {
                self.connectTask = nil
                return
            }
            self.status = .starting
            await self.connect()
            self.connectTask = nil
        }
    }

    func stop() {
        isStopping = true
        connectTask?.cancel()
        connectTask = nil
        process?.terminate()  // private server only; the shared service lives on
        process = nil
    }

    // MARK: - Connecting

    private func connect() async {
        if let shared = await discoverShared() {
            setConnected(shared)
            return
        }
        if await startSharedService(), let shared = await waitForShared(timeout: 15) {
            setConnected(shared)
            return
        }
        startOwnedServer()
    }

    private func setConnected(_ connection: OpencodeConnection) {
        if self.connection != connection { self.connection = connection }
        status = .running
        restartAttempts = 0
    }

    /// Reads the shared service registration and confirms it's healthy.
    private func discoverShared() async -> OpencodeConnection? {
        guard let data = try? Data(contentsOf: Self.serviceStateFile),
              let info = try? JSONDecoder().decode(ServiceState.self, from: data),
              let url = URL(string: info.url)
        else { return nil }
        let candidate = OpencodeConnection(baseURL: url, password: info.password, isShared: true)
        return await Self.isHealthy(candidate) ? candidate : nil
    }

    private func waitForShared(timeout: TimeInterval) async -> OpencodeConnection? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            if let shared = await discoverShared() { return shared }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return nil
    }

    /// Runs `opencode service start` off the main thread. True if it exited 0.
    private func startSharedService() async -> Bool {
        guard let executablePath else { return false }
        return await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executablePath)
            proc.arguments = ["service", "start"]
            proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
                return proc.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    // MARK: - Private server (fallback)

    private func startOwnedServer() {
        guard let executablePath, process == nil, !isStopping else { return }
        if ownedPort == nil { ownedPort = Self.findFreeTCPPort() }
        if ownedPassword == nil { ownedPassword = UUID().uuidString + UUID().uuidString }
        guard let port = ownedPort, let password = ownedPassword,
              let baseURL = URL(string: "http://127.0.0.1:\(port)")
        else {
            status = .unavailable("no free port available")
            return
        }
        status = .starting

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "\(port)"]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["OPENCODE_PASSWORD"] = password
        proc.environment = environment
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        generation += 1
        let myGeneration = generation
        // Resurrect the private server if it dies unexpectedly, on the *same*
        // port + password so attached terminals' `--server` URLs stay valid.
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleOwnedExit(generation: myGeneration) }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        let candidate = OpencodeConnection(baseURL: baseURL, password: password, isShared: false)
        Task { [weak self] in
            for _ in 0 ..< 60 {
                if Task.isCancelled { return }
                if await Self.isHealthy(candidate) {
                    self?.setConnected(candidate)
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            self?.status = .failed("server did not become ready")
        }
    }

    private func handleOwnedExit(generation gen: Int) {
        guard !isStopping, gen == generation else { return }
        process = nil
        guard restartAttempts < maxRestartAttempts else {
            status = .failed("server keeps exiting — gave up after \(maxRestartAttempts) restarts")
            return
        }
        restartAttempts += 1
        status = .starting
        let delay = min(0.5 * Double(restartAttempts), 5.0)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.isStopping, self.process == nil else { return }
            self.startOwnedServer()
        }
    }

    // MARK: - Helpers

    private struct ServiceState: Decodable {
        let url: String
        let password: String?
    }

    private static var serviceStateFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/opencode/service.json")
    }

    /// Healthy = an authenticated `GET /api/info` answers 200. (The v2 server
    /// serves its web UI for unknown paths with a 200, so a bare path probe
    /// would pass even against the wrong thing.)
    nonisolated static func isHealthy(_ connection: OpencodeConnection) async -> Bool {
        var request = OpencodeClient(connection: connection).request("api/info")
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private static func locateOpencode() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.opencode/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }

        // Fall back to the user's login shell PATH.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", "command -v opencode"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (!path.isEmpty && fm.isExecutableFile(atPath: path)) ? path : nil
    }

    private static func findFreeTCPPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindResult == 0 else { return nil }

        var actual = sockaddr_in()
        var len = size
        let nameResult = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard nameResult == 0 else { return nil }
        return UInt16(bigEndian: actual.sin_port)
    }
}
