import Foundation
import MCPServer

/// What a menu navigation actually did. A `Bool` collapsed four distinct outcomes into
/// two, and the one it hid is the expensive one: `AXUIElementPerformAction(AXPress)`
/// returns `.success` on a DISABLED menu item, so pressing an item the app has greyed
/// out reported success while nothing happened. Observed on Preview with no document
/// open — `Tools > Rotate Left` and `File > Print…` both press "successfully" and the
/// print dialog never appears. That also covers the documented responder-chain caveat:
/// Cut/Copy/Paste/Select All read `AXEnabled == false` in a non-key app.
public enum MenuNavigationOutcome: Sendable {
    /// Leaf found, enabled, and the press was accepted.
    case pressed(label: String)
    /// Leaf found but the app reports it disabled — pressing it would have been a no-op.
    case disabled(label: String)
    /// No item matched at some level of the path; carries where and what WAS there.
    case notFound(MenuMiss)
    /// Leaf found and enabled, but the app refused the AXPress.
    case pressRefused(label: String)
}

/// Why a path segment did not resolve, with the labels that were actually available at
/// that level. A bare "not found" sends the caller guessing; the candidate list lets it
/// correct the segment in one retry.
public struct MenuMiss: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case noMenuBar
        case noMatch
        /// An intermediate segment fuzzy-matched several items. Guessing among them would
        /// open the wrong menu, so the caller is asked for the exact label instead.
        case ambiguous(matches: [String])
        /// The segment matched an item that has nothing to descend into, but the path continues.
        case noSubmenu
    }

    public let segment: String
    /// Label of the menu that was being searched; nil for the menu bar itself.
    public let level: String?
    public let candidates: [String]
    public let kind: Kind

    static let candidateCap = 30

    static func list(_ labels: [String]) -> String {
        guard !labels.isEmpty else { return "(none — the menu exposed no items)" }
        let shown = labels.prefix(candidateCap).map { "'\($0)'" }.joined(separator: ", ")
        return labels.count > candidateCap ? shown + ", … (\(labels.count - candidateCap) more)" : shown
    }

    public var message: String {
        let place = level.map { "'\($0)'" } ?? "the menu bar"
        switch kind {
        case .noMenuBar:
            return "The app exposes no menu bar in its accessibility tree. Some apps only publish it while frontmost — retry with foreground:true."
        case .noMatch:
            return "No item '\(segment)' in \(place). Available: \(Self.list(candidates))."
        case .ambiguous(let matches):
            return "'\(segment)' matches several items in \(place): \(Self.list(matches)). Use the exact label."
        case .noSubmenu:
            return "'\(segment)' in \(place) has no submenu to open, but the path continues past it."
        }
    }
}

/// Outcome of matching one path segment against the labels at one menu level.
enum MenuLabelMatch: Equatable {
    case match(index: Int)
    case ambiguous(indices: [Int])
    case none
}

