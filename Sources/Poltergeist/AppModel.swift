import Foundation
import Combine
import SwiftUI
import AppKit
import GhosttyTerminal
import GhosttyTheme
import KeyboardShortcuts

/// Which system appearance a theme applies to.
enum ThemeSlot: Hashable { case light, dark }

extension KeyboardShortcuts.Name {
    /// Global hotkey to summon/hide Poltergeist from anywhere (system-wide).
    static let togglePoltergeist = Self(
        "togglePoltergeist",
        initial: .init(.p, modifiers: [.control, .option, .command])
    )

    // App-local shortcuts. These are NOT registered as global hotkeys (no
    // `onKeyUp`/`onKeyDown` handler) — AppModel's key monitor matches events
    // against them while the main window is focused. Defaults mirror the
    // previous hardcoded bindings; all are rebindable in Settings → Keyboard.
    static let newTerminal = Self("newTerminal", initial: .init(.t, modifiers: [.command]))
    static let newOpencodeSession = Self("newOpencodeSession", initial: .init(.t, modifiers: [.command, .shift]))
    static let nextSession = Self("nextSession", initial: .init(.rightBracket, modifiers: [.command, .shift]))
    static let previousSession = Self("previousSession", initial: .init(.leftBracket, modifiers: [.command, .shift]))
    static let splitRight = Self("splitRight", initial: .init(.d, modifiers: [.command]))
    static let splitDown = Self("splitDown", initial: .init(.d, modifiers: [.command, .shift]))
    static let focusNextPane = Self("focusNextPane", initial: .init(.rightBracket, modifiers: [.command]))
    static let focusPreviousPane = Self("focusPreviousPane", initial: .init(.leftBracket, modifiers: [.command]))
    static let toggleSidebar = Self("toggleSidebar", initial: .init(.b, modifiers: [.command, .option]))
}

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

    /// Inactive-pane dimming options (applied to unfocused panes in a split).
    @Published private(set) var dimInactivePanes: Bool = true
    @Published private(set) var inactivePaneDim: Double = 0.5  // user-facing 0…1

    /// Maps the user-facing 0…1 amount onto the usable 5%…95% dim band, so
    /// inactive panes are never fully invisible nor imperceptibly dimmed.
    var effectiveInactiveDim: Double { 0.05 + inactivePaneDim * 0.9 }

    /// Terminal font (nil family = libghostty's default). Applied live + used for
    /// new sessions.
    @Published private(set) var fontFamily: String?
    @Published private(set) var fontSize: Float = 14

    /// The theme in effect right now (for the current system appearance).
    var activeThemeDef: GhosttyThemeDefinition? { systemIsDark ? darkThemeDef : lightThemeDef }

    /// Window appearance forced to match the active theme, so text + macOS
    /// controls stay readable (light text on a dark theme, etc).
    var appearanceScheme: ColorScheme? { activeThemeDef.map { $0.isDark ? .dark : .light } }

    /// Flat list of all known opencode sessions (most recent first).
    @Published private(set) var opencodeSessions: [OpencodeSession] = []

    /// Project file-tree for the sidebar (folders nest; sessions are leaves).
    @Published private(set) var projectTree: [ProjectTreeNode] = []

    /// Lookup of opencode sessions by id so terminal rows can show metadata.
    @Published private(set) var opencodeByID: [String: OpencodeSession] = [:]

    /// Bumped to request opening the Settings window (⌘,); RootView observes this
    /// and invokes the SwiftUI `openSettings` environment action.
    @Published private(set) var openSettingsNonce = 0

    private let client: OpencodeClient?
    private var eventStream: OpencodeEventStream?
    private var cancellables = Set<AnyCancellable>()

    private var refreshWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    /// When the last refresh ran, to throttle the periodic poll (15s with a
    /// visible window, 30s when headless). User/SSE-driven refreshes ignore this.
    private var lastRefreshAt = Date.distantPast

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
        dimInactivePanes = appConfig.effectiveDimInactivePanes
        inactivePaneDim = appConfig.effectiveInactivePaneDim
        fontFamily = appConfig.fontFamily
        fontSize = appConfig.effectiveFontSize
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

        // Show last launch's sessions instantly; the background refresh reconciles
        // once the server is up. Give the restored terminal's startup a head start
        // before the first fetch contends for the main thread.
        hydrateOpencodeCache()
        refreshQuietUntil = Date().addingTimeInterval(2.0)

        server.start()

        if let base = server.baseURL {
            let stream = OpencodeEventStream(baseURL: base)
            stream.onEvent = { [weak self] in self?.scheduleRefresh() }
            stream.start()
            eventStream = stream
        }

        store.$selectedID
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        // A new terminal means a shell is about to spawn and query the terminal;
        // keep the main thread free briefly so the replies aren't delayed.
        store.$sessions
            .sink { [weak self] sessions in self?.noteSessionCount(sessions.count) }
            .store(in: &cancellables)
        // Refresh as soon as the server reports ready (don't wait for the timer).
        server.$status
            .sink { [weak self] status in if status == .running { self?.scheduleRefresh() } }
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
            MainActor.assumeIsolated {
                // Flush the latest in-memory list (no network — the request
                // wouldn't finish before exit, and the server is about to stop).
                self?.saveOpencodeCache()
                self?.server.stop()
            }
        }

        // Periodic reconcile (also catches sessions created in other tools).
        // Fires every 15s but only polls every 30s while no window is visible.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickRefresh() }
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

        // System-wide hotkey to summon/hide the app (configurable in Settings).
        KeyboardShortcuts.onKeyUp(for: .togglePoltergeist) { [weak self] in
            MainActor.assumeIsolated { self?.toggleAppVisibility() }
        }

        installShortcutMonitor()
    }

    // MARK: - Global hotkey

    /// Quake-style toggle: hide the app if it's frontmost, otherwise bring it
    /// (and a key window) to the front.
    func toggleAppVisibility() {
        if NSApp.isActive {
            NSApp.hide(nil)
        } else {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: - Terminal shortcut interception

    private var shortcutMonitor: Any?

    /// Toggles the sessions sidebar (⌘K ⌘B). Uses the same AppKit responder
    /// action as the native toolbar toggle, which reliably collapses/expands the
    /// NavigationSplitView's sidebar column.
    func toggleSidebar() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

    /// Requests opening the Settings window (see `openSettingsNonce`).
    func requestOpenSettings() { openSettingsNonce &+= 1 }

    /// True when a content window is on screen (false when closed, hidden, or
    /// minimized) — used to slow the background poll.
    private static func hasVisibleWindow() -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeKey }
    }

    /// True if `window` contains a Ghostty terminal surface anywhere in its view
    /// tree — i.e. it's our main window rather than Settings/an alert panel.
    private static func windowHostsTerminal(_ window: NSWindow?) -> Bool {
        guard let root = window?.contentView else { return false }
        func search(_ view: NSView) -> Bool {
            if view is AppTerminalView { return true }
            return view.subviews.contains(where: search)
        }
        return search(root)
    }

    /// A focused Ghostty surface treats ⌘D/⌘W/etc. as its own key bindings and
    /// swallows them via `performKeyEquivalent` before the menu can act. A local
    /// key monitor runs *earlier* in event dispatch, so we claim the app's
    /// terminal-context shortcuts here and let every other keystroke fall through
    /// to the terminal untouched.
    private func installShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleTerminalShortcut(event) }
            return handled ? nil : event
        }
    }

    /// Handles one of the app's known shortcuts when the main terminal window is
    /// key. Returns true if the event was consumed. We gate on the *window*
    /// hosting a terminal — not on a terminal being first responder — because a
    /// pane close briefly drops first-responder while the tree rebuilds; gating
    /// on first-responder there would let ⌘W fall through to the default Close
    /// Window (which, being the last window, quits the whole app). Settings and
    /// other windows host no terminal, so they keep default behaviour.
    private func handleTerminalShortcut(_ event: NSEvent) -> Bool {
        // Every shortcut carries ⌘/⌥/⌃, so plain typing skips all of this work
        // (no window search, no shortcut lookups).
        guard !event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              Self.windowHostsTerminal(NSApp.keyWindow)
        else { return false }

        let fresh = !event.isARepeat  // only act on the initial press; swallow repeats

        // User-configurable shortcuts (Settings → Keyboard).
        if matches(event, .newTerminal) { if fresh { store.newSession() }; return true }
        if matches(event, .newOpencodeSession) {
            if fresh, server.isReady { Task { await newOpencodeSession() } }
            return true
        }
        if matches(event, .nextSession) { if fresh { store.selectNext() }; return true }
        if matches(event, .previousSession) { if fresh { store.selectPrevious() }; return true }
        if matches(event, .splitRight) { if fresh { store.splitFocusedPane(.sideBySide) }; return true }
        if matches(event, .splitDown) { if fresh { store.splitFocusedPane(.stacked) }; return true }
        if matches(event, .focusNextPane) { if fresh { store.focusNextPane() }; return true }
        if matches(event, .focusPreviousPane) { if fresh { store.focusPreviousPane() }; return true }
        if matches(event, .toggleSidebar) { if fresh { toggleSidebar() }; return true }

        // Fixed shortcuts (not configurable). Key codes (ANSI): W=13, comma=43, Q=12.
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.contains(.command), mods.isDisjoint(with: [.option, .control]) else { return false }
        let shift = mods.contains(.shift)
        switch event.keyCode {
        case 13:  // ⌘W close pane / ⌘⇧W close window
            if fresh { if shift { NSApp.keyWindow?.close() } else { store.closeFocusedPane() } }
            return true
        case 43 where !shift:  // ⌘, — Settings
            if fresh { requestOpenSettings() }
            return true
        case 12 where !shift:  // ⌘Q — quit
            if fresh { NSApp.terminate(nil) }
            return true
        case 9 where !shift:  // ⌘V — paste a clipboard file reference as its path (Ghostty parity)
            // Only claim ⌘V when the clipboard holds file URLs (e.g. a CleanShot
            // screenshot, copied as a file with no plain-text string). Plain-text
            // ⌘V returns false and falls through to libghostty's own paste.
            guard let paste = Self.clipboardFilePaste() else { return false }
            if fresh { store.sendToFocusedPane(paste) }
            return true
        default:
            return false
        }
    }

    /// Whether `event` matches the (configurable) shortcut bound to `name`.
    private func matches(_ event: NSEvent, _ name: KeyboardShortcuts.Name) -> Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return false }
        return KeyboardShortcuts.Shortcut(event: event) == shortcut
    }

    /// Ghostty-parity ⌘V: when the pasteboard holds file references — CleanShot X
    /// and similar utilities copy a screenshot as a `public.file-url` with no
    /// plain-text string, which libghostty's `.string`-only paste drops — return
    /// their shell-escaped paths joined by spaces. Returns nil when there are no
    /// file URLs, so ordinary text ⌘V falls through to libghostty's paste (keeping
    /// bracketed paste + paste protection). Mirrors Ghostty's
    /// `NSPasteboard.getOpinionatedStringContents()`. opencode turns the pasted
    /// path into an image attachment; a shell just receives the path.
    private static func clipboardFilePaste() -> String? {
        let pasteboard = NSPasteboard.general
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return nil }
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return nil }
        return files.map { shellEscape($0.path) }.joined(separator: " ")
    }

    /// Backslash-escapes shell-sensitive characters so a path can be inserted into
    /// a live terminal buffer. Mirrors Ghostty's `Shell.escape`; opencode reverses
    /// it (`\X` → `X`) when turning a pasted path into an attachment. Backslash is
    /// escaped first (it leads the set) so we don't double-escape what we add.
    private static func shellEscape(_ string: String) -> String {
        var result = string
        for character in "\\ ()[]{}<>\"'`!#$&;|*?\t" {
            result = result.replacingOccurrences(of: String(character), with: "\\\(character)")
        }
        return result
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
        dimInactivePanes = newConfig.effectiveDimInactivePanes
        inactivePaneDim = newConfig.effectiveInactivePaneDim
        fontFamily = newConfig.fontFamily
        fontSize = newConfig.effectiveFontSize
        let defs = Self.resolveDefs(newConfig)
        lightThemeDef = defs.light
        darkThemeDef = defs.dark
        applyActiveAppearance()
    }

    // Inactive-pane dimming setters (persist + live-apply).

    func setDimInactivePanes(_ on: Bool) {
        var c = appliedConfig
        c.dimInactivePanes = on
        appliedConfig = c
        AppConfig.save(c)
        dimInactivePanes = on
    }

    func setInactivePaneDim(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        var c = appliedConfig
        c.inactivePaneDim = clamped
        appliedConfig = c
        AppConfig.save(c)
        inactivePaneDim = clamped
    }

    /// Sets the terminal font family (nil/empty = libghostty default); persists
    /// + live-applies to every open terminal.
    func setFontFamily(_ family: String?) {
        var c = appliedConfig
        let trimmed = family?.trimmingCharacters(in: .whitespaces)
        c.fontFamily = (trimmed?.isEmpty ?? true) ? nil : trimmed
        applyFontConfig(c)
    }

    /// Sets the terminal font size (points); persists + live-applies.
    func setFontSize(_ size: Float) {
        var c = appliedConfig
        c.fontSize = min(max(size, 6), 72)
        applyFontConfig(c)
    }

    private func applyFontConfig(_ newConfig: AppConfig) {
        appliedConfig = newConfig
        fontFamily = newConfig.fontFamily
        fontSize = newConfig.effectiveFontSize
        AppConfig.save(newConfig)
        applyActiveAppearance()
    }

    /// Applies the active theme (for the current system appearance) to every
    /// terminal + the store. Chrome follows via `activeThemeDef`/`appearanceScheme`.
    private func applyActiveAppearance() {
        let activeDef = systemIsDark ? darkThemeDef : lightThemeDef
        let terminalTheme = Self.terminalTheme(for: activeDef)
        let fontConfig = appliedConfig.fontConfiguration()
        store.updateAppearance(config: appliedConfig, terminalTheme: terminalTheme)
        for session in store.allTerminals {
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

    /// Periodic poll from the timer: skips unless enough time has passed for the
    /// current cadence (15s with a window on screen, 30s when headless).
    private func tickRefresh() {
        let minInterval: TimeInterval = Self.hasVisibleWindow() ? 15 : 30
        guard Date().timeIntervalSince(lastRefreshAt) >= minInterval - 1 else { return }
        scheduleRefresh()
    }

    /// Debounced refresh. Coalesces the bursts of SSE events + selection changes
    /// and waits out the quiet window so it never contends with terminal startup.
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietDelay, execute: work)
    }

    // MARK: - Refresh implementation

    /// Loads every top-level session in one request and groups them by directory
    /// in `rebuildTree`. Bails without touching the cache when the server is
    /// unreachable, so a transient failure never blanks the sidebar. Persists the
    /// result so the next launch can show it instantly.
    private func refresh() async {
        lastRefreshAt = Date()  // mark the poll time for the timer's cadence gate
        guard let client else { return }
        guard let sessions = try? await client.listSessions(directory: nil) else { return }
        var byID: [String: OpencodeSession] = [:]
        for session in sessions where session.parentID == nil {
            byID[session.id] = session
        }
        opencodeByID = byID
        rebuildTree()
        saveOpencodeCache()
    }

    // MARK: - Session cache (instant sidebar on next launch)

    private func hydrateOpencodeCache() {
        guard let data = try? Data(contentsOf: AppPaths.opencodeCacheFile),
              let sessions = try? JSONDecoder().decode([OpencodeSession].self, from: data)
        else { return }
        opencodeByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        rebuildTree()
    }

    private func saveOpencodeCache() {
        guard let data = try? JSONEncoder().encode(Array(opencodeByID.values)) else { return }
        try? data.write(to: AppPaths.opencodeCacheFile, options: .atomic)
    }

    private func rebuildTree() {
        let tops = Array(opencodeByID.values)
        opencodeSessions = tops.sorted { $0.updatedAt > $1.updatedAt }
        projectTree = Self.buildTree(from: tops, homeDirectory: homeDirectory)
    }

    /// Builds the sidebar file-tree from session directories. The home prefix is
    /// flattened away (top level shows the folders directly under ~), folders are
    /// ordered like a file tree, and each node's own sessions are recency-sorted.
    private static func buildTree(from sessions: [OpencodeSession], homeDirectory: String) -> [ProjectTreeNode] {
        final class Builder {
            let path: String
            let name: String
            var children: [String: Builder] = [:]
            var sessions: [OpencodeSession] = []
            init(path: String, name: String) { self.path = path; self.name = name }
        }

        let root = Builder(path: "", name: "")
        func child(of parent: Builder, name: String, path: String) -> Builder {
            if let existing = parent.children[name] { return existing }
            let node = Builder(path: path, name: name)
            parent.children[name] = node
            return node
        }

        for (directory, group) in Dictionary(grouping: sessions, by: { $0.directory ?? "—" }) {
            // The chain of (displayName, absolutePath) from a top-level node down
            // to this directory's node.
            var chain: [(name: String, path: String)] = []
            if directory == "—" {
                chain = [("Unknown", "—")]
            } else if directory == homeDirectory {
                chain = [("~", homeDirectory)]
            } else if directory.hasPrefix(homeDirectory + "/") {
                // Nest home-relative projects under a single "~" root node.
                chain = [("~", homeDirectory)]
                var accumulated = homeDirectory
                for component in directory.dropFirst(homeDirectory.count + 1).split(separator: "/").map(String.init) {
                    accumulated += "/" + component
                    chain.append((component, accumulated))
                }
            } else {
                let components = directory.split(separator: "/").map(String.init)
                var accumulated = ""
                for (index, component) in components.enumerated() {
                    accumulated += "/" + component
                    // Prefix the top-level non-home component with "/" so it reads
                    // as an absolute path, not a home-relative folder.
                    chain.append((index == 0 ? "/" + component : component, accumulated))
                }
                if components.isEmpty { chain = [("/", "/")] }  // directory == "/"
            }

            var node = root
            for step in chain {
                node = child(of: node, name: step.name, path: step.path)
            }
            node.sessions = group
        }

        func convert(_ builder: Builder) -> ProjectTreeNode {
            ProjectTreeNode(
                path: builder.path,
                name: builder.name,
                children: builder.children.values
                    .map(convert)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                sessions: builder.sessions.sorted { $0.updatedAt > $1.updatedAt }
            )
        }

        return root.children.values
            .map(convert)
            .sorted { a, b in
                // Unknown-directory node sinks to the bottom; others by path order.
                if a.name == "Unknown" { return false }
                if b.name == "Unknown" { return true }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
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
        rebuildTree()
        openOpencodeSession(created)
        scheduleRefresh()
    }

    /// Permanently deletes an opencode session from the server, closing any
    /// terminal attached to it.
    func deleteOpencodeSession(_ session: OpencodeSession) async {
        await removeOpencodeSessions([session])
    }

    /// Permanently deletes the opencode sessions with the given ids (used by the
    /// sidebar's per-project "delete all" and select & delete mode).
    func deleteOpencodeSessions(ids: Set<String>) async {
        await removeOpencodeSessions(ids.compactMap { opencodeByID[$0] })
    }

    /// Shared deletion: closes any attached terminals, removes the sessions
    /// server-side, then rebuilds the tree from the updated cache.
    private func removeOpencodeSessions(_ sessions: [OpencodeSession]) async {
        guard let client, !sessions.isEmpty else { return }
        for session in sessions {
            if let attached = store.sessions.first(where: { $0.opencodeSessionID == session.id }) {
                store.closeSession(attached.id)
            }
            try? await client.deleteSession(id: session.id, directory: session.directory)
            opencodeByID[session.id] = nil
        }
        rebuildTree()
        scheduleRefresh()
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
        if let attached = store.sessions.first(where: { $0.opencodeSessionID == session.id }) {
            store.rename(attached.id, to: title)
        }
        rebuildTree()
        scheduleRefresh()
    }
}
