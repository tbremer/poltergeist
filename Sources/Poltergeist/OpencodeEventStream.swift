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
@MainActor
final class OpencodeEventStream {
    var onEvent: (() -> Void)?

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
            guard line.hasPrefix("data:"), Self.isRelevant(line.dropFirst(5)) else { continue }
            onEvent?()
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