public struct MenuNavigator {
    /// Normalize a menu label for matching: fold the Unicode horizontal ellipsis (U+2026
    /// "…") to three ASCII dots so a caller's `"Save As..."` matches the system's
    /// `"Save As…"` (and vice-versa), collapse whitespace runs (menu titles carry
    /// non-breaking spaces), and lowercase. Without this, exact-lowercased matching could
    /// never hit any ellipsis menu item — the tool's own `"Save As..."` schema example
    /// included.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2026}", with: "...")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// Drop trailing ellipses from an already-normalized label, so "Print" reaches the
    /// menu's "Print…" — the ellipsis only says "opens a dialog", it is not part of the
    /// name callers think in.
    static func foldEllipsis(_ normalized: String) -> String {
        var s = normalized
        while s.hasSuffix("...") { s.removeLast(3) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Resolve one path segment against the labels at one menu level (nil/empty labels are
    /// separators and never match).
    ///
    /// The leaf must match EXACTLY (case/ellipsis/whitespace-insensitive). The old
    /// any-direction prefix rule let `["File", "Close Tab"]` press "Close", and an empty
    /// segment matched the first item — both pressed a real, wrong menu item and reported
    /// success. Intermediate segments may be abbreviated ("Fi" for "File"), but only when
    /// the abbreviation is unambiguous: opening the wrong top-level menu is just as silent.
    static func matchLabel(_ name: String, in labels: [String?], isLeaf: Bool) -> MenuLabelMatch {
        let target = normalize(name)
        let folded = foldEllipsis(target)
        guard !target.isEmpty, !folded.isEmpty else { return .none }

        let items: [(index: Int, label: String)] = labels.enumerated().compactMap { i, label in
            guard let label else { return nil }
            let n = normalize(label)
            return n.isEmpty ? nil : (i, n)
        }

        if let exact = items.first(where: { $0.label == target }) { return .match(index: exact.index) }
        if let loose = items.first(where: { foldEllipsis($0.label) == folded }) { return .match(index: loose.index) }
        if isLeaf { return .none }

        for tier in [{ (l: String) in l.hasPrefix(folded) }, { (l: String) in l.contains(folded) }] {
            let hits = items.filter { tier(foldEllipsis($0.label)) }
            if hits.count == 1 { return .match(index: hits[0].index) }
            if hits.count > 1 { return .ambiguous(indices: hits.map(\.index)) }
        }
        return .none
    }

    private enum ItemLookup {
        case found(AXElement)
        case miss(MenuMiss)
    }

    private static func lookup(_ name: String, in items: [AXElement], isLeaf: Bool, level: String?) -> ItemLookup {
        let labels = items.map { $0.title }
        switch matchLabel(name, in: labels, isLeaf: isLeaf) {
        case .match(let index):
            return .found(items[index])
        case .ambiguous(let indices):
            return .miss(MenuMiss(segment: name, level: level, candidates: labels.compactMap(nonEmpty),
                                  kind: .ambiguous(matches: indices.compactMap { nonEmpty(labels[$0]) })))
        case .none:
            return .miss(MenuMiss(segment: name, level: level, candidates: labels.compactMap(nonEmpty), kind: .noMatch))
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    public static func navigateMenu(pid: pid_t, menuPath: [String]) async throws -> MenuNavigationOutcome {
        let lane = AXExecutor.app(pid)
        let leafName = menuPath.last ?? ""

        // Silent path first: most apps expose the FULL menu hierarchy in the AX tree
        // without any menu ever opening (getMenuStructure relies on exactly this), so we
        // descend by reading children only and press JUST the leaf. Nothing flashes on
        // screen, no per-level waits, and it works while the app is frontmost too.
        enum Silent: Sendable {
            case noMenuBar
            case pressed(MenuNavigationOutcome)
            case needsVisibleWalk
        }
        let silent: Silent = await lane.run {
            guard let menuBar = AXElement.application(pid: pid).menuBar else { return .noMenuBar }
            guard let leaf = resolveLeafSilently(menuBar: menuBar, menuPath: menuPath) else { return .needsVisibleWalk }
            // Enablement read without opening the menu can be stale: AppKit only runs
            // `validateMenuItem:` when a menu is about to display. So a disabled reading
            // here is a *suspicion*, and we pay for the visible press-descend walk to get
            // AppKit's fresh verdict rather than refusing on stale state. An enabled
            // reading is trusted — a stale "enabled" costs the same unverifiable press
            // this tool always made.
            guard leaf.isEnabled else { return .needsVisibleWalk }
            let label = leaf.title ?? leafName
            return .pressed(leaf.press() ? .pressed(label: label) : .pressRefused(label: label))
        }
        switch silent {
        case .noMenuBar:
            return .notFound(MenuMiss(segment: menuPath.first ?? "", level: nil, candidates: [], kind: .noMenuBar))
        case .pressed(let outcome):
            return outcome
        case .needsVisibleWalk:
            // Fallback: apps that populate submenus lazily (only on actual open) need the
            // visible press-descend walk. Also the re-validation path for an item that read
            // disabled above.
            return try await pressDescend(menuPath: menuPath, pid: pid)
        }
    }

    /// Descend the menu tree by reading children only — no AXPress on intermediates, so
    /// no menu opens. Returns the leaf item, or nil when a level is missing/unpopulated
    /// (lazily-built menus), in which case the caller falls back to press-descend.
    private static func resolveLeafSilently(menuBar: AXElement, menuPath: [String]) -> AXElement? {
        var currentItems = menuBar.children
        for (index, menuName) in menuPath.enumerated() {
            let isLeaf = index == menuPath.count - 1
            guard case .found(let menuItem) = lookup(menuName, in: currentItems, isLeaf: isLeaf, level: nil) else { return nil }
            if isLeaf { return menuItem }
            guard let next = submenuItems(of: menuItem), !next.isEmpty else { return nil }
            currentItems = next
        }
        return nil
    }

    /// The descendable item list under a menu item: its AXMenu child's children, a
    /// nested first child's children (apps that skip the explicit AXMenu role), or its
    /// direct children. Nil when there is nothing to descend into.
    private static func submenuItems(of menuItem: AXElement) -> [AXElement]? {
        let children = menuItem.children
        if let submenu = children.first(where: { $0.role == "AXMenu" }) {
            return submenu.children
        }
        if let firstChild = children.first, !firstChild.children.isEmpty {
            return firstChild.children
        }
        return children.isEmpty ? nil : children
    }

    /// How long a pressed menu item gets to populate its submenu. A fixed 100ms sleep
    /// both wasted time on fast menus and gave slow lazy ones no more than 100ms; polling
    /// returns the moment items appear.
    static let submenuPopulateDeadline: Double = 0.6
    static let submenuPollInterval: Double = 0.03

    /// Visible fallback walk: press each intermediate item to force lazy submenu
    /// population, then press the leaf. Closes any half-open menu on failure or cancellation.
    private static func pressDescend(menuPath: [String], pid: pid_t) async throws -> MenuNavigationOutcome {
        let lane = AXExecutor.app(pid)
        guard var currentItems = await lane.run({ AXElement.application(pid: pid).menuBar?.children }) else {
            return .notFound(MenuMiss(segment: menuPath.first ?? "", level: nil, candidates: [], kind: .noMenuBar))
        }
        var level: String? = nil

        for (index, menuName) in menuPath.enumerated() {
            let isLeaf = index == menuPath.count - 1
            let items = currentItems
            let levelLabel = level

            enum Step: Sendable {
                case miss(MenuMiss)
                case leaf(MenuNavigationOutcome)
                case opened(AXElement, label: String)
            }
            let step: Step = await lane.run {
                let menuItem: AXElement
                switch lookup(menuName, in: items, isLeaf: isLeaf, level: levelLabel) {
                case .miss(let miss): return .miss(miss)
                case .found(let found): menuItem = found
                }
                let label = menuItem.title ?? menuName
                if isLeaf {
                    // Every ancestor menu is open now, so AppKit has run `validateMenuItem:`
                    // and this reading is authoritative.
                    guard menuItem.isEnabled else { return .leaf(.disabled(label: label)) }
                    return .leaf(menuItem.press() ? .pressed(label: label) : .pressRefused(label: label))
                }
                // Open the submenu; the caller then descends into the child whose role is
                // AXMenu rather than blindly taking children.first (a separator or title).
                _ = menuItem.press()
                return .opened(menuItem, label: label)
            }

            switch step {
            case .miss(let miss):
                // Descent failed before reaching the leaf — make sure we didn't leave a
                // menu hanging open. Route Escape to the target PID (background-safe) so
                // closing a half-open menu never hits the global HID stream.
                if index > 0 { InputSimulator.pressEscape(pid: pid) }
                return .notFound(miss)

            case .leaf(let outcome):
                // Pressing a disabled item does not dismiss the menu, so bail with Escape
                // rather than leaving one hanging open over the user's screen.
                if case .disabled = outcome, index > 0 { InputSimulator.pressEscape(pid: pid) }
                return outcome

            case .opened(let menuItem, let label):
                let end = Date().addingTimeInterval(submenuPopulateDeadline)
                var next: [AXElement]?
                while true {
                    next = await lane.run { submenuItems(of: menuItem) }
                    if let next, !next.isEmpty { break }
                    if Date() >= end { break }
                    do {
                        try await AXExecutor.pause(submenuPollInterval)
                    } catch {
                        // Cancelled with a menu held open by the presses above: close it
                        // the same way a failed descent does.
                        InputSimulator.pressEscape(pid: pid)
                        throw error
                    }
                }
                guard let next else {
                    // No descendable submenu — bail and close the open menu.
                    InputSimulator.pressEscape(pid: pid)
                    return .notFound(MenuMiss(segment: menuName, level: levelLabel, candidates: [], kind: .noSubmenu))
                }
                currentItems = next
                level = label
            }
        }
        return .notFound(MenuMiss(segment: menuPath.last ?? "", level: level, candidates: [], kind: .noMatch))
    }

    public static func getMenuStructure(pid: pid_t, maxDepth: Int = 3) -> JSONValue {
        let appElement = AXElement.application(pid: pid)
        guard let menuBar = appElement.menuBar else {
            return .object(["error": .string("No menu bar found")])
        }
        return menuToJSON(menuBar, depth: 0, maxDepth: maxDepth)
    }

    private static func menuToJSON(_ element: AXElement, depth: Int, maxDepth: Int) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if let title = element.title, !title.isEmpty {
            fields["title"] = .string(title)
        }
        if let role = element.role {
            fields["role"] = .string(role)
        }
        fields["enabled"] = .bool(element.isEnabled)

        if depth < maxDepth {
            let kids = element.children
            if !kids.isEmpty {
                fields["children"] = .array(kids.map { menuToJSON($0, depth: depth + 1, maxDepth: maxDepth) })
            }
        }

        return .object(fields)
    }
}
