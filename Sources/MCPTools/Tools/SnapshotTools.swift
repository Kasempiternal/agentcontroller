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
    /// Which element the BFS started from. `application` is the degraded case: the app
    /// exposed no window, so the walk can only reach the menu bar.
    enum WalkRoot: String, Sendable {
        case focusedWindow
        case firstWindow
        case application
    }

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
            description: "Snapshot a target into a COMPACT list of elements with stable ids (also available as 'describe_screen'). The server picks the backend from the identity: CDP a11y for a URL or attached Chrome page, bpy scene objects when a Blender socket handshakes, idb/WDA for an iOS simulator UDID, otherwise native AX. Returns [{id, role, label, enabled, frame}] plus backend. mode 'interactive' (default) keeps only controls; 'all' keeps every element. The ids feed interaction tools via elementId.")
        registry.register(def)

        // Alias: same handler under describe_screen so either name resolves.
        let alias = makeDefinition(name: "describe_screen",
            description: "Alias of 'snapshot': compact, stable-id description. Same auto-routing as snapshot (CDP / bpy / idb / AX) returning [{id, role, label, enabled, frame}]. mode 'interactive' (default) or 'all'.")
        registry.register(alias)
    }

    private static func makeDefinition(name: String, description: String) -> ToolRegistry.ToolDefinition {
        .init(
            name: name,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, PID, URL, or iOS simulator UDID")]),
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
                //
                // Which root we landed on is part of the answer, not an implementation
                // detail. When an app has no AX-reachable window the walk starts at the
                // application element, whose only child is the menu bar — so the tool
                // returned hundreds of AXMenuItem entries and called it a screen
                // snapshot. Observed on Preview: 362 elements, every one a menu item,
                // zero window content, no indication anything was missing.
                let walk: (root: WalkRoot, elements: [AXElement]) = await AXExecutor.app(pid).run {
                    let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let (root, kind): (AXElement, WalkRoot)
                    if let focused = app.focusedWindow {
                        (root, kind) = (focused, .focusedWindow)
                    } else if let first = app.windows.first {
                        (root, kind) = (first, .firstWindow)
                    } else {
                        (root, kind) = (app, .application)
                    }
                    return (kind, collect(root: root, interactiveOnly: interactiveOnly, maxDepth: maxDepth))
                }
                let collected = walk.elements

                // Register handles (assigns e1, e2, … in order), then read compact fields.
                let ids = await ElementHandleStore.shared.replace(with: collected, pid: pid)

                let items: [JSONValue] = await AXExecutor.app(pid).run {
                    zip(ids, collected).map { id, el in
                        compactDescriptor(id: id, element: el)
                    }
                }

                var payload: [String: JSONValue] = [
                    "mode": .string(interactiveOnly ? "interactive" : "all"),
                    "count": .int(items.count),
                    "root": .string(walk.root.rawValue),
                    "elements": .array(items),
                ]
                if walk.root == .application {
                    payload["warning"] = .string("No AX-reachable window for this app, so the walk started at the application element and these elements are its MENU BAR, not window content. macOS hides windows on an INACTIVE Space from accessibility, and an app that has never been frontmost exposes no focused window either. Check list_windows for the real window list; switch to that app's Space or use activate_app to snapshot its content.")
                }
                return ToolResult.json(.object(payload))
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
