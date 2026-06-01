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
}

public struct AXElementSearchResult: Sendable {
    public let element: AXElement
    public let path: String
    public let depth: Int
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

    public static func find(root: AXElement, criteria: AXElementSearchCriteria, maxDepth: Int = 10) -> [AXElementSearchResult] {
        var results: [AXElementSearchResult] = []
        bfs(root: root, criteria: criteria, maxDepth: maxDepth, results: &results)

        // Nth-match selection: when `index` is set, return exactly the element at that
        // 0-based position among all collected matches (empty if out of range).
        if let n = criteria.index {
            guard n >= 0, n < results.count else { return [] }
            return [results[n]]
        }
        return results
    }

    private static func bfs(root: AXElement, criteria: AXElementSearchCriteria, maxDepth: Int,
                            results: inout [AXElementSearchResult]) {
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

            if matches(attrs, criteria: criteria) {
                results.append(AXElementSearchResult(element: element, path: path, depth: depth))
            }

            if depth < maxDepth {
                let kids = AXElement.elements(fromCFArray: attrs[kAXChildrenAttribute as String])
                for (i, child) in kids.enumerated() {
                    queue.append((child, path, i, depth + 1))
                }
            }
        }
    }

    /// Match a node against the criteria using a single pre-read attribute snapshot.
    /// Semantics are identical to the previous per-attribute implementation:
    /// - exact matches: role / title / identifier / value (AXValue as String) / description
    /// - *Contains / labelContains: case-insensitive substring
    /// - labelContains haystack = title / description(label) / help / value
    /// - requires at least one criterion (`anyCriterion`)
    private static func matches(_ attrs: [String: CFTypeRef], criteria: AXElementSearchCriteria) -> Bool {
        let roleVal = attrs[kAXRoleAttribute as String] as? String
        let titleVal = attrs[kAXTitleAttribute as String] as? String
        let identifierVal = attrs[kAXIdentifierAttribute as String] as? String
        let descriptionVal = attrs[kAXDescriptionAttribute as String] as? String
        let helpVal = attrs[kAXHelpAttribute as String] as? String
        // `stringValue` historically only surfaced String AXValues; keep that semantics
        // for matching (non-string values were nil before).
        let valueVal = attrs[kAXValueAttribute as String] as? String

        if let role = criteria.role, roleVal != role { return false }
        if let title = criteria.title, titleVal != title { return false }
        if let contains = criteria.titleContains {
            guard let t = titleVal, t.localizedCaseInsensitiveContains(contains) else { return false }
        }
        if let identifier = criteria.identifier, identifierVal != identifier { return false }
        if let value = criteria.value, valueVal != value { return false }
        if let description = criteria.description, descriptionVal != description { return false }
        if let contains = criteria.descriptionContains {
            guard let d = descriptionVal, d.localizedCaseInsensitiveContains(contains) else { return false }
        }
        if let contains = criteria.labelContains {
            let haystacks = [titleVal, descriptionVal, helpVal, valueVal].compactMap { $0 }
            guard haystacks.contains(where: { $0.localizedCaseInsensitiveContains(contains) }) else { return false }
        }
        let anyCriterion = criteria.role != nil || criteria.title != nil || criteria.titleContains != nil
            || criteria.identifier != nil || criteria.value != nil
            || criteria.description != nil || criteria.descriptionContains != nil
            || criteria.labelContains != nil
        return anyCriterion
    }
}
