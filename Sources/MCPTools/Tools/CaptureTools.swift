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
            description: "Capture a screenshot of a specific app window. Returns a JPEG image by default (downscaled to keep payloads small); pass format/maxLongestSide/quality to override.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object({
                    var props: [String: JSONValue] = [
                        "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                        "windowTitle": .object(["type": .string("string"), "description": .string("Specific window title (optional, defaults to first window)")]),
                    ]
                    for (k, v) in encodingSchemaProperties { props[k] = v }
                    return props
                }()),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let windowTitle = args?["windowTitle"]?.stringValue
                let enc = encodingParams(from: args)

                do {
                    let captured = try await WindowCapturer.captureWindow(
                        pid: pid,
                        windowTitle: windowTitle,
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
                let resolved = await AXExecutor.shared.run { () -> (relativeRect: CGRect, windowOrigin: CGPoint, windowTitle: String?)? in
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
