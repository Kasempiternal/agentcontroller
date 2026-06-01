import ApplicationServices
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

                let activated = await MainActor.run { AppManager.activate(pid: pid) }
                await AXExecutor.shared.pause(0.1)
                await AXExecutor.shared.run {
                    InputSimulator.scroll(at: CGPoint(x: x, y: y), deltaX: Int32(deltaX), deltaY: Int32(deltaY))
                }
                return ToolResult.action(success: true, method: "coordinate", extra: [
                    "activated": .bool(activated),
                ])
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

                let activated = await MainActor.run { AppManager.activate(pid: pid) }
                await AXExecutor.shared.pause(0.1)
                await AXExecutor.shared.run {
                    InputSimulator.drag(from: CGPoint(x: sx, y: sy), to: CGPoint(x: ex, y: ey), duration: duration)
                }
                return ToolResult.action(success: true, method: "coordinate", extra: [
                    "activated": .bool(activated),
                ])
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

                let activated = await MainActor.run { AppManager.activate(pid: pid) }
                await AXExecutor.shared.pause(0.1)
                await AXExecutor.shared.run {
                    InputSimulator.drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty), duration: 0.5)
                }
                return ToolResult.action(success: true, method: "coordinate", extra: [
                    "activated": .bool(activated),
                ])
            }
        ))

        registry.register(.init(
            name: "scroll_until_visible",
            description: "Scroll until an element matching the selector is on-screen. Prefers the native one-call AXScrollToVisible; otherwise wheel-scrolls in `direction`, re-checking the element's frame against the focused window bounds, up to maxScrolls/timeout. Returns offscreen:true if the element exists but stays outside the window; errors if never found.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "direction": .object(["type": .string("string"), "enum": .array([.string("down"), .string("up")]), "description": .string("Scroll direction (default 'down')")]),
                    "maxScrolls": .object(["type": .string("integer"), "description": .string("Maximum scroll steps (default 20)")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Overall timeout in seconds (default 20)")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (default) or 'app'")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let direction = args?["direction"]?.stringValue ?? "down"
                let maxScrolls = args?["maxScrolls"]?.intValue ?? 20
                let timeout = args?["timeout"]?.doubleValue ?? 20.0
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)

                let activated = await MainActor.run { AppManager.activate(pid: pid) }
                await AXExecutor.shared.pause(0.1)

                let deadline = Date().addingTimeInterval(timeout)
                // Negative deltaY scrolls down (content moves up), positive scrolls up.
                let deltaY: Int32 = (direction == "up") ? 60 : -60

                var scrolls = 0
                while Date() < deadline {
                    // One AXExecutor pass: find element, try native scroll-to-visible, and
                    // measure visibility against the focused window. Returns the outcome.
                    enum Step: Sendable { case visible, offscreen(CGPoint), notFound }
                    let step: Step = await AXExecutor.shared.run { () -> Step in
                        let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                        let scope = args?["scope"]?.stringValue ?? "window"
                        let window = appElement.focusedWindow
                        let root: AXElement = (scope == "app") ? appElement : (window ?? appElement)
                        guard let r = AXElementSearch.find(root: root, criteria: criteria).first else {
                            return .notFound
                        }
                        let element = r.element
                        // Prefer the native one-call scroll-to-visible. The SDK ships no
                        // `kAXScrollToVisibleAction` constant, so the action name string is
                        // used directly (supported by AXScrollArea children).
                        if element.performAction("AXScrollToVisible") {
                            return .visible
                        }
                        // Otherwise check whether the element frame sits inside the window.
                        let winFrame = window?.frame
                        if let ef = element.frame, let wf = winFrame, wf.contains(CGPoint(x: ef.midX, y: ef.midY)) {
                            return .visible
                        }
                        // Found but outside the window; need a wheel scroll at the window center.
                        let center = winFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
                            ?? CGPoint(x: 400, y: 400)
                        return .offscreen(center)
                    }

                    switch step {
                    case .visible:
                        return ToolResult.action(success: true, method: "accessibility", extra: [
                            "found": .bool(true), "scrolls": .int(scrolls), "activated": .bool(activated),
                        ])
                    case .notFound:
                        if scrolls >= maxScrolls { break }
                        // Element not in tree yet — scroll the focused window center and retry.
                        let center = await AXExecutor.shared.run { () -> CGPoint in
                            let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                            if let wf = appElement.focusedWindow?.frame { return CGPoint(x: wf.midX, y: wf.midY) }
                            return CGPoint(x: 400, y: 400)
                        }
                        await AXExecutor.shared.run { InputSimulator.scroll(at: center, deltaY: deltaY) }
                        scrolls += 1
                        await AXExecutor.shared.pause(0.15)
                    case .offscreen(let center):
                        if scrolls >= maxScrolls {
                            return ToolResult.action(success: true, method: "accessibility", extra: [
                                "found": .bool(true), "offscreen": .bool(true),
                                "scrolls": .int(scrolls), "activated": .bool(activated),
                            ])
                        }
                        await AXExecutor.shared.run { InputSimulator.scroll(at: center, deltaY: deltaY) }
                        scrolls += 1
                        await AXExecutor.shared.pause(0.15)
                    }
                }

                // Deadline or maxScrolls exhausted: one last find to report offscreen vs miss.
                let finalState: Bool = await AXExecutor.shared.run {
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let scope = args?["scope"]?.stringValue ?? "window"
                    let root: AXElement = (scope == "app") ? appElement : (appElement.focusedWindow ?? appElement)
                    return AXElementSearch.find(root: root, criteria: criteria).first != nil
                }
                if finalState {
                    return ToolResult.action(success: true, method: "accessibility", extra: [
                        "found": .bool(true), "offscreen": .bool(true),
                        "scrolls": .int(scrolls), "activated": .bool(activated),
                    ])
                }
                return ToolResult.error("Element never became visible after \(scrolls) scroll(s): \(InteractionTools.describe(args))")
            }
        ))
    }
}
