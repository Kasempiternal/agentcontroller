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
    /// Elements one `buildTree` call will read. An app-rooted dump of a browser page or a
    /// large table is tens of thousands of nodes, each a round-trip into the target app and
    /// all of it in one JSON result; the walk stopped only at `maxDepth`, which bounds
    /// depth, not breadth.
    public static let defaultNodeBudget = 6_000

    /// Breadth-first so that when the budget runs out it is the deepest, least useful
    /// levels that are cut — a depth-first walk spends the whole budget inside the first
    /// big subtree (a sidebar, say) and never reaches the content. Unexpanded nodes
    /// keep their real `childCount` and carry `truncated: true`, the same marker a
    /// `maxDepth` cut already uses.
    public static func buildTree(root: AXElement, maxDepth: Int = 5, detail: AXTreeDetail = .lean,
                                 nodeBudget: Int = defaultNodeBudget) -> JSONValue {
        assemble(root: root, maxDepth: maxDepth, nodeBudget: nodeBudget) { describe($0, detail: detail) }
    }

    private struct TreeNode {
        var fields: [String: JSONValue]
        var children: [Int] = []
    }

    /// The budgeted walk itself, generic over the node type so the budget and truncation
    /// rules are testable without a live app. `read` returns one node's JSON fields and
    /// its children.
    static func assemble<Element>(
        root: Element, maxDepth: Int, nodeBudget: Int,
        read: (Element) -> (fields: [String: JSONValue], kids: [Element])
    ) -> JSONValue {
        var nodes: [TreeNode] = []
        var queue: [(element: Element, depth: Int, parent: Int?)] = [(root, 0, nil)]
        var head = 0
        var enqueued = 1
        var budgetHit = false

        while head < queue.count {
            let (element, depth, parent) = queue[head]
            head += 1

            var (fields, kids) = read(element)
            let index = nodes.count
            if !kids.isEmpty {
                fields["childCount"] = .int(kids.count)
                if depth < maxDepth {
                    let take = min(max(0, nodeBudget - enqueued), kids.count)
                    for kid in kids.prefix(take) { queue.append((kid, depth + 1, index)) }
                    enqueued += take
                    if take < kids.count {
                        fields["truncated"] = .bool(true)
                        budgetHit = true
                    }
                } else {
                    fields["truncated"] = .bool(true)
                }
            }
            nodes.append(TreeNode(fields: fields))
            if let parent { nodes[parent].children.append(index) }
        }

        // Children always have a higher index than their parent, so one reverse pass
        // assembles the nested value without recursion (this runs on a GCD thread with a
        // small stack, and a pathological chain could be thousands deep).
        var built = [JSONValue](repeating: .null, count: nodes.count)
        for i in stride(from: nodes.count - 1, through: 0, by: -1) {
            var fields = nodes[i].fields
            if !nodes[i].children.isEmpty {
                fields["children"] = .array(nodes[i].children.map { built[$0] })
            }
            built[i] = .object(fields)
        }

        guard budgetHit, case .object(var rootFields) = built[0] else { return built[0] }
        rootFields["nodeBudgetReached"] = .int(nodeBudget)
        rootFields["hint"] = .string("Tree cut at \(nodeBudget) elements, deepest levels first (nodes marked truncated have more children than shown). Narrow it: lower maxDepth, or use find_elements / snapshot to target one control.")
        return .object(rootFields)
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

    /// One node's JSON fields plus its children, from a single batched read.
    private static func describe(_ element: AXElement, detail: AXTreeDetail) -> (fields: [String: JSONValue], kids: [AXElement]) {
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
        if let rawValue = attrs[kAXValueAttribute as String] {
            if let v = rawValue as? String {
                if !v.isEmpty { fields["value"] = .string(v) }
            } else if let classified = AXValueExtract.jsonValue(rawValue) {
                // Non-string value (toggle / radio / slider / stepper state arriving as
                // CFBoolean or CFNumber). Surface it instead of dropping it so the tree
                // can assert control state.
                fields["value"] = classified
            }
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

        return (fields, AXElement.elements(fromCFArray: attrs[kAXChildrenAttribute as String]))
    }
}
