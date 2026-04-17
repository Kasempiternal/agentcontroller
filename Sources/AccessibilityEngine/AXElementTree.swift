import Foundation
import MCPServer
import ApplicationServices

public enum AXTreeDetail: String {
    case lean
    case full

    public init(raw: String?) {
        self = AXTreeDetail(rawValue: raw?.lowercased() ?? "") ?? .lean
    }
}

public struct AXElementTree {
    public static func buildTree(root: AXElement, maxDepth: Int = 5, detail: AXTreeDetail = .lean) -> JSONValue {
        nodeToJSON(root, depth: 0, maxDepth: maxDepth, detail: detail)
    }

    private static let leanAttrs: [String] = [
        kAXRoleAttribute as String,
        kAXTitleAttribute as String,
        kAXIdentifierAttribute as String,
        kAXValueAttribute as String,
        kAXEnabledAttribute as String,
        kAXFocusedAttribute as String,
        kAXChildrenAttribute as String,
    ]

    private static let fullAttrs: [String] = leanAttrs + [
        kAXDescriptionAttribute as String,
        kAXRoleDescriptionAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
    ]

    private static func nodeToJSON(_ element: AXElement, depth: Int, maxDepth: Int, detail: AXTreeDetail) -> JSONValue {
        let names = detail == .full ? fullAttrs : leanAttrs
        let attrs = element.readAttributes(names)

        var fields: [String: JSONValue] = [:]
        fields["role"] = .string((attrs[kAXRoleAttribute as String] as? String) ?? "unknown")

        if let t = attrs[kAXTitleAttribute as String] as? String, !t.isEmpty {
            fields["title"] = .string(t)
        }
        if let id = attrs[kAXIdentifierAttribute as String] as? String, !id.isEmpty {
            fields["identifier"] = .string(id)
        }
        if let v = attrs[kAXValueAttribute as String] as? String, !v.isEmpty {
            fields["value"] = .string(v)
        }
        fields["enabled"] = .bool((attrs[kAXEnabledAttribute as String] as? Bool) ?? true)
        if (attrs[kAXFocusedAttribute as String] as? Bool) == true {
            fields["focused"] = .bool(true)
        }

        if detail == .full {
            if let l = attrs[kAXDescriptionAttribute as String] as? String, !l.isEmpty {
                fields["description"] = .string(l)
            }
            if let rd = attrs[kAXRoleDescriptionAttribute as String] as? String, !rd.isEmpty {
                fields["roleDescription"] = .string(rd)
            }
            if let pos = AXValueExtract.point(attrs[kAXPositionAttribute as String]) {
                fields["position"] = .object(["x": .double(pos.x), "y": .double(pos.y)])
            }
            if let sz = AXValueExtract.size(attrs[kAXSizeAttribute as String]) {
                fields["size"] = .object(["width": .double(sz.width), "height": .double(sz.height)])
            }
            let actions = element.actionNames
            if !actions.isEmpty {
                fields["actions"] = .array(actions.map { .string($0) })
            }
        }

        let kidArray = AXElement.elements(fromCFArray: attrs[kAXChildrenAttribute as String])

        if !kidArray.isEmpty {
            if depth < maxDepth {
                fields["children"] = .array(kidArray.map { nodeToJSON($0, depth: depth + 1, maxDepth: maxDepth, detail: detail) })
                fields["childCount"] = .int(kidArray.count)
            } else {
                fields["childCount"] = .int(kidArray.count)
                fields["truncated"] = .bool(true)
            }
        }

        return .object(fields)
    }
}
