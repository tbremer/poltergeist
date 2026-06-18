import Foundation
import Combine
import SwiftUI
import AppKit
import GhosttyTerminal
import GhosttyTheme

/// Which system appearance a theme applies to.
enum ThemeSlot: Hashable { case light, dark }

/// Top-level app state: owns the opencode server, the terminal session store,
/// and the live opencode session list shown in the sidebar.
@MainActor
final class AppModel: ObservableObject {
    let server: OpencodeServerManager
    let store: SessionStore

    /// Resolved theme per appearance (applied to terminals + window chrome).
    @Published private(set) var lightThemeDef: GhosttyThemeDefinition?
    @Published private(set) var darkThemeDef: GhosttyThemeDefinition?
    /// True when macOS is in Dark mode (selects which slot is active).
    @Published private(set) var systemIsDark = false

    /// The theme in effect right now (for the current system appearance).
    var activeThemeDef: GhosttyThemeDefinition? { systemIsDark ? darkThemeDef : lightThemeDef }

    /// Window appearance forced to match the active theme, so text + macOS
    /// controls stay readable (light text on a dark theme, etc).
    var appearanceScheme: ColorScheme? { activeThemeDef.map { $0.isDark ? .dark : .light } }

    /// Flat list of all known opencode sessions (most recent first).
    @Published private(set) var opencodeSessions: [OpencodeSession] = []

    /// All opencode sessions grouped by working directory (active dir first).
    @Published private(set) var opencodeGroups: [OpencodeProjectGroup] = []

    /// Lookup of opencode sessions by id so terminal rows can show metadata.
    @Published private(set) var opencodeByID: [String: OpencodeSession] = [:]

    private let client: OpencodeClient?
    private var eventStream: OpencodeEventStream?
    private var cancellables = Set<AnyCancellable>()

    private var lightWork: DispatchWorkItem?
    private var lightTimer: Timer?
    private var fullTimer: Timer?
    private var refreshEnabled = false

    /// Project worktrees discovered by the full refresh, cached so light
    /// refreshes don't re-enumerate every time.
    private var cachedWorktrees: Set<String> = []

    /// Suppress refreshes until this time. Set briefly when a terminal spawns so
    /// the new shell's startup capability queries get the main thread — otherwise
    /// our fan-out delays GhosttyKit's replies and they leak to the prompt.
    private var refreshQuietUntil = Date.distantPast
    private var knownSessionCount = 0

    private var appliedConfig = AppConfig()
    private var configWatcher: ConfigWatcher?
    private var configReloadWork: DispatchWorkItem?
    private var appearanceObserver: NSObjectProtocol?

    private var homeDirectory: String { FileManager.default.homeDirectoryForCurrentUser.path }

