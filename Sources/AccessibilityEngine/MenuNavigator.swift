import Foundation
import MCPServer

public struct MenuNavigator {
    public static func navigateMenu(pid: pid_t, menuPath: [String]) -> Bool {
        let appElement = AXElement.application(pid: pid)
        guard let menuBar = appElement.menuBar else { return false }

        var currentItems = menuBar.children
        for (index, menuName) in menuPath.enumerated() {
            guard let menuItem = currentItems.first(where: {
                $0.title?.lowercased() == menuName.lowercased()
            }) else {
                return false
            }

            if index == menuPath.count - 1 {
                // Last item — click it
                return menuItem.press()
            } else {
                // Open submenu
                _ = menuItem.press()
                usleep(100_000) // 100ms for menu to open
                // Get submenu children
                let children = menuItem.children
                if let submenu = children.first {
                    currentItems = submenu.children
                } else {
                    currentItems = children
                }
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
