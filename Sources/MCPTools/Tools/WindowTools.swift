import Foundation
import MCPServer
import AccessibilityEngine
import ScreenCapture

struct WindowTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "list_windows",
            description: "List all visible windows, optionally filtered by app",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID (optional, lists all if omitted)")]),
                ]),
            ]),
            handler: { args in
                let pid = args?["app"]?.stringValue.flatMap { AppManager.resolvePID(from: $0) }
                let windows = await MainActor.run { WindowManager.listWindows(pid: pid) }
                let items: [JSONValue] = windows.map { w in
                    .object([
                        "title": .string(w.title),
                        "app": .string(w.appName),
                        "bundleId": .string(w.appBundleId ?? ""),
                        "pid": .int(Int(w.pid)),
                        "index": .int(w.index),
                        "bounds": .object([
                            "x": .double(w.bounds.origin.x),
                            "y": .double(w.bounds.origin.y),
                            "width": .double(w.bounds.width),
                            "height": .double(w.bounds.height),
                        ]),
                        "isMinimized": .bool(w.isMinimized),
                        "isFullScreen": .bool(w.isFullScreen),
                    ])
                }
                return ToolResult.json(.object([
                    "count": .int(items.count),
                    "windows": .array(items),
                ]))
            }
        ))

        registry.register(.init(
            name: "get_window_bounds",
            description: "Get the position and size of an app window",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "windowIndex": .object(["type": .string("integer"), "description": .string("Window index (default 0)")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let index = args?["windowIndex"]?.intValue ?? 0
                let bounds = await MainActor.run { WindowManager.getWindowBounds(pid: pid, windowIndex: index) }
                guard let b = bounds else {
                    return ToolResult.error("Window not found")
                }
                return ToolResult.json(.object([
                    "x": .double(b.origin.x),
                    "y": .double(b.origin.y),
                    "width": .double(b.width),
                    "height": .double(b.height),
                ]))
            }
        ))

        registry.register(.init(
            name: "set_window_bounds",
            description: "Set the position and/or size of an app window",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "windowIndex": .object(["type": .string("integer"), "description": .string("Window index (default 0)")]),
                    "x": .object(["type": .string("number"), "description": .string("X position")]),
                    "y": .object(["type": .string("number"), "description": .string("Y position")]),
                    "width": .object(["type": .string("number"), "description": .string("Width")]),
                    "height": .object(["type": .string("number"), "description": .string("Height")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let index = args?["windowIndex"]?.intValue ?? 0
                var position: CGPoint? = nil
                var size: CGSize? = nil
                if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
                    position = CGPoint(x: x, y: y)
                }
                if let w = args?["width"]?.doubleValue, let h = args?["height"]?.doubleValue {
                    size = CGSize(width: w, height: h)
                }
                // Capture immutable copies before the @Sendable MainActor closure — Swift 6
                // rejects mutable `var` captures crossing the actor boundary.
                let pos = position
                let sz = size
                let success = await MainActor.run {
                    WindowManager.setWindowBounds(pid: pid, windowIndex: index, position: pos, size: sz)
                }
                if success { await ShareableContentCache.shared.invalidate() }
                return ToolResult.action(success: success, method: "accessibility")
            }
        ))

        registry.register(.init(
            name: "minimize_window",
            description: "Minimize an app window to the Dock",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "windowIndex": .object(["type": .string("integer"), "description": .string("Window index (default 0)")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let index = args?["windowIndex"]?.intValue ?? 0
                let success = await MainActor.run { WindowManager.minimize(pid: pid, windowIndex: index) }
                if success { await ShareableContentCache.shared.invalidate() }
                return ToolResult.action(success: success, method: "accessibility")
            }
        ))

        registry.register(.init(
            name: "restore_window",
            description: "Restore a minimized window from the Dock",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "windowIndex": .object(["type": .string("integer"), "description": .string("Window index (default 0)")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let index = args?["windowIndex"]?.intValue ?? 0
                let success = await MainActor.run { WindowManager.restore(pid: pid, windowIndex: index) }
                if success { await ShareableContentCache.shared.invalidate() }
                return ToolResult.action(success: success, method: "accessibility")
            }
        ))
    }
}
