import Foundation
import MCPServer
import AccessibilityEngine

struct ScrollTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "scroll",
            description: "Scroll at a specific position within an app window. Use negative deltaY to scroll down, positive to scroll up.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "deltaX": .object(["type": .string("number"), "description": .string("Horizontal scroll amount (default 0)")]),
                    "deltaY": .object(["type": .string("number"), "description": .string("Vertical scroll amount (negative = down)")]),
                ]),
                "required": .array([.string("app"), .string("x"), .string("y"), .string("deltaY")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                guard let x = args?["x"]?.doubleValue,
                      let y = args?["y"]?.doubleValue,
                      let deltaY = args?["deltaY"]?.intValue else {
                    throw ToolError.missingParameter("x, y, deltaY")
                }
                let deltaX = args?["deltaX"]?.intValue ?? 0

                await MainActor.run {
                    AppManager.activate(pid: pid)
                    usleep(100_000)
                    InputSimulator.scroll(at: CGPoint(x: x, y: y), deltaX: Int32(deltaX), deltaY: Int32(deltaY))
                }
                return ToolResult.json(.object(["success": .bool(true)]))
            }
        ))

        registry.register(.init(
            name: "swipe",
            description: "Swipe gesture from one point to another (implemented as a mouse drag)",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "startX": .object(["type": .string("number"), "description": .string("Start X coordinate")]),
                    "startY": .object(["type": .string("number"), "description": .string("Start Y coordinate")]),
                    "endX": .object(["type": .string("number"), "description": .string("End X coordinate")]),
                    "endY": .object(["type": .string("number"), "description": .string("End Y coordinate")]),
                    "duration": .object(["type": .string("number"), "description": .string("Duration in seconds (default 0.3)")]),
                ]),
                "required": .array([.string("app"), .string("startX"), .string("startY"), .string("endX"), .string("endY")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                guard let sx = args?["startX"]?.doubleValue,
                      let sy = args?["startY"]?.doubleValue,
                      let ex = args?["endX"]?.doubleValue,
                      let ey = args?["endY"]?.doubleValue else {
                    throw ToolError.missingParameter("startX, startY, endX, endY")
                }
                let duration = args?["duration"]?.doubleValue ?? 0.3

                await MainActor.run {
                    AppManager.activate(pid: pid)
                    usleep(100_000)
                    InputSimulator.drag(from: CGPoint(x: sx, y: sy), to: CGPoint(x: ex, y: ey), duration: duration)
                }
                return ToolResult.json(.object(["success": .bool(true)]))
            }
        ))

        registry.register(.init(
            name: "drag_drop",
            description: "Drag from one position and drop at another",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "fromX": .object(["type": .string("number"), "description": .string("Source X")]),
                    "fromY": .object(["type": .string("number"), "description": .string("Source Y")]),
                    "toX": .object(["type": .string("number"), "description": .string("Target X")]),
                    "toY": .object(["type": .string("number"), "description": .string("Target Y")]),
                ]),
                "required": .array([.string("app"), .string("fromX"), .string("fromY"), .string("toX"), .string("toY")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                guard let fx = args?["fromX"]?.doubleValue,
                      let fy = args?["fromY"]?.doubleValue,
                      let tx = args?["toX"]?.doubleValue,
                      let ty = args?["toY"]?.doubleValue else {
                    throw ToolError.missingParameter("fromX, fromY, toX, toY")
                }

                await MainActor.run {
                    AppManager.activate(pid: pid)
                    usleep(100_000)
                    InputSimulator.drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty), duration: 0.5)
                }
                return ToolResult.json(.object(["success": .bool(true)]))
            }
        ))
    }
}
