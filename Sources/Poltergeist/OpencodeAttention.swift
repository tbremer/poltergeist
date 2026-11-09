import AppKit
import SwiftUI
import UserNotifications

/// Why an opencode session is waiting on the user, in priority order.
enum OpencodeAttention: Int, Comparable, Sendable {
    /// The agent finished its turn and is idle — your move (not blocked).
    case finished
    /// A form/question is waiting for an answer (blocked).
    case question
    /// A permission request is waiting for a decision (blocked).
    case permission

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var symbol: String {
        switch self {
        case .finished: return "circle.fill"
        case .question: return "questionmark.bubble.fill"
        case .permission: return "hand.raised.fill"
        }
    }

    var color: Color {
        switch self {
        case .finished: return .accentColor
        case .question, .permission: return .orange
        }
    }

    var help: String {
        switch self {
        case .finished: return "Finished — waiting for your next prompt"
        case .question: return "Waiting for your answer"
        case .permission: return "Waiting for permission"
        }
    }
}

/// Tracks which top-level opencode sessions are waiting on the user.
///
/// - Blocked states come from the event stream (`permission.asked`/`.replied`,
///   `form.created`/`.replied`/`.cancelled`), plus a one-time sync of pending
///   prompts for running sessions on (re)connect.
/// - "Finished" comes from `session.execution.*` events (a root session's turn
///   ending), with `GET /api/session/active` polled as a backstop for events
///   missed while the stream was down. It clears when the user looks at the
///   session (see `AppModel`) or it starts running again.
///
/// Subagent (child) sessions are folded into their root session, since that's
/// what the sidebar shows and what the user interacts with.
@MainActor
final class OpencodeAttentionTracker: ObservableObject {
    /// Root session ID → strongest current reason it's waiting.
    @Published private(set) var states: [String: OpencodeAttention] = [:]

    /// A root newly entered a state or escalated (root, state, detail text).
    var onRaised: ((String, OpencodeAttention, String?) -> Void)?
    /// Whether the user is looking at this root right now; a turn that ends
    /// while they watch isn't flagged as "finished".
    var isWatching: (String) -> Bool = { _ in false }
    /// IDs known to be roots (the sidebar's session list).
    var knownRoots: () -> Set<String> = { [] }

    private var client: OpencodeClient?
    private var rootOf: [String: String] = [:]
    private var permissions: [String: (root: String, detail: String?)] = [:]
    private var forms: [String: (root: String, detail: String?)] = [:]
    /// Prompts resolved before their (async-resolved) "asked" landed.
    private var resolvedPromptIDs: Set<String> = []
    private var finished: Set<String> = []
    private var activeRoots: Set<String> = []
    private var hasActiveBaseline = false

    var hasActiveRoots: Bool { !activeRoots.isEmpty }

    /// Starts over for a new server connection (nil = disconnected).
    func reset(client: OpencodeClient?) {
        self.client = client
        rootOf = [:]
        permissions = [:]
        forms = [:]
        resolvedPromptIDs = []
        finished = []
        activeRoots = []
        hasActiveBaseline = false
        publish(notify: false)
    }

    func handle(_ event: OpencodeAttentionEvent) async {
        switch event {
        case .executionStarted(let sessionID):
            let root = await resolveRoot(sessionID)
            activeRoots.insert(root)
            finished.remove(root)
        case .executionEnded(let sessionID):
            // A subagent finishing doesn't mean the root's turn is over.
            let root = await resolveRoot(sessionID)
            guard root == sessionID else { return }
            activeRoots.remove(root)
            if !isWatching(root) { finished.insert(root) }
        case .permissionAsked(let id, let sessionID, let summary):
            let root = await resolveRoot(sessionID)
            guard !resolvedPromptIDs.contains(id) else { return }
            permissions[id] = (root, summary.isEmpty ? nil : summary)
        case .permissionResolved(let id, _):
            if permissions.removeValue(forKey: id) == nil { resolvedPromptIDs.insert(id) }
        case .formCreated(let id, let sessionID, let title):
            let root = await resolveRoot(sessionID)
            guard !resolvedPromptIDs.contains(id) else { return }
            forms[id] = (root, title)
        case .formResolved(let id, _):
            if forms.removeValue(forKey: id) == nil { resolvedPromptIDs.insert(id) }
        }
        publish(notify: true)
    }

