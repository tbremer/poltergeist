import SwiftUI
import AppKit
import GhosttyTerminal

/// User-configurable dimming applied to unfocused panes when a tab is split.
struct PaneDimming: Equatable {
    var enabled: Bool
    var amount: Double  // effective dim, 0 = none … 1 = full
}

/// Renders a tab's pane tree. Leaves are terminal surfaces; splits are laid out
/// by a custom container with a draggable divider whose position is stored on
/// the node (so splitting one pane never disturbs the others).
struct PaneTreeView: View {
    let node: PaneNode
    /// Whether this tab is split (so unfocused panes dim).
    let tabIsSplit: Bool
    /// How unfocused panes are dimmed (user-configurable).
    let dimming: PaneDimming
    let store: SessionStore

    var body: some View {
        switch node {
        case let .leaf(session):
            PaneLeafView(session: session, tabIsSplit: tabIsSplit, dimming: dimming)
        case let .split(id, axis, fraction, first, second):
            SplitContainer(
                splitID: id,
                axis: axis,
                fraction: fraction,
                first: first,
                second: second,
                tabIsSplit: tabIsSplit,
                dimming: dimming,
                store: store
            )
        }
    }
}

/// Lays out a split's two subtrees with a draggable divider. The divider's
/// position comes from the node's `fraction` (single source of truth); a live
/// `dragFraction` overlays it only while dragging for smooth feedback. Double-
/// click equalizes every pane in the tab.
private struct SplitContainer: View {
    let splitID: UUID
    let axis: SplitAxis
    let fraction: Double
    let first: PaneNode
    let second: PaneNode
    let tabIsSplit: Bool
    let dimming: PaneDimming
    let store: SessionStore

    @State private var dragFraction: Double?

    private static let dividerThickness: CGFloat = 6
    private static let minFraction = 0.08

    private var horizontal: Bool { axis == .sideBySide }

    var body: some View {
        let space = splitID.uuidString
        GeometryReader { geo in
            let total = horizontal ? geo.size.width : geo.size.height
            let available = max(0, total - Self.dividerThickness)
            let f = min(max(dragFraction ?? fraction, Self.minFraction), 1 - Self.minFraction)
            let firstSize = available * f
            let secondSize = available - firstSize

            if horizontal {
                HStack(spacing: 0) {
                    PaneTreeView(node: first, tabIsSplit: tabIsSplit, dimming: dimming, store: store)
                        .frame(width: firstSize, height: geo.size.height)
                    divider(length: geo.size.height, available: available, space: space)
                    PaneTreeView(node: second, tabIsSplit: tabIsSplit, dimming: dimming, store: store)
                        .frame(width: secondSize, height: geo.size.height)
                }
                .coordinateSpace(name: space)
            } else {
                VStack(spacing: 0) {
                    PaneTreeView(node: first, tabIsSplit: tabIsSplit, dimming: dimming, store: store)
                        .frame(width: geo.size.width, height: firstSize)
                    divider(length: geo.size.width, available: available, space: space)
                    PaneTreeView(node: second, tabIsSplit: tabIsSplit, dimming: dimming, store: store)
                        .frame(width: geo.size.width, height: secondSize)
                }
                .coordinateSpace(name: space)
            }
        }
    }

    private func divider(length: CGFloat, available: CGFloat, space: String) -> some View {
        Color.clear
            .frame(
                width: horizontal ? Self.dividerThickness : length,
                height: horizontal ? length : Self.dividerThickness
            )
            .overlay {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: horizontal ? 1 : length, height: horizontal ? length : 1)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                // Track the cursor's absolute position in the split's (stable)
                // coordinate space rather than a translation in the divider's own
                // space — the divider moves as you drag, so a local translation
                // feeds back on itself and oscillates. minimumDistance lets a
                // stationary double-click reach the equalize tap handler.
                DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
                    .onChanged { value in
                        guard available > 0 else { return }
                        let pos = horizontal ? value.location.x : value.location.y
                        let newFirst = pos - Self.dividerThickness / 2
                        dragFraction = min(max(newFirst / available, Self.minFraction), 1 - Self.minFraction)
                    }
                    .onEnded { _ in
                        if let dragFraction { store.setSplitFraction(dragFraction, splitID: splitID) }
                        dragFraction = nil
                    }
            )
            // Double-click resets just this divider to 50/50 (its two immediate
            // children); other dividers are untouched.
            .onTapGesture(count: 2) { store.setSplitFraction(0.5, splitID: splitID) }
    }
}

/// A single terminal pane. Keyboard focus is left entirely to the Ghostty
/// surface (clicking it makes it first responder); we read its `isFocused`
/// state only to fade inactive panes when the tab is split. We deliberately
/// avoid `.terminalFocused` and store writes on focus — both forced first
/// responder and the resulting view-tree churn intermittently swallowed
/// keystrokes.
private struct PaneLeafView: View {
    @ObservedObject var session: TerminalSession
    let tabIsSplit: Bool
    let dimming: PaneDimming

    var body: some View {
        // Fade only unfocused panes of a split, and only when enabled.
        let dim = tabIsSplit && dimming.enabled && !session.state.isFocused
        TerminalSurfaceView(context: session.state)
            .opacity(dim ? 1 - dimming.amount : 1)
    }
}
