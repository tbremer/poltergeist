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
    var promptStyle = TerminalPromptStyle()
    /// Answer to a pane's close-tab confirmation (true = close).
    var onCloseTabPrompt: (Bool) -> Void = { _ in }

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
                    PaneLeafView(
                        session: placement.session, tabIsSplit: tabIsSplit, dimming: dimming, store: store,
                        promptStyle: promptStyle, onCloseTabPrompt: onCloseTabPrompt
                    )
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
    let promptStyle: TerminalPromptStyle
    let onCloseTabPrompt: (Bool) -> Void

    var body: some View {
        let dim = tabIsSplit && dimming.enabled && !session.state.isFocused
        TerminalSurfaceView(context: session.state)
            .opacity(dim ? 1 - dimming.amount : 1)
            .onChange(of: session.state.isFocused) { _, focused in
                if focused { store.unfocusOtherPanes(except: session.id) }
            }
            .overlay {
                if let title = session.closeTabPrompt {
                    GeometryReader { geo in
                        // Centered horizontally; vertically the leftover space is
                        // split 1/3 above, 2/3 below (three equal flexible spacers).
                        VStack(spacing: 0) {
                            Color.clear.frame(maxHeight: .infinity)
                            CloseTabPromptView(
                                title: title, style: promptStyle, availableWidth: geo.size.width,
                                onAnswer: onCloseTabPrompt
                            )
                            Color.clear.frame(maxHeight: .infinity)
                            Color.clear.frame(maxHeight: .infinity)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
    }
}

/// Colors for in-pane prompts, taken from the terminal theme so they read as
/// part of the terminal rather than app chrome.
struct TerminalPromptStyle {
    /// Theme background (nil = system window background); drawn opaquely by
    /// `PanelBackground`.
    var themeBackground: NSColor?
    var background: Color { Color(nsColor: themeBackground ?? .windowBackgroundColor) }
    var foreground: Color = .primary
    var accent: Color = .orange
}

/// Terminal-styled confirmation drawn centered over a pane (not a macOS
/// alert): answered from the keyboard (Y/Return close, N/Esc cancel — see
/// `AppModel.handleCloseTabPrompt`) or by clicking. Holds no focus, so the
/// terminal stays first responder underneath. Laid out on a character grid
/// with a classic TUI drop shadow of `▒` cells (one row down, two columns
/// right).
private struct CloseTabPromptView: View {
    let title: String
    let style: TerminalPromptStyle
    /// The pane's width, to size the panel (in whole columns) to fit.
    let availableWidth: CGFloat
    let onAnswer: (Bool) -> Void

    /// Content height before snapping the panel up to whole rows.
    @State private var contentHeight: CGFloat = 0

    /// Panel width in columns: up to 54, leaving room for margins + shadow.
    private var columns: CGFloat {
        let fit = ((availableWidth - 32) / PromptGrid.cell.width).rounded(.down) - 2
        return max(24, min(54, fit))
    }

    var body: some View {
        let cell = PromptGrid.cell
        let panel = CGSize(width: columns * cell.width, height: PromptGrid.snap(contentHeight, to: cell.height))
        content
            .frame(width: panel.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)  // intrinsic height, independent of the frame below
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            .frame(width: panel.width, height: panel.height, alignment: .top)
            .background(PanelBackground(themeColor: style.themeBackground))
            .overlay(Rectangle().strokeBorder(style.accent, lineWidth: 1))
            .background(alignment: .topLeading) {
                ShadeShadow(panel: panel, color: style.foreground.opacity(0.45))
            }
            .opacity(contentHeight == 0 ? 0 : 1)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: PromptGrid.cell.height / 2) {
            Text("Close tab?")
                .fontWeight(.bold)
                .foregroundStyle(style.accent)
            Text("\u{201C}\(title)\u{201D} is still working. Closing the tab won't stop it on the server.")
                .foregroundStyle(style.foreground)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: PromptGrid.cell.width * 3) {
                key("y", "close", primary: true) { onAnswer(true) }
                key("n", "cancel", primary: false) { onAnswer(false) }
            }
        }
        .font(Font(PromptGrid.font))
        .padding(.horizontal, PromptGrid.cell.width * 2)
        .padding(.vertical, PromptGrid.cell.height)
    }

    private func key(_ key: String, _ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: PromptGrid.cell.width) {
                Text(" \(key) ")
                    .fontWeight(.bold)
                    .foregroundStyle(primary ? style.background : style.foreground)
                    .background(primary ? style.accent : style.foreground.opacity(0.15))
                Text(label).foregroundStyle(style.foreground.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// The prompt's character grid: Menlo (which has the block/shade glyphs, so
/// they tile without font fallback) and its cell size.
@MainActor
private enum PromptGrid {
    static let font = NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)

    static let cell: CGSize = {
        let width = ("M" as NSString).size(withAttributes: [.font: font]).width
        let height = NSLayoutManager().defaultLineHeight(for: font)
        return CGSize(width: ceil(width), height: ceil(height))
    }()

    static func snap(_ length: CGFloat, to unit: CGFloat) -> CGFloat {
        (length / unit).rounded(.up) * unit
    }
}

/// The drop shadow: `▒` cells along the panel's right edge (two columns,
/// starting one row down) and bottom edge (one row, starting two columns in).
/// Glyphs only, no fill, so the terminal shows through like a real TUI shadow.
private struct ShadeShadow: View {
    let panel: CGSize
    let color: Color

    var body: some View {
        let cell = PromptGrid.cell
        Canvas { context, _ in
            let glyph = context.resolve(Text("\u{2592}").font(Font(PromptGrid.font)).foregroundColor(color))
            func draw(column: Int, row: Int) {
                let rect = CGRect(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height,
                                  width: cell.width, height: cell.height)
                context.draw(glyph, in: rect)
            }
            let columns = Int((panel.width / cell.width).rounded())
            let rows = Int((panel.height / cell.height).rounded())
            for row in 1 ... max(rows, 1) {
                draw(column: columns, row: row)
                draw(column: columns + 1, row: row)
            }
            for column in 2 ..< columns + 2 {
                draw(column: column, row: rows)
            }
        }
        .frame(width: panel.width + cell.width * 2, height: panel.height + cell.height)
        .allowsHitTesting(false)
    }
}
