import SwiftUI
import AppKit
import ObjectiveC

/// Poltergeist — an OpenCode-aware terminal built on libghostty/GhosttyKit.
///
/// M0: launchable SwiftUI shell with the GhosttyTerminal dependency linked.
/// Built as a non-bundled SPM executable (no App Sandbox applied), which is the
/// requirement for the real PTY backend in later milestones.
@main
struct PoltergeistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model, store: model.store)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            // These actions are driven by AppModel's key monitor against the
            // user-configurable shortcuts (Settings → Keyboard), so the menu
            // items are click targets without hardcoded key equivalents. The
            // fixed ⌘W/⌘⇧W close commands keep their equivalents.
            CommandMenu("Session") {
                Button("New Terminal") { model.store.newSession() }
                Button("New OpenCode Session") { Task { await model.newOpencodeSession() } }
                    .disabled(!model.server.isReady)
                Divider()
                Button("Split Right") { model.store.splitFocusedPane(.sideBySide) }
                Button("Split Down") { model.store.splitFocusedPane(.stacked) }
                Divider()
                Button("Close Pane") { model.store.closeFocusedPane() }
                Button("Close Window") { NSApp.keyWindow?.close() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Focus Next Pane") { model.store.focusNextPane() }
                Button("Focus Previous Pane") { model.store.focusPreviousPane() }
                Divider()
                Button("Next Session") { model.store.selectNext() }
                Button("Previous Session") { model.store.selectPrevious() }
                Button("Switch Session…") { model.requestSessionSwitcher() }
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Ensures the window comes to the foreground when launched as a bare executable
/// (i.e. via `swift run`, before we ship a real .app bundle).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make .help() tooltips appear quickly, including the rapid "move to the
        // next item" case (AppKit's default is 1.5s, with a separate ~0.5s
        // quick-mode delay that the public knob doesn't affect).
        Self.makeToolTipsAppearInstantly()

        // Sessions are managed in-app via the sidebar, not native window tabs.
        // Disabling automatic tabbing removes the system tab bar + its "+" button
        // (which would otherwise spawn a whole new window/UI).
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running when the window closes — AppModel (terminals + the opencode
    /// server) lives at app scope and survives, so closing is just hiding the UI.
    /// Reopen via the dock icon or the global show/hide hotkey.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Reopen on dock click: front an existing (e.g. minimized) window, else let
    /// SwiftUI recreate the WindowGroup window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        if let window = sender.windows.first(where: { $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
            return false
        }
        return true  // no window to restore → SwiftUI opens a fresh one
    }

    /// Makes .help() tooltips appear quickly. AppKit's default hover delay is
    /// 1.5s, and its "quick mode" re-show path (moving straight to the next item)
    /// uses a separate ~0.5s delay that the public setter doesn't affect. We set
    /// the base delay AND override the private delay computation, which writes the
    /// result through a `double *` out-parameter. All reflection-guarded so it
    /// safely no-ops if these private APIs ever change.
    private static func makeToolTipsAppearInstantly() {
        let fastDelay = 0.02
        guard let toolTipClass = NSClassFromString("NSToolTipManager") else { return }

        // Baseline initial delay via the supported setter.
        if let classObject = (toolTipClass as AnyObject) as? NSObjectProtocol {
            let sharedSelector = NSSelectorFromString("sharedToolTipManager")
            if classObject.responds(to: sharedSelector),
               let manager = classObject.perform(sharedSelector)?.takeUnretainedValue() as? NSObject,
               manager.responds(to: NSSelectorFromString("setInitialToolTipDelay:")) {
                manager.setValue(fastDelay, forKey: "initialToolTipDelay")
            }
        }

        // Override the delay computation so the quick-mode / subsequent-hover path
        // is fast too. Signature: -(void)_getDisplayDelay:(double*) inQuickMode:(BOOL*) forView:(id).
        let selector = NSSelectorFromString("_getDisplayDelay:inQuickMode:forView:")
        guard let method = class_getInstanceMethod(toolTipClass, selector) else { return }
        typealias Compute = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<ObjCBool>?, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Compute.self)
        let override: @convention(block) (AnyObject, UnsafeMutablePointer<Double>?, UnsafeMutablePointer<ObjCBool>?, AnyObject?) -> Void = { manager, delay, quickMode, view in
            original(manager, selector, delay, quickMode, view)
            delay?.pointee = fastDelay
        }
        method_setImplementation(method, imp_implementationWithBlock(override))
    }
}
