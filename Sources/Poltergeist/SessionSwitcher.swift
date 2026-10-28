import SwiftUI
import AppKit

// MARK: - Collapse detection

/// Reports whether the `NavigationSplitView`'s sidebar column is collapsed.
///
/// The app toggles the sidebar through the AppKit `toggleSidebar:` responder
/// action (see `AppModel.toggleSidebar`), which bypasses SwiftUI's
/// `columnVisibility` binding — so that binding can't be trusted for detection.
/// Instead we locate the backing `NSSplitViewItem` and read its ground-truth
/// `isCollapsed`, re-reading it whenever the split view resizes its subviews
/// (which covers the native toggle, the ⌥⌘B action, and divider drags alike).
struct SidebarCollapseObserver: NSViewRepresentable {
    @Binding var collapsed: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(from: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator { newValue in
            if collapsed != newValue { collapsed = newValue }
        }
    }

    final class Coordinator: NSObject, @unchecked Sendable {
        private let onChange: (Bool) -> Void
        private weak var sidebarItem: NSSplitViewItem?
        private var token: NSObjectProtocol?
        private var collapseObservation: NSKeyValueObservation?
        private var attached = false

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }

        /// Finds the sidebar split item and starts watching it. Retries briefly
        /// because the AppKit hierarchy isn't fully assembled on the first pass.
        @MainActor
        func attach(from view: NSView, attempt: Int = 0) {
            guard !attached else { return }
            if let splitVC = Self.findSplitViewController(from: view),
               let sidebar = splitVC.splitViewItems.first(where: { $0.behavior == .sidebar })
                   ?? splitVC.splitViewItems.first {
                attached = true
                sidebarItem = sidebar
                onChange(sidebar.isCollapsed)
                token = NotificationCenter.default.addObserver(
                    forName: NSSplitView.didResizeSubviewsNotification,
                    object: splitVC.splitView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let item = self.sidebarItem else { return }
                        self.onChange(item.isCollapsed)
                    }
                }
                // Belt and braces: also observe the item directly, in case the
                // final resize notification lands before `isCollapsed` flips.
                collapseObservation = sidebar.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        guard let self, let item = self.sidebarItem else { return }
                        self.onChange(item.isCollapsed)
                    }
                }
                return
            }
            guard attempt < 30 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak view] in
                MainActor.assumeIsolated {
                    guard let self, let view else { return }
                    self.attach(from: view, attempt: attempt + 1)
                }
            }
        }

        /// Finds the `NSSplitViewController` backing the `NavigationSplitView`.
        /// This observer sits beside the split view (not inside it), and the
        /// controller isn't reachable through the responder chain or the window's
        /// view-controller children, so we search the window's view tree for the
        /// `NSSplitView` and take its delegate (the controller always delegates for
        /// its own split view).
        @MainActor
        private static func findSplitViewController(from view: NSView) -> NSSplitViewController? {
            guard let root = view.window?.contentView else { return nil }
            return search(root)
        }

        @MainActor
        private static func search(_ view: NSView) -> NSSplitViewController? {
            if let split = view as? NSSplitView,
               let controller = split.delegate as? NSSplitViewController {
                return controller
            }
            for sub in view.subviews {
                if let found = search(sub) { return found }
            }
            return nil
        }
    }
}

// MARK: - Session switcher (collapsed-sidebar hover menu)

/// A toolbar control shown next to the sidebar toggle when the sidebar is
/// collapsed (and temporarily, via the switcher hotkey, when it's open).
/// Hovering it reveals a compact menu of the active terminal sessions (name +
/// ⌘-number accelerator) so you can switch without expanding the sidebar;
/// choosing a session selects + focuses it and leaves the sidebar as it was.
/// Clicking the control also toggles the menu.
///
/// Opened from the hotkey, the menu takes keyboard focus (↑/↓, Return, Esc,
/// 1–9/0). Opened by hover it stays passive, so typing keeps going to the
/// terminal underneath.
struct SessionSwitcherButton: View {
    @ObservedObject var store: SessionStore
    /// Set to request opening the menu for keyboard use; reset once handled.
    @Binding var keyboardOpenRequested: Bool
    /// Called whenever the menu closes.
    var onClose: () -> Void = {}
    @StateObject private var hover = HoverController()

    var body: some View {
        Button {
            hover.toggle()
        } label: {
            Image(systemName: "rectangle.stack")
        }
        .help("Switch session")
        .onHover { hover.setButtonHover($0) }
        .popover(isPresented: $hover.showing, arrowEdge: .bottom) {
            SessionSwitcherMenu(
                store: store,
                keyboardFocus: hover.keyboardDriven,
                onHoverChange: { hover.setMenuHover($0) },
                onDone: { hover.close() }
            )
        }
        .onAppear { handleKeyboardRequest() }
        .onChange(of: keyboardOpenRequested) { _, _ in handleKeyboardRequest() }
        .onChange(of: hover.showing) { _, showing in
            if !showing { onClose() }
        }
    }

