import ApplicationServices
import Foundation
import MCPServer
import AccessibilityEngine

struct ScrollTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "scroll",
            description: "Scroll at a specific position within an app window. Use negative deltaY to scroll down, positive to scroll up. BACKGROUND-SAFE BY DEFAULT: the scroll-wheel event is delivered to the target PID with no cursor warp and no app activation — the user's mouse and focus are untouched. Set foreground:true only for apps that ignore PID-targeted scrolls (activates the app, warps the real cursor to the point, and scrolls via the global HID stream).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "deltaX": .object(["type": .string("number"), "description": .string("Horizontal scroll amount (default 0)")]),
                    "deltaY": .object(["type": .string("number"), "description": .string("Vertical scroll amount (negative = down)")]),
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (background-safe). When true, activates the app and scrolls via the global HID stream (moves the real cursor).")]),
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
                let foreground = args?["foreground"]?.boolValue ?? false

                var activated = false
                if foreground {
                    activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.shared.pause(0.1)
                }
                let targetPid: pid_t? = foreground ? nil : pid
                await AXExecutor.shared.run {
                    InputSimulator.scroll(at: CGPoint(x: x, y: y), deltaX: Int32(deltaX), deltaY: Int32(deltaY), pid: targetPid)
                }
                var extra: [String: JSONValue] = ["activated": .bool(activated)]
                if !foreground, let warning = await offTargetWarning(pid: pid, x: x, y: y) {
                    extra["warning"] = .string(warning)
                }
                return ToolResult.action(success: true, method: foreground ? "coordinate" : "coordinate-pid", extra: extra)
            }
        ))

        registry.register(.init(
            name: "swipe",
            description: "Swipe gesture from one point to another (implemented as a mouse drag). BACKGROUND-SAFE BY DEFAULT: the drag events are delivered to the target PID without warping the real cursor or activating the app. NOTE: drags are the least reliable synthetic gesture — many apps poll the real OS pointer mid-drag, so a PID-targeted drag with a stationary cursor can desync; if the gesture doesn't take, set foreground:true to activate the app and drag via the global HID stream (which moves the real cursor).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "startX": .object(["type": .string("number"), "description": .string("Start X coordinate")]),
                    "startY": .object(["type": .string("number"), "description": .string("Start Y coordinate")]),
                    "endX": .object(["type": .string("number"), "description": .string("End X coordinate")]),
                    "endY": .object(["type": .string("number"), "description": .string("End Y coordinate")]),
                    "duration": .object(["type": .string("number"), "description": .string("Duration in seconds (default 0.3)")]),
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (background-safe). When true, activates the app and drags via the global HID stream (moves the real cursor).")]),
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
                let foreground = args?["foreground"]?.boolValue ?? false

                var activated = false
                if foreground {
                    activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.shared.pause(0.1)
                }
                let targetPid: pid_t? = foreground ? nil : pid
                await AXExecutor.shared.run {
                    InputSimulator.drag(from: CGPoint(x: sx, y: sy), to: CGPoint(x: ex, y: ey), duration: duration, pid: targetPid)
                }
                var extra: [String: JSONValue] = ["activated": .bool(activated)]
                if !foreground, let warning = await offTargetWarning(pid: pid, x: sx, y: sy) {
                    extra["warning"] = .string(warning)
                }
                return ToolResult.action(success: true, method: foreground ? "coordinate" : "coordinate-pid", extra: extra)
            }
        ))

        registry.register(.init(
            name: "drag_drop",
            description: "Drag from one position and drop at another. BACKGROUND-SAFE BY DEFAULT: the drag events are delivered to the target PID without warping the real cursor or activating the app. NOTE: drags are the least reliable synthetic gesture — many apps poll the real OS pointer mid-drag, so a PID-targeted drag with a stationary cursor can desync; if the drop doesn't take, set foreground:true to activate the app and drag via the global HID stream (which moves the real cursor).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "fromX": .object(["type": .string("number"), "description": .string("Source X")]),
                    "fromY": .object(["type": .string("number"), "description": .string("Source Y")]),
                    "toX": .object(["type": .string("number"), "description": .string("Target X")]),
                    "toY": .object(["type": .string("number"), "description": .string("Target Y")]),
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (background-safe). When true, activates the app and drags via the global HID stream (moves the real cursor).")]),
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
                let foreground = args?["foreground"]?.boolValue ?? false

                var activated = false
                if foreground {
                    activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.shared.pause(0.1)
                }
                let targetPid: pid_t? = foreground ? nil : pid
                await AXExecutor.shared.run {
                    InputSimulator.drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty), duration: 0.5, pid: targetPid)
                }
                var extra: [String: JSONValue] = ["activated": .bool(activated)]
                if !foreground, let warning = await offTargetWarning(pid: pid, x: fx, y: fy) {
                    extra["warning"] = .string(warning)
                }
                return ToolResult.action(success: true, method: foreground ? "coordinate" : "coordinate-pid", extra: extra)
            }
        ))

        registry.register(.init(
            name: "scroll_until_visible",
            description: "Scroll until an element matching the selector is on-screen. BACKGROUND-SAFE: prefers the native one-call AXScrollToVisible (pure AX, no input events); the wheel-scroll fallback is delivered to the target PID without warping the cursor or activating the app. Re-checks the element's frame against the focused window bounds, up to maxScrolls/timeout. Returns offscreen:true if the element exists but stays outside the window; errors if never found. Set foreground:true only for apps that ignore PID-targeted scrolls (activates + global HID, moves the real cursor).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(SelectorSchema.merged(into: [
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "direction": .object(["type": .string("string"), "enum": .array([.string("down"), .string("up")]), "description": .string("Scroll direction (default 'down')")]),
                    "maxScrolls": .object(["type": .string("integer"), "description": .string("Maximum scroll steps (default 20)")]),
                    "timeout": .object(["type": .string("number"), "description": .string("Overall timeout in seconds (default 20)")]),
                    "scope": .object(["type": .string("string"), "enum": .array([.string("window"), .string("app")]), "description": .string("Search scope: 'window' (default) or 'app'")]),
                    "foreground": .object(["type": .string("boolean"), "description": .string("Default false (background-safe). When true, activates the app and uses global-HID wheel scrolls for the fallback (moves the real cursor).")]),
                ])),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let direction = args?["direction"]?.stringValue ?? "down"
                let maxScrolls = args?["maxScrolls"]?.intValue ?? 20
                let timeout = args?["timeout"]?.doubleValue ?? 20.0
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
                let foreground = args?["foreground"]?.boolValue ?? false

                // Background-safe: never activate. The AXScrollToVisible primary path and
                // the PID-targeted wheel fallback both run without bringing the app
                // forward or moving the cursor. foreground:true restores activate + global
                // HID scrolls for apps that ignore PID-targeted scrolls.
                var activated = false
                if foreground {
                    activated = await MainActor.run { AppManager.activate(pid: pid) }
                    await AXExecutor.shared.pause(0.1)
                }
                let targetPid: pid_t? = foreground ? nil : pid

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
                        await AXExecutor.shared.run { InputSimulator.scroll(at: center, deltaY: deltaY, pid: targetPid) }
                        scrolls += 1
                        await AXExecutor.shared.pause(0.15)
                    case .offscreen(let center):
                        if scrolls >= maxScrolls {
                            return ToolResult.action(success: true, method: "accessibility", extra: [
                                "found": .bool(true), "offscreen": .bool(true),
                                "scrolls": .int(scrolls), "activated": .bool(activated),
                            ])
                        }
                        await AXExecutor.shared.run { InputSimulator.scroll(at: center, deltaY: deltaY, pid: targetPid) }
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
