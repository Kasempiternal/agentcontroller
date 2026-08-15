import Foundation
import ApplicationServices

public struct AXElementSearchCriteria: Sendable {
    public var role: String?
    public var title: String?
    public var titleContains: String?
    public var identifier: String?
    public var value: String?
    public var description: String?
    public var descriptionContains: String?
    /// Case-insensitive substring match across `title`, `description`, `help`, and `value`.
    /// Use when you see visible text on screen but don't know which AX attribute carries it
    /// (SwiftUI puts labels in different attributes depending on Button/Text/Image variants).
    public var labelContains: String?
    public var maxResults: Int
    /// 0-based index to disambiguate several identical matches. When non-nil, `find`
    /// returns the single element at this position among ALL matches (collecting past
    /// `maxResults` as needed, up to a sane internal cap) instead of the first matches.
    /// When nil, behavior is unchanged. Set via the memberwise init or assigned after
    /// init (e.g. `criteria.index = n`).
    public var index: Int?

    public init(role: String? = nil, title: String? = nil, titleContains: String? = nil,
                identifier: String? = nil, value: String? = nil,
                description: String? = nil, descriptionContains: String? = nil,
                labelContains: String? = nil,
                maxResults: Int = 20,
                index: Int? = nil) {
        self.role = role
        self.title = title
        self.titleContains = titleContains
        self.identifier = identifier
        self.value = value
        self.description = description
        self.descriptionContains = descriptionContains
        self.labelContains = labelContains
        self.maxResults = maxResults
        self.index = index
    }

    /// True when at least one element matcher is set. `matches` requires this
    /// (empty criteria must never match everything), and callers use it to
    /// distinguish "stale handle with a selector fallback" from "stale handle
    /// with nothing to fall back to".
    public var hasAnyMatcher: Bool {
        criteriaCount > 0
    }

    /// How many element matchers are set. The denominator for a partial-match score:
    /// an element satisfying `criteriaCount` criteria is a hit, one satisfying some but
    /// not all is a near miss.
    public var criteriaCount: Int {
        var n = 0
        for set in [role, title, titleContains, identifier, value,
                    description, descriptionContains, labelContains] where set != nil {
            n += 1
        }
        return n
    }
}

public struct AXElementSearchResult: Sendable {
    public let element: AXElement
    public let path: String
    public let depth: Int
}

/// What a completed walk saw, beyond the elements it matched.
///
/// Exists so a caller can tell "this control has not rendered yet" apart from "this
/// selector describes nothing in this app". Both look identical from a zero-result
/// search, but they deserve opposite responses: the first is worth waiting out, the
/// second is a 4-second wait for an answer that cannot change.
public struct AXSearchProbe: Sendable {
    /// Elements actually walked. A near-zero count means the UI had not rendered.
    public let nodesVisited: Int
    /// Elements that satisfied at least one criterion but not all of them — evidence
    /// that something *like* the target is present (right role, wrong title; right
    /// label, wrong role).
    public let nearMisses: Int
    /// Elements that satisfied every criterion but one. A strong signal the target
    /// exists and is mid-update (a button whose title is still changing).
    public let oneAway: Int
    /// How many criteria the caller supplied.
    public let criteriaCount: Int

    public static let empty = AXSearchProbe(nodesVisited: 0, nearMisses: 0, oneAway: 0, criteriaCount: 0)
}

public struct AXElementSearch {
    /// Hard cap on total nodes visited during a single BFS, regardless of `maxDepth` /
    /// `maxResults`. Guards against a malformed (or maliciously cyclic) AX tree blowing
    /// up time/memory. Combined with the per-element identity visited-set below.
    private static let maxNodesVisited = 10_000

    /// When `criteria.index` is set, we keep collecting matches past `maxResults` so we
    /// can reach the Nth one, but still bound total matches collected.
    private static let indexMatchCap = 5_000

    /// Attributes a single node may need for matching + building its children's path
    /// labels. Read once per node in one batched IPC round-trip (vs 6-9 separate reads).
    private static let matchAttrs: [String] = [
        kAXRoleAttribute as String,
        kAXTitleAttribute as String,
        kAXIdentifierAttribute as String,
        kAXValueAttribute as String,
        kAXDescriptionAttribute as String,
        kAXHelpAttribute as String,
        kAXChildrenAttribute as String,
    ]

    /// Default `maxDepth` matches `snapshot`'s walk depth (12) — a shallower
    /// search default meant an element visible in a snapshot could be
    /// unreachable by the selector-based tools (click/assert/wait).
    public static func find(root: AXElement, criteria: AXElementSearchCriteria, maxDepth: Int = 12) -> [AXElementSearchResult] {
        findProbing(root: root, criteria: criteria, maxDepth: maxDepth).results
    }

    /// `find`, plus what the walk saw on the way. Same cost — the probe counters are
    /// accumulated from the per-node attribute snapshot the match already reads.
    public static func findProbing(
        root: AXElement,
        criteria: AXElementSearchCriteria,
        maxDepth: Int = 12
    ) -> (results: [AXElementSearchResult], probe: AXSearchProbe) {
        var results: [AXElementSearchResult] = []
        var probe = AXSearchProbe.empty
        bfs(root: root, criteria: criteria, maxDepth: maxDepth, results: &results, probe: &probe)

        // Nth-match selection: when `index` is set, return exactly the element at that
        // 0-based position among all collected matches (empty if out of range).
        if let n = criteria.index {
            guard n >= 0, n < results.count else { return ([], probe) }
            return ([results[n]], probe)
        }
        return (results, probe)
    }

