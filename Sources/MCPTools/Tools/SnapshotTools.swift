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
        "AXIncrementor", "AXSegmentedControl", "AXColorWell", "AXSwitch",
    ]

    /// Actions that say nothing about interactivity. WebKit hangs AXShowMenu and
    /// AXScrollToVisible on EVERY node (static text, groups, cells), so "has any action"
    /// kept ~2,300 of a GitHub page's nodes in 'interactive' mode — a 262 KB result that
    /// overflows the agent's tool-result limit. Only actions that do something count.
    private static let incidentalActions: Set<String> = [
        "AXShowMenu", "AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI", "AXRaise",
    ]

    private static let maxNodes = 6_000

    static func register(in registry: ToolRegistry) {
        let def = makeDefinition(name: "snapshot",
            description: "Snapshot a target into a COMPACT list of elements with stable ids (also available as 'describe_screen'). The server picks the backend from the identity: a web page opens in the browser the user named (else their default browser) and is read via AX — or CDP for headless:true / a Chrome debug port; bpy scene objects when a Blender socket handshakes, idb/WDA for an iOS simulator UDID, otherwise native AX. Returns [{id, role, label, enabled, frame}] plus backend. mode 'interactive' (default) keeps only controls; 'all' keeps every element. The ids feed interaction tools via elementId.")
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
                    "app": .object(["type": .string("string"), "description": .string("Bundle ID, app name, PID, URL, or iOS simulator UDID. For a web page in a specific browser pass the browser here (e.g. 'Safari') plus `url`.")]),
                    "url": .object(["type": .string("string"), "description": .string("Web page to open first. Goes to the browser in `app`/`browser`, else the user's default browser; loaded in the background before the snapshot.")]),
                    "browser": .object(["type": .string("string"), "description": .string("'safari', 'chrome', 'firefox', … or 'default'. Same as naming the browser in `app`.")]),
                    "headless": .object(["type": .string("boolean"), "description": .string("With url: use a private headless Chromium (CDP) instead of a visible browser. Scripted testing only.")]),
                    "mode": .object(["type": .string("string"), "description": .string("'interactive' (default, controls only) or 'all' (every element)")]),
                    "maxDepth": .object(["type": .string("integer"), "description": .string("Maximum tree depth to walk (default 12; 40 for web browsers, whose page content sits deep)")]),
                    "maxElements": .object(["type": .string("integer"), "description": .string("Cap on returned elements (default 500); the result says when it truncated.")]),
                ]),
                "required": .array([.string("app")]),
            ]),
            handler: { args in
                let pid = try args!.resolvePID()
                let mode = args?["mode"]?.stringValue?.lowercased() ?? "interactive"
                let interactiveOnly = mode != "all"
                // Web content in a browser sits ~15-30 levels down (window → tab group →
                // scroll area → web area → DOM groups). At 12 a Safari snapshot returned
                // only toolbar and tab buttons; the page's own links never appeared. The
                // node budget and maxElements still bound the walk.
                let isBrowser = args?["app"]?.stringValue.map(BrowserResolver.isBrowserName) ?? false
                let maxDepth = args?["maxDepth"]?.intValue ?? (isBrowser ? 40 : 12)

                // Cap BEFORE describing: past a few hundred elements the result outgrows what
                // an agent can take in, so descriptors are built only for the first
                // `maxElements`; the rest are still walked, only to report `matched`.
                let maxElements = max(1, args?["maxElements"]?.intValue ?? 500)

                // Collect the live elements (BFS) off the MainActor.
                //
                // Which root we landed on is part of the answer, not an implementation
                // detail. When an app has no AX-reachable window the walk starts at the
                // application element, whose only child is the menu bar — so the tool
                // returned hundreds of AXMenuItem entries and called it a screen
                // snapshot. Observed on Preview: 362 elements, every one a menu item,
                // zero window content, no indication anything was missing.
                let walk: (root: WalkRoot, kept: [Kept], matched: Int) = await AXExecutor.app(pid).run {
                    let app = AXElement.application(pid: pid, timeout: AXElement.defaultToolTimeout)
                    let (root, kind): (AXElement, WalkRoot)
                    if let focused = app.focusedWindow {
                        (root, kind) = (focused, .focusedWindow)
                    } else if let first = app.windows.first {
                        (root, kind) = (first, .firstWindow)
                    } else {
                        (root, kind) = (app, .application)
                    }
                    let (kept, matched) = collect(root: root, interactiveOnly: interactiveOnly,
                                                  maxDepth: maxDepth, maxElements: maxElements)
                    return (kind, kept, matched)
                }
                let truncated = walk.matched > maxElements

                // Register handles (assigns e1, e2, … in order). The fingerprints come from
                // the walk's own reads, so identity checking costs no extra IPC.
                let ids = await ElementHandleStore.shared.replace(
                    with: walk.kept.map(\.element),
                    fingerprints: walk.kept.map(\.fingerprint),
                    pid: pid
                )
                let items: [JSONValue] = zip(ids, walk.kept).map { id, kept in
                    var fields = kept.fields
                    fields["id"] = .string(id)
                    return .object(fields)
                }

                var payload: [String: JSONValue] = [
                    "mode": .string(interactiveOnly ? "interactive" : "all"),
                    "count": .int(items.count),
                    "root": .string(walk.root.rawValue),
                    "elements": .array(items),
                ]
                if truncated {
                    payload["truncated"] = .bool(true)
                    payload["matched"] = .int(walk.matched)
                    payload["hint"] = .string("Showing the first \(maxElements) of \(walk.matched) elements in tree order. Use find_elements with labelContains/role to target something specific, or raise maxElements.")
                }
                if walk.root == .application {
                    payload["warning"] = .string("No AX-reachable window for this app, so the walk started at the application element and these elements are its MENU BAR, not window content. macOS hides windows on an INACTIVE Space from accessibility, and an app that has never been frontmost exposes no focused window either. Check list_windows for the real window list; switch to that app's Space or use activate_app to snapshot its content.")
                }
                return ToolResult.json(.object(payload))
            }
        )
    }

    /// One element that made the cut, with everything the result needs, read during the walk.
    private struct Kept: Sendable {
        let element: AXElement
        let fingerprint: AXElementFingerprint
        /// The compact descriptor minus its `id`, which exists only after registration.
        let fields: [String: JSONValue]
    }

    /// What the walk needs from every node: its role (to qualify it) and its children.
    private static let traversalAttributes: [String] = [
        kAXRoleAttribute as String,
        kAXChildrenAttribute as String,
    ]

    /// What a descriptor and its handle fingerprint need, read only for nodes that make
    /// the cut. The walk used to read children + role + actionNames per node and then ~9
    /// single attributes per emitted element; a snapshot of a few hundred controls was
    /// thousands of IPC calls, each one a context switch into the target app. Splitting
    /// the batch (rather than one maximal read per node) is deliberate: on a Safari page
    /// of 1,743 nodes, traversal + detail took ~0.45s against ~0.7s for one maximal read
    /// per node, because nodes that fail to qualify or fall past `maxElements` dragged
    /// position/size/value across IPC for nothing.
    private static let detailAttributes: [String] = [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
        kAXIdentifierAttribute as String,
        kAXEnabledAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
    ]

    /// BFS the window once, keeping nodes that qualify. Bounded by `maxNodes` and a visited
    /// set (CFHash identity) so a cyclic/huge AX tree can't run away. Returns the first
    /// `maxElements` qualifying nodes, plus how many qualified in total.
    private static func collect(root: AXElement, interactiveOnly: Bool, maxDepth: Int,
                                maxElements: Int) -> (kept: [Kept], matched: Int) {
        var kept: [Kept] = []
        var matched = 0
        var queue: [(AXElement, Int)] = [(root, 0)]
        var head = 0
        var visited = Set<Int>()
        var nodes = 0

        while head < queue.count && nodes < maxNodes {
            let (el, depth) = queue[head]
            head += 1
            if !visited.insert(Int(bitPattern: CFHash(el.ref))).inserted { continue }
            nodes += 1

            // 'all' mode keeps every node until the cap, so there the detail rides along in
            // the same read; otherwise it is fetched only once the node qualifies.
            let describeNow = !interactiveOnly && kept.count < maxElements
            var attrs = el.readAttributes(describeNow ? traversalAttributes + detailAttributes : traversalAttributes)

            if depth > 0 || !interactiveOnly {
                // An element that answered nothing is unreadable, not "has no actions":
                // asking it for actionNames would only repeat the failure.
                if !interactiveOnly || (!attrs.isEmpty && qualifies(
                    role: attrs[kAXRoleAttribute as String] as? String,
                    actions: el.actionNames
                )) {
                    matched += 1
                    if kept.count < maxElements {
                        if !describeNow {
                            attrs.merge(el.readAttributes(detailAttributes)) { current, _ in current }
                        }
                        kept.append(Kept(
                            element: el,
                            fingerprint: AXElementFingerprint(attributes: attrs),
                            fields: descriptorFields(from: attrs)
                        ))
                    }
                }
            }

            if depth < maxDepth {
                for child in AXElement.elements(fromCFArray: attrs[kAXChildrenAttribute as String]) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return (kept, matched)
    }

    /// Interactive == a known controly role OR at least one AX action that does something.
    /// `actions` is an autoclosure: only roles outside `interactiveRoles` pay the IPC call
    /// to list their actions.
    static func qualifies(role: String?, actions: @autoclosure () -> [String]) -> Bool {
        if let role, interactiveRoles.contains(role) { return true }
        return actions().contains { !incidentalActions.contains($0) }
    }

    /// Token-lean descriptor fields (no `id`, no nested children) from a node's batched
    /// attributes.
    static func descriptorFields(from attrs: [String: CFTypeRef]) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "role": .string((attrs[kAXRoleAttribute as String] as? String) ?? "unknown"),
            "enabled": .bool((attrs[kAXEnabledAttribute as String] as? Bool) ?? true),
        ]
        if let label = label(from: attrs) { fields["label"] = .string(label) }
        if let origin = AXValueExtract.point(attrs[kAXPositionAttribute as String]),
           let size = AXValueExtract.size(attrs[kAXSizeAttribute as String]) {
            fields["frame"] = .object([
                "x": .double(origin.x), "y": .double(origin.y),
                "w": .double(size.width), "h": .double(size.height),
            ])
        }
        return fields
    }

    /// label falls back through title → description(label) → value → identifier.
    static func label(from attrs: [String: CFTypeRef]) -> String? {
        if let title = attrs[kAXTitleAttribute as String] as? String, !title.isEmpty { return title }
        if let text = attrs[kAXDescriptionAttribute as String] as? String, !text.isEmpty { return text }
        if let value = AssertTools.stringFor(AXValueExtract.jsonValue(attrs[kAXValueAttribute as String])),
           !value.isEmpty { return value }
        if let id = attrs[kAXIdentifierAttribute as String] as? String, !id.isEmpty { return id }
        return nil
    }
}
