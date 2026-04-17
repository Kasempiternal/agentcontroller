import Foundation
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
                let tree = await MainActor.run {
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
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let criteria = AXElementSearchCriteria(from: args, maxResults: args?["maxResults"]?.intValue ?? 20)

                let results = await MainActor.run {
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    return AXElementSearch.find(root: appElement, criteria: criteria)
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

                let result = await MainActor.run {
                    let appElement = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let results = AXElementSearch.find(root: appElement, criteria: criteria)
                    guard let first = results.first else { return JSONValue.null }

                    let element = first.element
                    var attrs: [String: JSONValue] = [:]
                    for name in element.attributeNames {
                        if let str: String = element.attribute(name) {
                            attrs[name] = .string(str)
                        } else if let b: Bool = element.attribute(name) {
                            attrs[name] = .bool(b)
                        } else if let n: Int = element.attribute(name) {
                            attrs[name] = .int(n)
                        } else {
                            attrs[name] = .string("(complex value)")
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
    }
}
