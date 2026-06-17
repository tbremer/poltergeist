import Foundation

/// Subscribes to the opencode server's SSE event stream (`GET /event`) and
/// invokes `onEvent` whenever an event arrives, reconnecting on drop.
///
/// We don't parse individual event payloads here — any event is treated as a
/// cue to refresh the session list (the caller debounces).
@MainActor
final class OpencodeEventStream {
    var onEvent: (() -> Void)?

    private let baseURL: URL
    private var task: Task<Void, Never>?

    init(baseURL: URL) {
        self.baseURL = baseURL
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
        var request = URLRequest(url: baseURL.appendingPathComponent("event"))
        request.timeoutInterval = 3600

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            if line.hasPrefix("data:") {
                onEvent?()
            }
        }
    }
}
