import SwiftUI
import AppKit
import GhosttyTerminal

/// User-configurable dimming applied to unfocused panes when a tab is split.
struct PaneDimming: Equatable {
    var enabled: Bool
    var amount: Double  // effective dim, 0 = none … 1 = full
}

/// Lays a tab's pane tree out as a *flat* set of positioned surfaces keyed by
/// session id. Restructuring the tree (split/close) only changes each pane's
/// frame — it never destroys or rebuilds a surviving pane's view, so scrollback
/// and keyboard focus are preserved. Dividers are drawn on top and drive the
/// stored split fractions.
struct PaneTabView: View {
    let tree: PaneNode
    let tabIsSplit: Bool
    let dimming: PaneDimming
    let store: SessionStore

    /// Live divider drag (split id + proposed fraction), reflected in the layout
    /// without touching the store until the drag ends.
    @State private var drag: DragState?
    /// Stable per-tab coordinate space for divider drags.
    @State private var space = UUID().uuidString

    private struct DragState { let id: UUID; let fraction: Double }

    var body: some View {
        GeometryReader { geo in
            let layout = PaneLayout.compute(
                tree,
                in: CGRect(origin: .zero, size: geo.size),
                drag: drag.map { ($0.id, $0.fraction) }
            )
            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.session.id) { placement in
                    PaneLeafView(session: placement.session, tabIsSplit: tabIsSplit, dimming: dimming, store: store)
                        .frame(width: placement.rect.width, height: placement.rect.height)
                        .position(x: placement.rect.midX, y: placement.rect.midY)
                }
                ForEach(layout.dividers) { divider in
                    DividerHandle(
                        divider: divider,
                        space: space,
                        onDrag: { drag = DragState(id: divider.id, fraction: $0) },
                        onCommit: { store.setSplitFraction($0, splitID: divider.id); drag = nil },
                        onReset: { store.setSplitFraction(0.5, splitID: divider.id) }
                    )
                    .frame(width: divider.rect.width, height: divider.rect.height)
                    .position(x: divider.rect.midX, y: divider.rect.midY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: space)
        }
    }
}

/// Geometry for one tab: each leaf's frame plus the divider rects.
private struct PaneLayout {
    struct Placement { let session: TerminalSession; let rect: CGRect }

    var panes: [Placement] = []
    var dividers: [DividerLayout] = []

    static let dividerThickness: CGFloat = 6
    static let minFraction: Double = 0.08

    static func compute(_ node: PaneNode, in rect: CGRect, drag: (id: UUID, fraction: Double)?) -> PaneLayout {
        var layout = PaneLayout()
        layout.add(node, in: rect, drag: drag)
        return layout
    }

    private mutating func add(_ node: PaneNode, in rect: CGRect, drag: (id: UUID, fraction: Double)?) {
        switch node {
        case let .leaf(session):
            panes.append(Placement(session: session, rect: rect))
        case let .split(id, axis, fraction, first, second):
            let raw = (drag?.id == id) ? drag!.fraction : fraction
            let f = min(max(raw, Self.minFraction), 1 - Self.minFraction)
            let t = Self.dividerThickness
            switch axis {
            case .sideBySide:
                let available = max(0, rect.width - t)
                let firstW = available * f
                add(first, in: CGRect(x: rect.minX, y: rect.minY, width: firstW, height: rect.height), drag: drag)
                dividers.append(DividerLayout(
                    id: id, axis: axis,
                    rect: CGRect(x: rect.minX + firstW, y: rect.minY, width: t, height: rect.height),
                    available: available, origin: rect.minX
                ))
                add(second, in: CGRect(x: rect.minX + firstW + t, y: rect.minY, width: available - firstW, height: rect.height), drag: drag)
            case .stacked:
                let available = max(0, rect.height - t)
                let firstH = available * f
                add(first, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstH), drag: drag)
                dividers.append(DividerLayout(
                    id: id, axis: axis,
                    rect: CGRect(x: rect.minX, y: rect.minY + firstH, width: rect.width, height: t),
                    available: available, origin: rect.minY
                ))
                add(second, in: CGRect(x: rect.minX, y: rect.minY + firstH + t, width: rect.width, height: available - firstH), drag: drag)
            }
        }
    }
}

private struct DividerLayout: Identifiable {
    let id: UUID
    let axis: SplitAxis
    let rect: CGRect
    let available: CGFloat  // resizable length along the split axis
    let origin: CGFloat     // start of the split region along the axis
}

/// A draggable divider. Maps the cursor's absolute position (in the tab's
/// coordinate space) to a fraction — no feedback loop from the divider moving
/// under the cursor. Double-click recenters it.
private struct DividerHandle: View {
    let divider: DividerLayout
    let space: String
    let onDrag: (Double) -> Void
    let onCommit: (Double) -> Void
    let onReset: () -> Void

    private var horizontal: Bool { divider.axis == .sideBySide }

    var body: some View {
        Color.clear
            .overlay {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(
                        width: horizontal ? 1 : divider.rect.width,
                        height: horizontal ? divider.rect.height : 1
                    )
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
                DragGesture(minimumDistance: 2, coordinateSpace: .named(space))
                    .onChanged { onDrag(fraction(at: $0.location)) }
                    .onEnded { onCommit(fraction(at: $0.location)) }
            )
            .onTapGesture(count: 2) { onReset() }
    }

    private func fraction(at point: CGPoint) -> Double {
        guard divider.available > 0 else { return 0.5 }
        let pos = horizontal ? point.x : point.y
        let firstSize = pos - divider.origin - PaneLayout.dividerThickness / 2
        return min(max(firstSize / divider.available, PaneLayout.minFraction), 1 - PaneLayout.minFraction)
    }
}

/// A single terminal pane. Keyboard focus is left entirely to the Ghostty
/// surface (clicking it makes it first responder); we read its `isFocused`
/// state only to fade inactive panes when the tab is split. When a pane takes
/// focus it tells the others to drop their (default-on) cursor so only the
/// active pane blinks. We avoid `.terminalFocused` and store writes on focus —
/// both forced first responder and view-tree churn swallowed keystrokes.
private struct PaneLeafView: View {
    @ObservedObject var session: TerminalSession
    let tabIsSplit: Bool
    let dimming: PaneDimming
    let store: SessionStore

    var body: some View {
        let dim = tabIsSplit && dimming.enabled && !session.state.isFocused
        TerminalSurfaceView(context: session.state)
            .opacity(dim ? 1 - dimming.amount : 1)
            .onChange(of: session.state.isFocused) { _, focused in
                if focused { store.unfocusOtherPanes(except: session.id) }
            }
    }
}
