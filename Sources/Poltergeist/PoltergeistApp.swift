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
            CommandMenu("Session") {
                Button("New Terminal") { model.store.newSession() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New OpenCode Session") { Task { await model.newOpencodeSession() } }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!model.server.isReady)
                Divider()
                Button("Close Session") {
                    if let id = model.store.selectedID { model.store.closeSession(id) }
                }
                .keyboardShortcut("w", modifiers: .command)
                Button("Next Session") { model.store.selectNext() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Session") { model.store.selectPrevious() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
