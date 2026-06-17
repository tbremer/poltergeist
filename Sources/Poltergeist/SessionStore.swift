import Foundation
import Combine
import AppKit

/// Owns the set of terminal sessions and the current selection, and persists
/// both session metadata and scrollback across launches.
///
/// On launch it restores the previous sessions (replaying saved scrollback and
/// starting fresh shells in the last working directory). The live PTYs keep
/// running while a session is in the list, even when not the visible one.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: TerminalSession.ID?

    private var nextOrdinal = 1
    private var cancellables = Set<AnyCancellable>()
    private var saveWork: DispatchWorkItem?
    private var flushTimer: Timer?

    init() {
        restoreOrCreate()

        // Persist selection changes (e.g. clicking a sidebar row).
        $selectedID
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSave() }
            .store(in: &cancellables)

        // Flush scrollback + metadata on quit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistAll() }
        }

        // Periodic scrollback flush for crash resilience.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushScrollbacks() }
        }
    }

    var selectedSession: TerminalSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    @discardableResult
    func newSession(workingDirectory: URL? = nil) -> TerminalSession {
        let session = TerminalSession(ordinal: nextOrdinal, workingDirectory: workingDirectory)
        nextOrdinal += 1
        sessions.append(session)
        selectedID = session.id
        scheduleSave()
        return session
    }

    func closeSession(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.terminate()
        session.deleteScrollback()

        // If we closed the selected one, select the neighbour (next, else last).
        if selectedID == id {
            let next = sessions.indices.contains(index) ? sessions[index] : sessions.last
            selectedID = next?.id
        }
        scheduleSave()
    }

    func rename(_ id: TerminalSession.ID, to title: String?) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.customTitle = title
        scheduleSave()
    }

    // MARK: - Persistence

    private func restoreOrCreate() {
        guard let state = Persistence.load(), !state.sessions.isEmpty else {
            newSession()
            return
        }

        nextOrdinal = max(state.nextOrdinal, 1)
        for ps in state.sessions {
            let session = TerminalSession(
                id: ps.id,
                ordinal: ps.ordinal,
                customTitle: ps.customTitle,
                workingDirectory: ps.workingDirectory.map { URL(fileURLWithPath: $0) },
                createdAt: ps.createdAt
            )
            sessions.append(session)
        }

        if let sel = state.selectedID, sessions.contains(where: { $0.id == sel }) {
            selectedID = sel
        } else {
            selectedID = sessions.first?.id
        }

        // Never reuse an ordinal that's still in the list.
        nextOrdinal = max(nextOrdinal, (sessions.map(\.ordinal).max() ?? 0) + 1)
    }

    private func snapshot() -> PersistedState {
        PersistedState(
            sessions: sessions.map {
                PersistedSession(
                    id: $0.id,
                    ordinal: $0.ordinal,
                    customTitle: $0.customTitle,
                    workingDirectory: $0.currentDirectory,
                    createdAt: $0.createdAt
                )
            },
            selectedID: selectedID,
            nextOrdinal: nextOrdinal
        )
    }

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.persistMetadata() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func persistMetadata() {
        Persistence.save(snapshot())
    }

    private func flushScrollbacks() {
        for session in sessions { session.flush() }
    }

    func persistAll() {
        flushScrollbacks()
        persistMetadata()
    }
}
