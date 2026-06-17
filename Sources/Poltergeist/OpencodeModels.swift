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
}
