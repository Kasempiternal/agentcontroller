import Foundation
import MCPServer
import ApplicationServices

public enum AXTreeDetail: String {
    case lean   // role, title, identifier, value, enabled, focused, children
    case full   // everything above + description, roleDescription, position, size, actionNames

    public static func from(_ raw: String?) -> AXTreeDetail {
        switch raw?.lowercased() {
        case "full": return .full
        default: return .lean
        }
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
            if let posValue = attrs[kAXPositionAttribute as String],
               CFGetTypeID(posValue) == AXValueGetTypeID() {
                let axValue = posValue as! AXValue
                var point = CGPoint.zero
                if AXValueGetType(axValue) == .cgPoint {
                    AXValueGetValue(axValue, .cgPoint, &point)
                    fields["position"] = .object(["x": .double(point.x), "y": .double(point.y)])
                }
            }
            if let szValue = attrs[kAXSizeAttribute as String],
               CFGetTypeID(szValue) == AXValueGetTypeID() {
                let axValue = szValue as! AXValue
                var size = CGSize.zero
                if AXValueGetType(axValue) == .cgSize {
                    AXValueGetValue(axValue, .cgSize, &size)
                    fields["size"] = .object(["width": .double(size.width), "height": .double(size.height)])
                }
            }
            let actions = element.actionNames
            if !actions.isEmpty {
                fields["actions"] = .array(actions.map { .string($0) })
            }
        }

        // Children: safely unwrap CFArray; bail gracefully on type mismatch.
        let kidArray: [AXElement]
        if let childrenCF = attrs[kAXChildrenAttribute as String],
           CFGetTypeID(childrenCF) == CFArrayGetTypeID() {
            let array = childrenCF as! CFArray
            let count = CFArrayGetCount(array)
            kidArray = (0..<count).compactMap { i in
                guard let ptr = CFArrayGetValueAtIndex(array, i) else { return nil }
                let ref = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
                return AXElement(ref)
            }
        } else {
            kidArray = []
        }

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
