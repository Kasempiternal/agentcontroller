import ApplicationServices
import Foundation
import MCPServer
import AccessibilityEngine

struct InteractionTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "click",
            description: "Click a UI element (AX action, background-safe) or at screen coordinates (CGEvent, requires focus). For element matching, use role+title/identifier when known; use labelContains when you see the text on-screen but don't know which AX attribute carries it (common with SwiftUI buttons that stash labels in AXDescription).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "role": .object(["type": .string("string"), "description": .string("AX role (e.g. 'AXButton')")]),
                    "title": .object(["type": .string("string"), "description": .string("Exact AXTitle match")]),
                    "titleContains": .object(["type": .string("string"), "description": .string("Partial AXTitle match (case-insensitive)")]),
                    "identifier": .object(["type": .string("string"), "description": .string("Accessibility identifier")]),
                    "description": .object(["type": .string("string"), "description": .string("Exact AXDescription match (SwiftUI Button labels often land here)")]),
                    "descriptionContains": .object(["type": .string("string"), "description": .string("Partial AXDescription match")]),
                    "labelContains": .object(["type": .string("string"), "description": .string("Substring across title/description/help/value — preferred when unsure")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate (screen points) for coordinate click")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate (screen points) for coordinate click")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()

                // Coordinate-based click
                if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
                    await MainActor.run {
                        AppManager.activate(pid: pid)
                        usleep(100_000)
                        InputSimulator.click(at: CGPoint(x: x, y: y))
                    }
                    return ToolResult.json(.object(["success": .bool(true), "method": .string("coordinate")]))
                }

                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)

                let result = await MainActor.run {
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let results = AXElementSearch.find(root: appElement, criteria: criteria)
                    guard let first = results.first else { return false }
                    return first.element.press()
                }

                return ToolResult.json(.object([
                    "success": .bool(result),
                    "method": .string("accessibility"),
                ]))
            }
        ))

        registry.register(.init(
            name: "double_click",
            description: "Double-click a UI element or at coordinates. AX path (two press actions, background-safe) preferred; falls back to coordinate CGEvent if AX press fails. Accepts the same matchers as click (role/title/identifier/description/labelContains).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "role": .object(["type": .string("string"), "description": .string("AX role")]),
                    "title": .object(["type": .string("string"), "description": .string("Exact AXTitle")]),
                    "titleContains": .object(["type": .string("string"), "description": .string("Partial AXTitle")]),
                    "identifier": .object(["type": .string("string"), "description": .string("Accessibility identifier")]),
                    "description": .object(["type": .string("string"), "description": .string("Exact AXDescription")]),
                    "labelContains": .object(["type": .string("string"), "description": .string("Substring across title/description/help/value")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()

                // Coordinate path: still requires focus.
                if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
                    await MainActor.run {
                        AppManager.activate(pid: pid)
                        usleep(100_000)
                        InputSimulator.doubleClick(at: CGPoint(x: x, y: y))
                    }
                    return ToolResult.json(.object(["success": .bool(true), "method": .string("coordinate")]))
                }

                let axResult = await MainActor.run { () -> (found: Bool, center: CGPoint?) in
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
                    guard let r = AXElementSearch.find(root: appElement, criteria: criteria).first else {
                        return (false, nil)
                    }
                    // Try AX double-press (works in background for most standard controls)
                    let first = r.element.press()
                    let second = r.element.press()
                    if first && second {
                        return (true, nil)
                    }
                    // Fall back to coordinate-based double click at element center
                    guard let pos = r.element.position, let sz = r.element.size else {
                        return (true, nil)
                    }
                    return (true, CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2))
                }

                if !axResult.found {
                    return ToolResult.error("Element not found")
                }
                if let pt = axResult.center {
                    // AX press returned false; use coordinate-based double click as fallback
                    await MainActor.run {
                        AppManager.activate(pid: pid)
                        usleep(100_000)
                        InputSimulator.doubleClick(at: pt)
                    }
                    return ToolResult.json(.object(["success": .bool(true), "method": .string("coordinate-fallback")]))
                }
                return ToolResult.json(.object(["success": .bool(true), "method": .string("accessibility")]))
            }
        ))

        registry.register(.init(
            name: "right_click",
            description: "Right-click a UI element (AX showMenu, background-safe) or at coordinates to open a context menu. Accepts the same matchers as click.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "role": .object(["type": .string("string"), "description": .string("AX role")]),
                    "title": .object(["type": .string("string"), "description": .string("Exact AXTitle")]),
                    "titleContains": .object(["type": .string("string"), "description": .string("Partial AXTitle")]),
                    "identifier": .object(["type": .string("string"), "description": .string("Accessibility identifier")]),
                    "description": .object(["type": .string("string"), "description": .string("Exact AXDescription")]),
                    "labelContains": .object(["type": .string("string"), "description": .string("Substring across title/description/help/value")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                if let x = args?["x"]?.doubleValue, let y = args?["y"]?.doubleValue {
                    await MainActor.run {
                        AppManager.activate(pid: pid)
                        usleep(100_000)
                        InputSimulator.rightClick(at: CGPoint(x: x, y: y))
                    }
                    return ToolResult.json(.object(["success": .bool(true)]))
                }
                let result = await MainActor.run {
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
                    guard let r = AXElementSearch.find(root: appElement, criteria: criteria).first else { return false }
                    return r.element.showMenu()
                }
                return ToolResult.json(.object(["success": .bool(result)]))
            }
        ))

        registry.register(.init(
            name: "type_text",
            description: "Type text into the focused element. Optionally focus a specific element first by role/title.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "text": .object(["type": .string("string"), "description": .string("Text to type")]),
                    "role": .object(["type": .string("string"), "description": .string("AX role of element to focus first")]),
                    "title": .object(["type": .string("string"), "description": .string("Title of element to focus first")]),
                    "identifier": .object(["type": .string("string"), "description": .string("Identifier of element to focus first")]),
                ]),
                "required": .array([.string("app"), .string("text")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                guard let text = args?["text"]?.stringValue else {
                    throw ToolError.missingParameter("text")
                }
                let hasTarget = args?["role"] != nil || args?["title"] != nil || args?["identifier"] != nil

                // Try AX set-value first. For AXTextField / AXTextArea this works in the
                // background. SwiftUI TextField often rejects AX-set silently (its
                // @Binding only fires on NSTextDidChangeNotification, not AX), so we
                // read back and fall through to CGEvent if the value didn't stick.
                enum TypeOutcome {
                    case axSuccess
                    case axFocusedFallback(AXElement)
                    case noTarget
                }
                let outcome: TypeOutcome = await MainActor.run {
                    guard hasTarget else { return .noTarget }
                    let criteria = AXElementSearchCriteria(from: args, maxResults: 1)
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    guard let r = AXElementSearch.find(root: appElement, criteria: criteria).first else {
                        return .noTarget
                    }
                    let role = r.element.role ?? ""
                    if role == "AXTextField" || role == "AXTextArea",
                       r.element.setAttribute(kAXValueAttribute, value: text as CFString),
                       r.element.stringValue == text {
                        return .axSuccess
                    }
                    return .axFocusedFallback(r.element)
                }

                if case .axSuccess = outcome {
                    return ToolResult.json(.object(["success": .bool(true), "typed": .string(text), "method": .string("accessibility")]))
                }

                await MainActor.run {
                    AppManager.activate(pid: pid)
                    usleep(100_000)
                    if case .axFocusedFallback(let element) = outcome {
                        _ = element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
                    }
                    InputSimulator.typeText(text)
                }
                return ToolResult.json(.object(["success": .bool(true), "typed": .string(text), "method": .string("keyboard")]))
            }
        ))

        registry.register(.init(
            name: "send_shortcut",
            description: "Send a keyboard shortcut (e.g. Cmd+S, Cmd+Shift+Z)",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "key": .object(["type": .string("string"), "description": .string("Key name (e.g. 's', 'z', 'return', 'tab', 'f5')")]),
                    "modifiers": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Modifier keys: 'cmd', 'shift', 'opt'/'alt', 'ctrl'"),
                    ]),
                ]),
                "required": .array([.string("app"), .string("key")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                guard let keyName = args?["key"]?.stringValue else {
                    throw ToolError.missingParameter("key")
                }
                guard let keyCode = InputSimulator.keyCode(for: keyName) else {
                    throw ToolError.invalidParameter("Unknown key: \(keyName)")
                }
                let modNames = args?["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let flags = InputSimulator.modifierFlags(from: modNames)

                await MainActor.run {
                    AppManager.activate(pid: pid)
                    usleep(100_000)
                    InputSimulator.sendShortcut(keyCode: keyCode, modifiers: flags)
                }
                return ToolResult.json(.object(["success": .bool(true)]))
            }
        ))
    }
}
