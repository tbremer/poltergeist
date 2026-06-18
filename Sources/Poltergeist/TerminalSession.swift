import Foundation
import Combine
import GhosttyTerminal

/// A single terminal session: a real shell (or any command) running on a PTY,
/// rendered by a GhosttyKit surface via the `.inMemory` backend.
///
/// Owns the `TerminalViewState` (rendering + published terminal state), the
/// `InMemoryTerminalSession` (GhosttyKit I/O bridge), and the `PTYProcess`
/// (child process + pty). Managed by `SessionStore`.
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
        fontFamily: String? = nil,
        fontSize: Float = 14
    ) {
        let pty = PTYProcess()

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

        pty.onOutput = { [weak io] data in io?.receive(data) }
        pty.onExit = { [weak io] code, ms in
            io?.finish(exitCode: UInt32(truncatingIfNeeded: code), runtimeMilliseconds: ms)
        }
        // Scrollback is intentionally not persisted/replayed: replaying the raw
        // byte log re-feeds the shell's capability queries into the surface,
        // which re-answers them into the new shell (garbled output). Sessions
        // restore fresh (name, cwd, new shell).

        var terminalConfiguration = TerminalConfiguration()
        if let fontFamily, !fontFamily.isEmpty {
            terminalConfiguration = terminalConfiguration.fontFamily(fontFamily)
        }
        terminalConfiguration = terminalConfiguration.fontSize(fontSize)

        let state = TerminalViewState(terminalConfiguration: terminalConfiguration)
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
}
