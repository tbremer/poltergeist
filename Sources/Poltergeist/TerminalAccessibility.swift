import AppKit
import GhosttyTerminal

/// Exposes the terminal cursor to Accessibility so tools like emoji pickers,
/// dictation, and screen readers can find it. libghostty-spm's AppTerminalView
/// doesn't implement this (Ghostty.app does, in its own view code).
extension AppTerminalView {
    override open func isAccessibilityElement() -> Bool { true }
    override open func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override open func accessibilityHelp() -> String? { "Terminal content area" }

    /// Terminals have no real text selection model here; report an empty
    /// range at 0 so clients ask for its bounds.
    override open func accessibilitySelectedTextRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    /// Backs AXBoundsForRange: the cursor rect libghostty reports for input methods.
    override open func accessibilityFrame(for range: NSRange) -> NSRect {
        firstRect(forCharacterRange: range, actualRange: nil)
    }
}