    private func handleKeyboardRequest() {
        guard keyboardOpenRequested else { return }
        keyboardOpenRequested = false
        if hover.showing && hover.keyboardDriven {
            hover.close()  // hotkey again while open → toggle closed
            return
        }
        // A freshly-mounted toolbar item needs a run-loop turn to land in the
        // window before a popover can anchor to it.
        DispatchQueue.main.async { hover.openForKeyboard() }
    }
}

/// Opens on hover of either the button or the menu, and closes a short beat
/// after the pointer leaves both (bridging the gap over the popover's arrow). A
/// keyboard-opened menu ignores hover-out and closes on pick/Esc/click-away. A
/// reference type so the delayed-close work reads live hover state rather than a
/// captured SwiftUI value snapshot.
@MainActor
private final class HoverController: ObservableObject {
    @Published var showing = false
    /// Opened via the hotkey: the menu takes keyboard focus.
    @Published private(set) var keyboardDriven = false
    private var overButton = false
    private var overMenu = false
    private var closeWork: DispatchWorkItem?

    func setButtonHover(_ inside: Bool) {
        overButton = inside
        inside ? open() : scheduleClose()
    }

    func setMenuHover(_ inside: Bool) {
        overMenu = inside
        inside ? open() : scheduleClose()
    }

    func toggle() { showing ? close() : open() }

    func openForKeyboard() {
        keyboardDriven = true
        open()
    }

    func close() {
        closeWork?.cancel()
        overButton = false
        overMenu = false
        keyboardDriven = false
        showing = false
    }

    private func open() {
        closeWork?.cancel()
        if !showing { showing = true }
    }

    private func scheduleClose() {
        closeWork?.cancel()
        guard !keyboardDriven else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.keyboardDriven, !self.overButton, !self.overMenu else { return }
                self.showing = false
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
}

/// The menu body: one row per active terminal session. A single highlight is
/// shared by the mouse (hover) and keyboard (↑/↓), so they never disagree.
private struct SessionSwitcherMenu: View {
    @ObservedObject var store: SessionStore
    let keyboardFocus: Bool
    let onHoverChange: (Bool) -> Void
    let onDone: () -> Void
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                SessionSwitcherRow(
                    session: session,
                    shortcut: Self.shortcut(index: index, count: store.sessions.count),
                    selected: session.id == store.selectedID,
                    highlighted: highlighted == index,
                    onHover: { if $0 { highlighted = index } }
                ) {
                    pick(number: index + 1)
                }
            }
        }
        .padding(6)
        .frame(minWidth: 240)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { move(by: -1); return .handled }
        .onKeyPress(.downArrow) { move(by: 1); return .handled }
        .onKeyPress(.return) {
            if let highlighted { pick(number: highlighted + 1) }
            return .handled
        }
        .onKeyPress(.escape) { onDone(); return .handled }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let number = Int(press.characters) else { return .ignored }
            pick(number: number)  // 0 = last, matching ⌘0
            return .handled
        }
        .onHover { onHoverChange($0) }
        .onAppear {
            highlighted = store.sessions.firstIndex { $0.id == store.selectedID } ?? 0
            if keyboardFocus { focused = true }
        }
        .onChange(of: keyboardFocus) { _, on in
            if on { focused = true }
        }
    }

    private func move(by offset: Int) {
        let count = store.sessions.count
        guard count > 0 else { return }
        highlighted = ((highlighted ?? 0) + offset + count) % count
    }

    /// Selects + focuses session `number` (1-based; 0 = last) and closes.
    private func pick(number: Int) {
        guard number == 0 || store.sessions.indices.contains(number - 1) else { return }
        store.selectSession(number: number)
        onDone()
    }

    /// The ⌘-number accelerator shown on the right: positional ⌘1–⌘9 for the
    /// first nine sessions. A tenth-or-later session only has an accelerator when
    /// it's the last one (⌘0 always targets the last session).
    private static func shortcut(index: Int, count: Int) -> String? {
        let number = index + 1
        if number <= 9 { return "⌘\(number)" }
        if index == count - 1 { return "⌘0" }
        return nil
    }
}

/// One session row: icon + name on the left, ⌘-number accelerator (secondary
/// color) on the right. Observes the session so its name stays live.
private struct SessionSwitcherRow: View {
    @ObservedObject var session: TerminalSession
    let shortcut: String?
    let selected: Bool
    let highlighted: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    private var isOpencode: Bool { session.opencodeActive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isOpencode ? "sparkles" : "terminal")
                    .foregroundStyle(isOpencode ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(session.displayName).lineLimit(1)
                Spacer(minLength: 16)
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(fill))
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
    }

    private var fill: Color {
        if selected { return Color.accentColor.opacity(highlighted ? 0.3 : 0.18) }
        return highlighted ? Color.primary.opacity(0.08) : .clear
    }
}
