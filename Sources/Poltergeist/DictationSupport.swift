import AppKit
import ObjectiveC
import GhosttyTerminal

/// Makes macOS dictation available in terminals by patching three of
/// libghostty-spm's `NSTextInputClient` methods on `AppTerminalView` to
/// behave like upstream Ghostty's `SurfaceView` (where dictation works):
///
/// - `selectedRange()`: the library returns `{NSNotFound, 0}` whenever no IME
///   composition is in progress, i.e. "no insertion point", so macOS never
///   offers dictation (the mic doesn't appear). Report an empty selection at
///   0 instead.
/// - `firstRect(forCharacterRange:actualRange:)`: zero width for an empty
///   range, so the dictation mic indicator anchors at the cursor.
/// - `characterIndex(for:)`: 0 rather than `NSNotFound`.
///
/// Swapped in at runtime (the methods live in the library's own extension, so
/// they can't be overridden from here). Remove once libghostty-spm fixes it.
@MainActor
enum DictationSupport {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        patch(#selector(NSTextInputClient.selectedRange)) { (original: @escaping SelectedRange) in
            let block: @convention(block) (AnyObject) -> NSRange = { view in
                let range = original(view, #selector(NSTextInputClient.selectedRange))
                return range.location == NSNotFound ? NSRange(location: 0, length: 0) : range
            }
            return block
        }

        let firstRect = #selector(NSTextInputClient.firstRect(forCharacterRange:actualRange:))
        patch(firstRect) { (original: @escaping FirstRect) in
            let block: @convention(block) (AnyObject, NSRange, NSRangePointer?) -> NSRect = { view, range, actual in
                var rect = original(view, firstRect, range, actual)
                if range.length == 0 { rect.size.width = 0 }
                return rect
            }
            return block
        }

        patch(#selector(NSTextInputClient.characterIndex(for:))) { (_: CharacterIndex) in
            let block: @convention(block) (AnyObject, NSPoint) -> Int = { _, _ in 0 }
            return block
        }
    }

    private typealias SelectedRange = @convention(c) (AnyObject, Selector) -> NSRange
    private typealias FirstRect = @convention(c) (AnyObject, Selector, NSRange, NSRangePointer?) -> NSRect
    private typealias CharacterIndex = @convention(c) (AnyObject, Selector, NSPoint) -> Int

    /// Replaces `selector` on `AppTerminalView` with the block built from its
    /// original implementation. Only touches a method the class itself
    /// defines, never one inherited from NSView.
    private static func patch<Original>(_ selector: Selector, _ makeBlock: (Original) -> Any) {
        let cls: AnyClass = AppTerminalView.self
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return }
        defer { free(methods) }
        guard let method = (0 ..< Int(count)).map({ methods[$0] }).first(where: { method_getName($0) == selector })
        else {
            FocusDebug.log("dictation: \(NSStringFromSelector(selector)) not found on AppTerminalView; not patched")
            return
        }
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        method_setImplementation(method, imp_implementationWithBlock(makeBlock(original)))
        FocusDebug.log("dictation: patched \(NSStringFromSelector(selector))")
    }
}
