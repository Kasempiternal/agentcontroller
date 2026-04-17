import ApplicationServices
import Foundation
import MCPServer
import AccessibilityEngine

struct InteractionTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "click",
            description: "Click on a UI element by searching for it (role/title/identifier), or click at specific coordinates. Prefers AX press action for reliability.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle ID, app name, or PID"),
                    ]),
                    "role": .object([
                        "type": .string("string"),
                        "description": .string("AX role (e.g. 'AXButton')"),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Element title to click"),
                    ]),
                    "titleContains": .object([
                        "type": .string("string"),
                        "description": .string("Partial title match"),
                    ]),
                    "identifier": .object([
                        "type": .string("string"),
                        "description": .string("Accessibility identifier"),
                    ]),
                    "x": .object([
                        "type": .string("number"),
                        "description": .string("X coordinate (screen points) for coordinate-based click"),
                    ]),
                    "y": .object([
                        "type": .string("number"),
                        "description": .string("Y coordinate (screen points) for coordinate-based click"),
                    ]),
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

                // Element-based click via AX
                let criteria = AXElementSearchCriteria(
                    role: args?["role"]?.stringValue,
                    title: args?["title"]?.stringValue,
                    titleContains: args?["titleContains"]?.stringValue,
                    identifier: args?["identifier"]?.stringValue,
                    maxResults: 1
                )

                let result = await MainActor.run {
                    let appElement = AXElement.application(pid: pid)
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
            description: "Double-click at coordinates or on a UI element. AX-targeted double-click first tries two press actions (no activation, works in background); falls back to coordinate-based CGEvent if needed.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "title": .object(["type": .string("string"), "description": .string("Element title")]),
                    "role": .object(["type": .string("string"), "description": .string("AX role")]),
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

                // AX path: no activate needed. Two presses usually satisfy "double click" semantics.
                let axResult = await MainActor.run { () -> (found: Bool, center: CGPoint?) in
                    let appElement = AXElement.application(pid: pid)
                    let criteria = AXElementSearchCriteria(
                        role: args?["role"]?.stringValue,
                        title: args?["title"]?.stringValue,
                        maxResults: 1
                    )
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
            description: "Right-click at coordinates or on a UI element to open context menu",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "x": .object(["type": .string("number"), "description": .string("X coordinate")]),
                    "y": .object(["type": .string("number"), "description": .string("Y coordinate")]),
                    "title": .object(["type": .string("string"), "description": .string("Element title")]),
                    "role": .object(["type": .string("string"), "description": .string("AX role")]),
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
                // AX showMenu action
                let result = await MainActor.run {
                    let appElement = AXElement.application(pid: pid)
                    let criteria = AXElementSearchCriteria(
                        role: args?["role"]?.stringValue,
                        title: args?["title"]?.stringValue,
                        maxResults: 1
                    )
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

                // AX fast path: if element targeting info was provided, try to set value
                // via AX without activating the app. Works in background for NSTextField /
                // AXTextArea. If read-back shows the value didn't stick (SwiftUI TextField
                // bug), fall back to CGEvent typing with activation.
                let axOutcome: String? = await MainActor.run { () -> String? in
                    guard args?["role"] != nil || args?["title"] != nil || args?["identifier"] != nil else {
                        return nil
                    }
                    let criteria = AXElementSearchCriteria(
                        role: args?["role"]?.stringValue,
                        title: args?["title"]?.stringValue,
                        identifier: args?["identifier"]?.stringValue,
                        maxResults: 1
                    )
                    let appElement = AXElement.application(pid: pid)
                    guard let r = AXElementSearch.find(root: appElement, criteria: criteria).first else {
                        return nil
                    }
                    let role = r.element.role ?? ""
                    if role == "AXTextField" || role == "AXTextArea" {
                        let ok = r.element.setAttribute(kAXValueAttribute, value: text as CFString)
                        if !ok { return nil }
                        // Read back — SwiftUI TextField often rejects AX-set silently
                        if r.element.stringValue == text {
                            return "accessibility"
                        }
                        return nil // fall through to CGEvent path
                    }
                    return nil
                }

                if let method = axOutcome {
                    return ToolResult.json(.object(["success": .bool(true), "typed": .string(text), "method": .string(method)]))
                }

                // CGEvent fallback: needs activation + keyboard focus.
                await MainActor.run {
                    AppManager.activate(pid: pid)
                    usleep(100_000)
                    if args?["role"] != nil || args?["title"] != nil || args?["identifier"] != nil {
                        let criteria = AXElementSearchCriteria(
                            role: args?["role"]?.stringValue,
                            title: args?["title"]?.stringValue,
                            identifier: args?["identifier"]?.stringValue,
                            maxResults: 1
                        )
                        let appElement = AXElement.application(pid: pid)
                        if let r = AXElementSearch.find(root: appElement, criteria: criteria).first {
                            _ = r.element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
                        }
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
