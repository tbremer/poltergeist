import AppKit
import SwiftUI

/// While the sidebar is collapsed, hovering the window's leading edge reveals
/// the sidebar as a floating panel over the terminal (no layout change). The
/// panel is a full, interactive copy of the sidebar and hides a beat after the
/// pointer leaves it. Hover state lives here (not in `RootView`) so showing and
/// hiding the panel doesn't re-render the terminal surfaces.
struct FloatingSidebar<Content: View>: View {
    /// True while the real sidebar is collapsed.
    let enabled: Bool
    let background: Color?
    /// Matches the docked sidebar's last width.
    let width: CGFloat
    @ViewBuilder let content: () -> Content
    @StateObject private var hover = EdgeHoverController()
    @State private var metrics = WindowMetrics()

    /// The hot zone covers the window "gutter" — twice the traffic lights'
    /// inset — so the panel appears before the pointer reaches the edge.
    private var edgeWidth: CGFloat { metrics.inset * 2 }

    var body: some View {
        ZStack(alignment: .leading) {
            if enabled {
                // Tracking-area only: clicks/selection in the strip still reach
                // the terminal underneath.
                EdgeHoverZone { hover.setEdgeHover($0) }
                    .frame(width: edgeWidth)
                    .frame(maxHeight: .infinity)
            }
            if enabled && hover.showing {
                panel
                    .transition(.move(edge: .leading))
            }
        }
        .frame(maxHeight: .infinity, alignment: .leading)
        .background(WindowMetricsReader(metrics: $metrics))
        .animation(.easeOut(duration: 0.15), value: hover.showing)
        .onChange(of: enabled) { _, on in
            if !on { hover.close() }
        }
    }

    /// A floating card with the docked sidebar's width/background. It sits
    /// directly below the titlebar (leaving the traffic lights and toolbar
    /// uncovered), inset on the other sides by the traffic lights' inset, with corners
    /// concentric to the window's.
    private var panel: some View {
        let shape = Self.panelShape
        return content()
            .scrollContentBackground(.hidden)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(panelBackground)
            .clipShape(shape)
            .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 3)
            // No top inset: the card starts right where the titlebar ends.
            .padding([.leading, .trailing, .bottom], metrics.inset)
            .ignoresSafeArea(edges: .bottom)
            // The inset counts as "inside" so crossing it doesn't close the panel.
            .contentShape(Rectangle())
            .onHover { hover.setPanelHover($0) }
    }

    /// macOS 26+: `ConcentricRectangle` resolves its radius against the window's
    /// own corner (the window is the default container shape for content that
    /// reaches its edges), so no radius is hard-coded. Earlier: a small fixed
    /// radius, roughly concentric with pre-Tahoe window corners.
    private static var panelShape: AnyShape {
        if #available(macOS 26.0, *) {
            return AnyShape(ConcentricRectangle(corners: .concentric(minimum: 12), isUniform: true))
        }
        return AnyShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// An opaque AppKit view, so it reliably stacks above the terminal (also an
    /// AppKit view) rather than relying on SwiftUI drawing order.
    private var panelBackground: some View {
        PanelBackground(themeColor: background.map { NSColor($0) })
    }
}

/// The panel fill: the theme background (or the system window background when
/// unthemed), lifted slightly toward white so the floating panel reads as a
/// raised surface over the identical terminal color. Re-resolves on
/// light/dark changes.
private struct PanelBackground: NSViewRepresentable {
    let themeColor: NSColor?

    func makeNSView(context: Context) -> FillView {
        let view = FillView()
        view.themeColor = themeColor
        return view
    }

    func updateNSView(_ nsView: FillView, context: Context) {
        nsView.themeColor = themeColor
    }

    final class FillView: NSView {
        /// How far to lift the base color toward white.
        private static let lift: CGFloat = 0.025

        var themeColor: NSColor? {
            didSet { if themeColor != oldValue { needsDisplay = true } }
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var wantsUpdateLayer: Bool { true }
        override var isOpaque: Bool { true }

        override func updateLayer() {
            var fill = NSColor.windowBackgroundColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let base = (self.themeColor ?? NSColor.windowBackgroundColor).usingColorSpace(.sRGB)
                    ?? NSColor.windowBackgroundColor
                fill = base.blended(withFraction: Self.lift, of: .white) ?? base
            }
            layer?.backgroundColor = fill.withAlphaComponent(1).cgColor
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
}

/// An invisible strip that reports pointer enter/exit via a tracking area but
/// never takes part in hit-testing, so it can sit over the terminal without
/// stealing clicks, drags, or text selection.
private struct EdgeHoverZone: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> ZoneView {
        let view = ZoneView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: ZoneView, context: Context) {
        nsView.onHover = onHover
    }

    final class ZoneView: NSView {
        var onHover: ((Bool) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}

/// Window geometry the floating panel matches: the traffic lights' inset from
/// the window edge (read from the close button; there's no public constant).
struct WindowMetrics: Equatable {
    var inset: CGFloat = 9
}

/// Reads `WindowMetrics` from the hosting window, re-reading on resize and
/// full-screen changes.
private struct WindowMetricsReader: NSViewRepresentable {
    @Binding var metrics: WindowMetrics

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { metrics in
            if self.metrics != metrics { self.metrics = metrics }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: ((WindowMetrics) -> Void)?
        /// Main-thread only; read again in the nonisolated deinit.
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.read() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.read() }
        }

        private func read() {
            guard let window else { return }
            var metrics = WindowMetrics()
            if let button = window.standardWindowButton(.closeButton), button.superview != nil {
                let frame = button.convert(button.bounds, to: nil)
                if frame.minX > 0 { metrics.inset = frame.minX }
            }
            onChange?(metrics)
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Opens when the pointer reaches the edge or panel; closes shortly after it
/// leaves both. Closing is suspended while a menu (e.g. a row's context menu)
/// is tracking, since the pointer leaves the panel to reach the menu. A
/// reference type so delayed work reads live state, not a captured snapshot.
@MainActor
private final class EdgeHoverController: ObservableObject {
    @Published private(set) var showing = false
    private var overEdge = false
    private var overPanel = false
    private var menuTracking = false
    private var closeWork: DispatchWorkItem?
    /// Only mutated in init; read again in the nonisolated deinit.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTracking = false
                self.scheduleClose()
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setEdgeHover(_ inside: Bool) {
        overEdge = inside
        inside ? open() : scheduleClose()
    }

    func setPanelHover(_ inside: Bool) {
        overPanel = inside
        inside ? open() : scheduleClose()
    }

    func close() {
        closeWork?.cancel()
        overEdge = false
        overPanel = false
        showing = false
    }

    private func open() {
        closeWork?.cancel()
        if !showing { showing = true }
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.overEdge, !self.overPanel, !self.menuTracking else { return }
                self.showing = false
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
