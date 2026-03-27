import Foundation
import MCPServer
import AccessibilityEngine

struct InspectionTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "get_element_tree",
            description: "Get the accessibility UI element tree for an application. Returns a hierarchical JSON tree of all UI elements with their roles, titles, and properties.",
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
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let maxDepth = args?["maxDepth"]?.intValue ?? 5
                let tree = await MainActor.run {
                    let appElement = AXElement.application(pid: pid)
                    return AXElementTree.buildTree(root: appElement, maxDepth: maxDepth)
                }
                return ToolResult.json(tree)
            }
        ))

        registry.register(.init(
            name: "find_elements",
            description: "Search for UI elements matching criteria (role, title, identifier). Returns matching elements with their paths for use with interaction tools.",
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
                        "description": .string("Exact title match"),
                    ]),
                    "titleContains": .object([
                        "type": .string("string"),
                        "description": .string("Partial title match (case-insensitive)"),
                    ]),
                    "identifier": .object([
                        "type": .string("string"),
                        "description": .string("Accessibility identifier"),
                    ]),
                    "value": .object([
                        "type": .string("string"),
                        "description": .string("Element value"),
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
                let criteria = AXElementSearchCriteria(
                    role: args?["role"]?.stringValue,
                    title: args?["title"]?.stringValue,
                    titleContains: args?["titleContains"]?.stringValue,
                    identifier: args?["identifier"]?.stringValue,
                    value: args?["value"]?.stringValue,
                    maxResults: args?["maxResults"]?.intValue ?? 20
                )

                let results = await MainActor.run {
                    let appElement = AXElement.application(pid: pid)
                    return AXElementSearch.find(root: appElement, criteria: criteria)
                }

                let items: [JSONValue] = results.map { r in
                    var fields: [String: JSONValue] = [
                        "path": .string(r.path),
                        "depth": .int(r.depth),
                        "role": .string(r.element.role ?? "unknown"),
                    ]
                    if let t = r.element.title { fields["title"] = .string(t) }
                    if let id = r.element.identifier { fields["identifier"] = .string(id) }
                    if let v = r.element.stringValue { fields["value"] = .string(v) }
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
                let criteria = AXElementSearchCriteria(
                    role: args?["role"]?.stringValue,
                    title: args?["title"]?.stringValue,
                    identifier: args?["identifier"]?.stringValue,
                    maxResults: 1
                )

                let result = await MainActor.run {
                    let appElement = AXElement.application(pid: pid)
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
