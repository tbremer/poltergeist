import SwiftUI
import AppKit

/// Poltergeist — an OpenCode-aware terminal built on libghostty/GhosttyKit.
///
/// M0: launchable SwiftUI shell with the GhosttyTerminal dependency linked.
/// Built as a non-bundled SPM executable (no App Sandbox applied), which is the
/// requirement for the real PTY backend in later milestones.
@main
struct PoltergeistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}

/// Ensures the window comes to the foreground when launched as a bare executable
/// (i.e. via `swift run`, before we ship a real .app bundle).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
