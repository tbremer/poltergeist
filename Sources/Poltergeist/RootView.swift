import AppKit
import GhosttyTerminal
import GhosttyTheme
import SwiftUI

/// The editor-style shell: a sessions sidebar + a live terminal detail pane.
///
/// M3: multiple `TerminalSession`s managed by a `SessionStore`. Create with the
/// sidebar "+" (⌘T), switch via the sidebar, close (⌘W / context menu), rename
/// via context menu. Background sessions stay alive in a keep-alive ZStack so
/// their output is never dropped.
struct RootView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var store: SessionStore

  @Environment(\.openSettings) private var openSettings

  @State private var renamingID: TerminalSession.ID?
  @State private var renameText: String = ""
  @State private var pendingDelete: OpencodeSession?
  @State private var pendingDeleteProject: ProjectTreeNode?
  @State private var renamingOpencode: OpencodeSession?
  @State private var opencodeRenameText: String = ""

  /// Per-project select & delete mode: the directory currently being edited
  /// (nil = off) and the set of chosen opencode session ids.
  @State private var selectionProject: String?
  @State private var selectedSessionIDs: Set<String> = []
  @State private var confirmingDeleteSelection = false
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
        .modifier(ThemedSidebarBackground(color: themeBackground))
    } detail: {
      TerminalDetailView(store: store, dimming: paneDimming)
        .navigationTitle(store.selectedSession?.displayName ?? "Poltergeist")
        .navigationSubtitle(subtitle)
      // Collapsed: New Terminal rides next to the relocated native
      // sidebar toggle by the traffic lights (Notes-style).
      // .toolbar {
      //   if columnVisibility == .detailOnly {
      //     ToolbarItem(placement: .navigation) { newTerminalButton }
      //   }
      // }
    }
    .preferredColorScheme(model.appearanceScheme)
    .background(WindowChromeConfigurator(backgroundColor: themeBackground))
    .onChange(of: model.openSettingsNonce) { _, _ in openSettings() }
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
      isPresented: deleteProjectConfirmBinding,
      presenting: pendingDeleteProject
    ) { project in
      Button("Delete \(project.sessions.count) Sessions", role: .destructive) {
        let ids = Set(project.sessions.map(\.id))
        Task { await model.deleteOpencodeSessions(ids: ids) }
        pendingDeleteProject = nil
      }
      Button("Cancel", role: .cancel) { pendingDeleteProject = nil }
    } message: { project in
      Text(
        "All \(project.sessions.count) opencode sessions in “\(folderLabel(project))” will be permanently removed from opencode."
      )
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
      Text(
        "The \(selectedSessionIDs.count) selected opencode sessions will be permanently removed from opencode."
      )
    }
    .alert("Rename opencode session", isPresented: opencodeRenameBinding) {
      TextField("Title", text: $opencodeRenameText)
      Button("Cancel", role: .cancel) { renamingOpencode = nil }
      Button("Save") { commitOpencodeRename() }
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    let openCodeExpanded = store.isExpanded(Self.openCodeSectionKey)
    return List(selection: $store.selectedID) {
      Section("Sessions") {
        ForEach(store.sessions) { session in
          SessionRow(
            session: session,
            opencode: session.opencodeSessionID.flatMap { model.opencodeByID[$0] },
            onClose: { store.closeSession(session.id) }
          )
          .tag(session.id)
          .modifier(MiddleClickClose { store.closeSession(session.id) })
          .contextMenu {
            Button("Rename…") { beginRename(session) }
            Button("Close", role: .destructive) {
              store.closeSession(session.id)
            }
          }
        }
      }

      // OpenCode section: a collapsible header + the project tree. When
      // collapsed it's pinned to the bottom of the sidebar (safeAreaInset).
      if openCodeExpanded {
        Divider()
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
        openCodeHeaderButton(expanded: true)
        if model.projectTree.isEmpty {
          Text(model.server.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(sidebarItems) { item in
          sidebarRow(item)
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if !openCodeExpanded {
        VStack(spacing: 0) {
          Divider()
          openCodeHeaderButton(expanded: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
      }
    }
    .navigationTitle("Poltergeist")
    .frame(minWidth: 220)
    // Keep the system sidebar toggle (it sits at the sidebar's trailing edge
    // with the default styling and relocates by the traffic lights when
    // collapsed). New Terminal joins it there with default placement.
    .toolbar {
      ToolbarItem {
        newTerminalButton
        // Button {
        //   store.newSession()
        // } label: {
        //   Image(systemName: "square.and.arrow.down.badge.checkmark.fill")
        // }
        // .help("New Terminal (⌘T)")
      }
    }
  }

  private var newTerminalButton: some View {
    Button {
      store.newSession()
    } label: {
      Image(systemName: "plus")
    }
    .help("New Terminal (⌘T)")
  }

  /// Sentinel expansion key for the whole OpenCode section (never a real path).
  private static let openCodeSectionKey = "\u{0}opencode-section"

  /// Collapsible "OpenCode" header (toggles the whole section). Used inline when
  /// expanded and pinned to the bottom of the sidebar when collapsed.
  private func openCodeHeaderButton(expanded: Bool) -> some View {
    Button {
      store.setExpanded(Self.openCodeSectionKey, !expanded)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 10)
        Text("OpenCode")
        Spacer(minLength: 4)
        Text("\(model.opencodeSessions.count)").foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
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

  /// Inactive-pane dimming options resolved for the terminal area.
  private var paneDimming: PaneDimming {
    PaneDimming(enabled: model.dimInactivePanes, amount: model.effectiveInactiveDim)
  }

  // MARK: - Project tree

  /// One row in the flattened project tree.
  private enum SidebarItem: Identifiable {
    case folder(ProjectTreeNode, depth: Int, expanded: Bool, selecting: Bool)
    case session(OpencodeSession, depth: Int, projectPath: String)

    var id: String {
      switch self {
      case .folder(let node, _, _, _): return "folder:" + node.path
      case .session(let session, _, _): return "session:" + session.id
      }
    }
  }

  /// Flattens the tree into visible rows, honoring per-folder expansion (a
  /// folder in select mode is force-expanded).
  private var sidebarItems: [SidebarItem] {
    var rows: [SidebarItem] = []
    appendItems(model.projectTree, depth: 0, into: &rows)
    return rows
  }

  private func appendItems(_ nodes: [ProjectTreeNode], depth: Int, into rows: inout [SidebarItem]) {
    for node in nodes {
      let selecting = selectionProject == node.path
      let expanded = store.isExpanded(node.path) || selecting
      rows.append(.folder(node, depth: depth, expanded: expanded, selecting: selecting))
      if expanded {
        appendItems(node.children, depth: depth + 1, into: &rows)
        for session in node.sessions {
          rows.append(.session(session, depth: depth + 1, projectPath: node.path))
        }
      }
    }
  }

  @ViewBuilder
  private func sidebarRow(_ item: SidebarItem) -> some View {
    switch item {
    case .folder(let node, let depth, let expanded, let selecting):
      folderRow(node, depth: depth, expanded: expanded, selecting: selecting)
    case .session(let session, let depth, let projectPath):
      sessionRow(session, depth: depth, projectPath: projectPath)
    }
  }

  @ViewBuilder
  private func folderRow(_ node: ProjectTreeNode, depth: Int, expanded: Bool, selecting: Bool)
    -> some View
  {
    let leading = CGFloat(depth) * 12
    if selecting {
      HStack(spacing: 8) {
        Text(folderLabel(node)).lineLimit(1)
        Spacer(minLength: 4)
        Button("Delete (\(selectedSessionIDs.count))", role: .destructive) {
          confirmingDeleteSelection = true
        }
        .disabled(selectedSessionIDs.isEmpty)
        Button("Done") { exitSelectMode() }
      }
      .buttonStyle(.borderless)
      .font(.callout)
      .padding(.leading, leading)
    } else if node.sessions.isEmpty {
      folderButton(node, expanded: expanded).padding(.leading, leading)
    } else {
      folderButton(node, expanded: expanded)
        .contextMenu {
          Button("Select Sessions") { enterSelectMode(node) }
          Button("Delete All Sessions…", role: .destructive) { pendingDeleteProject = node }
        }
        .padding(.leading, leading)
    }
  }

  private func folderButton(_ node: ProjectTreeNode, expanded: Bool) -> some View {
    Button {
      store.setExpanded(node.path, !store.isExpanded(node.path))
    } label: {
      HStack(spacing: 4) {
        Image(systemName: expanded ? "chevron.down" : "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 10)
        Text(folderLabel(node)).lineLimit(1)
        Spacer(minLength: 4)
        Text("\(node.totalSessions)").foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func sessionRow(_ session: OpencodeSession, depth: Int, projectPath: String) -> some View
  {
    OpencodeSessionLeaf(
      session: session,
      depth: depth,
      selecting: selectionProject == projectPath,
      selected: selectedSessionIDs.contains(session.id),
      onTap: {
        if selectionProject == projectPath {
          toggleSelection(session.id)
        } else {
          model.openOpencodeSession(session)
        }
      },
      onOpen: { model.openOpencodeSession(session) },
      onRename: { beginOpencodeRename(session) },
      onDelete: { pendingDelete = session }
    )
  }

  /// Folder display label: append "/" except for the root and Unknown nodes.
  private func folderLabel(_ node: ProjectTreeNode) -> String {
    (node.name == "Unknown" || node.name == "/") ? node.name : node.name + "/"
  }

  private func enterSelectMode(_ node: ProjectTreeNode) {
    selectionProject = node.path
    selectedSessionIDs = []
    store.setExpanded(node.path, true)
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

  private var deleteProjectConfirmBinding: Binding<Bool> {
    Binding(get: { pendingDeleteProject != nil }, set: { if !$0 { pendingDeleteProject = nil } })
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
  let dimming: PaneDimming

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
      // Keep every tab's pane tree in the hierarchy so background terminals keep
      // rendering/receiving; only the selected tab is visible + interactive.
      ZStack {
        ForEach(store.sessions) { tab in
          let tree = store.tree(for: tab)
          PaneTabView(
            tree: tree,
            tabIsSplit: !tree.isSingleLeaf,
            dimming: dimming,
            store: store
          )
          .opacity(tab.id == store.selectedID ? 1 : 0)
          .allowsHitTesting(tab.id == store.selectedID)
        }
      }
    }
  }
}

/// Invokes `action` on a middle-click anywhere in the view, while staying
/// transparent to every other event (so left-click selection still works).
private struct MiddleClickClose: ViewModifier {
  let action: () -> Void
  func body(content: Content) -> some View {
    content.overlay(MiddleClickCatcher(action: action))
  }
}

private struct MiddleClickCatcher: NSViewRepresentable {
  let action: () -> Void

  func makeNSView(context: Context) -> NSView { CatcherView(action: action) }
  func updateNSView(_ nsView: NSView, context: Context) {
    (nsView as? CatcherView)?.action = action
  }

  final class CatcherView: NSView {
    var action: () -> Void
    init(action: @escaping () -> Void) {
      self.action = action
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Only claim the hit for a middle mouse-down; otherwise be transparent so
    // left-clicks, hover, etc. reach the SwiftUI row beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
      guard let event = NSApp.currentEvent,
        event.type == .otherMouseDown, event.buttonNumber == 2
      else { return nil }
      return super.hitTest(point) != nil ? self : nil
    }

    override func otherMouseDown(with event: NSEvent) {
      if event.buttonNumber == 2 { action() } else { super.otherMouseDown(with: event) }
    }
  }
}

/// Tints the native window titlebar to the active theme background so the top
/// bar blends with the sidebar/terminal. Restores default chrome when no theme.
private struct WindowChromeConfigurator: NSViewRepresentable {
  let backgroundColor: Color?

  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ nsView: NSView, context: Context) {
    let color = backgroundColor
    DispatchQueue.main.async {
      guard let window = nsView.window else { return }
      if let color {
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(color)
      } else {
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.backgroundColor = .windowBackgroundColor
      }
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
  let onClose: () -> Void
  @State private var hovering = false

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
            if let updated = opencode.updatedRelative {
              Text(updated).help(opencode.updatedTooltip ?? "")
            }
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      if hovering {
        Button(action: onClose) {
          Image(systemName: "xmark").font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close session")
      }
    }
    .onHover { hovering = $0 }
  }
}

/// One opencode session leaf in the project tree. Tap opens (or toggles in
/// select mode); hovering reveals a delete button.
private struct OpencodeSessionLeaf: View {
  let session: OpencodeSession
  let depth: Int
  let selecting: Bool
  let selected: Bool
  let onTap: () -> Void
  let onOpen: () -> Void
  let onRename: () -> Void
  let onDelete: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 8) {
      if selecting {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
      }
      OpencodeRow(session: session)
      Spacer(minLength: 4)
      if session.isStale {
        Image(systemName: "moon.zzz.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("No activity in over 30 days")
      }
      if hovering && !selecting {
        Button(action: onDelete) {
          Image(systemName: "trash").font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Delete session")
      }
    }
    .padding(.leading, CGFloat(depth) * 12)
    .contentShape(Rectangle())
    .onTapGesture { onTap() }
    .onHover { hovering = $0 }
    .contextMenu {
      Button("Open", action: onOpen)
      Button("Rename…", action: onRename)
      Divider()
      Button("Delete", role: .destructive, action: onDelete)
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
        if let updated = session.updatedRelative {
          Text(updated).help(session.updatedTooltip ?? "")
        }
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
    .padding(.vertical, 1)
    .contentShape(Rectangle())
  }
}
