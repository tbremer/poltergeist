import Foundation
import Combine
import AppKit

/// Top-level app state: owns the opencode server, the terminal session store,
/// and the live opencode session list shown in the sidebar.
@MainActor
final class AppModel: ObservableObject {
    let server: OpencodeServerManager
    let store: SessionStore

    /// opencode sessions for the currently selected terminal's directory.
    @Published private(set) var opencodeSessions: [OpencodeSession] = []

    private let client: OpencodeClient?
    private var eventStream: OpencodeEventStream?
    private var cancellables = Set<AnyCancellable>()
    private var refreshWork: DispatchWorkItem?

    init() {
        let server = OpencodeServerManager()
        self.server = server

        // Point every terminal at the (soon-to-be-ready) shared server.
        var overrides: [String: String] = [:]
        if let base = server.baseURL {
            overrides["OPENCODE_BASE_URL"] = base.absoluteString
        }
        store = SessionStore(environmentOverrides: overrides)

        client = server.baseURL.map { OpencodeClient(baseURL: $0) }

        server.start()

        if let base = server.baseURL {
            let stream = OpencodeEventStream(baseURL: base)
            stream.onEvent = { [weak self] in self?.scheduleRefresh() }
            stream.start()
            eventStream = stream
        }

        // Refresh the opencode list when the active terminal (its directory)
        // changes, and when the server becomes ready.
        store.$selectedID
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        server.$status
            .sink { [weak self] status in
                if status == .running { self?.scheduleRefresh() }
            }
            .store(in: &cancellables)
        // Surface server status changes (starting → running) to the UI.
        server.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.server.stop() }
        }
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func refresh() async {
        guard let client else { return }
        let directory = store.selectedSession?.currentDirectory
        guard let list = try? await client.listSessions(directory: directory) else { return }
        opencodeSessions = list
            .filter { $0.parentID == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
