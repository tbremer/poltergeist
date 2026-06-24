import Foundation

/// How a split arranges its two panes.
enum SplitAxis: Hashable {
    case sideBySide  // left | right  (horizontal divider drag) — ⌘D
    case stacked     // top / bottom  (vertical divider drag) — ⌘⇧D
}

/// A binary tree of terminal panes for one sidebar tab. Leaves own a live
/// `TerminalSession` (PTY + surface); splits arrange two subtrees with a divider
/// at `fraction` (the share of space given to `first`, 0…1).
indirect enum PaneNode: Identifiable {
    case leaf(TerminalSession)
    case split(id: UUID, axis: SplitAxis, fraction: Double, first: PaneNode, second: PaneNode)

    var id: String {
        switch self {
        case let .leaf(session): return "leaf:\(session.id)"
        case let .split(splitID, _, _, _, _): return "split:\(splitID)"
        }
    }

    /// All sessions at the leaves, left-to-right / top-to-bottom.
    var leaves: [TerminalSession] {
        switch self {
        case let .leaf(session): return [session]
        case let .split(_, _, _, first, second): return first.leaves + second.leaves
        }
    }

    var firstLeaf: TerminalSession? { leaves.first }

    var isSingleLeaf: Bool {
        if case .leaf = self { return true }
        return false
    }

    /// Replaces the leaf whose session id matches with `replacement`, preserving
    /// every existing split's id, axis, and fraction (so unrelated dividers stay
    /// exactly where they are when a sibling pane is split).
    func replacingLeaf(_ id: TerminalSession.ID, with replacement: PaneNode) -> PaneNode {
        switch self {
        case let .leaf(session):
            return session.id == id ? replacement : self
        case let .split(splitID, axis, fraction, first, second):
            return .split(
                id: splitID,
                axis: axis,
                fraction: fraction,
                first: first.replacingLeaf(id, with: replacement),
                second: second.replacingLeaf(id, with: replacement)
            )
        }
    }

    /// Removes the leaf with the given id, collapsing its parent split into the
    /// sibling. Returns the resulting tree (nil if nothing remains) and the
    /// removed session (nil if the id wasn't found).
    func removingLeaf(_ id: TerminalSession.ID) -> (node: PaneNode?, removed: TerminalSession?) {
        switch self {
        case let .leaf(session):
            return session.id == id ? (nil, session) : (self, nil)
        case let .split(splitID, axis, fraction, first, second):
            let fromFirst = first.removingLeaf(id)
            if let removed = fromFirst.removed {
                let node = fromFirst.node.map {
                    PaneNode.split(id: splitID, axis: axis, fraction: fraction, first: $0, second: second)
                } ?? second
                return (node, removed)
            }
            let fromSecond = second.removingLeaf(id)
            if let removed = fromSecond.removed {
                let node = fromSecond.node.map {
                    PaneNode.split(id: splitID, axis: axis, fraction: fraction, first: first, second: $0)
                } ?? first
                return (node, removed)
            }
            return (self, nil)
        }
    }

    /// Returns a copy with the divider `fraction` updated on the split with `id`
    /// (every other split is left exactly as it was).
    func settingFraction(_ value: Double, forSplit id: UUID) -> PaneNode {
        switch self {
        case .leaf:
            return self
        case let .split(splitID, axis, fraction, first, second):
            return .split(
                id: splitID,
                axis: axis,
                fraction: splitID == id ? value : fraction,
                first: first.settingFraction(value, forSplit: id),
                second: second.settingFraction(value, forSplit: id)
            )
        }
    }
}
