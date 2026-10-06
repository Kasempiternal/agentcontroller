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
    /// Walk the menu bar when the search root is an application element. Off by default:
    /// the menu bar holds hundreds of always-present items (every "Close", "Save", "Copy"
    /// the app has), so an app-wide `titleContains: "Save"` matched a closed menu entry
    /// and assert_visible passed with no Save dialog on screen. Roles starting with
    /// "AXMenu" opt in implicitly — asking for a menu item is asking for the menu bar.
    public var includeMenus: Bool

    public init(role: String? = nil, title: String? = nil, titleContains: String? = nil,
                identifier: String? = nil, value: String? = nil,
                description: String? = nil, descriptionContains: String? = nil,
                labelContains: String? = nil,
                maxResults: Int = 20,
                index: Int? = nil,
                includeMenus: Bool = false) {
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
        self.includeMenus = includeMenus
    }

    /// Whether an application-rooted search descends into the menu bar.
    public var walksMenuBar: Bool {
        includeMenus || role?.hasPrefix("AXMenu") == true
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
    /// Visited elements whose attributes could not be read at all (hung, busy or gone).
    /// Their subtrees were never enumerated, so a miss says nothing about them.
    public let unreadableNodes: Int
    /// The search root itself could not be read.
    public let rootUnreadable: Bool
    /// The root is an application and its window list READ BACK as empty (an answer, not a
    /// failed read): the app is running with nothing on screen. A walk of such an app
    /// visits only the root, which looks exactly like an app that exposes no tree.
    public let appHasNoWindows: Bool

    public init(nodesVisited: Int, nearMisses: Int, oneAway: Int, criteriaCount: Int,
                unreadableNodes: Int = 0, rootUnreadable: Bool = false, appHasNoWindows: Bool = false) {
        self.nodesVisited = nodesVisited
        self.nearMisses = nearMisses
        self.oneAway = oneAway
        self.criteriaCount = criteriaCount
        self.unreadableNodes = unreadableNodes
        self.rootUnreadable = rootUnreadable
        self.appHasNoWindows = appHasNoWindows
    }

    public static let empty = AXSearchProbe(nodesVisited: 0, nearMisses: 0, oneAway: 0, criteriaCount: 0)

    /// Whether a zero-result walk is evidence of absence. A walk that read the root, got
    /// at least one level below it, and could read nearly everything it touched actually
    /// looked; anything less (dead pid, hung app, no accessibility permission, a window
    /// that exposes nothing) returns zero results too, and must not be mistaken for
    /// "the element is gone". An app whose window list read back empty has nothing on
    /// screen to be found, so its one-node walk is complete rather than uninformative.
    public var isConclusive: Bool {
        if rootUnreadable { return false }
        if appHasNoWindows { return true }
        return nodesVisited >= 2 && unreadableNodes * 4 <= nodesVisited
    }
}

public struct AXElementSearch {
    /// Hard cap on total nodes visited during a single BFS, regardless of `maxDepth` /
    /// `maxResults`. Guards against a malformed (or maliciously cyclic) AX tree blowing
    /// up time/memory. Combined with the per-element identity visited-set below.
    private static let maxNodesVisited = 10_000

    /// When `criteria.index` is set, we keep collecting matches past `maxResults` so we
    /// can reach the Nth one, but still bound total matches collected.
    private static let indexMatchCap = 5_000

    /// Attributes one node needs for THIS search, read in one batched IPC round-trip.
    /// role/title/identifier build the path label and children drive the walk, so they are
    /// always read. The rest are fetched only when a criterion looks at them — AXValue in
    /// particular is the full text of every text area, and used to cross IPC for every node
    /// of every poll even when the selector was a button title.
    static func matchAttributes(for criteria: AXElementSearchCriteria) -> [String] {
        var names = [
            kAXRoleAttribute as String,
            kAXTitleAttribute as String,
            kAXIdentifierAttribute as String,
            kAXChildrenAttribute as String,
        ]
        let label = criteria.labelContains != nil
        if label || criteria.description != nil || criteria.descriptionContains != nil {
            names.append(kAXDescriptionAttribute as String)
        }
        if label { names.append(kAXHelpAttribute as String) }
        if label || criteria.value != nil { names.append(kAXValueAttribute as String) }
        return names
    }

    private static let menuBarAttrs: [String] = [
        kAXMenuBarAttribute as String,
        kAXExtrasMenuBarAttribute as String,
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
        var unreadable = 0
        var rootUnreadable = false
        var appHasNoWindows = false
        let attributeNames = matchAttributes(for: criteria)

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
            let attrs = element.readAttributes(attributeNames)
            if attrs.isEmpty {
                unreadable += 1
                if depth == 0 { rootUnreadable = true }
            }

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
                var kids = AXElement.elements(fromCFArray: attrs[kAXChildrenAttribute as String])
                if depth == 0, (attrs[kAXRoleAttribute as String] as? String) == kAXApplicationRole as String,
                   !criteria.walksMenuBar {
                    let expanded = appWindowChildren(app: element, children: kids)
                    kids = expanded.children
                    appHasNoWindows = expanded.windowListEmpty
                }
                for (i, child) in kids.enumerated() {
                    queue.append((child, path, i, depth + 1))
                }
            }
        }

        probe = AXSearchProbe(
            nodesVisited: nodesVisited,
            nearMisses: nearMisses,
            oneAway: oneAway,
            criteriaCount: criteria.criteriaCount,
            unreadableNodes: unreadable,
            rootUnreadable: rootUnreadable,
            appHasNoWindows: appHasNoWindows
        )
    }

    /// The application element's children for an app-wide search without menus: its
    /// children minus the menu bars, plus every window in `kAXWindows` and the focused
    /// window. Fullscreen and other-Space windows are missing from `kAXWindows` and from
    /// `kAXChildren` alike but still answer as the focused window, so an app-wide
    /// assert_visible would otherwise not see the window the user is looking at. Duplicates
    /// are harmless: the walk dedupes by element identity.
    ///
    /// `windowListEmpty` is true only when `kAXWindows` was READ and came back as an empty
    /// array and nothing else is left to walk: a running app with no windows. A failed read
    /// (hung or busy app) leaves it false, because that is not an answer.
    private static func appWindowChildren(app: AXElement, children: [AXElement]) -> (children: [AXElement], windowListEmpty: Bool) {
        let extra = app.readAttributes(menuBarAttrs + [
            kAXWindowsAttribute as String,
            kAXFocusedWindowAttribute as String,
        ])
        let menuBars = menuBarAttrs.compactMap { extra[$0] }
        var out = children.filter { child in !menuBars.contains { CFEqual($0, child.ref) } }
        let windows = AXElement.elements(fromCFArray: extra[kAXWindowsAttribute as String])
        out.append(contentsOf: windows)
        if let focused = extra[kAXFocusedWindowAttribute as String],
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            out.append(AXElement(focused as! AXUIElement))
        }
        let windowsRead = extra[kAXWindowsAttribute as String].map { CFGetTypeID($0) == CFArrayGetTypeID() } ?? false
        return (out, windowsRead && out.isEmpty)
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
