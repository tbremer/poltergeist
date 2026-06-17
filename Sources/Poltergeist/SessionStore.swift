import Foundation
import Combine

/// Owns the set of terminal sessions and the current selection.
///
/// This is the source of truth the sidebar and detail pane bind to. Sessions
/// are created/closed here; the underlying PTYs keep running while a session is
/// in the list (even when not the visible one).
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: TerminalSession.ID?

    private var nextOrdinal = 1

    init() {
        newSession()
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
        return session
    }

    func closeSession(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        session.terminate()

        // If we closed the selected one, select the neighbour (next, else last).
        if selectedID == id {
            let next = sessions.indices.contains(index) ? sessions[index] : sessions.last
            selectedID = next?.id
        }
    }
}
