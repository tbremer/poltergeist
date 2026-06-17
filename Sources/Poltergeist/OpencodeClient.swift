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
}
