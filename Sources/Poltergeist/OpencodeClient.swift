import Foundation

/// Minimal REST client for the opencode server.
struct OpencodeClient: Sendable {
    let baseURL: URL

    /// Lists sessions, optionally scoped to a project directory.
    ///
    /// The server caps results at 100 by default and ignores offset/cursor
    /// params, so we request a high explicit `limit` to avoid silently
    /// truncating busy projects.
    func listSessions(directory: String?, limit: Int = 1000) async throws -> [OpencodeSession] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("session"),
            resolvingAgainstBaseURL: false
        )
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let directory {
            items.append(URLQueryItem(name: "directory", value: directory))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([OpencodeSession].self, from: data)
    }

    /// Creates a new session in the given directory.
    func createSession(directory: String) async throws -> OpencodeSession {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("session"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "directory", value: directory)]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(OpencodeSession.self, from: data)
    }

    /// Permanently deletes a session.
    func deleteSession(id: String, directory: String?) async throws {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("session").appendingPathComponent(id),
            resolvingAgainstBaseURL: false
        )
        if let directory {
            components?.queryItems = [URLQueryItem(name: "directory", value: directory)]
        }
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    /// Renames a session (PATCH /session/:id with { title }).
    func updateSessionTitle(id: String, title: String, directory: String?) async throws {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("session").appendingPathComponent(id),
            resolvingAgainstBaseURL: false
        )
        if let directory {
            components?.queryItems = [URLQueryItem(name: "directory", value: directory)]
        }
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title])
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}
