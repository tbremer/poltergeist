import Foundation
import Combine
import GhosttyTerminal

/// A single terminal session: a real shell (or any command) running on a PTY,
/// rendered by a GhosttyKit surface via the `.inMemory` backend.
///
/// Owns the `TerminalViewState` (rendering + published terminal state), the
/// `InMemoryTerminalSession` (GhosttyKit I/O bridge), the `PTYProcess`
/// (child process + pty), and a `Scrollback` (capture/replay). Managed by
/// `SessionStore`.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    let ordinal: Int
    let createdAt: Date
    let state: TerminalViewState

    /// User-assigned name; overrides the shell-reported title when set.
    @Published var customTitle: String?

    /// Directory the shell was launched in; persistence fallback before the
    /// shell reports its own working directory.
    let launchDirectory: String

    /// The opencode server session this terminal is attached to, if any.
    let opencodeSessionID: String?

    private let pty: PTYProcess
    private let ioSession: InMemoryTerminalSession
    private let scrollback: Scrollback
    private var cancellables = Set<AnyCancellable>()

    init(
        id: UUID = UUID(),
        ordinal: Int,
        customTitle: String? = nil,
        workingDirectory: URL? = nil,
        createdAt: Date = Date(),
        environmentOverrides: [String: String] = [:],
        command: [String]? = nil,
        opencodeSessionID: String? = nil,
        fontSize: Float = 14
    ) {
        let pty = PTYProcess()
        let scrollback = Scrollback(url: AppPaths.scrollbackFile(for: id))

        // Launch parameters: the user's login shell.
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shellPath as NSString).lastPathComponent
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Poltergeist"
        for (key, value) in environmentOverrides { environment[key] = value }
        let cwd = (workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser).path

        // Either run a custom command (e.g. `opencode attach …`) or the login shell.
        let executable: String
        let argv: [String]
        if let command, let first = command.first {
            executable = first
            argv = command
        } else {
            executable = shellPath
            argv = ["-\(shellName)"] // leading dash → login shell
        }

        pty.configure(
            executable: executable,
            argv: argv,
            environment: environment,
            cwd: cwd
        )

        // Bridge GhosttyKit's in-memory backend to the PTY. Weak captures avoid
        // a retain cycle between the I/O session and the PTY process.
        let io = InMemoryTerminalSession(
            write: { [weak pty] data in pty?.write(data) },
            resize: { [weak pty] viewport in
                pty?.handleResize(
                    columns: viewport.columns,
                    rows: viewport.rows,
                    widthPixels: viewport.widthPixels,
                    heightPixels: viewport.heightPixels
                )
            }
        )

        // Tee live shell output to both the surface and the scrollback capture.
        pty.onOutput = { [weak io, weak scrollback] data in
            io?.receive(data)
            scrollback?.append(data)
        }
        pty.onExit = { [weak io] code, ms in
            io?.finish(exitCode: UInt32(truncatingIfNeeded: code), runtimeMilliseconds: ms)
        }
        // NOTE: We intentionally do NOT replay saved scrollback into the live
        // surface. Replaying the raw byte log re-feeds the shell's original
        // terminal capability queries (XTVERSION, DA1, OSC color, kitty, …),
        // which the surface then re-answers into the freshly-spawned shell —
        // leaking garbled control-sequence text to the prompt. A faithful
        // "restore last screen" needs a styled screen snapshot, which the
        // in-memory backend doesn't expose. Sessions restore fresh instead.

        let state = TerminalViewState()
        state.configuration = TerminalSurfaceOptions(
            backend: .inMemory(io),
            fontSize: fontSize,
            workingDirectory: nil,
            context: .window
        )

        self.id = id
        self.ordinal = ordinal
        self.createdAt = createdAt
        self.customTitle = customTitle
        self.launchDirectory = cwd
        self.opencodeSessionID = opencodeSessionID
        self.pty = pty
        self.ioSession = io
        self.scrollback = scrollback
        self.state = state

        // Re-publish when the underlying terminal state changes (title, cwd, …)
        // so the sidebar/title stay in sync.
        state.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Name shown in the sidebar: a custom name if set, else the shell-reported
    /// title, else a stable fallback.
    var displayName: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !state.title.isEmpty { return state.title }
        return "Terminal \(ordinal)"
    }

    /// Current working directory if the shell has reported one, else the launch dir.
    var currentDirectory: String {
        state.workingDirectory ?? launchDirectory
    }

    func terminate() {
        pty.terminate()
    }

    /// Persist the captured scrollback to disk. Safe to call off the main actor.
    nonisolated func flush() {
        scrollback.flush()
    }

    /// Remove the persisted scrollback (used when a session is closed for good).
    nonisolated func deleteScrollback() {
        scrollback.delete()
    }
}
