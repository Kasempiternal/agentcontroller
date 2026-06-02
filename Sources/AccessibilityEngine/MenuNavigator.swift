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
            let children = menuItem.children
            if let submenu = children.first(where: { $0.role == "AXMenu" }) {
                currentItems = submenu.children
            } else if let firstChild = children.first, !firstChild.children.isEmpty {
                // Some apps nest the menu one level deeper without an explicit AXMenu role.
                currentItems = firstChild.children
            } else if !children.isEmpty {
                currentItems = children
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
