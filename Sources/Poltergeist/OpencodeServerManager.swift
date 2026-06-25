import Foundation
import Darwin

/// Spawns and supervises a single `opencode serve` instance for the app.
///
/// We pick a free TCP port up front so `baseURL` (and thus `OPENCODE_BASE_URL`)
/// is known immediately — even before the server finishes booting — so every
/// spawned terminal can be told where the server is.
@MainActor
final class OpencodeServerManager: ObservableObject {
    enum Status: Equatable {
        case unavailable(String)
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var status: Status = .starting

    let baseURL: URL?

    let executablePath: String?
    private let port: UInt16?
    private var process: Process?
    private var healthCheckTask: Task<Void, Never>?

    /// True once we've deliberately stopped the server (app quitting), so the
    /// termination handler doesn't try to resurrect it.
    private var isStopping = false
    /// Consecutive auto-restarts since the server was last healthy. Used to back
    /// off and eventually give up on a crash loop; reset on a healthy boot.
    private var restartAttempts = 0
    private let maxRestartAttempts = 5
    /// Identifies the current server process so a late termination handler from a
    /// superseded process is ignored.
    private var generation = 0

    init() {
        let exe = Self.locateOpencode()
        executablePath = exe

        guard exe != nil else {
            port = nil
            baseURL = nil
            status = .unavailable("opencode binary not found")
            return
        }
        if let p = Self.findFreeTCPPort() {
            port = p
            baseURL = URL(string: "http://127.0.0.1:\(p)")
        } else {
            port = nil
            baseURL = nil
            status = .unavailable("no free port available")
        }
    }

    var statusText: String {
        switch status {
        case let .unavailable(msg): "opencode unavailable — \(msg)"
        case .starting: "starting opencode server…"
        case .running: "no opencode sessions for this directory"
        case let .failed(msg): "opencode server error — \(msg)"
        }
    }

    var isReady: Bool {
        if case .running = status { return true }
        return false
    }

    func start() {
        guard let executablePath, let port, let baseURL, process == nil else { return }
        status = .starting

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "\(port)"]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        proc.environment = ProcessInfo.processInfo.environment
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        generation += 1
        let myGeneration = generation
        // Resurrect the server if it dies unexpectedly: attached terminals embed
        // this port in their `attach` URL, so a death otherwise breaks every
        // session with "unable to connect" until the app relaunches. The handler
        // fires on a background thread, so hop back to the main actor.
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleServerExit(generation: myGeneration) }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        let healthURL = baseURL.appendingPathComponent("session")
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            for _ in 0 ..< 60 {
                if Task.isCancelled { return }
                var req = URLRequest(url: healthURL)
                req.timeoutInterval = 1
                if let (_, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    self?.markServerRunning()
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            self?.status = .failed("server did not become ready")
        }
    }

    func stop() {
        isStopping = true
        healthCheckTask?.cancel()
        healthCheckTask = nil
        process?.terminate()
        process = nil
    }

    /// Health check passed. Clear the restart counter so a later one-off crash
    /// restarts promptly instead of counting toward the give-up cap.
    private func markServerRunning() {
        status = .running
        restartAttempts = 0
    }

    /// Invoked (on the main actor) when the server process exits. Relaunches it on
    /// the *same* port — keeping `baseURL`/`OPENCODE_BASE_URL` and existing attach
    /// URLs valid — unless we stopped it deliberately or it's crash-looping.
    private func handleServerExit(generation gen: Int) {
        // Ignore deliberate stops and stale handlers from a superseded process.
        guard !isStopping, gen == generation else { return }
        process = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil

        guard restartAttempts < maxRestartAttempts else {
            status = .failed("server keeps exiting — gave up after \(maxRestartAttempts) restarts")
            return
        }
        restartAttempts += 1
        status = .starting
        // Brief, growing backoff: a one-off crash recovers almost immediately
        // while a tight crash loop doesn't spin.
        let delay = min(0.5 * Double(restartAttempts), 5.0)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.isStopping, self.process == nil else { return }
            self.start()
        }
    }

    // MARK: - Helpers

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
