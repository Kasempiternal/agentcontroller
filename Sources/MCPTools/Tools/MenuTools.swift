import Foundation
import MCPServer
import AccessibilityEngine

struct MenuTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "navigate_menu",
            description: "Navigate and click a menu item by path (e.g. ['File', 'Save As...'])",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "menuPath": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Array of menu item names (e.g. ['File', 'Save As...'])"),
                    ]),
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

                // Activate on the MainActor (NSRunningApplication is main-thread-only),
                // settle without blocking the main thread, then drive the AX menu walk on
                // the serial executor.
                let activated = await MainActor.run { AppManager.activate(pid: pid) }
                await AXExecutor.shared.pause(0.2)
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
