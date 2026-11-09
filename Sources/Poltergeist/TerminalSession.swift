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

    /// Whether opencode is the foreground process in this tab (any of its panes).
    /// Drives the sidebar sparkle; polled by `SessionStore`. Starts true for
    /// attached sessions so the icon doesn't flicker before the first poll.
    @Published private(set) var opencodeActive: Bool

    /// Why opencode in this pane is waiting on the user, from its OSC 7501
    /// program-status reports (see `ProgramStatus`).
    @Published private(set) var paneAttention: OpencodeAttention?
    /// The strongest attention across this tab's panes (set by `SessionStore`
    /// on tab sessions only).
    @Published private(set) var tabAttention: OpencodeAttention?
    /// opencode's own title/message for the current attention, if any.
    private(set) var attentionTitle: String?
    private(set) var attentionMessage: String?
    /// The opencode session this pane's TUI last reported (works for an
    /// `opencode` started by hand, unlike `opencodeSessionID`).
    private(set) var reportedOpencodeSessionID: String?
    /// Called on the main actor when `paneAttention` changes.
    var onAttentionChange: (() -> Void)?

    private var statusWorking = false
    private var statusBlockedKind: String?
    private var statusFinished = false
    /// Sessions in this pane's TUI that are working or blocked (session ID →
    /// title), from the per-session OSC 7501 reports.
    private var busySessions: [String: String] = [:]

    /// Shown over the pane while asking whether to close a busy opencode tab:
    /// the title of the session that's still running.
    @Published private(set) var closeTabPrompt: String?

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
        fontSize: Float = 14,
        theme: TerminalTheme = .default
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

        // Either run a custom command (e.g. `opencode --server … --session …`) or the login shell.
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

        // (pty.onOutput is set below, once `self` exists, to also scan for
        // opencode's program-status reports.)
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
        // fontThicken(false) matches Ghostty's default; the library's default is true.
        terminalConfiguration = terminalConfiguration.fontSize(fontSize).windowPaddingY(0).fontThicken(false)
            .poltergeistKeybinds()

        let state = TerminalViewState(theme: theme, terminalConfiguration: terminalConfiguration)
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
        self.opencodeActive = opencodeSessionID != nil
        self.pty = pty
        self.ioSession = io
        self.state = state

        // Read opencode's program-status reports out of the output stream
        // (off the main thread), applying them on the main actor.
        let scanner = ProgramStatusScanner()
        pty.onOutput = { [weak io, weak self] data in
            io?.receive(data)
            let reports = scanner.scan(data)
            guard !reports.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(reports) }
            }
        }

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

    /// Whether this terminal's foreground job is opencode; `nil` if unknown
    /// (PTY not started yet, or exited).
    func foregroundIsOpencode() -> Bool? {
        pty.foregroundProcessNames()?.contains { $0 == "opencode" || $0.hasPrefix("opencode-") }
    }

    /// Publishes only on change, so polling doesn't churn the sidebar.
    func setOpencodeActive(_ active: Bool) {
        if opencodeActive != active { opencodeActive = active }
    }

    // MARK: - Attention (opencode program status)

    /// Applies OSC 7501 reports. Whole-TUI reports (no `id`) drive the state;
    /// per-session ones just tell us which session the TUI is on. A turn that
    /// goes working → idle is "finished" until the user looks (`markSeen`).
    private func apply(_ reports: [ProgramStatus]) {
        for report in reports {
            if let id = report.sessionID {
                if report.state != .clear { reportedOpencodeSessionID = id }
                switch report.state {
                case .working, .blocked: busySessions[id] = report.title ?? ""
                case .idle, .clear: busySessions[id] = nil
                }
                continue
            }
            switch report.state {
            case .working:
                statusWorking = true
                statusBlockedKind = nil
                statusFinished = false
                attentionTitle = report.title
                attentionMessage = nil
            case .blocked:
                statusBlockedKind = report.kind ?? "question"
                statusFinished = false
                attentionTitle = report.title
                attentionMessage = report.message
            case .idle:
                if statusWorking { statusFinished = true }
                statusWorking = false
                statusBlockedKind = nil
                attentionMessage = nil
            case .clear:
                resetProgramStatus()
                return
            }
        }
        updatePaneAttention()
    }

    /// The user has seen this pane; drop "finished".
    func markSeen() {
        guard statusFinished else { return }
        statusFinished = false
        updatePaneAttention()
    }

    /// opencode is gone from this pane (exited): forget its status.
    func resetProgramStatus() {
        statusWorking = false
        statusBlockedKind = nil
        statusFinished = false
        attentionMessage = nil
        busySessions = [:]
        closeTabPrompt = nil
        updatePaneAttention()
    }

    /// The title of the session in opencode's *current* tab, if it's working
    /// or blocked. The TUI titles the terminal `OC | <title>` (truncated to 40
    /// with "…") for the current tab, or `OpenCode` when that session is still
    /// untitled (`New session - <date>`), which we match against the titles in
    /// the per-session reports.
    func busyCurrentTabTitle() -> String? {
        let title = state.title
        guard title.hasPrefix("OC | ") else {
            guard title == "OpenCode" else { return nil }
            return busySessions.values.contains(where: Self.isDefaultSessionTitle) ? "New session" : nil
        }
        let shown = String(title.dropFirst(5))
        if shown.hasSuffix("\u{2026}") {
            let stem = shown.dropLast()
            return busySessions.values.first { $0.hasPrefix(stem) }
        }
        return busySessions.values.first { $0 == shown }
    }

    private static func isDefaultSessionTitle(_ title: String) -> Bool {
        title.isEmpty || title.hasPrefix("New session - ") || title.hasPrefix("Child session - ")
    }

    func showCloseTabPrompt(_ title: String) { closeTabPrompt = title }
    func dismissCloseTabPrompt() { if closeTabPrompt != nil { closeTabPrompt = nil } }

    func setTabAttention(_ attention: OpencodeAttention?) {
        if tabAttention != attention { tabAttention = attention }
    }

    private func updatePaneAttention() {
        let next: OpencodeAttention?
        switch statusBlockedKind {
        case "permission": next = .permission
        case .some: next = .question
        case nil: next = statusFinished ? .finished : nil
        }
        guard next != paneAttention else { return }
        paneAttention = next
        onAttentionChange?()
    }

    /// Live-applies appearance (font + theme) to the running surface.
    func applyAppearance(theme: TerminalTheme, fontConfig: TerminalConfiguration) {
        state.controller.setTerminalConfiguration(fontConfig)
        state.controller.setTheme(theme)
    }
}
