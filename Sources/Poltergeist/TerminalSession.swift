import Foundation
import Combine
import GhosttyTerminal

/// A single terminal session: a real shell (or any command) running on a PTY,
/// rendered by a GhosttyKit surface via the `.inMemory` backend.
///
/// Owns the `TerminalViewState` (rendering + published terminal state), the
/// `InMemoryTerminalSession` (GhosttyKit I/O bridge), and the `PTYProcess`
/// (child process + pty), and wires them together. Managed by `SessionStore`.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let ordinal: Int
    let state: TerminalViewState

    /// User-assigned name; overrides the shell-reported title when set.
    @Published var customTitle: String?

    private let pty: PTYProcess
    private let ioSession: InMemoryTerminalSession
    private var cancellables = Set<AnyCancellable>()

    init(ordinal: Int, workingDirectory: URL? = nil, fontSize: Float = 14) {
        let pty = PTYProcess()

        // Launch parameters: the user's login shell, in their home directory.
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shellPath as NSString).lastPathComponent
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Poltergeist"
        let cwd = (workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser).path

        pty.configure(
            executable: shellPath,
            argv: ["-\(shellName)"], // leading dash → login shell
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

        let state = TerminalViewState()
        state.configuration = TerminalSurfaceOptions(
            backend: .inMemory(io),
            fontSize: fontSize,
            workingDirectory: nil,
            context: .window
        )

        self.ordinal = ordinal
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

    func terminate() {
        pty.terminate()
    }
}
