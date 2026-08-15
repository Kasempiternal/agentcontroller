import ApplicationServices
import Foundation
import MCPServer
import AccessibilityEngine
import ScreenCapture

struct CaptureTools {
    /// Shared schema fragment for the payload-size controls every screenshot tool accepts.
    private static var encodingSchemaProperties: [String: JSONValue] {
        [
            "maxLongestSide": .object([
                "type": .string("integer"),
                "description": .string("Cap the longest image side in pixels, preserving aspect ratio. Default ~1400 to keep payloads small."),
            ]),
            "maxWidth": .object([
                "type": .string("integer"),
                "description": .string("Alias for maxLongestSide."),
            ]),
            "format": .object([
                "type": .string("string"),
                "enum": .array([.string("png"), .string("jpeg")]),
                "description": .string("Image format. Default 'jpeg' (typically 20-50x smaller than PNG)."),
            ]),
            "quality": .object([
                "type": .string("number"),
                "description": .string("JPEG quality 0-1. Default 0.7. Ignored for PNG."),
            ]),
        ]
    }

    /// Parse the shared encoding params from tool args, applying agent-friendly defaults.
    private static func encodingParams(from args: JSONValue?) -> (maxLongestSide: Int?, format: ImageFormat, quality: CGFloat) {
        let cap = args?["maxLongestSide"]?.intValue
            ?? args?["maxWidth"]?.intValue
            ?? WindowCapturer.defaultMaxLongestSide
        let format = ImageFormat.parse(args?["format"]?.stringValue)
        let quality = CGFloat(args?["quality"]?.doubleValue ?? 0.7)
        return (cap, format, quality)
    }

    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "screenshot_window",
            description: "Capture a screenshot of a specific app window. Works in the background — the window does NOT need to be frontmost and can be fully covered by other windows (capture reads the window's own backing store). Minimized windows cannot be captured (call restore_window first). Disambiguate multi-window apps with windowTitle or windowIndex (index into list_windows order). Returns a JPEG by default (downscaled to keep payloads small); pass format/maxLongestSide/quality to override.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object({
                    var props: [String: JSONValue] = [
                        "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                        "windowTitle": .object(["type": .string("string"), "description": .string("Specific window title (optional; default = most plausible main window)")]),
                        "windowIndex": .object(["type": .string("integer"), "description": .string("Window index in the app's AX window order (same as list_windows), for windows with duplicate/empty titles")]),
                    ]
                    for (k, v) in encodingSchemaProperties { props[k] = v }
                    return props
                }()),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                var windowTitle = args?["windowTitle"]?.stringValue
                var windowOrigin: CGPoint? = nil
                let windowIndex = args?["windowIndex"]?.intValue
                let enc = encodingParams(from: args)

                // Pre-resolve via AX: detect the all-minimized case for a precise error
                // (SCKit cannot capture minimized windows), and turn windowIndex into the
                // matching AX window's title + origin for SCWindow resolution.
                struct AXWindowInfo: Sendable {
                    let count: Int
                    let allMinimized: Bool
                    let indexTitle: String?
                    let indexOrigin: CGPoint?
                }
                let ax: AXWindowInfo = await AXExecutor.app(pid).run {
                    let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let windows = app.windows
                    let allMin = !windows.isEmpty && windows.allSatisfy {
                        ($0.attribute(kAXMinimizedAttribute) as Bool?) ?? false
                    }
                    if let windowIndex, windowIndex >= 0, windowIndex < windows.count {
                        return AXWindowInfo(count: windows.count, allMinimized: allMin,
                                            indexTitle: windows[windowIndex].title,
                                            indexOrigin: windows[windowIndex].position)
                    }
                    return AXWindowInfo(count: windows.count, allMinimized: allMin,
                                        indexTitle: nil, indexOrigin: nil)
                }
                if ax.allMinimized {
                    return ToolResult.error("All windows of this app are minimized — minimized windows cannot be captured. Call restore_window first (note: restoring makes the window visible on screen again).")
                }
                if let windowIndex {
                    guard windowIndex >= 0, windowIndex < ax.count else {
                        return ToolResult.error("windowIndex \(windowIndex) is out of range (app has \(ax.count) window(s))")
                    }
                    windowTitle = ax.indexTitle
                    windowOrigin = ax.indexOrigin
                }

                do {
                    let captured = try await WindowCapturer.captureWindow(
                        pid: pid,
                        windowTitle: windowTitle,
                        windowOrigin: windowOrigin,
                        maxLongestSide: enc.maxLongestSide,
                        format: enc.format,
                        quality: enc.quality
                    )
                    return ToolResult.image(base64: captured.data.base64EncodedString(), mimeType: captured.mimeType)
                } catch {
                    return ToolResult.error(error.localizedDescription)
                }
            }
        ))

        registry.register(.init(
            name: "start_recording",
            description: "Start recording a window to a .mov video (H.264, 30fps max) — visual evidence for a QA flow. Works in the background like screenshots (window can be covered; minimized windows won't record). One recording at a time; finish with stop_recording, which returns the file path. Requires macOS 15+.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "windowTitle": .object(["type": .string("string"), "description": .string("Specific window title (optional; default = most plausible main window)")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let windowTitle = args?["windowTitle"]?.stringValue
                guard #available(macOS 15.0, *) else {
                    return ToolResult.error("start_recording requires macOS 15 or later")
                }
                do {
                    let url = try await WindowRecorder.shared.start(pid: pid, windowTitle: windowTitle)
                    return ToolResult.json(.object([
                        "recording": .bool(true),
                        "path": .string(url.path),
                    ]))
                } catch {
                    return ToolResult.error(error.localizedDescription)
                }
            }
        ))

        registry.register(.init(
            name: "stop_recording",
            description: "Stop the window recording started with start_recording and finalize the .mov file. Returns {path, seconds}.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            handler: { _ in
                guard #available(macOS 15.0, *) else {
                    return ToolResult.error("stop_recording requires macOS 15 or later")
                }
                do {
                    let result = try await WindowRecorder.shared.stop()
                    return ToolResult.json(.object([
                        "path": .string(result.path),
                        "seconds": .double((result.seconds * 10).rounded() / 10),
                    ]))
                } catch {
                    return ToolResult.error(error.localizedDescription)
                }
            }
        ))

        registry.register(.init(
            name: "screenshot_element",
            description: "Capture a screenshot of a specific UI element by cropping its enclosing window to the element's bounds. Returns a JPEG by default.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object({
                    var props: [String: JSONValue] = [
                        "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                        "role": .object(["type": .string("string"), "description": .string("AX role of the element")]),
                        "title": .object(["type": .string("string"), "description": .string("Title of the element")]),
                        "identifier": .object(["type": .string("string"), "description": .string("Accessibility identifier")]),
                    ]
                    for (k, v) in encodingSchemaProperties { props[k] = v }
                    return props
                }()),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let enc = encodingParams(from: args)

                // Find the element AND its ENCLOSING AX window, then measure the element
                // relative to that specific window. For multi-window apps (sheets,
                // inspectors) the element can live in a window other than windows.first,
                // so we must crop the SAME window we offset against — not window A's
                // coordinates applied to window B's capture.
                let resolved = await AXExecutor.app(pid).run { () -> (relativeRect: CGRect, windowOrigin: CGPoint, windowTitle: String?)? in
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
                    guard let result = AXElementSearch.find(root: appElement, criteria: criteria).first,
                          let pos = result.element.position,
                          let size = result.element.size else { return nil }

                    // Walk parents up to the enclosing AXWindow; fall back to the app's
                    // focused window, then the first window.
                    let enclosing = enclosingWindow(of: result.element)
                        ?? appElement.focusedWindow
                        ?? appElement.windows.first
                    let windowOrigin = enclosing?.position ?? appElement.windows.first?.position ?? .zero
                    let windowTitle = enclosing?.title

                    let relativeRect = CGRect(
                        x: pos.x - windowOrigin.x,
                        y: pos.y - windowOrigin.y,
                        width: size.width,
                        height: size.height
                    )
                    return (relativeRect, windowOrigin, windowTitle)
                }

                guard let resolved else {
                    return ToolResult.error("Element not found")
                }

                do {
                    let captured = try await WindowCapturer.captureRegion(
                        pid: pid,
                        region: resolved.relativeRect,
                        windowTitle: resolved.windowTitle,
                        windowOrigin: resolved.windowOrigin,
                        maxLongestSide: enc.maxLongestSide,
                        format: enc.format,
                        quality: enc.quality
                    )
                    return ToolResult.image(base64: captured.data.base64EncodedString(), mimeType: captured.mimeType)
                } catch {
                    return ToolResult.error(error.localizedDescription)
                }
            }
        ))

        registry.register(.init(
            name: "screenshot_screen",
            description: "Capture a screenshot of the entire screen. Returns a JPEG by default (downscaled to keep payloads small).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object({
                    var props: [String: JSONValue] = [
                        "screenIndex": .object(["type": .string("integer"), "description": .string("Screen index (default 0 = main display)")]),
                    ]
                    for (k, v) in encodingSchemaProperties { props[k] = v }
                    return props
                }()),
            ]),
            handler: { args in
                let screenIndex = args?["screenIndex"]?.intValue ?? 0
                let enc = encodingParams(from: args)
                do {
                    let captured = try await WindowCapturer.captureScreen(
                        screenIndex: screenIndex,
                        scale: 1.0,
                        maxLongestSide: enc.maxLongestSide,
                        format: enc.format,
                        quality: enc.quality
                    )
                    return ToolResult.image(base64: captured.data.base64EncodedString(), mimeType: captured.mimeType)
                } catch {
                    return ToolResult.error(error.localizedDescription)
                }
            }
        ))
    }

    /// Walk the parent chain until we hit the element whose role is AXWindow.
    /// Bounded to avoid pathological loops in malformed AX trees.
    private static func enclosingWindow(of element: AXElement) -> AXElement? {
        var current: AXElement? = element
        var hops = 0
        while let node = current, hops < 64 {
            // kAXWindowRole == "AXWindow"; compared as a literal to avoid importing
            // ApplicationServices into this module.
            if node.role == "AXWindow" { return node }
            current = node.parent
            hops += 1
        }
        return nil
    }
}
