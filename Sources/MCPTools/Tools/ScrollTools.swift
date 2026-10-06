import ApplicationServices
import Foundation
import MCPServer
import AccessibilityEngine

struct ScrollTools {
    /// Termination rule for the scroll_until_visible loop, extracted so it is testable
    /// without an app. The old loop used `break` inside a `switch`, which only leaves the
    /// switch: once maxScrolls was spent it fell back to the top of the `while` and ran
    /// back-to-back tree searches — each a full AX walk — until the 20s deadline.
    static func canScrollAgain(scrolls: Int, maxScrolls: Int, now: Date, deadline: Date) -> Bool {
        scrolls < maxScrolls && now < deadline
    }

    /// One look at the target during scroll_until_visible.
    enum Visibility: Sendable {
        case visible
        /// In the tree but outside the window. `center` is where to aim the wheel; nil
        /// when no window frame is known.
        case offscreen(center: CGPoint?)
        /// Not in the tree (yet) — a lazily-built list may materialize rows as it scrolls.
        case notFound(center: CGPoint?)

        var center: CGPoint? {
            switch self {
            case .visible: return nil
            case .offscreen(let c), .notFound(let c): return c
            }
        }
    }

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

                return try await InteractionTools.coordinateInput(pid: pid, x: x, y: y, foreground: foreground) { target, point in
                    InputSimulator.scroll(at: point, deltaX: Int32(deltaX), deltaY: Int32(deltaY), pid: target)
                }
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
                    "duration": .object(["type": .string("number"), "description": .string("Duration in seconds (default 0.3, clamped to 0-5)")]),
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
                let duration = InputSimulator.clampedGestureDuration(args?["duration"]?.doubleValue ?? 0.3)
                let foreground = args?["foreground"]?.boolValue ?? false

                return try await InteractionTools.dragInput(
                    pid: pid, from: CGPoint(x: sx, y: sy), to: CGPoint(x: ex, y: ey), duration: duration, foreground: foreground)
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

                return try await InteractionTools.dragInput(
                    pid: pid, from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty), duration: 0.5, foreground: foreground)
            }
        ))

        registry.register(.init(
            name: "scroll_until_visible",
            description: "Scroll until an element matching the selector is on-screen. BACKGROUND-SAFE: prefers the native one-call AXScrollToVisible (pure AX, no input events); the wheel-scroll fallback is delivered to the target PID without warping the cursor or activating the app. Re-checks the element's frame against the focused window bounds, up to maxScrolls/timeout. ERRORS if the element never becomes visible — the message says whether it was never in the tree or was in the tree but stayed outside the window. Set foreground:true only for apps that ignore PID-targeted scrolls (activates + global HID, moves the real cursor).",
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
                let maxScrolls = max(0, args?["maxScrolls"]?.intValue ?? 20)
                let timeout = args?["timeout"]?.doubleValue ?? 20.0
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
                let foreground = args?["foreground"]?.boolValue ?? false
                let scope = args?["scope"]?.stringValue ?? "window"

                // Background-safe: never activate. The AXScrollToVisible primary path and
                // the PID-targeted wheel fallback both run without bringing the app
                // forward or moving the cursor. foreground:true makes each wheel step
                // activate-and-verify the app first (see InteractionTools.deliver), so a
                // step never posts a global scroll into the user's app.
                let deadline = Date().addingTimeInterval(timeout)
                // Negative deltaY scrolls down (content moves up), positive scrolls up.
                let deltaY: Int32 = (direction == "up") ? 60 : -60

                var scrolls = 0
                var last: Visibility = .notFound(center: nil)
                while true {
                    // One AXExecutor pass: find element, try native scroll-to-visible, and
                    // measure visibility against the window. The wheel target comes out of
                    // the same pass so a miss costs one lane hop, not two.
                    last = await AXExecutor.app(pid).run { () -> Visibility in
                        let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                        let window = appElement.focusedWindow
                        // An app that never took focus has no focused window but still has
                        // windows; aiming at its first one beats aiming at nothing.
                        let winFrame = (window ?? appElement.windows.first)?.frame
                        let center = winFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
                        let root: AXElement = (scope == "app") ? appElement : (window ?? appElement)
                        guard let r = AXElementSearch.find(root: root, criteria: criteria).first else {
                            return .notFound(center: center)
                        }
                        let element = r.element
                        // Prefer the native one-call scroll-to-visible. The SDK ships no
                        // `kAXScrollToVisibleAction` constant, so the action name string is
                        // used directly (supported by AXScrollArea children).
                        if element.performAction("AXScrollToVisible") { return .visible }
                        if let ef = element.frame, let wf = winFrame, wf.contains(CGPoint(x: ef.midX, y: ef.midY)) {
                            return .visible
                        }
                        return .offscreen(center: center)
                    }
                    if case .visible = last {
                        return ToolResult.action(success: true, method: "accessibility", extra: [
                            "found": .bool(true), "scrolls": .int(scrolls), "activated": .bool(foreground),
                        ])
                    }
                    guard canScrollAgain(scrolls: scrolls, maxScrolls: maxScrolls, now: Date(), deadline: deadline) else { break }
                    // Scrolling at a guessed point can hit another app's window or nothing
                    // at all, and still report success — so with no frame to aim at, stop.
                    guard let center = last.center else {
                        return ToolResult.error("Cannot scroll: the app exposes no window frame to aim the scroll wheel at (no focused window and no AX windows), so a wheel step would land at an arbitrary screen point. Bring a window up (list_windows, activate_app) and retry. Target: \(InteractionTools.describe(args))")
                    }
                    if case .refused(let error) = try await InteractionTools.deliver(pid: pid, foreground: foreground, {
                        InputSimulator.scroll(at: center, deltaY: deltaY, pid: $0)
                    }) {
                        return error
                    }
                    scrolls += 1
                    try await AXExecutor.pause(0.15)
                }

                // maxScrolls or the deadline ran out with the element still not visible.
                // `last` is the look taken after the final scroll, so it is the verdict.
                let limits = "after \(scrolls) scroll(s) (maxScrolls=\(maxScrolls), timeout=\(timeout)s)"
                if case .offscreen = last {
                    return ToolResult.error("The element exists but stayed outside the window \(limits): \(InteractionTools.describe(args)). Try a larger maxScrolls, direction:'\(direction == "up" ? "down" : "up")', or scope:'app' if it lives in another window.")
                }
                return ToolResult.error("Element never became visible \(limits): \(InteractionTools.describe(args))")
            }
        ))
    }
}
