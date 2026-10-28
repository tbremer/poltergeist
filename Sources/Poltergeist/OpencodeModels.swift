import Foundation

/// A subset of the opencode v2 server's Session object (GET /api/session).
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

    private enum CodingKeys: String, CodingKey {
        case id, title, directory, parentID, cost, tokens, agent, model, version, time
    }

    /// v2 nests the directory as `location.directory`.
    private enum V2Keys: String, CodingKey { case location }
    private struct Location: Decodable { var directory: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        tokens = try c.decodeIfPresent(Tokens.self, forKey: .tokens)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        model = try c.decodeIfPresent(Model.self, forKey: .model)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        time = try c.decodeIfPresent(Time.self, forKey: .time)
        // Flat `directory` is what our on-disk cache (and v1) stores; v2 API
        // responses carry it under `location`.
        let v2 = try decoder.container(keyedBy: V2Keys.self)
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
            ?? v2.decodeIfPresent(Location.self, forKey: .location)?.directory
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

    /// Absolute last-updated timestamp for the relative-date tooltip
    /// (e.g. "Last updated Jun 17, 2026 at 3:42 PM").
    var updatedTooltip: String? {
        guard let updated = time?.updated else { return nil }
        let date = Date(timeIntervalSince1970: updated / 1000)
        return "Last updated \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// A node in the sidebar's project file-tree. A node may be a pure folder, a
/// project directory holding sessions, or both (a project with sub-projects).
struct ProjectTreeNode: Identifiable, Hashable {
    /// Absolute filesystem path of this node (stable identity + expansion key).
    let path: String
    /// Display label for this path component (e.g. "Projects", "~", "Unknown").
    let name: String
    var children: [ProjectTreeNode]
    /// Top-level opencode sessions whose directory is exactly this node's path.
    var sessions: [OpencodeSession]

    var id: String { path }

    /// Total sessions in this node and all descendants (for the folder badge).
    var totalSessions: Int {
        sessions.count + children.reduce(0) { $0 + $1.totalSessions }
    }
}
