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

    var effectiveFontSize: Float { fontSize ?? 14 }

    /// The font portion of the config as a `TerminalConfiguration`.
    func fontConfiguration() -> TerminalConfiguration {
        var configuration = TerminalConfiguration()
        if let fontFamily, !fontFamily.isEmpty {
            configuration = configuration.fontFamily(fontFamily)
        }
        return configuration.fontSize(effectiveFontSize)
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
