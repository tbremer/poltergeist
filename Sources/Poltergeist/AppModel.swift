import Foundation
import Combine
import AppKit

/// Top-level app state: owns the opencode server, the terminal session store,
/// and the live opencode session list shown in the sidebar.
@MainActor
final class AppModel: ObservableObject {
    let server: OpencodeServerManager
    let store: SessionStore

    /// opencode sessions for the currently selected terminal's directory.
    @Published private(set) var opencodeSessions: [OpencodeSession] = []

    /// All opencode sessions grouped by working directory (active dir first).
    @Published private(set) var opencodeGroups: [OpencodeProjectGroup] = []

    /// Lookup of opencode sessions by id (accumulated across refreshes) so
    /// terminal rows can show metadata even when not in the current dir list.
    @Published private(set) var opencodeByID: [String: OpencodeSession] = [:]

    private let client: OpencodeClient?
    private var eventStream: OpencodeEventStream?
    private var cancellables = Set<AnyCancellable>()
    private var refreshWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var refreshEnabled = false

    init() {
        let server = OpencodeServerManager()
        self.server = server

        // Point every terminal at the (soon-to-be-ready) shared server.
        var overrides: [String: String] = [:]
        if let base = server.baseURL {
            overrides["OPENCODE_BASE_URL"] = base.absoluteString
        }
        store = SessionStore(environmentOverrides: overrides)

        client = server.baseURL.map { OpencodeClient(baseURL: $0) }

        server.start()

        if let base = server.baseURL {
            let stream = OpencodeEventStream(baseURL: base)
            stream.onEvent = { [weak self] in self?.scheduleRefresh() }
            stream.start()
            eventStream = stream
        }

        // Refresh the opencode list when the active terminal (its directory)
        // changes, and when the server becomes ready.
        store.$selectedID
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        server.$status
            .sink { [weak self] status in
                if status == .running { self?.scheduleRefresh() }
            }
            .store(in: &cancellables)
        // Surface server status changes (starting → running) to the UI.
        server.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.server.stop() }
        }

        // Periodic refresh keeps cost/tokens and the activity indicator current.
        // Gentle cadence since each refresh fans out across all projects.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }

        // Defer the first opencode load so it doesn't contend with terminal
        // startup on the main thread. GhosttyKit answers the shell's startup
        // capability queries (OSC color, Kitty graphics) on a main-thread render
        // tick; if our fan-out hogs main during that window, the replies arrive
        // late and leak to the prompt as garbled text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshEnabled = true
                self?.scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        guard refreshEnabled else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func refresh() async {
        guard let client else { return }

        // Enumerate all projects, then fetch each project's sessions concurrently.
        let projects = (try? await client.listProjects()) ?? []
        var directories = Set(projects.compactMap(\.worktree))
        directories.insert(FileManager.default.homeDirectoryForCurrentUser.path) // global project
        if let active = store.selectedSession?.currentDirectory { directories.insert(active) }

        var byID: [String: OpencodeSession] = [:]
        await withTaskGroup(of: [OpencodeSession].self) { group in
            for directory in directories {
                group.addTask { (try? await client.listSessions(directory: directory)) ?? [] }
            }
            for await sessions in group {
                for session in sessions where session.parentID == nil {
                    byID[session.id] = session
                }
            }
        }

        let tops = Array(byID.values)
        let activeDir = store.selectedSession?.currentDirectory
        var groups = Dictionary(grouping: tops, by: { $0.directory ?? "—" })
            .map { OpencodeProjectGroup(directory: $0.key, sessions: $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
        groups.sort { a, b in
            if a.directory == activeDir { return true }
            if b.directory == activeDir { return false }
            return a.mostRecent > b.mostRecent
        }

        opencodeGroups = groups
        opencodeSessions = tops.sorted { $0.updatedAt > $1.updatedAt }
        for session in tops { opencodeByID[session.id] = session }
    }

    /// Opens an opencode server session in a new terminal attached to our server.
    /// If a terminal is already attached to this session, selects it instead.
    func openOpencodeSession(_ session: OpencodeSession) {
        if let existing = store.sessions.first(where: { $0.opencodeSessionID == session.id }) {
            store.selectedID = existing.id
            return
        }
        guard let baseURL = server.baseURL, let exe = server.executablePath else { return }
        var args = [exe, "attach", baseURL.absoluteString, "--session", session.id]
        if let dir = session.directory { args += ["--dir", dir] }
        store.newSession(
            command: args,
            workingDirectory: session.directory.map { URL(fileURLWithPath: $0) },
            customTitle: session.title,
            opencodeSessionID: session.id
        )
    }

    /// Creates a new opencode session (in the active terminal's directory) and
    /// opens it in an attached terminal.
    func newOpencodeSession() async {
        guard let client else { return }
        let directory = store.selectedSession?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let created = try? await client.createSession(directory: directory) else { return }
        opencodeByID[created.id] = created
        openOpencodeSession(created)
        scheduleRefresh()
    }

    /// Permanently deletes an opencode session from the server, closing any
    /// terminal attached to it.
    func deleteOpencodeSession(_ session: OpencodeSession) async {
        guard let client else { return }
        if let attached = store.sessions.first(where: { $0.opencodeSessionID == session.id }) {
            store.closeSession(attached.id)
        }
        try? await client.deleteSession(id: session.id, directory: session.directory)
        opencodeByID[session.id] = nil
        opencodeSessions.removeAll { $0.id == session.id }
        opencodeGroups = opencodeGroups.compactMap { group in
            var group = group
            group.sessions.removeAll { $0.id == session.id }
            return group.sessions.isEmpty ? nil : group
        }
        scheduleRefresh()
    }
}
