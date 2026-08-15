import Foundation
import ApplicationServices
import MCPServer
import AccessibilityEngine

/// Stable-handle screen snapshot. Walks the focused window once, collects the elements that
/// matter (interactive controls by default, or everything), caches the live AXElement refs
/// in `ElementHandleStore`, and returns a COMPACT flat list `[{id, role, label, enabled,
/// frame}]`. The agent uses this instead of the verbose `get_element_tree`, and the returned
/// `id`s (e1, e2, …) feed the interaction tools' `elementId` param for O(1), BFS-free reuse.
struct SnapshotTools {
    /// Roles that are inherently interactive even if they happen to expose no AX actions.
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXLink", "AXSlider",
        "AXStepper", "AXTab", "AXTabGroup", "AXComboBox", "AXDisclosureTriangle",
        "AXIncrementor", "AXSegmentedControl", "AXToolbar", "AXColorWell", "AXSwitch",
    ]

    private static let maxNodes = 6_000

    static func register(in registry: ToolRegistry) {
        let def = makeDefinition(name: "snapshot",
            description: "Snapshot the focused window into a COMPACT list of elements with stable ids (also available as 'describe_screen'). Returns [{id, role, label, enabled, frame}] — far cheaper than get_element_tree. mode 'interactive' (default) keeps only controls; 'all' keeps every element. The ids feed interaction tools via elementId.")
        registry.register(def)

        // Alias: same handler under describe_screen so either name resolves.
        let alias = makeDefinition(name: "describe_screen",
            description: "Alias of 'snapshot': compact, stable-id description of the focused window's elements [{id, role, label, enabled, frame}]. mode 'interactive' (default) or 'all'.")
        registry.register(alias)
    }

    private static func makeDefinition(name: String, description: String) -> ToolRegistry.ToolDefinition {
        .init(
            name: name,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, or PID")]),
                    "mode": .object(["type": .string("string"), "description": .string("'interactive' (default, controls only) or 'all' (every element)")]),
                    "maxDepth": .object(["type": .string("integer"), "description": .string("Maximum tree depth to walk (default 12)")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let mode = args?["mode"]?.stringValue?.lowercased() ?? "interactive"
                let interactiveOnly = mode != "all"
                let maxDepth = args?["maxDepth"]?.intValue ?? 12

                // Collect the live elements (BFS) off the MainActor.
                let collected: [AXElement] = await AXExecutor.app(pid).run {
                    let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let root = app.focusedWindow ?? app.windows.first ?? app
                    return collect(root: root, interactiveOnly: interactiveOnly, maxDepth: maxDepth)
                }

                // Register handles (assigns e1, e2, … in order), then read compact fields.
                let ids = await ElementHandleStore.shared.replace(with: collected, pid: pid)

                let items: [JSONValue] = await AXExecutor.app(pid).run {
                    zip(ids, collected).map { id, el in
                        compactDescriptor(id: id, element: el)
                    }
                }

                return ToolResult.json(.object([
                    "mode": .string(interactiveOnly ? "interactive" : "all"),
                    "count": .int(items.count),
                    "elements": .array(items),
                ]))
            }
        )
    }

    /// BFS the window once, keeping nodes that qualify. Bounded by `maxNodes` and a visited
    /// set (CFHash identity) so a cyclic/huge AX tree can't run away.
    private static func collect(root: AXElement, interactiveOnly: Bool, maxDepth: Int) -> [AXElement] {
        var out: [AXElement] = []
        var queue: [(AXElement, Int)] = [(root, 0)]
        var head = 0
        var visited = Set<Int>()
        var nodes = 0

        while head < queue.count && nodes < maxNodes {
            let (el, depth) = queue[head]
            head += 1
            if !visited.insert(Int(bitPattern: CFHash(el.ref))).inserted { continue }
            nodes += 1

            if depth > 0 || !interactiveOnly {
                if !interactiveOnly || qualifies(el) {
                    out.append(el)
                }
            }

            if depth < maxDepth {
                for child in el.children {
                    queue.append((child, depth + 1))
                }
            }
        }
        return out
    }

    /// Interactive == has at least one AX action OR a known controly role.
    private static func qualifies(_ el: AXElement) -> Bool {
        if !el.actionNames.isEmpty { return true }
        if let role = el.role, interactiveRoles.contains(role) { return true }
        return false
    }

    /// Token-lean descriptor — no nested children. label falls back through
    /// title → description(label) → value → identifier.
    private static func compactDescriptor(id: String, element el: AXElement) -> JSONValue {
        let label = firstNonEmpty(
            el.title,
            el.label,
            AssertTools.stringFor(el.valueJSON) ?? el.stringValue,
            el.identifier
        )
        var fields: [String: JSONValue] = [
            "id": .string(id),
            "role": .string(el.role ?? "unknown"),
            "enabled": .bool(el.isEnabled),
        ]
        if let label, !label.isEmpty { fields["label"] = .string(label) }
        if let f = el.frame {
            fields["frame"] = .object([
                "x": .double(f.origin.x), "y": .double(f.origin.y),
                "w": .double(f.size.width), "h": .double(f.size.height),
            ])
        }
        return .object(fields)
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for c in candidates {
            if let c, !c.isEmpty { return c }
        }
        return nil
    }
}
