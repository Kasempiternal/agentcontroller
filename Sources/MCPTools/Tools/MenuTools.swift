import Foundation
import MCPServer
import AccessibilityEngine

struct MenuTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "navigate_menu",
            description: "Navigate and click a menu item by path (e.g. ['File', 'Save As...']). BACKGROUND-SAFE BY DEFAULT: the menu hierarchy is resolved by READING the AX tree (no menu ever opens on screen) and only the leaf item is pressed — no cursor move, no app activation, nothing visible. Apps that populate submenus lazily fall back to an AX press-descend walk automatically. A DISABLED leaf is reported as an ERROR rather than a false success: macOS returns 'press succeeded' for a greyed-out item, so an action whose precondition is unmet (no document open, nothing selected) and responder-chain items (Copy/Paste/Cut/Select All) in a non-active app used to look like they worked. Set foreground:true only for apps that expose their menu bar in the AX tree solely while frontmost.",
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
                    await AXExecutor.pause(0.2)
                }
                let outcome = await AXExecutor.app(pid).run {
                    MenuNavigator.navigateMenu(pid: pid, menuPath: path)
                }
                let readablePath = path.joined(separator: " > ")
                switch outcome {
                case .notFound:
                    return ToolResult.error("Menu path not found: \(readablePath)")
                case .pressRefused(let label):
                    return ToolResult.error("Menu item '\(label)' is enabled but refused the press (\(readablePath))")
                case .disabled(let label):
                    return ToolResult.error("Menu item '\(label)' is DISABLED — pressing it would have been a no-op, so nothing happened (\(readablePath)). The app greys an item out when its precondition is unmet: no document open, nothing selected, or — for responder-chain items like Cut/Copy/Paste/Select All — the app is not active. Fix the precondition (open a document, make a selection) or use activate_app, then retry.")
                case .pressed(let label):
                    return ToolResult.action(success: true, method: "accessibility", extra: [
                        "activated": .bool(activated),
                        "menuPath": .array(path.map { .string($0) }),
                        "item": .string(label),
                    ])
                }
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
                let structure = await AXExecutor.app(pid).run {
                    MenuNavigator.getMenuStructure(pid: pid, maxDepth: maxDepth)
                }
                return ToolResult.json(structure)
            }
        ))
    }
}
