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
            description: "Capture a screenshot of a specific app window. Works in the background — the window does NOT need to be frontmost and can be fully covered by other windows (capture reads the window's own backing store). Minimized windows cannot be captured (call restore_window first). Default window is the app's focused window; pick another with windowTitle (windows sharing a title resolve to the focused one if it has that title, else the largest on-screen one) or windowIndex (index into list_windows order, exact even for duplicate titles). Returns a JPEG by default (downscaled to keep payloads small); pass format/maxLongestSide/quality to override.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object({
                    var props: [String: JSONValue] = [
                        "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                        "windowTitle": .object(["type": .string("string"), "description": .string("Specific window title (optional; default = the app's focused window)")]),
                        "windowIndex": .object(["type": .string("integer"), "description": .string("Window index in the app's AX window order (same as list_windows), for windows with duplicate/empty titles")]),
                    ]
                    for (k, v) in encodingSchemaProperties { props[k] = v }
                    return props
                }()),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let enc = encodingParams(from: args)

                let hint: WindowHint
                switch await resolveWindowHint(
                    pid: pid, windowTitle: args?["windowTitle"]?.stringValue, windowIndex: args?["windowIndex"]?.intValue
                ) {
                case .hint(let resolved): hint = resolved
                case .failure(let message): return ToolResult.error(message)
                }

                do {
                    let captured = try await WindowCapturer.captureWindow(
                        pid: pid,
                        windowTitle: hint.title,
                        windowOrigin: hint.origin,
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
            description: "Start recording a window to a .mov video (H.264, 30fps max, held to 4096px on the long edge) — visual evidence for a QA flow. Works in the background like screenshots (window can be covered; minimized windows won't record). One recording at a time; finish with stop_recording, which returns the file path. A recording stops by itself after maxSeconds (default 600, at most 3600) or when AgentController quits; stop_recording still returns the finished file. Requires macOS 15+.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "windowTitle": .object(["type": .string("string"), "description": .string("Specific window title (optional; default = the app's focused window)")]),
                    "maxSeconds": .object(["type": .string("number"), "description": .string("Stop automatically after this many seconds. Default 600, maximum 3600.")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                guard #available(macOS 15.0, *) else {
                    return ToolResult.error("start_recording requires macOS 15 or later")
                }

                let hint: WindowHint
                switch await resolveWindowHint(
                    pid: pid, windowTitle: args?["windowTitle"]?.stringValue, windowIndex: nil
                ) {
                case .hint(let resolved): hint = resolved
                case .failure(let message): return ToolResult.error(message)
                }

                let maxSeconds = args?["maxSeconds"]?.doubleValue
                do {
                    let url = try await WindowRecorder.shared.start(
                        pid: pid, windowTitle: hint.title, windowOrigin: hint.origin, maxSeconds: maxSeconds
                    )
                    return ToolResult.json(.object([
                        "recording": .bool(true),
                        "path": .string(url.path),
                        "maxSeconds": .double(RecordingLimit.seconds(requested: maxSeconds)),
                    ]))
                } catch {
                    return ToolResult.error(error.localizedDescription)
                }
            }
        ))

        registry.register(.init(
            name: "stop_recording",
            description: "Stop the window recording started with start_recording and finalize the .mov file. Returns {path, seconds}, plus autoStopReason when the recording had already ended on its own (time limit, app quit).",
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
                    var fields: [String: JSONValue] = [
                        "path": .string(result.path),
                        "seconds": .double((result.seconds * 10).rounded() / 10),
                    ]
                    if let reason = result.autoStopReason { fields["autoStopReason"] = .string(reason) }
                    return ToolResult.json(.object(fields))
                } catch {
                    return ToolResult.error(error.localizedDescription)
                }
            }
        ))

        registry.register(.init(
            name: "screenshot_element",
            description: "Capture a screenshot of a specific UI element by cropping its enclosing window to the element's bounds. Identify the element with elementId from snapshot/describe_screen, or with role/title/identifier selectors (a stale elementId falls back to the selectors when given). Returns a JPEG by default.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object({
                    var props: [String: JSONValue] = [
                        "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                        "elementId": .object(["type": .string("string"), "description": .string("Element id from snapshot/describe_screen (e.g. 'e12'). Preferred over selectors.")]),
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

                let handleId = args?["elementId"]?.stringValue
                let cached = if let handleId { await ElementHandleStore.shared.resolve(handleId) } else { nil as AXElement? }
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)

                // Find the element AND its ENCLOSING AX window, then measure the element
                // relative to that specific window. For multi-window apps (sheets,
                // inspectors) the element can live in a window other than windows.first,
                // so we must crop the SAME window we offset against — not window A's
                // coordinates applied to window B's capture.
                let lookup = await AXExecutor.app(pid).run { () -> ElementLookup in
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)

                    // A cached ref whose element the app has since destroyed answers every
                    // read with an error, so one role read tells live from stale.
                    var element = cached.flatMap { $0.role != nil ? $0 : nil }
                    if element == nil {
                        if handleId != nil, !criteria.hasAnyMatcher { return .staleHandle }
                        element = AXElementSearch.find(root: appElement, criteria: criteria).first?.element
                    }
                    guard let element, let frame = element.frame else { return .notFound }

                    // Walk parents up to the enclosing AXWindow; fall back to the app's
                    // focused window, then the first window.
                    let enclosing = enclosingWindow(of: element)
                        ?? appElement.focusedWindow
                        ?? appElement.windows.first
                    let windowOrigin = enclosing?.position ?? appElement.windows.first?.position ?? .zero

                    let region: CGRect
                    if let windowSize = enclosing?.size {
                        guard let visible = CaptureSizing.localRegion(
                            of: frame, in: CGRect(origin: windowOrigin, size: windowSize)
                        ) else { return .outsideWindow }
                        region = visible
                    } else {
                        region = frame.offsetBy(dx: -windowOrigin.x, dy: -windowOrigin.y)
                    }
                    return .found(region: region, windowOrigin: windowOrigin, windowTitle: enclosing?.title)
                }

                switch lookup {
                case .staleHandle:
                    return InteractionTools.staleHandleError(handleId ?? "?")
                case .notFound:
                    return ToolResult.error("Element not found (\(InteractionTools.describe(args)))")
                case .outsideWindow:
                    return ToolResult.error("The element lies outside its window's visible area (scrolled out of view or clipped), so there is nothing to crop. Scroll it into view first.")
                case .found(let region, let windowOrigin, let windowTitle):
                    do {
                        let captured = try await WindowCapturer.captureRegion(
                            pid: pid,
                            region: region,
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

    private enum ElementLookup: Sendable {
        case found(region: CGRect, windowOrigin: CGPoint, windowTitle: String?)
        case notFound
        case staleHandle
        case outsideWindow
    }

    /// Which window a capture means, as the title and origin `WindowPicker` matches on.
    private struct WindowHint: Sendable {
        let title: String?
        let origin: CGPoint?
    }

    private enum WindowHintOutcome {
        case hint(WindowHint)
        case failure(String)
    }

    /// One AX pass that answers every window question a capture has: are they all
    /// minimized (SCKit cannot capture those), which window does `windowIndex` name, and
    /// which window is focused (the default when the caller names nothing).
    private static func resolveWindowHint(pid: pid_t, windowTitle: String?, windowIndex: Int?) async -> WindowHintOutcome {
        struct Survey: Sendable {
            let count: Int
            let allMinimized: Bool
            let indexed: WindowHint?
            let focused: WindowHint?
        }
        let survey: Survey = await AXExecutor.app(pid).run {
            let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
            let windows = app.windows
            let allMinimized = !windows.isEmpty && windows.allSatisfy {
                ($0.attribute(kAXMinimizedAttribute) as Bool?) ?? false
            }
            var indexed: WindowHint?
            if let windowIndex, windowIndex >= 0, windowIndex < windows.count {
                indexed = WindowHint(title: windows[windowIndex].title, origin: windows[windowIndex].position)
            }
            let focused = app.focusedWindow.map { WindowHint(title: $0.title, origin: $0.position) }
            return Survey(count: windows.count, allMinimized: allMinimized, indexed: indexed, focused: focused)
        }

        if survey.allMinimized {
            return .failure("All windows of this app are minimized — minimized windows cannot be captured. Call restore_window first (note: restoring makes the window visible on screen again).")
        }
        if let windowIndex {
            guard let indexed = survey.indexed else {
                return .failure("windowIndex \(windowIndex) is out of range (app has \(survey.count) window(s))")
            }
            return .hint(indexed)
        }
        if let windowTitle, !windowTitle.isEmpty {
            // Several windows can share a title ("Untitled"); when the focused one is
            // among them it is the one the caller most plausibly means.
            let focusedOrigin = survey.focused?.title == windowTitle ? survey.focused?.origin : nil
            return .hint(WindowHint(title: windowTitle, origin: focusedOrigin))
        }
        // No hint from the caller: the app's focused window, not the largest one.
        return .hint(survey.focused ?? WindowHint(title: nil, origin: nil))
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
