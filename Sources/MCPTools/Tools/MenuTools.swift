import Foundation
import MCPServer
import AccessibilityEngine

struct MenuTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "navigate_menu",
            description: "Navigate and click a menu item by path (e.g. ['File', 'Save As...']). BACKGROUND-SAFE BY DEFAULT: the menu walk presses each AXMenuItem via the Accessibility API, which invokes the command in-process WITHOUT dropping the visible menu, moving the cursor, or bringing the app forward. Set foreground:true only for apps that build their menus lazily and expose them in the AX tree only when frontmost.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "menuPath": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Array of menu item names (e.g. ['File', 'Save As...'])"),
                    ]),
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (background-safe). When true, activates the app first — only needed for apps that populate their menu bar in the AX tree lazily when frontmost.")]),
                ]),
                "required": .array([.string("app"), .string("menuPath")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                guard let pathValues = args?["menuPath"]?.arrayValue else {
                    throw ToolError.missingParameter("menuPath")
                }
                let path = pathValues.compactMap(\.stringValue)
                guard !path.isEmpty else {
                    throw ToolError.invalidParameter("menuPath must not be empty")
                }
                let foreground = args?["foreground"]?.boolValue ?? false

                // Background-safe: the AX menu walk (AXPress on menu items) works without
                // the app being frontmost, so do NOT activate by default. foreground:true
                // activates first for apps that build menus lazily when active.
                var activated = false
                if foreground {
                    activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.shared.pause(0.2)
                }
                let success = await AXExecutor.shared.run {
                    MenuNavigator.navigateMenu(pid: pid, menuPath: path)
                }
                guard success else {
                    return ToolResult.error("Menu path not found or item refused: \(path.joined(separator: " > "))")
                }
                return ToolResult.action(success: true, method: "accessibility", extra: [
                    "activated": .bool(activated),
                    "menuPath": .array(path.map { .string($0) }),
                ])
            }
        ))

        registry.register(.init(
            name: "get_menu_structure",
            description: "Get the menu bar structure for an app",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "maxDepth": .object(["type": .string("integer"), "description": .string("Maximum depth (default 3)")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let maxDepth = args?["maxDepth"]?.intValue ?? 3
                let structure = await AXExecutor.shared.run {
                    MenuNavigator.getMenuStructure(pid: pid, maxDepth: maxDepth)
                }
                return ToolResult.json(structure)
            }
        ))
    }
}
