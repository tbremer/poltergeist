import Foundation

/// Minimal REST client for the opencode v2 server API (`/api/...`, HTTP Basic
/// auth with username `opencode`). Responses wrap payloads in `{ "data": … }`.
struct OpencodeClient: Sendable {
    let connection: OpencodeConnection

    /// Lists every top-level (root), non-archived session across all projects.
    /// The listing is global (every project), so one paginated query covers
    /// everything. Follows `cursor.next` until a page comes back empty.
    func listRootSessions(pageSize: Int = 100, maxPages: Int = 100) async throws -> [OpencodeSession] {
        var sessions: [OpencodeSession] = []
        var seen = Set<String>()
        var cursor: String?
        for _ in 0 ..< maxPages {
            var query = [
                URLQueryItem(name: "parentID", value: "null"),
                URLQueryItem(name: "archived", value: "false"),
                URLQueryItem(name: "limit", value: String(pageSize)),
            ]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: SessionsPage = try await send(request("api/session", query: query))
            let fresh = page.data.filter { seen.insert($0.id).inserted }
            sessions += fresh
            guard !fresh.isEmpty, let next = page.cursor.next else { break }
            cursor = next
        }
        return sessions
    }

    /// Creates a new session located in `directory`.
    func createSession(directory: String) async throws -> OpencodeSession {
        var req = request("api/session", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["location": ["directory": directory]])
        req.timeoutInterval = 10
        let envelope: Envelope<OpencodeSession> = try await send(req)
        return envelope.data
    }

    /// Permanently deletes a session.
    func deleteSession(id: String) async throws {
        var req = request("api/session/\(id)", method: "DELETE")
        req.timeoutInterval = 10
        try await sendIgnoringBody(req)
    }

    /// Renames a session (PATCH /api/session/:id with { title }).
    func updateSessionTitle(id: String, title: String) async throws {
        var req = request("api/session/\(id)", method: "PATCH")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["title": title])
        req.timeoutInterval = 10
        try await sendIgnoringBody(req)
    }

    // MARK: - Plumbing

    /// An authenticated request for `path` (relative to the server root).
    func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(
            url: connection.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        var req = URLRequest(url: components?.url ?? connection.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 5
        if method != "GET" { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let password = connection.password {
            let token = Data("opencode:\(password)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendIgnoringBody(_ req: URLRequest) async throws {
        let (_, response) = try await URLSession.shared.data(for: req)
        try Self.check(response)
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    private struct Envelope<T: Decodable>: Decodable { let data: T }

    private struct SessionsPage: Decodable {
        let data: [OpencodeSession]
        let cursor: Cursor
        struct Cursor: Decodable { let next: String? }
    }
}
