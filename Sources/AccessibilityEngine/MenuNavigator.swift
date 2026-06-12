import Foundation
import MCPServer

public struct MenuNavigator {
    /// Normalize a menu label for matching: fold the Unicode horizontal ellipsis (U+2026
    /// "…") to three ASCII dots so a caller's `"Save As..."` matches the system's
    /// `"Save As…"` (and vice-versa), trim surrounding whitespace, and lowercase. Without
    /// this, exact-lowercased matching could never hit any ellipsis menu item — the
    /// tool's own `"Save As..."` schema example included.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2026}", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Find the best child matching `name` among `items`: exact → prefix → contains
    /// (all on normalized labels). Returns nil if nothing matches.
    static func matchItem(_ name: String, in items: [AXElement]) -> AXElement? {
        let target = normalize(name)
        let labeled = items.compactMap { item -> (AXElement, String)? in
            guard let t = item.title, !t.isEmpty else { return nil }
            return (item, normalize(t))
        }
        if let exact = labeled.first(where: { $0.1 == target }) { return exact.0 }
        if let prefix = labeled.first(where: { $0.1.hasPrefix(target) || target.hasPrefix($0.1) }) { return prefix.0 }
        if let contains = labeled.first(where: { $0.1.contains(target) }) { return contains.0 }
        return nil
    }

    public static func navigateMenu(pid: pid_t, menuPath: [String]) -> Bool {
        let appElement = AXElement.application(pid: pid)
        guard let menuBar = appElement.menuBar else { return false }

        // Silent path first: most apps expose the FULL menu hierarchy in the AX tree
        // without any menu ever opening (getMenuStructure relies on exactly this), so we
        // descend by reading children only and press JUST the leaf. Nothing flashes on
        // screen, no 100ms-per-level waits, and it works while the app is frontmost too.
        if let leaf = resolveLeafSilently(menuBar: menuBar, menuPath: menuPath), leaf.press() {
            return true
        }

        // Fallback: apps that populate submenus lazily (only on actual open) need the
        // visible press-descend walk.
        return pressDescend(menuBar: menuBar, menuPath: menuPath, pid: pid)
    }

    /// Descend the menu tree by reading children only — no AXPress on intermediates, so
    /// no menu opens. Returns the leaf item, or nil when a level is missing/unpopulated
    /// (lazily-built menus), in which case the caller falls back to press-descend.
    private static func resolveLeafSilently(menuBar: AXElement, menuPath: [String]) -> AXElement? {
        var currentItems = menuBar.children
        for (index, menuName) in menuPath.enumerated() {
            guard let menuItem = matchItem(menuName, in: currentItems) else { return nil }
            if index == menuPath.count - 1 { return menuItem }
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

    /// Visible fallback walk: press each intermediate item to force lazy submenu
    /// population, then press the leaf. Closes any half-open menu on failure.
    private static func pressDescend(menuBar: AXElement, menuPath: [String], pid: pid_t) -> Bool {
        var currentItems = menuBar.children
        for (index, menuName) in menuPath.enumerated() {
            guard let menuItem = matchItem(menuName, in: currentItems) else {
                // Descent failed before reaching the leaf — make sure we didn't leave a
                // menu hanging open. Route Escape to the target PID (background-safe) so
                // closing a half-open menu never hits the global HID stream.
                if index > 0 { InputSimulator.pressEscape(pid: pid) }
                return false
            }

            if index == menuPath.count - 1 {
                // Last item — click it.
                return menuItem.press()
            }

            // Open the submenu, then descend into the child whose role is AXMenu rather
            // than blindly taking children.first (which can be a separator or title).
            _ = menuItem.press()
            usleep(100_000) // 100ms for menu to open
            if let next = submenuItems(of: menuItem) {
                currentItems = next
            } else {
                // No descendable submenu — bail and close the open menu. Route Escape to
                // the target PID (background-safe) rather than the global HID stream.
                InputSimulator.pressEscape(pid: pid)
                return false
            }
        }
        return false
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
