import SwiftUI
import GhosttyTerminal
import GhosttyTheme

/// The editor-style shell: a sessions sidebar + a live terminal detail pane.
///
/// M3: multiple `TerminalSession`s managed by a `SessionStore`. Create with the
/// sidebar "+" (⌘T), switch via the sidebar, close (⌘W / context menu), rename
/// via context menu. Background sessions stay alive in a keep-alive ZStack so
/// their output is never dropped.
struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SessionStore

    @State private var renamingID: TerminalSession.ID?
    @State private var renameText: String = ""
    @State private var pendingDelete: OpencodeSession?
    @State private var pendingDeleteGroup: OpencodeProjectGroup?
    @State private var renamingOpencode: OpencodeSession?
    @State private var opencodeRenameText: String = ""

    /// Per-project select & delete mode: the directory currently being edited
    /// (nil = off) and the set of chosen opencode session ids.
    @State private var selectionProject: String?
    @State private var selectedSessionIDs: Set<String> = []
    @State private var confirmingDeleteSelection = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .modifier(ThemedSidebarBackground(color: themeBackground))
        } detail: {
            TerminalDetailView(store: store)
                .navigationTitle(store.selectedSession?.displayName ?? "Poltergeist")
                .navigationSubtitle(subtitle)
        }
        .preferredColorScheme(model.appearanceScheme)
        .alert("Rename Session", isPresented: renamingBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Save") { commitRename() }
        }
        .confirmationDialog(
            "Delete opencode session?",
            isPresented: deleteConfirmBinding,
            presenting: pendingDelete
        ) { session in
            Button("Delete", role: .destructive) {
                Task { await model.deleteOpencodeSession(session) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { session in
            Text("“\(session.title ?? session.id)” will be permanently removed from opencode.")
        }
        .confirmationDialog(
            "Delete all sessions for this project?",
            isPresented: deleteGroupConfirmBinding,
            presenting: pendingDeleteGroup
        ) { group in
            Button("Delete \(group.sessions.count) Sessions", role: .destructive) {
                Task { await model.deleteAllOpencodeSessions(in: group) }
                pendingDeleteGroup = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteGroup = nil }
        } message: { group in
            Text("All \(group.sessions.count) opencode sessions in “\(group.displayName)” will be permanently removed from opencode.")
        }
        .confirmationDialog(
            "Delete selected sessions?",
            isPresented: $confirmingDeleteSelection
        ) {
            Button("Delete \(selectedSessionIDs.count) Sessions", role: .destructive) {
                let ids = selectedSessionIDs
                Task { await model.deleteOpencodeSessions(ids: ids) }
                exitSelectMode()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The \(selectedSessionIDs.count) selected opencode sessions will be permanently removed from opencode.")
        }
        .alert("Rename opencode session", isPresented: opencodeRenameBinding) {
            TextField("Title", text: $opencodeRenameText)
            Button("Cancel", role: .cancel) { renamingOpencode = nil }
            Button("Save") { commitOpencodeRename() }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $store.selectedID) {
            Section("Sessions") {
                ForEach(store.sessions) { session in
                    SessionRow(
                        session: session,
                        opencode: session.opencodeSessionID.flatMap { model.opencodeByID[$0] }
                    )
                    .tag(session.id)
                    .contextMenu {
                        Button("Rename…") { beginRename(session) }
                        Button("Close", role: .destructive) {
                            store.closeSession(session.id)
                        }
                    }
                }
            }

            Section("OpenCode") {
                Button {
                    Task { await model.newOpencodeSession() }
                } label: {
                    Label("New session", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .disabled(!model.server.isReady)

                if model.opencodeGroups.isEmpty {
                    Text(model.server.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(model.opencodeGroups) { group in
                projectSection(group)
            }
        }
        .navigationTitle("Poltergeist")
        .frame(minWidth: 220)
        .toolbar {
            ToolbarItem {
                Button { store.newSession() } label: {
                    Image(systemName: "plus")
                }
                .help("New Terminal (⌘T)")
            }
        }
    }

    private var subtitle: String {
        store.selectedSession?.state.workingDirectory.map { dir in
            (dir as NSString).abbreviatingWithTildeInPath
        } ?? ""
    }

    /// Sidebar tint derived from the active theme's background (nil = default chrome).
    private var themeBackground: Color? {
        model.activeThemeDef.flatMap { Color(hexRGB: $0.background) }
    }

    // MARK: - Project sections

    @ViewBuilder
    private func projectSection(_ group: OpencodeProjectGroup) -> some View {
        let selecting = selectionProject == group.directory
        let expanded = store.expandedGroups.contains(group.directory) || selecting
        Section {
            if expanded {
                ForEach(group.sessions) { ocSession in
                    opencodeSessionRow(ocSession, selecting: selecting)
                }
            }
        } header: {
            projectHeader(group, selecting: selecting)
        }
    }

    @ViewBuilder
    private func opencodeSessionRow(_ ocSession: OpencodeSession, selecting: Bool) -> some View {
        Button {
            if selecting {
                toggleSelection(ocSession.id)
            } else {
                model.openOpencodeSession(ocSession)
            }
        } label: {
            HStack(spacing: 8) {
                if selecting {
                    let on = selectedSessionIDs.contains(ocSession.id)
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? Color.accentColor : Color.secondary)
                }
                OpencodeRow(session: ocSession)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { model.openOpencodeSession(ocSession) }
            Button("Rename…") { beginOpencodeRename(ocSession) }
            Divider()
            Button("Delete", role: .destructive) { pendingDelete = ocSession }
        }
    }

    @ViewBuilder
    private func projectHeader(_ group: OpencodeProjectGroup, selecting: Bool) -> some View {
        if selecting {
            HStack(spacing: 8) {
                Text(group.displayName).lineLimit(1)
                Spacer(minLength: 4)
                Button("Delete (\(selectedSessionIDs.count))", role: .destructive) {
                    confirmingDeleteSelection = true
                }
                .disabled(selectedSessionIDs.isEmpty)
                Button("Done") { exitSelectMode() }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        } else {
            let expanded = store.expandedGroups.contains(group.directory)
            Button {
                store.setGroupExpanded(group.directory, !expanded)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(group.displayName).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(group.sessions.count)").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Select Sessions") { enterSelectMode(group) }
                    .disabled(group.sessions.isEmpty)
                Button("Delete All Sessions…", role: .destructive) {
                    pendingDeleteGroup = group
                }
                .disabled(group.sessions.isEmpty)
            }
        }
    }

    private func enterSelectMode(_ group: OpencodeProjectGroup) {
        selectionProject = group.directory
        selectedSessionIDs = []
        store.setGroupExpanded(group.directory, true)
    }

    private func exitSelectMode() {
        selectionProject = nil
        selectedSessionIDs = []
    }

    private func toggleSelection(_ id: String) {
        if selectedSessionIDs.contains(id) {
            selectedSessionIDs.remove(id)
        } else {
            selectedSessionIDs.insert(id)
        }
    }

    // MARK: - Rename

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteGroupConfirmBinding: Binding<Bool> {
        Binding(get: { pendingDeleteGroup != nil }, set: { if !$0 { pendingDeleteGroup = nil } })
    }

    private var opencodeRenameBinding: Binding<Bool> {
        Binding(get: { renamingOpencode != nil }, set: { if !$0 { renamingOpencode = nil } })
    }


    private func beginOpencodeRename(_ session: OpencodeSession) {
        renamingOpencode = session
        opencodeRenameText = session.title ?? ""
    }

    private func commitOpencodeRename() {
        guard let session = renamingOpencode else { return }
        let trimmed = opencodeRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Task { await model.renameOpencodeSession(session, to: trimmed) }
        }
        renamingOpencode = nil
    }

    private func beginRename(_ session: TerminalSession) {
        renamingID = session.id
        renameText = session.customTitle ?? session.displayName
    }

    private func commitRename() {
        if let id = renamingID {
            let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            store.rename(id, to: trimmed.isEmpty ? nil : trimmed)
        }
        renamingID = nil
    }
}

/// The terminal area. Observes only `store`, so opencode/server refreshes (the
/// 4s timer + SSE) don't re-render the live terminal surfaces — which was
/// stealing keyboard focus mid-keystroke.
private struct TerminalDetailView: View {
    @ObservedObject var store: SessionStore
    @FocusState private var focusedSession: TerminalSession.ID?

    var body: some View {
        if store.sessions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No sessions").font(.title3)
                Text("Press ⌘T to create one").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Keep every surface in the hierarchy so background sessions keep
            // rendering/receiving; only the selected one is visible + focused.
            ZStack {
                ForEach(store.sessions) { session in
                    TerminalSurfaceView(context: session.state)
                        .terminalFocused($focusedSession, equals: session.id)
                        .opacity(session.id == store.selectedID ? 1 : 0)
                        .allowsHitTesting(session.id == store.selectedID)
                }
            }
            .onChange(of: store.selectedID) { _, newValue in
                focusedSession = newValue
            }
            .onAppear { focusedSession = store.selectedID }
        }
    }
}

/// Tints the sidebar to the theme background (and hides the default material)
/// when a theme is active; otherwise leaves the default chrome untouched.
private struct ThemedSidebarBackground: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color {
            content
                .scrollContentBackground(.hidden)
                .background(color)
        } else {
            content
        }
    }
}

/// One row in the sessions sidebar. Observes its session so the name updates
/// live as the shell sets its title or the user renames it.
private struct SessionRow: View {
    @ObservedObject var session: TerminalSession
    let opencode: OpencodeSession?

    private var isOpencode: Bool { session.opencodeSessionID != nil }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isOpencode ? "sparkles" : "terminal")
                .foregroundStyle(isOpencode ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.displayName).lineLimit(1)
                    if opencode?.isStale == true {
                        Image(systemName: "moon.zzz.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("No activity in over 30 days")
                    }
                }
                if let opencode {
                    HStack(spacing: 5) {
                        if opencode.isRecentlyActive {
                            Circle().fill(.green).frame(width: 6, height: 6)
                        }
                        if let model = opencode.model?.id { Text(model) }
                        if let cost = opencode.cost, cost > 0 { Text(String(format: "$%.2f", cost)) }
                        if let updated = opencode.updatedRelative { Text(updated) }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
    }
}

/// One row in the sidebar's OpenCode section — a server session with quick stats.
private struct OpencodeRow: View {
    let session: OpencodeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(session.title ?? session.id)
                    .font(.callout)
                    .lineLimit(1)
                if session.isStale {
                    Spacer(minLength: 4)
                    Image(systemName: "moon.zzz.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("No activity in over 30 days")
                }
            }
            HStack(spacing: 6) {
                if session.isRecentlyActive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                if let model = session.model?.id { Text(model) }
                if let cost = session.cost, cost > 0 { Text(String(format: "$%.2f", cost)) }
                Text("\(session.totalTokens) tok")
                if let updated = session.updatedRelative { Text(updated) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}
