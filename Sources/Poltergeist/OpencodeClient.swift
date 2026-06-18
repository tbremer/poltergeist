import Foundation

/// Minimal REST client for the opencode server.
struct OpencodeClient: Sendable {
    let baseURL: URL

    /// Lists sessions, optionally scoped to a project directory.
    func listSessions(directory: String?) async throws -> [OpencodeSession] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("session"),
            resolvingAgainstBaseURL: false
        )
        if let directory {
            components?.queryItems = [URLQueryItem(name: "directory", value: directory)]
        }
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([OpencodeSession].self, from: data)
    }

    /// Lists all known projects.
    func listProjects() async throws -> [OpencodeProject] {
        var request = URLRequest(url: baseURL.appendingPathComponent("project"))
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode([OpencodeProject].self, from: data)
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
}
