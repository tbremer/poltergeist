import Foundation

/// Subscribes to the opencode v2 server's event stream (`GET /api/event`, SSE)
/// and invokes `onEvent` when something sidebar-relevant happens, reconnecting
/// on drop.
///
/// We don't model payloads — a relevant event is just a cue to refresh the
/// session list (the caller debounces). The stream is chatty while an agent
/// works (text deltas, tool progress, …, many per second), so we skip those
/// high-frequency kinds and non-session events; otherwise the caller's debounce
/// would keep resetting and the sidebar would never refresh mid-turn.
///
/// Separately, prompts that block on the user (permission requests and forms)
/// are parsed and delivered via `onAttention` as they happen.
@MainActor
final class OpencodeEventStream {
    var onEvent: (() -> Void)?
    var onAttention: ((OpencodeAttentionEvent) -> Void)?

    private let connection: OpencodeConnection
    private var task: Task<Void, Never>?

    init(connection: OpencodeConnection) {
        self.connection = connection
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                do { try await self.consume() } catch { /* fall through to retry */ }
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func consume() async throws {
        var request = OpencodeClient(connection: connection).request("api/event")
        request.timeoutInterval = 3600

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5)
            if let attention = OpencodeAttentionEvent(payload: payload) {
                onAttention?(attention)
            }
            if Self.isRelevant(payload) {
                onEvent?()
            }
        }
    }

    private struct EventHeader: Decodable { let type: String? }

    /// Session lifecycle/usage events refresh the sidebar; streaming chatter and
    /// non-session events (server, shell, …) don't.
    private static func isRelevant(_ payload: Substring) -> Bool {
        guard let type = try? JSONDecoder().decode(EventHeader.self, from: Data(payload.utf8)).type,
              type.hasPrefix("session.")
        else { return false }
        return !(type.hasSuffix(".delta") || type.hasSuffix(".progress") || type.hasSuffix(".streamed"))
    }
}

/// A prompt-lifecycle event from the stream. Payload shapes (verified against
/// opencode 2.1.4):
/// - `permission.asked`    `{ id, sessionID, action, resources }`
/// - `permission.replied`  `{ sessionID, requestID, reply }` (`.rejected` alike)
/// - `form.created`        `{ form: { id, sessionID, title } }`
/// - `form.replied` / `form.cancelled`  `{ id, sessionID }`
/// - `session.execution.started` / `.succeeded` / `.failed` / `.interrupted`
///   `{ sessionID }` — a turn starting and ending
enum OpencodeAttentionEvent: Sendable {
    case executionStarted(sessionID: String)
    case executionEnded(sessionID: String)
    case permissionAsked(id: String, sessionID: String, summary: String)
    case permissionResolved(id: String, sessionID: String)
    case formCreated(id: String, sessionID: String, title: String?)
    case formResolved(id: String, sessionID: String)

    private struct Envelope: Decodable {
        let type: String?
        let data: Payload?
    }

    private struct Payload: Decodable {
        let id: String?
        let requestID: String?
        let formID: String?
        let sessionID: String?
        let action: String?
        let resources: [String]?
        let title: String?
        let form: FormInfo?
    }

    private struct FormInfo: Decodable {
        let id: String?
        let sessionID: String?
        let title: String?
    }

    init?(payload: Substring) {
        // Cheap prefilter before decoding: the stream is chatty.
        guard payload.contains("\"permission.") || payload.contains("\"form.")
                || payload.contains("\"session.execution."),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(payload.utf8)),
              let type = envelope.type, let data = envelope.data
        else { return nil }
        switch type {
        case "session.execution.started":
            guard let sessionID = data.sessionID else { return nil }
            self = .executionStarted(sessionID: sessionID)
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            guard let sessionID = data.sessionID else { return nil }
            self = .executionEnded(sessionID: sessionID)
        case "permission.asked":
            guard let id = data.id, let sessionID = data.sessionID else { return nil }
            let summary = [data.action, data.resources?.first].compactMap { $0 }.joined(separator: ": ")
            self = .permissionAsked(id: id, sessionID: sessionID, summary: summary)
        case "permission.replied", "permission.rejected":
            guard let id = data.requestID ?? data.id, let sessionID = data.sessionID else { return nil }
            self = .permissionResolved(id: id, sessionID: sessionID)
        case "form.created":
            guard let form = data.form, let id = form.id, let sessionID = form.sessionID else { return nil }
            self = .formCreated(id: id, sessionID: sessionID, title: form.title)
        case "form.replied", "form.cancelled":
            guard let id = data.id ?? data.formID ?? data.form?.id,
                  let sessionID = data.sessionID ?? data.form?.sessionID
            else { return nil }
            self = .formResolved(id: id, sessionID: sessionID)
        default:
            return nil
        }
    }
}
