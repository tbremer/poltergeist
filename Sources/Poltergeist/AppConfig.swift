import Foundation

/// User-editable appearance configuration, read from
/// `~/Library/Application Support/Poltergeist/config.json`.
///
/// Example:
/// ```json
/// { "fontFamily": "JetBrains Mono", "fontSize": 13 }
/// ```
struct AppConfig: Codable {
    var fontFamily: String?
    var fontSize: Float?

    var effectiveFontSize: Float { fontSize ?? 14 }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: AppPaths.configFile),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }
}