    init() {
        let server = OpencodeServerManager()
        self.server = server

        let appConfig = AppConfig.load()
        appliedConfig = appConfig
        let isDark = Self.osIsDark()
        systemIsDark = isDark
        let defs = Self.resolveDefs(appConfig)
        lightThemeDef = defs.light
        darkThemeDef = defs.dark
        let activeDef = isDark ? defs.dark : defs.light

        // Point every terminal at the (soon-to-be-ready) shared server.
        var overrides: [String: String] = [:]
        if let base = server.baseURL {
            overrides["OPENCODE_BASE_URL"] = base.absoluteString
        }
        store = SessionStore(
            environmentOverrides: overrides,
            config: appConfig,
            terminalTheme: Self.terminalTheme(for: activeDef)
        )
        client = server.baseURL.map { OpencodeClient(baseURL: $0) }
        knownSessionCount = store.sessions.count

        server.start()

        if let base = server.baseURL {
            let stream = OpencodeEventStream(baseURL: base)
            stream.onEvent = { [weak self] in self?.scheduleLightRefresh() }
            stream.start()
            eventStream = stream
        }

        store.$selectedID
            .sink { [weak self] _ in self?.scheduleLightRefresh() }
            .store(in: &cancellables)
        // A new terminal means a shell is about to spawn and query the terminal;
        // keep the main thread free briefly so the replies aren't delayed.
        store.$sessions
            .sink { [weak self] sessions in self?.noteSessionCount(sessions.count) }
            .store(in: &cancellables)
        server.$status
            .sink { [weak self] status in if status == .running { self?.scheduleLightRefresh() } }
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

        // Frequent, cheap refresh of the active project only.
        lightTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleLightRefresh() }
        }
        // Occasional full sweep across all projects (also prunes deleted sessions).
        fullTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestFullRefresh() }
        }

        // Defer the first load so it doesn't contend with terminal startup on the
        // main thread (late capability-query replies leak to the prompt as garble).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshEnabled = true
                self?.requestFullRefresh()
            }
        }

        // Live-apply config.json changes (theme/font) without relaunch.
        let watcher = ConfigWatcher(directory: AppPaths.supportDirectory)
        watcher.onChange = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scheduleConfigReload() }
            }
        }
        watcher.start()
        configWatcher = watcher

        // React to macOS Dark/Light changes: re-pick the active theme + appearance.
        appearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.systemIsDark = Self.osIsDark()
                self.applyActiveAppearance()
            }
        }
    }

    // MARK: - Live config reload

    private func scheduleConfigReload() {
        configReloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reloadConfig() }
        }
        configReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func reloadConfig() {
        let newConfig = AppConfig.load()
        guard newConfig != appliedConfig else { return }
        applyConfig(newConfig)
    }

    var lightThemeName: String? { appliedConfig.lightTheme }
    var darkThemeName: String? { appliedConfig.darkTheme }

    private func applyConfig(_ newConfig: AppConfig) {
        appliedConfig = newConfig
        let defs = Self.resolveDefs(newConfig)
        lightThemeDef = defs.light
        darkThemeDef = defs.dark
        applyActiveAppearance()
    }

    /// Applies the active theme (for the current system appearance) to every
    /// terminal + the store. Chrome follows via `activeThemeDef`/`appearanceScheme`.
    private func applyActiveAppearance() {
        let activeDef = systemIsDark ? darkThemeDef : lightThemeDef
        let terminalTheme = Self.terminalTheme(for: activeDef)
        let fontConfig = appliedConfig.fontConfiguration()
        store.updateAppearance(config: appliedConfig, terminalTheme: terminalTheme)
        for session in store.sessions {
            session.applyAppearance(theme: terminalTheme, fontConfig: fontConfig)
        }
    }

    /// Picks a theme (nil = default) for an appearance slot; persists + live-applies.
    func selectTheme(_ name: String?, for slot: ThemeSlot) {
        var newConfig = appliedConfig
        switch slot {
        case .light: newConfig.lightTheme = name
        case .dark: newConfig.darkTheme = name
        }
        AppConfig.save(newConfig)
        applyConfig(newConfig)
    }

    private static func resolveDefs(
        _ config: AppConfig
    ) -> (light: GhosttyThemeDefinition?, dark: GhosttyThemeDefinition?) {
        let light = (config.lightTheme ?? config.theme).flatMap { GhosttyThemeCatalog.theme(named: $0) }
        let dark = (config.darkTheme ?? config.theme).flatMap { GhosttyThemeCatalog.theme(named: $0) }
        return (light, dark)
    }

    /// A TerminalTheme that shows `def` regardless of the surface's appearance.
    private static func terminalTheme(for def: GhosttyThemeDefinition?) -> TerminalTheme {
        guard let def else { return .default }
        let config = def.toTerminalConfiguration()
        return TerminalTheme(light: config, dark: config)
    }

    private static func osIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased().contains("dark") ?? false
    }

    // MARK: - Refresh scheduling

    private func noteSessionCount(_ count: Int) {
        if count > knownSessionCount {
            refreshQuietUntil = Date().addingTimeInterval(1.5)
        }
        knownSessionCount = count
    }

    private var quietDelay: TimeInterval { max(0.3, refreshQuietUntil.timeIntervalSinceNow) }

    private func scheduleLightRefresh() {
        guard refreshEnabled else { return }
        lightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.lightRefresh() }
            }
        }
        lightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietDelay, execute: work)
    }

    private func requestFullRefresh() {
        guard refreshEnabled else { return }
        // Skip while quiet; a later sweep/light refresh will catch up.
        guard refreshQuietUntil.timeIntervalSinceNow <= 0 else { return }
        Task { await fullRefresh() }
    }

    // MARK: - Refresh implementations

    /// Light: only the active terminal's project (+ attached terminals + home).
    /// Upserts into the cache so other groups are left intact.
    private func lightRefresh() async {
        var directories: Set<String> = [homeDirectory]
        if let active = store.selectedSession?.currentDirectory { directories.insert(active) }
        for session in store.sessions where session.opencodeSessionID != nil {
            directories.insert(session.currentDirectory)
        }
        let fetched = await fetchSessions(directories: directories)
        for (id, session) in fetched { opencodeByID[id] = session }
        rebuildGroups()
    }

    /// Full: enumerate all projects and replace the cache (also prunes deletions).
    private func fullRefresh() async {
        guard let client else { return }
        let projects = (try? await client.listProjects()) ?? []
        cachedWorktrees = Set(projects.compactMap(\.worktree))

        var directories = cachedWorktrees
        directories.insert(homeDirectory)
        if let active = store.selectedSession?.currentDirectory { directories.insert(active) }

        let fetched = await fetchSessions(directories: directories)
        opencodeByID = fetched
        rebuildGroups()
    }

    private func fetchSessions(directories: Set<String>) async -> [String: OpencodeSession] {
        guard let client else { return [:] }
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
        return byID
    }

    private func rebuildGroups() {
        let tops = Array(opencodeByID.values)
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
    }

    // MARK: - Actions

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
        let directory = store.selectedSession?.currentDirectory ?? homeDirectory
        guard let created = try? await client.createSession(directory: directory) else { return }
        opencodeByID[created.id] = created
        openOpencodeSession(created)
        scheduleLightRefresh()
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
        scheduleLightRefresh()
    }

    /// Renames an opencode session server-side (PATCH), with an optimistic
    /// local update so the sidebar reflects it immediately.
    func renameOpencodeSession(_ session: OpencodeSession, to title: String) async {
        guard let client else { return }
        try? await client.updateSessionTitle(id: session.id, title: title, directory: session.directory)

        if var existing = opencodeByID[session.id] {
            existing.title = title
            opencodeByID[session.id] = existing
        }
        opencodeSessions = opencodeSessions.map { retitled($0, ifID: session.id, to: title) }
        opencodeGroups = opencodeGroups.map { group in
            var group = group
            group.sessions = group.sessions.map { retitled($0, ifID: session.id, to: title) }
            return group
        }
        if let attached = store.sessions.first(where: { $0.opencodeSessionID == session.id }) {
            store.rename(attached.id, to: title)
        }
        scheduleLightRefresh()
    }

    private func retitled(_ session: OpencodeSession, ifID id: String, to title: String) -> OpencodeSession {
        guard session.id == id else { return session }
        var copy = session
        copy.title = title
        return copy
    }
}
