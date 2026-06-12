import Foundation

/// Server-side table of stable element handles.
///
/// Previously every interaction tool re-ran a full `AXElementSearch` BFS by
/// role/title/labelContains on each call, and the `path` string returned by
/// `find_elements`/`wait_for_element` was decorative — no tool consumed it.
///
/// `snapshot`/`describe_screen` walks the tree once, hands the model a flat list of
/// numbered elements (`e1`, `e2`, …), and caches the live `AXElement` refs here. The
/// interaction tools then accept an optional `elementId` and do an O(1) lookup instead
/// of another BFS. Ids are monotonic across snapshots so a stale id never silently
/// resolves to a different element after a re-snapshot.
public actor ElementHandleStore {
    public static let shared = ElementHandleStore()

    private struct Entry {
        let pid: pid_t
        let element: AXElement
    }

    private var handles: [String: Entry] = [:]
    private var seq = 0

    private init() {}

    /// Replace ONE app's handles with a fresh snapshot (other apps' handles survive, so
    /// interleaved two-app testing doesn't churn ids). Returns the assigned ids, in
    /// input order.
    @discardableResult
    public func replace(with elements: [AXElement], pid: pid_t) -> [String] {
        handles = handles.filter { $0.value.pid != pid }
        var ids: [String] = []
        ids.reserveCapacity(elements.count)
        for element in elements {
            seq += 1
            let id = "e\(seq)"
            handles[id] = Entry(pid: pid, element: element)
            ids.append(id)
        }
        return ids
    }

    /// Resolve a handle id to its cached element, or nil if unknown/stale.
    public func resolve(_ id: String) -> AXElement? {
        handles[id]?.element
    }
}