    /// Re-reads which sessions are running and flags roots whose turn ended.
    func pollActive() async {
        guard let client, let ids = try? await client.activeSessionIDs() else { return }
        var roots = Set<String>()
        for id in ids { roots.insert(await resolveRoot(id)) }
        if hasActiveBaseline {
            for root in activeRoots.subtracting(roots) where !isWatching(root) {
                finished.insert(root)
            }
        }
        finished.subtract(roots)
        activeRoots = roots
        hasActiveBaseline = true
        publish(notify: true)
    }

    /// Picks up prompts already pending when we connect (events only cover
    /// what happens afterwards). Only running sessions can be blocked on one.
    func syncPending() async {
        guard let client, let ids = try? await client.activeSessionIDs() else { return }
        for id in ids {
            let root = await resolveRoot(id)
            for request in (try? await client.pendingPermissions(sessionID: id)) ?? [] {
                let summary = [request.action, request.resources?.first].compactMap { $0 }.joined(separator: ": ")
                permissions[request.id] = (root, summary.isEmpty ? nil : summary)
            }
            for form in (try? await client.pendingForms(sessionID: id)) ?? [] {
                forms[form.id] = (root, form.title)
            }
        }
        publish(notify: false)
    }

    /// The user has seen `root`; drop its "finished" flag.
    func clearFinished(_ root: String) {
        guard finished.remove(root) != nil else { return }
        publish(notify: false)
    }

    // MARK: - Private

    /// Maps a (possibly subagent) session ID to its root, caching the walk.
    private func resolveRoot(_ id: String) async -> String {
        if knownRoots().contains(id) { return id }
        if let cached = rootOf[id] { return cached }
        var current = id
        for _ in 0 ..< 8 {
            guard let client, let session = try? await client.session(id: current) else { break }
            guard let parent = session.parentID else { break }
            current = parent
        }
        rootOf[id] = current
        return current
    }

    private func publish(notify: Bool) {
        var next: [String: OpencodeAttention] = [:]
        var detail: [String: String] = [:]
        for root in finished { next[root] = .finished }
        for (_, form) in forms {
            next[form.root] = max(next[form.root] ?? .question, .question)
            if let text = form.detail { detail[form.root] = text }
        }
        for (_, request) in permissions {
            next[request.root] = .permission
            if let text = request.detail { detail[request.root] = text }
        }
        guard next != states else { return }
        if notify {
            for (root, state) in next {
                if let old = states[root], old >= state { continue }  // not new, not escalated
                onRaised?(root, state, detail[root])
            }
        }
        states = next
    }
}

/// Posts a macOS notification when a session starts waiting, and opens its
/// target (a tab ID, or an opencode session ID) when the notification is clicked. Needs a real app bundle (the
/// notification center is unavailable to a bare `swift build` binary, where
/// this quietly does nothing).
@MainActor
final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Clicked a notification for this target.
    var onOpen: ((String) -> Void)?

    private let center: UNUserNotificationCenter?
    private var authorized: Bool?

    override init() {
        center = Bundle.main.bundleIdentifier != nil ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    func post(target: String, title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["target": target]
        let request = UNNotificationRequest(identifier: Self.identifier(target), content: content, trigger: nil)
        Task { @MainActor in
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            try? await center.add(request)
        }
    }

    /// Removes a delivered notification once its target stops waiting.
    func withdraw(target: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier(target)])
    }

    private static func identifier(_ target: String) -> String { "attention-\(target)" }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let target = response.notification.request.content.userInfo["target"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let target { self.onOpen?(target) }
            }
        }
        completionHandler()
    }
}

/// Small trailing indicator for a session row.
struct AttentionBadge: View {
    let attention: OpencodeAttention

    var body: some View {
        Image(systemName: attention.symbol)
            .font(attention == .finished ? .system(size: 7) : .caption)
            .foregroundStyle(attention.color)
            .help(attention.help)
    }
}
