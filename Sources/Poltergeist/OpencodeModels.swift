import Foundation

/// A subset of the opencode server's Session object (GET /session).
struct OpencodeSession: Codable, Identifiable, Hashable {
    let id: String
    var title: String?
    var directory: String?
    var parentID: String?
    var cost: Double?
    var tokens: Tokens?
    var agent: String?
    var model: Model?
    var version: String?
    var time: Time?

    struct Tokens: Codable, Hashable {
        var input: Int?
        var output: Int?
        var reasoning: Int?
        var cache: Cache?

        struct Cache: Codable, Hashable {
            var read: Int?
            var write: Int?
        }
    }

    struct Model: Codable, Hashable {
        var id: String?
        var providerID: String?
        var variant: String?
    }

    struct Time: Codable, Hashable {
        var created: Double?
        var updated: Double?
    }

    var totalTokens: Int {
        (tokens?.input ?? 0) + (tokens?.output ?? 0) + (tokens?.reasoning ?? 0)
    }

    var updatedAt: Double { time?.updated ?? 0 }

    /// Lightweight "active" indicator: updated within the last several seconds.
    var isRecentlyActive: Bool {
        guard let updated = time?.updated else { return false }
        return Date().timeIntervalSince1970 * 1000 - updated < 10_000
    }

    /// Dormant indicator: no server-side activity in over 30 days. Sessions with
    /// no recorded update time are treated as not stale.
    var isStale: Bool {
        guard let updated = time?.updated else { return false }
        let thirtyDaysMillis = 30.0 * 24 * 60 * 60 * 1000
        return Date().timeIntervalSince1970 * 1000 - updated > thirtyDaysMillis
    }

    /// Compact "time since last update" for the sidebar (e.g. "2d ago"). nil when
    /// the server reports no update time.
    var updatedRelative: String? {
        guard let updated = time?.updated else { return nil }
        let seconds = Date().timeIntervalSince1970 - updated / 1000
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        case ..<604_800: return "\(Int(seconds / 86_400))d ago"
        case ..<2_592_000: return "\(Int(seconds / 604_800))w ago"
        case ..<31_536_000: return "\(Int(seconds / 2_592_000))mo ago"
        default: return "\(Int(seconds / 31_536_000))y ago"
        }
    }
}

/// A project as returned by GET /project.
struct OpencodeProject: Codable, Identifiable, Hashable {
    let id: String
    var worktree: String?
}

/// Sessions grouped by working directory for the sidebar.
struct OpencodeProjectGroup: Identifiable, Hashable {
    let directory: String
    var sessions: [OpencodeSession]

    var id: String { directory }

    var displayName: String {
        directory == "—" ? "Unknown" : (directory as NSString).abbreviatingWithTildeInPath
    }

    var mostRecent: Double { sessions.map(\.updatedAt).max() ?? 0 }
}
