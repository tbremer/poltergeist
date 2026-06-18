import SwiftUI
import GhosttyTerminal

/// The editor-style shell: a sessions sidebar + a live terminal detail pane.
///
/// M3: multiple `TerminalSession`s managed by a `SessionStore`. Create with the
/// sidebar "+" (⌘T), switch via the sidebar, close (⌘W / context menu), rename
/// via context menu. Background sessions stay alive in a keep-alive ZStack so
/// their output is never dropped.
struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SessionStore
    @FocusState private var focusedSession: TerminalSession.ID?

    @State private var renamingID: TerminalSession.ID?
    @State private var renameText: String = ""
    @State private var pendingDelete: OpencodeSession?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .navigationTitle(store.selectedSession?.displayName ?? "Poltergeist")
                .navigationSubtitle(subtitle)
        }
        .background {
            // ⌘W closes the selected session (hidden accelerator).
            Button("") {
                if let id = store.selectedID { store.closeSession(id) }
            }
            .keyboardShortcut("w", modifiers: .command)
            .hidden()
        }
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

                if model.opencodeSessions.isEmpty {
                    Text(model.server.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.opencodeSessions) { ocSession in
                        Button {
                            model.openOpencodeSession(ocSession)
                        } label: {
                            OpencodeRow(session: ocSession)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open") { model.openOpencodeSession(ocSession) }
                            Divider()
                            Button("Delete", role: .destructive) {
                                pendingDelete = ocSession
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Poltergeist")
        .frame(minWidth: 220)
        .toolbar {
            ToolbarItem {
                Button { store.newSession() } label: {
                    Image(systemName: "plus")
                }
                .keyboardShortcut("t", modifiers: .command)
                .help("New Session (⌘T)")
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
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

    private var subtitle: String {
        store.selectedSession?.state.workingDirectory.map { dir in
            (dir as NSString).abbreviatingWithTildeInPath
        } ?? ""
    }

    // MARK: - Rename

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
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
                Text(session.displayName).lineLimit(1)
                if let opencode {
                    HStack(spacing: 5) {
                        if opencode.isRecentlyActive {
                            Circle().fill(.green).frame(width: 6, height: 6)
                        }
                        if let model = opencode.model?.id { Text(model) }
                        if let cost = opencode.cost, cost > 0 { Text(String(format: "$%.2f", cost)) }
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
            Text(session.title ?? session.id)
                .font(.callout)
                .lineLimit(1)
            HStack(spacing: 6) {
                if session.isRecentlyActive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                if let model = session.model?.id { Text(model) }
                if let cost = session.cost, cost > 0 { Text(String(format: "$%.2f", cost)) }
                Text("\(session.totalTokens) tok")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}