    private static func bfs(root: AXElement, criteria: AXElementSearchCriteria, maxDepth: Int,
                            results: inout [AXElementSearchResult], probe: inout AXSearchProbe) {
        // Probe counters, accumulated from the same per-node attribute snapshot the
        // match reads — the walk costs no more than it did before.
        var nearMisses = 0
        var oneAway = 0

        // Each queue entry carries its PARENT's path prefix and its own sibling index.
        // The full path label (`role:name`) is built from the node's OWN batched
        // snapshot when it is dequeued — so each node is read exactly once.
        // O(1) dequeue via head cursor instead of O(n) `removeFirst()`.
        var queue: [(element: AXElement, parentPath: String, siblingIndex: Int, depth: Int)] =
            [(root, "", -1, 0)]
        var head = 0

        // Cycle / explosion guard: stop revisiting the same element (keyed by AX element
        // identity hash) and cap total nodes visited.
        var visited = Set<Int>()
        var nodesVisited = 0

        // When `index` is requested we must collect enough matches to reach the Nth, so
        // the per-loop result limit is relaxed (still bounded by `indexMatchCap`).
        let collectingForIndex = criteria.index != nil
        let resultLimit = collectingForIndex ? indexMatchCap : criteria.maxResults

        while head < queue.count && results.count < resultLimit && nodesVisited < maxNodesVisited {
            let (element, parentPath, siblingIndex, depth) = queue[head]
            head += 1

            if !visited.insert(Int(bitPattern: CFHash(element.ref))).inserted { continue }
            nodesVisited += 1

            // Single batched read per node, reused for matching, this node's path label,
            // and enumerating children.
            let attrs = element.readAttributes(matchAttrs)

            // Build this node's path from its own snapshot. Root keeps the literal "root".
            let path: String
            if depth == 0 {
                path = "root"
            } else {
                let role = (attrs[kAXRoleAttribute as String] as? String) ?? "element"
                let name = (attrs[kAXTitleAttribute as String] as? String)
                    ?? (attrs[kAXIdentifierAttribute as String] as? String)
                    ?? "\(siblingIndex)"
                path = "\(parentPath)/\(role):\(name)"
            }

            let satisfied = satisfiedCriteria(attrs, criteria: criteria)
            if satisfied == criteria.criteriaCount && criteria.hasAnyMatcher {
                results.append(AXElementSearchResult(element: element, path: path, depth: depth))
            } else if satisfied > 0 {
                nearMisses += 1
                if satisfied == criteria.criteriaCount - 1 { oneAway += 1 }
            }

            if depth < maxDepth {
                let kids = AXElement.elements(fromCFArray: attrs[kAXChildrenAttribute as String])
                for (i, child) in kids.enumerated() {
                    queue.append((child, path, i, depth + 1))
                }
            }
        }

        probe = AXSearchProbe(
            nodesVisited: nodesVisited,
            nearMisses: nearMisses,
            oneAway: oneAway,
            criteriaCount: criteria.criteriaCount
        )
    }

    /// How many of the supplied criteria this node satisfies, from a single pre-read
    /// attribute snapshot. Matching semantics are unchanged:
    /// - exact matches: role / title / identifier / value (AXValue as String) / description
    /// - *Contains / labelContains: case-insensitive substring
    /// - labelContains haystack = title / description(label) / help / value
    ///
    /// A full match is `satisfied == criteria.criteriaCount` (with at least one criterion
    /// set). Counting instead of short-circuiting on the first failure is what lets a
    /// caller tell "nothing here resembles the target" from "the target is one attribute
    /// away from matching" — the difference between a hopeless retry and a useful one.
    private static func satisfiedCriteria(_ attrs: [String: CFTypeRef], criteria: AXElementSearchCriteria) -> Int {
        let roleVal = attrs[kAXRoleAttribute as String] as? String
        let titleVal = attrs[kAXTitleAttribute as String] as? String
        let identifierVal = attrs[kAXIdentifierAttribute as String] as? String
        let descriptionVal = attrs[kAXDescriptionAttribute as String] as? String
        let helpVal = attrs[kAXHelpAttribute as String] as? String
        // `stringValue` historically only surfaced String AXValues; keep that semantics
        // for matching (non-string values were nil before).
        let valueVal = attrs[kAXValueAttribute as String] as? String

        var satisfied = 0
        if let role = criteria.role, roleVal == role { satisfied += 1 }
        if let title = criteria.title, titleVal == title { satisfied += 1 }
        if let contains = criteria.titleContains,
           let t = titleVal, t.localizedCaseInsensitiveContains(contains) { satisfied += 1 }
        if let identifier = criteria.identifier, identifierVal == identifier { satisfied += 1 }
        if let value = criteria.value, valueVal == value { satisfied += 1 }
        if let description = criteria.description, descriptionVal == description { satisfied += 1 }
        if let contains = criteria.descriptionContains,
           let d = descriptionVal, d.localizedCaseInsensitiveContains(contains) { satisfied += 1 }
        if let contains = criteria.labelContains {
            let haystacks = [titleVal, descriptionVal, helpVal, valueVal].compactMap { $0 }
            if haystacks.contains(where: { $0.localizedCaseInsensitiveContains(contains) }) { satisfied += 1 }
        }
        return satisfied
    }
}
