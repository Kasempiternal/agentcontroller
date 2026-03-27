import Foundation
import MCPServer

public struct AXElementTree {
    public static func buildTree(root: AXElement, maxDepth: Int = 5) -> JSONValue {
        return nodeToJSON(root, depth: 0, maxDepth: maxDepth)
    }

    private static func nodeToJSON(_ element: AXElement, depth: Int, maxDepth: Int) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        fields["role"] = .string(element.role ?? "unknown")
        if let t = element.title, !t.isEmpty { fields["title"] = .string(t) }
        if let id = element.identifier, !id.isEmpty { fields["identifier"] = .string(id) }
        if let v = element.stringValue, !v.isEmpty { fields["value"] = .string(v) }
        if let l = element.label, !l.isEmpty { fields["description"] = .string(l) }
        if let rd = element.roleDescription, !rd.isEmpty { fields["roleDescription"] = .string(rd) }
        if let pos = element.position {
            fields["position"] = .object(["x": .double(pos.x), "y": .double(pos.y)])
        }
        if let sz = element.size {
            fields["size"] = .object(["width": .double(sz.width), "height": .double(sz.height)])
        }
        fields["enabled"] = .bool(element.isEnabled)
        if element.isFocused { fields["focused"] = .bool(true) }

        let actions = element.actionNames
        if !actions.isEmpty {
            fields["actions"] = .array(actions.map { .string($0) })
        }

        if depth < maxDepth {
            let kids = element.children
            if !kids.isEmpty {
                fields["children"] = .array(kids.map { nodeToJSON($0, depth: depth + 1, maxDepth: maxDepth) })
                fields["childCount"] = .int(kids.count)
            }
        } else {
            let count = element.children.count
            if count > 0 {
                fields["childCount"] = .int(count)
                fields["truncated"] = .bool(true)
            }
        }

        return .object(fields)
    }
}
