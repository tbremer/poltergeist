import Foundation
import GhosttyTerminal

/// User-editable appearance configuration, read from
/// `~/Library/Application Support/Poltergeist/config.json`.
///
/// Example:
/// ```json
/// { "fontFamily": "JetBrains Mono", "fontSize": 13, "theme": "Aardvark Blue" }
/// ```
///
/// `theme` is a name from the GhosttyTheme catalog (iTerm2 color schemes).
/// Changes are applied live (the file is watched).
struct AppConfig: Codable, Equatable {
    var fontFamily: String?
    var fontSize: Float?
    var theme: String?        // single theme (forces window appearance) if light/dark unset
    var lightTheme: String?   // theme for light system appearance
    var darkTheme: String?    // theme for dark system appearance

    // Inactive-pane dimming (applies to unfocused panes when a tab is split).
    var dimInactivePanes: Bool?   // master on/off (default on)
    var inactivePaneDim: Double?  // user-facing amount 0…1 (default 0.5)

    var effectiveFontSize: Float { fontSize ?? 14 }

    var effectiveDimInactivePanes: Bool { dimInactivePanes ?? true }
    /// User-facing dim amount, 0…1 (shown as 0–100%).
    var effectiveInactivePaneDim: Double { min(max(inactivePaneDim ?? 0.5, 0), 1) }

    /// The font portion of the config as a `TerminalConfiguration`.
    ///
    /// `fontThicken(false)` matches Ghostty's own default — libghostty-spm's
    /// `TerminalConfiguration.default` forces `font-thicken = true`, which makes
    /// text noticeably bolder/softer than native Ghostty.
    func fontConfiguration() -> TerminalConfiguration {
        var configuration = TerminalConfiguration()
        if let fontFamily, !fontFamily.isEmpty {
            configuration = configuration.fontFamily(fontFamily)
        }
        return configuration.fontSize(effectiveFontSize).windowPaddingY(0).fontThicken(false)
            .poltergeistKeybinds()
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: AppPaths.configFile),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    static func save(_ config: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: AppPaths.configFile, options: .atomic)
    }
}

extension TerminalConfiguration {
    /// Ghostty binds ⌃Tab / ⌃⇧Tab to next/previous *Ghostty* tab by default;
    /// Poltergeist has no Ghostty tabs, so the press would be consumed and
    /// never reach the program. Unbind them so ⌃Tab (and ⌥Tab, replayed as
    /// ⌃Tab for opencode's tabs) is encoded to the PTY like any other key.
    func poltergeistKeybinds() -> TerminalConfiguration {
        custom("keybind", "ctrl+tab=unbind")
            .custom("keybind", "ctrl+shift+tab=unbind")
    }
}
