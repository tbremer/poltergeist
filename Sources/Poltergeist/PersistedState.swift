import Foundation

/// Metadata for a session that survives app restarts. The live process is not
/// preserved — on restore we start a fresh shell in the last known working
/// directory.
struct PersistedSession: Codable, Identifiable {
    var id: UUID
    var ordinal: Int
    var customTitle: String?
    var workingDirectory: String?
    var createdAt: Date
}

struct PersistedState: Codable {
    var sessions: [PersistedSession]
    var selectedID: UUID?
    var nextOrdinal: Int
    /// Legacy (pre-tree sidebar): directories the user had expanded. Ignored now.
    var expandedGroups: [String]? = nil
    /// Legacy: previously persisted collapsed folders. Tree expansion is now
    /// in-memory and resets each launch (only the top-level folder opens), so this
    /// is no longer read or written.
    var collapsedGroups: [String]? = nil
}

enum Persistence {
    static func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: AppPaths.sessionsFile) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    static func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: AppPaths.sessionsFile, options: .atomic)
    }
}
