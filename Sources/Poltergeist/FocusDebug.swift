import AppKit
import GhosttyTerminal

/// Focus diagnostics, enabled with `POLTERGEIST_DEBUG_FOCUS=1` (no-op otherwise).
/// Logs first-responder changes, focus attempts, selection changes, clicks, and
/// where key events land (key codes only, never characters) to stderr. Kept for
/// the sidebar-focus regression point documented in AGENTS.md.
@MainActor
enum FocusDebug {
    static let enabled = ProcessInfo.processInfo.environment["POLTERGEIST_DEBUG_FOCUS"] == "1"
    private static let start = Date()
    private static var lastResponder = ""
    private static var timer: Timer?
    weak static var store: SessionStore?

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let t = String(format: "%8.3f", Date().timeIntervalSince(start))
        FileHandle.standardError.write(Data("[focus \(t)] \(message())\n".utf8))
    }

    /// Polls the key window's first responder and logs changes.
    static func install(store: SessionStore) {
        guard enabled else { return }
        self.store = store
        log("focus debug enabled")
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            MainActor.assumeIsolated {
                var hit = "?"
                if let content = event.window?.contentView {
                    let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                    hit = describe(content.hitTest(point))
                }
                log("\(event.type == .leftMouseDown ? "mouseDown" : "mouseUp  ") on \(hit)")
            }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = describeCurrent()
                if now != lastResponder {
                    log("firstResponder → \(now)")
                    lastResponder = now
                }
            }
        }
    }

    static func describeCurrent() -> String {
        guard let window = NSApp.keyWindow else { return "<no key window>" }
        return describe(window.firstResponder)
    }

    static func describe(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        if let term = responder as? AppTerminalView {
            return "terminal(\(label(for: term)))"
        }
        return String(describing: type(of: responder))
    }

    static func label(for state: TerminalViewState) -> String {
        guard let store else { return "?" }
        if let session = store.allTerminals.first(where: { $0.state === state }) {
            let isTab = store.sessions.contains { $0.id == session.id }
            return "#\(session.ordinal)\(isTab ? "" : " pane") \(session.id.uuidString.prefix(4))"
        }
        return "unknown"
    }

    private static func label(for view: AppTerminalView) -> String {
        guard let state = view.delegate as? TerminalViewState else { return "no-delegate" }
        return label(for: state)
    }

    static func selectedLabel() -> String {
        guard let store, let session = store.selectedSession else { return "none" }
        return label(for: session.state)
    }
}
