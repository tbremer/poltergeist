import Foundation
import Combine
import AppKit
import GhosttyTerminal

/// Owns the set of terminal sessions and the current selection, and persists
/// session metadata across launches.
///
/// On launch it restores the previous sessions (starting fresh shells in the
/// last working directory). The live PTYs keep running while a session is in
/// the list, even when not the visible one.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: TerminalSession.ID?
    /// Per-path expansion overrides for the OpenCode sidebar tree, recorded when
    /// the user clicks a disclosure triangle. In-memory only (not persisted): each
    /// launch starts from the depth-aware default in `isExpanded`, so the tree
    /// always opens with just the top-level folder expanded.
    @Published private var expansionOverrides: [String: Bool] = [:]

    /// Per-tab pane layout. Absent means the tab is a single pane (its own
    /// session). Splits add extra `TerminalSession`s that live only in the tree
    /// (not in `sessions`, so they don't appear in the sidebar).
    @Published private(set) var paneTrees: [TerminalSession.ID: PaneNode] = [:]

    private var nextOrdinal = 1
    private let environmentOverrides: [String: String]
    private var config: AppConfig
    private var terminalTheme: TerminalTheme?
    private var cancellables = Set<AnyCancellable>()
    private var saveWork: DispatchWorkItem?

    init(
        environmentOverrides: [String: String] = [:],
        config: AppConfig = AppConfig(),
        terminalTheme: TerminalTheme? = nil
    ) {
        self.environmentOverrides = environmentOverrides
        self.config = config
        self.terminalTheme = terminalTheme
        restoreOrCreate()

        // Scrollback persistence was removed; clean up any leftover files.
        try? FileManager.default.removeItem(
            at: AppPaths.supportDirectory.appendingPathComponent("scrollback", isDirectory: true)
        )

        // Persist selection changes (e.g. clicking a sidebar row).
        $selectedID
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSave() }
            .store(in: &cancellables)

        // Persist metadata on quit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistMetadata() }
        }
    }

    var selectedSession: TerminalSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    /// Builds a terminal (PTY + surface) without inserting it anywhere. Used for
    /// both new sidebar tabs and split panes.
    private func makeSession(
        command: [String]? = nil,
        workingDirectory: URL? = nil,
        customTitle: String? = nil,
        opencodeSessionID: String? = nil
    ) -> TerminalSession {
        let session = TerminalSession(
            ordinal: nextOrdinal,
            customTitle: customTitle,
            workingDirectory: workingDirectory,
            environmentOverrides: environmentOverrides,
            command: command,
            opencodeSessionID: opencodeSessionID,
            fontFamily: config.fontFamily,
            fontSize: config.effectiveFontSize,
            theme: terminalTheme ?? .default
        )
        nextOrdinal += 1
        return session
    }

    @discardableResult
    func newSession(
        command: [String]? = nil,
        workingDirectory: URL? = nil,
        customTitle: String? = nil,
        opencodeSessionID: String? = nil
    ) -> TerminalSession {
        let session = makeSession(
            command: command,
            workingDirectory: workingDirectory,
            customTitle: customTitle,
            opencodeSessionID: opencodeSessionID
        )
        sessions.append(session)
        selectedID = session.id
        scheduleSave()
        return session
    }

    func closeSession(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)

        // Terminate the tab's session plus any split panes it owns.
        let toTerminate = paneTrees[id]?.leaves ?? [session]
        paneTrees[id] = nil
        toTerminate.forEach { $0.terminate() }

        // If we closed the selected one, select the neighbour (next, else last).
        if selectedID == id {
            let next = sessions.indices.contains(index) ? sessions[index] : sessions.last
            selectedID = next?.id
        }
        scheduleSave()
    }

    func rename(_ id: TerminalSession.ID, to title: String?) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.customTitle = title
        scheduleSave()
    }

    func selectNext() {
        guard !sessions.isEmpty else { return }
        guard let id = selectedID, let idx = sessions.firstIndex(where: { $0.id == id }) else {
            selectedID = sessions.first?.id
            return
        }
        selectedID = sessions[(idx + 1) % sessions.count].id
    }

    func selectPrevious() {
        guard !sessions.isEmpty else { return }
        guard let id = selectedID, let idx = sessions.firstIndex(where: { $0.id == id }) else {
            selectedID = sessions.last?.id
            return
        }
        selectedID = sessions[(idx - 1 + sessions.count) % sessions.count].id
    }

    // MARK: - Panes (splits)

    /// The pane layout for a tab (single leaf of the tab's own session by default).
    func tree(for tab: TerminalSession) -> PaneNode {
        paneTrees[tab.id] ?? .leaf(tab)
    }

    /// Every live terminal across all tabs (tabs + their split panes), de-duped.
    var allTerminals: [TerminalSession] {
        var seen = Set<TerminalSession.ID>()
        var result: [TerminalSession] = []
        for tab in sessions {
            for leaf in tree(for: tab).leaves where seen.insert(leaf.id).inserted {
                result.append(leaf)
            }
        }
        return result
    }

    /// The leaf the user is working in: the pane whose Ghostty surface currently
    /// holds keyboard focus, else the tab's own session. Read on demand (rather
    /// than tracked reactively) so focus changes don't churn the view tree and
    /// knock the terminal out of first-responder.
    private func focusedLeaf(in tab: TerminalSession) -> TerminalSession {
        tree(for: tab).leaves.first { $0.state.isFocused } ?? tab
    }

    /// Splits the focused pane of the selected tab, opening a new shell beside it
    /// (in the focused pane's working directory) and moving keyboard focus to it.
    func splitFocusedPane(_ axis: SplitAxis) {
        guard let tabID = selectedID, let tab = sessions.first(where: { $0.id == tabID }) else { return }
        let current = tree(for: tab)
        let target = focusedLeaf(in: tab)
        let newPane = makeSession(workingDirectory: URL(fileURLWithPath: target.currentDirectory))
        // New split takes half of the target pane's own region; existing splits
        // keep their fractions, so no other pane moves or resizes.
        let split = PaneNode.split(id: UUID(), axis: axis, fraction: 0.5, first: .leaf(target), second: .leaf(newPane))
        paneTrees[tabID] = current.replacingLeaf(target.id, with: split)
        focusSurface(of: newPane)
    }

    /// Sets the divider position of a single split (used by both divider drags
    /// and double-click-to-center, which passes 0.5). Only the matching split
    /// changes; all other dividers keep their positions. Keyboard focus returns
    /// to the active pane once the layout settles.
    func setSplitFraction(_ fraction: Double, splitID: UUID) {
        guard let tabID = selectedID, let tab = sessions.first(where: { $0.id == tabID }),
              let tree = paneTrees[tabID] else { return }
        let focused = focusedLeaf(in: tab)
        paneTrees[tabID] = tree.settingFraction(fraction, forSplit: splitID)
        focusSurface(of: focused)
    }

    /// Adding a pane rebuilds the surrounding view tree, which drops the
    /// terminal's first-responder status. Once the new surface is mounted we make
    /// it first responder so keyboard focus follows the split. This is a one-shot
    /// (not a `.terminalFocused` binding) to avoid the continuous focus-sync that
    /// otherwise swallows keystrokes in this layout.
    private func focusSurface(of session: TerminalSession, attempt: Int = 0) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           let content = window.contentView,
           let view = Self.terminalView(for: session.state, in: content) {
            window.makeFirstResponder(view)
            return
        }
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak session] in
            guard let self, let session else { return }
            self.focusSurface(of: session, attempt: attempt + 1)
        }
    }

    /// Forces every pane except `id` to relinquish Ghostty focus, so only the
    /// active pane renders a live (solid, blinking) cursor. New surfaces default
    /// to focused, and AppKit only resigns the *previous* first responder, so
    /// never-focused panes (e.g. siblings after a split) need an explicit nudge.
    /// Pure side-effect on the views — no published state changes.
    func unfocusOtherPanes(except id: TerminalSession.ID) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let content = window.contentView else { return }
        for session in allTerminals where session.id != id {
            Self.terminalView(for: session.state, in: content).map { _ = $0.resignFirstResponder() }
        }
    }

    /// Finds the Ghostty surface view bound to `state` (its delegate) within a
    /// view subtree.
    private static func terminalView(for state: TerminalViewState, in view: NSView) -> AppTerminalView? {
        if let term = view as? AppTerminalView, let delegate = term.delegate as? TerminalViewState, delegate === state {
            return term
        }
        for sub in view.subviews {
            if let found = terminalView(for: state, in: sub) { return found }
        }
        return nil
    }

    /// Closes the focused pane. With no splits this closes the whole tab; within a
    /// split it removes that pane and collapses the split into its sibling, then
    /// moves keyboard focus to a neighbouring pane.
    func closeFocusedPane() {
        guard let tabID = selectedID, let tab = sessions.first(where: { $0.id == tabID }) else { return }
        let current = tree(for: tab)

        guard !current.isSingleLeaf else {
            closeSession(tabID)
            return
        }

        let target = focusedLeaf(in: tab)
        // Guard against a stale/foreign focus target nuking the whole tab: only
        // act on a pane that's actually in this tree.
        guard let targetIndex = current.leaves.firstIndex(where: { $0.id == target.id }),
              case let result = current.removingLeaf(target.id),
              let removed = result.removed, let newTree = result.node
        else {
            return
        }
        removed.terminate()

        if removed.id == tabID {
            // The tab's own session was closed; promote a remaining pane so the
            // sidebar entry stays alive (its id becomes the tab's new id).
            guard let promoted = newTree.firstLeaf,
                  let index = sessions.firstIndex(where: { $0.id == tabID }) else { return }
            sessions[index] = promoted
            paneTrees[tabID] = nil
            paneTrees[promoted.id] = newTree.isSingleLeaf ? nil : newTree
            if selectedID == tabID { selectedID = promoted.id }
        } else {
            paneTrees[tabID] = newTree.isSingleLeaf ? nil : newTree
        }
        scheduleSave()

        // Re-focus the previous pane in the group (the neighbour before the one
        // we closed), so focus loops back instead of leaving every pane showing
        // its default cursor.
        let remaining = newTree.leaves
        if !remaining.isEmpty {
            focusSurface(of: remaining[max(0, targetIndex - 1)])
        }
    }

    /// Moves keyboard focus to the next pane (left→right, top→bottom) within the
    /// selected tab, wrapping around. ⌘].
    func focusNextPane() { cycleFocus(by: 1) }

    /// Moves keyboard focus to the previous pane (right→left, bottom→top),
    /// wrapping around. ⌘[.
    func focusPreviousPane() { cycleFocus(by: -1) }

    private func cycleFocus(by offset: Int) {
        guard let tab = selectedSession else { return }
        let leaves = tree(for: tab).leaves
        guard leaves.count > 1 else { return }
        let current = leaves.firstIndex { $0.state.isFocused } ?? 0
        let target = leaves[(current + offset + leaves.count) % leaves.count]
        focusSurface(of: target)
    }

    /// Whether a sidebar tree row is expanded. With no user override, the
    /// `defaultExpanded` value decides — callers pass `depth == 0`, so only the
    /// top-level folder opens by default; a click records an explicit override for
    /// this launch via `setExpanded`.
    func isExpanded(_ path: String, defaultExpanded: Bool) -> Bool {
        expansionOverrides[path] ?? defaultExpanded
    }

    func setExpanded(_ path: String, _ expanded: Bool) {
        expansionOverrides[path] = expanded
    }

    /// Updates the appearance applied to newly-created sessions (live reload).
    func updateAppearance(config: AppConfig, terminalTheme: TerminalTheme?) {
        self.config = config
        self.terminalTheme = terminalTheme
    }

    // MARK: - Persistence

    private func restoreOrCreate() {
        guard let state = Persistence.load(), !state.sessions.isEmpty else {
            newSession()
            return
        }

        nextOrdinal = max(state.nextOrdinal, 1)
        for ps in state.sessions {
            let session = TerminalSession(
                id: ps.id,
                ordinal: ps.ordinal,
                customTitle: ps.customTitle,
                workingDirectory: ps.workingDirectory.map { URL(fileURLWithPath: $0) },
                createdAt: ps.createdAt,
                environmentOverrides: environmentOverrides,
                fontFamily: config.fontFamily,
                fontSize: config.effectiveFontSize,
                theme: terminalTheme ?? .default
            )
            sessions.append(session)
        }

        if let sel = state.selectedID, sessions.contains(where: { $0.id == sel }) {
            selectedID = sel
        } else {
            selectedID = sessions.first?.id
        }

        // Never reuse an ordinal that's still in the list.
        nextOrdinal = max(nextOrdinal, (sessions.map(\.ordinal).max() ?? 0) + 1)
    }

    private func snapshot() -> PersistedState {
        PersistedState(
            sessions: sessions.map {
                PersistedSession(
                    id: $0.id,
                    ordinal: $0.ordinal,
                    customTitle: $0.customTitle,
                    workingDirectory: $0.currentDirectory,
                    createdAt: $0.createdAt
                )
            },
            selectedID: selectedID,
            nextOrdinal: nextOrdinal
        )
    }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.persistMetadata() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func persistMetadata() {
        Persistence.save(snapshot())
    }
}
