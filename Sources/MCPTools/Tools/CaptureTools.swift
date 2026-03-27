import Foundation
import MCPServer
import AccessibilityEngine
import ScreenCapture

struct CaptureTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "screenshot_window",
            description: "Capture a screenshot of a specific app window. Returns a PNG image.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "windowTitle": .object(["type": .string("string"), "description": .string("Specific window title (optional, defaults to first window)")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let windowTitle = args?["windowTitle"]?.stringValue

                do {
                    let pngData = try await WindowCapturer.captureWindow(pid: pid, windowTitle: windowTitle)
                    let base64 = pngData.base64EncodedString()
                    return ToolResult.image(base64: base64)
                } catch {
                    return ToolResult.error(error.localizedDescription)
                }
            }
        ))

        registry.register(.init(
            name: "screenshot_element",
            description: "Capture a screenshot of a specific UI element by cropping the window capture to the element's bounds",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "role": .object(["type": .string("string"), "description": .string("AX role of the element")]),
                    "title": .object(["type": .string("string"), "description": .string("Title of the element")]),
                    "identifier": .object(["type": .string("string"), "description": .string("Accessibility identifier")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()

                // Find the element and get its bounds relative to the window
                let elementFrame = await MainActor.run { () -> (elementFrame: CGRect, windowOrigin: CGPoint)? in
                    let appElement = AXElement.application(pid: pid)
                    let criteria = AXElementSearchCriteria(
                        role: args?["role"]?.stringValue,
                        title: args?["title"]?.stringValue,
                        identifier: args?["identifier"]?.stringValue,
                        maxResults: 1
                    )
                    guard let result = AXElementSearch.find(root: appElement, criteria: criteria).first,
                          let pos = result.element.position,
                          let size = result.element.size else { return nil }
                    let windows = appElement.windows
                    let windowOrigin = windows.first?.position ?? .zero
                    return (CGRect(origin: pos, size: size), windowOrigin)
                }

                guard let frame = elementFrame else {
                    return ToolResult.error("Element not found")
                }

                let relativeRect = CGRect(
                    x: frame.elementFrame.origin.x - frame.windowOrigin.x,
                    y: frame.elementFrame.origin.y - frame.windowOrigin.y,
                    width: frame.elementFrame.width,
                    height: frame.elementFrame.height
                )

                do {
                    let pngData = try await WindowCapturer.captureRegion(pid: pid, region: relativeRect)
                    return ToolResult.image(base64: pngData.base64EncodedString())
                } catch {
                    return ToolResult.error(error.localizedDescription)
                }
            }
        ))

        registry.register(.init(
            name: "screenshot_screen",
            description: "Capture a screenshot of the entire screen",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "screenIndex": .object(["type": .string("integer"), "description": .string("Screen index (default 0 = main display)")]),
                ]),
            ]),
            handler: { args in
                let screenIndex = args?["screenIndex"]?.intValue ?? 0
                do {
                    let pngData = try await WindowCapturer.captureScreen(screenIndex: screenIndex, scale: 1.0)
                    return ToolResult.image(base64: pngData.base64EncodedString())
                } catch {
                    return ToolResult.error(error.localizedDescription)
                }
            }
        ))
    }
}
