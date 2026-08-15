import Foundation
import ApplicationServices
import MCPServer
import AccessibilityEngine

struct InspectionTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "get_element_tree",
            description: "Get the accessibility UI element tree for an application. Returns a hierarchical JSON tree of UI elements with roles, titles, and properties.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle ID, app name, or PID"),
                    ]),
                    "maxDepth": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum tree depth (default 5)"),
                    ]),
                    "detail": .object([
                        "type": .string("string"),
                        "description": .string("'lean' (default) returns role/title/identifier/value/enabled/focused/children. 'full' also includes description/roleDescription/position/size/actions."),
                    ]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let maxDepth = args?["maxDepth"]?.intValue ?? 5
                let detail = AXTreeDetail(raw: args?["detail"]?.stringValue)
                let tree = await AXExecutor.app(pid).run {
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    return AXElementTree.buildTree(root: appElement, maxDepth: maxDepth, detail: detail)
                }
                return ToolResult.json(tree)
            }
        ))

        registry.register(.init(
            name: "find_elements",
            description: "Search for UI elements by role, title, identifier, description, or visible label text. Returns matches with their paths for use with interaction tools. Use labelContains when you can see the text on screen but don't know which AX attribute carries it (SwiftUI varies).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle ID, app name, or PID"),
                    ]),
                    "role": .object([
                        "type": .string("string"),
                        "description": .string("AX role (e.g. 'AXButton', 'AXTextField', 'AXStaticText')"),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Exact AXTitle match"),
                    ]),
                    "titleContains": .object([
                        "type": .string("string"),
                        "description": .string("Partial AXTitle match (case-insensitive)"),
                    ]),
                    "identifier": .object([
                        "type": .string("string"),
                        "description": .string("Accessibility identifier (.accessibilityIdentifier in SwiftUI)"),
                    ]),
                    "value": .object([
                        "type": .string("string"),
                        "description": .string("Element AXValue"),
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("Exact AXDescription match (SwiftUI Button labels often land here)"),
                    ]),
                    "descriptionContains": .object([
                        "type": .string("string"),
                        "description": .string("Partial AXDescription match (case-insensitive)"),
                    ]),
                    "labelContains": .object([
                        "type": .string("string"),
                        "description": .string("Substring match across title/description/help/value — use when you see the text but don't know where SwiftUI put it"),
                    ]),
                    "maxResults": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum results to return (default 20)"),
                    ]),
                    "scope": SelectorSchema.scopeProperty(default: "app"),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let criteria = AXElementSearchCriteria(from: args, maxResults: args?["maxResults"]?.intValue ?? 20)

                let results = await AXExecutor.app(pid).run {
                    let root = SearchScope.root(pid: pid, args: args, defaultScope: "app")
                    return AXElementSearch.find(root: root, criteria: criteria)
                }

                let items: [JSONValue] = results.map { r in
                    var fields: [String: JSONValue] = [
                        "path": .string(r.path),
                        "depth": .int(r.depth),
                        "role": .string(r.element.role ?? "unknown"),
                    ]
                    if let t = r.element.title, !t.isEmpty { fields["title"] = .string(t) }
                    if let id = r.element.identifier, !id.isEmpty { fields["identifier"] = .string(id) }
                    if let v = r.element.stringValue, !v.isEmpty { fields["value"] = .string(v) }
                    if let d = r.element.label, !d.isEmpty { fields["description"] = .string(d) }
                    if let pos = r.element.position {
                        fields["position"] = .object(["x": .double(pos.x), "y": .double(pos.y)])
                    }
                    if let sz = r.element.size {
                        fields["size"] = .object(["width": .double(sz.width), "height": .double(sz.height)])
                    }
                    fields["enabled"] = .bool(r.element.isEnabled)
                    fields["actions"] = .array(r.element.actionNames.map { .string($0) })
                    return .object(fields)
                }

                return ToolResult.json(.object([
                    "count": .int(items.count),
                    "elements": .array(items),
                ]))
            }
        ))

        registry.register(.init(
            name: "get_element_attributes",
            description: "Get all accessibility attributes of a specific UI element found by role and title/identifier",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle ID, app name, or PID"),
                    ]),
                    "role": .object([
                        "type": .string("string"),
                        "description": .string("AX role of the element"),
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Title of the element"),
                    ]),
                    "identifier": .object([
                        "type": .string("string"),
                        "description": .string("Accessibility identifier"),
                    ]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let criteria = AXElementSearchCriteria(from: args, maxResults: 1)

                let result = await AXExecutor.app(pid).run { () -> JSONValue in
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let results = AXElementSearch.find(root: appElement, criteria: criteria)
                    guard let first = results.first else { return JSONValue.null }

                    let element = first.element
                    var attrs: [String: JSONValue] = [:]
                    for name in element.attributeNames {
                        // Prefer the real classified value for AXValue so toggles/sliders
                        // surface their actual state (CFBoolean/CFNumber), not "(complex value)".
                        if name == (kAXValueAttribute as String), let jv = element.valueJSON {
                            attrs[name] = jv
                            continue
                        }
                        if let str: String = element.attribute(name) {
                            attrs[name] = .string(str)
                        } else if let b: Bool = element.attribute(name) {
                            attrs[name] = .bool(b)
                        } else if let n: Int = element.attribute(name) {
                            attrs[name] = .int(n)
                        } else {
                            // Short type tag instead of an opaque literal. Skip walking large
                            // relationship/UI-element attrs; just name their shape.
                            attrs[name] = .string(complexTypeTag(for: element, attribute: name))
                        }
                    }
                    attrs["_actions"] = .array(element.actionNames.map { .string($0) })
                    attrs["_path"] = .string(first.path)
                    return JSONValue.object(attrs)
                }

                if result.isNull {
                    return ToolResult.error("Element not found")
                }
                return ToolResult.json(result)
            }
        ))

        registerGetFocusedElement(in: registry)
    }

    static func registerGetFocusedElement(in registry: ToolRegistry) {
        registry.register(.init(
            name: "get_focused_element",
            description: "Report the element that holds the app's INTERNAL keyboard focus (kAXFocusedUIElement) — role, label, value, frame, and enclosing window. Works while the app is in the background (every app keeps its own focus chain even when not frontmost). Use before/after type_text to verify where keystrokes will land.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let result = await AXExecutor.app(pid).run { () -> JSONValue in
                    let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    guard let ref: AXUIElement = app.attribute(kAXFocusedUIElementAttribute) else {
                        return .null
                    }
                    let el = AXElement(ref)
                    var fields: [String: JSONValue] = [
                        "role": .string(el.role ?? "unknown"),
                        "enabled": .bool(el.isEnabled),
                    ]
                    if let t = el.title, !t.isEmpty { fields["title"] = .string(t) }
                    if let id = el.identifier, !id.isEmpty { fields["identifier"] = .string(id) }
                    if let v = el.valueJSON { fields["value"] = v }
                    if let d = el.label, !d.isEmpty { fields["description"] = .string(d) }
                    if let f = el.frame {
                        fields["frame"] = .object([
                            "x": .double(f.origin.x), "y": .double(f.origin.y),
                            "w": .double(f.size.width), "h": .double(f.size.height),
                        ])
                    }
                    // Name the enclosing window so multi-window focus is unambiguous.
                    var current: AXElement? = el
                    var hops = 0
                    while let node = current, hops < 64 {
                        if node.role == "AXWindow" {
                            if let t = node.title, !t.isEmpty { fields["window"] = .string(t) }
                            break
                        }
                        current = node.parent
                        hops += 1
                    }
                    return .object(fields)
                }
                if result.isNull {
                    return ToolResult.error("App has no focused element (nothing holds its internal keyboard focus)")
                }
                return ToolResult.json(result)
            }
        ))
    }

    /// A short, token-lean tag describing a non-scalar attribute value instead of the old
    /// opaque "(complex value)" literal. We read the raw CFTypeRef once and name its shape
    /// (array / AX element / AX point-or-size / class name) — never recursing into it, so a
    /// big relationship attribute (children, related elements) can't explode the payload.
    static func complexTypeTag(for element: AXElement, attribute name: String) -> String {
        guard let raw: CFTypeRef = element.attribute(name) else { return "[empty]" }
        let typeID = CFGetTypeID(raw)
        if typeID == CFArrayGetTypeID() {
            let count = CFArrayGetCount((raw as! CFArray))
            return "[array \(count)]"
        }
        if typeID == AXUIElementGetTypeID() {
            return "[axelement]"
        }
        if typeID == AXValueGetTypeID() {
            if AXValueExtract.point(raw) != nil { return "[axvalue point]" }
            if AXValueExtract.size(raw) != nil { return "[axvalue size]" }
            return "[axvalue]"
        }
        // Fall back to the CF/NS class name (e.g. AXTextMarker, NSAttributedString, NSURL).
        let className = CFCopyTypeIDDescription(typeID) as String? ?? "value"
        return "[\(className)]"
    }
}
