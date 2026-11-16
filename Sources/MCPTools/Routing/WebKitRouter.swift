import AppKit
import Foundation
import ImageIO
import MCPServer
import ScreenCapture
import AccessibilityEngine

/// `browser:"webkit"` (or `app:"webkit"`): the page is WebKit rendered off screen inside this app.
/// One name, every tool: `ToolRegistry.callTool` hands such a call here before anything resolves a
/// browser or an app, so a tool this backend lacks answers with the supported list instead of
/// falling through to a process that happens to be called "WebKit".
struct WebKitTarget: Equatable, Sendable {
    var profile = "default"
    var page = "main"
    var url: URL?
    var options = WebKitBackend.Options()
    /// An argument the call got wrong, reported before any page is touched.
    var problem: String?

    var key: String { WebKitBackend.key(profile: profile, name: page) }

    static let name = "webkit"

    /// The options a call may carry when it names WebKit, for every tool that accepts them.
    static var optionSchema: [String: JSONValue] {
        [
            "profile": .object(["type": .string("string"), "description": .string("WebKit only: the cookie and storage profile (default 'default'). A login made on a local page survives between calls and restarts.")]),
            "page": .object(["type": .string("string"), "description": .string("WebKit only: which page of the profile (default 'main'); each has its own viewport.")]),
            "width": .object(["type": .string("number"), "description": .string("WebKit only: viewport width in CSS pixels (1-8000). Kept until changed.")]),
            "height": .object(["type": .string("number"), "description": .string("WebKit only: viewport height in CSS pixels (1-8000). Kept until changed.")]),
            "colorScheme": .object(["type": .string("string"), "enum": .array([.string("light"), .string("dark"), .string("system")]), "description": .string("WebKit only: prefers-color-scheme (default light). Kept until changed.")]),
            "deviceScaleFactor": .object(["type": .string("number"), "description": .string("WebKit only: device pixel ratio, 0.5-5 (default 2). Kept until changed.")]),
        ]
    }

    static func merged(into base: [String: JSONValue], include: [String]? = nil) -> [String: JSONValue] {
        var out = base
        for (key, value) in optionSchema where include?.contains(key) ?? true && out[key] == nil { out[key] = value }
        return out
    }

    /// nil when the call does not name WebKit.
    static func parse(_ arguments: JSONValue) -> WebKitTarget? {
        var target = WebKitTarget()
        var named = false
        for key in ["browser", "app", "target"] {
            guard let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { continue }
            if value == name {
                named = true
            } else if value.hasPrefix(name + ":") {
                named = true
                target.url = TargetIdentity.parseURL(String(value.dropFirst(name.count + 1)))
            }
        }
        guard named else { return nil }
        if target.url == nil, let raw = arguments["url"]?.stringValue {
            target.url = TargetIdentity.parseURL(raw)
            if target.url == nil, !raw.isEmpty { target.problem = "url must be http(s), file, about or data: \(raw)" }
        }
        if let profile = arguments["profile"]?.stringValue, !profile.isEmpty { target.profile = sanitized(profile) }
        if let page = arguments["page"]?.stringValue, !page.isEmpty { target.page = sanitized(page) }
        target.options.width = dimension(arguments["width"], "width", &target.problem)
        target.options.height = dimension(arguments["height"], "height", &target.problem)
        if let scheme = arguments["colorScheme"]?.stringValue {
            if let parsed = WebKitBackend.ColorScheme(rawValue: scheme.lowercased()) {
                target.options.colorScheme = parsed
            } else {
                target.problem = "colorScheme must be light, dark or system, got \(scheme)"
            }
        }
        if let factor = (arguments["deviceScaleFactor"] ?? arguments["dpr"])?.doubleValue {
            if factor >= 0.5, factor <= 5 {
                target.options.scale = CGFloat(factor)
            } else {
                target.problem = "deviceScaleFactor must be between 0.5 and 5, got \(factor)"
            }
        }
        return target
    }

    private static func dimension(_ value: JSONValue?, _ name: String, _ problem: inout String?) -> CGFloat? {
        guard let value, let number = value.doubleValue else { return nil }
        guard number >= 1, number <= Double(WebKitBackend.maxViewportSide) else {
            problem = "\(name) must be between 1 and \(Int(WebKitBackend.maxViewportSide)) CSS pixels, got \(number)"
            return nil
        }
        return CGFloat(number)
    }

    /// Names become part of a key and a store identifier, never a path.
    private static func sanitized(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.prefix(48))
        return cleaned.isEmpty ? "default" : cleaned
    }
}

enum WebKitRouter {
    /// What the backend implements. `CapabilityRecord.Backend.webkit.supportedTools` is this set.
    static let supportedTools: Set<String> = [
        "open_url", "snapshot", "describe_screen", "read_text", "read_all_text",
        "click", "double_click", "type_text", "send_shortcut", "scroll",
        "find_elements", "assert_visible", "assert_not_visible", "wait_for_element",
        "screenshot_window", "screenshot_element", "set_window_bounds", "get_window_bounds", "run_app_code",
    ]

    /// Tools where a `url` on the call means "show me that page": navigate first, then act.
    private static let navigatingTools: Set<String> = [
        "snapshot", "describe_screen", "read_all_text", "screenshot_window",
        "find_elements", "assert_visible", "assert_not_visible", "wait_for_element",
    ]

    /// Entry for a call that names WebKit (`app`, `browser`, `target`).
    static func handle(name: String, arguments: JSONValue, target: WebKitTarget) async -> JSONValue {
        if let problem = target.problem { return ToolResult.error(problem) }
        guard supportedTools.contains(name) else {
            return ToolResult.error(CapabilityRecord.unsupportedMessage(tool: name, backend: .webkit))
        }
        do {
            return try await run(name: name, arguments: arguments, target: target)
        } catch {
            return ToolResult.error(error.localizedDescription)
        }
    }

    /// Entry for a call that carries only an element id.
    static func handle(name: String, arguments: JSONValue, ref: RoutedRef) async -> JSONValue {
        guard case .webkit(let key, _, _, _, _) = ref else { return ToolResult.error("Not a WebKit element") }
        guard supportedTools.contains(name) else {
            return ToolResult.error(CapabilityRecord.unsupportedMessage(tool: name, backend: .webkit))
        }
        var target = WebKitTarget()
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 { target.profile = parts[0]; target.page = parts[1] }
        do {
            return try await run(name: name, arguments: arguments, target: target)
        } catch {
            return ToolResult.error(error.localizedDescription)
        }
    }

    @MainActor
    private static func run(name: String, arguments: JSONValue, target: WebKitTarget) async throws -> JSONValue {
        let backend = WebKitBackend.shared
        if let handle = arguments["elementId"]?.stringValue {
            guard let ref = await RoutedHandleStore.shared.resolve(handle), case .webkit = ref else {
                throw WebKitBackend.Failure(message: "Unknown or retired element id \(handle): call snapshot again for fresh ids.")
            }
            return try await perform(name: name, arguments: arguments, target: target, ref: ref)
        }
        let navigates = name == "open_url" || navigatingTools.contains(name)
        let page: WebKitPage
        if let existing = backend.page(key: target.key) {
            page = existing
            existing.touch()
            if existing.apply(target.options) { await existing.settle() }
        } else if target.url != nil || name == "open_url" {
            page = backend.page(profile: target.profile, name: target.page, options: target.options)
        } else {
            throw WebKitBackend.Failure.noPage(target.key)
        }
        var note: String?
        if navigates, let url = target.url {
            let reload = arguments["reload"]?.boolValue == true
            if reload || !page.isShowing(url) {
                let outcome = reload ? await page.reload() : await page.load(url)
                if let error = outcome.error { throw WebKitBackend.Failure(message: "Could not load \(url.absoluteString): \(error)") }
                if outcome.timedOut {
                    note = "The load event did not fire within \(Int(WebKitBackend.loadTimeout))s; this is whatever had rendered. Re-snapshot (or wait_for_element) if content looks incomplete."
                }
                let settleMs = min(max(arguments["settleMs"]?.doubleValue ?? 300, 0), 10_000)
                await page.settle(settleMs / 1000)
            } else if name == "open_url" {
                note = "\(url.absoluteString) is already showing; nothing was reloaded (pass reload:true to reload)."
            }
        } else if name == "open_url" {
            throw ToolError.missingParameter("url")
        }
        return try await perform(name: name, arguments: arguments, target: target, page: page, note: note)
    }

    // MARK: - Page-level tools

    @MainActor
    private static func perform(name: String, arguments: JSONValue, target: WebKitTarget, page: WebKitPage, note: String?) async throws -> JSONValue {
        switch name {
        case "open_url":
            return ToolResult.json(.object(await pageInfo(page, note: note)))
        case "snapshot", "describe_screen":
            let interactive = (arguments["mode"]?.stringValue?.lowercased() ?? "interactive") != "all"
            let limit = max(arguments["maxElements"]?.intValue ?? 500, 1)
            let result = try await collect(page, interactiveOnly: interactive, limit: limit, identifier: nil)
            let ids = await RoutedHandleStore.shared.replace(refs: result.refs, scope: .webkit(page.key))
            var fields = await pageInfo(page, note: note)
            fields["mode"] = .string(interactive ? "interactive" : "all")
            fields["count"] = .int(result.elements.count)
            fields["elements"] = .array(zip(ids, result.elements).map { id, element in element.withId(id) })
            if result.total > result.elements.count {
                fields["truncated"] = .bool(true)
                fields["matched"] = .int(result.total)
            }
            return ToolResult.json(.object(fields))
        case "read_all_text":
            let result = try await page.script(WebKitScripts.bodyText, inPageWorld: true)
            return ToolResult.json(.object(["text": .string(result["text"]?.stringValue ?? ""), "backend": .string("webkit")]))
        case "screenshot_window":
            return try await screenshot(page, arguments: arguments, rect: nil, note: note)
        case "set_window_bounds", "get_window_bounds":
            if name == "set_window_bounds", target.options.width == nil, target.options.height == nil, target.options.colorScheme == nil, target.options.scale == nil {
                throw ToolError.missingParameter("width and/or height (CSS pixels of the WebKit viewport)")
            }
            return ToolResult.json(.object(await pageInfo(page, note: note)))
        case "find_elements", "assert_visible", "assert_not_visible", "wait_for_element":
            return try await query(name: name, arguments: arguments, page: page)
        case "scroll":
            guard let deltaY = arguments["deltaY"]?.doubleValue else { throw ToolError.missingParameter("deltaY") }
            let deltaX = arguments["deltaX"]?.doubleValue ?? 0
            let position = try await page.script(WebKitScripts.scrollBy, arguments: ["dx": -deltaX, "dy": -deltaY])
            return ToolResult.json(.object(["backend": .string("webkit"), "scrollX": position["x"] ?? .null, "scrollY": position["y"] ?? .null]))
        case "send_shortcut":
            guard let keyName = arguments["key"]?.stringValue else { throw ToolError.missingParameter("key") }
            guard let key = WebKitKey.named(keyName) else { throw ToolError.invalidParameter("Unknown key: \(keyName)") }
            var flags: NSEvent.ModifierFlags = []
            for modifier in arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                switch modifier.lowercased() {
                case "cmd", "command": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "opt", "alt", "option": flags.insert(.option)
                case "ctrl", "control": flags.insert(.control)
                default: throw ToolError.invalidParameter("Unknown modifier: \(modifier)")
                }
            }
            page.key(key, modifiers: flags)
            await page.settle(0.1)
            return ToolResult.action(success: true, method: "webkit-key")
        case "run_app_code":
            guard let code = arguments["code"]?.stringValue else { throw ToolError.missingParameter("code") }
            try requireConsent(arguments: arguments)
            let value = try await page.script(WebKitScripts.evaluate, arguments: ["code": code], inPageWorld: true, timeout: 60)
            return ToolResult.json(.object(["backend": .string("webkit"), "result": value]))
        default:
            throw Refusal(message: CapabilityRecord.unsupportedMessage(tool: name, backend: .webkit))
        }
    }

    // MARK: - Element tools

    @MainActor
    private static func perform(name: String, arguments: JSONValue, target: WebKitTarget, ref: RoutedRef) async throws -> JSONValue {
        guard case .webkit(let key, let document, let index, _, let label) = ref else { throw WebKitBackend.Failure.stale }
        guard let page = WebKitBackend.shared.page(key: key) else { throw WebKitBackend.Failure.noPage(key) }
        page.touch()
        let (epoch, generation) = try split(document)
        guard epoch == page.epoch else { throw WebKitBackend.Failure.stale }
        let args: [String: Any] = ["gen": generation, "index": index]

        switch name {
        case "click", "double_click":
            let point = try await page.script(WebKitScripts.clickPoint, arguments: args)
            try fail(point)
            if let reason = point["notClickable"]?.stringValue { throw Refusal(message: "'\(label)' is not clickable: \(reason).") }
            if point["native"]?.boolValue == true {
                throw Refusal(message: "'\(label)' is a native control (select, file or date picker): its menu cannot be shown off screen. For a select, type_text with the option's text sets it.")
            }
            var method = name == "double_click" ? "webkit-double-click" : "webkit-click"
            var extra: [String: JSONValue] = [:]
            if point["ok"]?.boolValue == true, let x = point["x"]?.doubleValue, let y = point["y"]?.doubleValue {
                page.click(at: CGPoint(x: x, y: y), count: name == "double_click" ? 2 : 1)
            } else {
                // Something else sits on top of it. A DOM click still reaches the element, and the
                // agent is told it was not a pointer click.
                let clicked = try await page.script(WebKitScripts.domClick, arguments: args)
                try fail(clicked)
                method = "webkit-dom-click"
                extra["note"] = .string("'\(label)' is covered by <\(point["covered"]?.stringValue ?? "another element")> at its centre, so a pointer click could not land; the element's own click handler was run instead.")
            }
            await page.settle(0.15)
            return withDialogs(ToolResult.action(success: true, method: method, extra: extra), page)
        case "type_text":
            guard let text = arguments["text"]?.stringValue else { throw ToolError.missingParameter("text") }
            let prepared = try await page.script(WebKitScripts.prepareTyping, arguments: args.merging(["text": text]) { $1 })
            try fail(prepared)
            if let error = prepared["error"]?.stringValue { throw Refusal(message: "'\(label)': \(error).") }
            if prepared["handled"]?.boolValue == true {
                return ToolResult.action(success: true, method: "webkit-select", extra: ["selected": prepared["selected"] ?? .null])
            }
            page.type(text)
            await page.settle(0.1)
            return withDialogs(ToolResult.action(success: true, method: "webkit-type"), page)
        case "read_text", "read_all_text":
            let result = try await page.script(WebKitScripts.readElement, arguments: args)
            try fail(result)
            return ToolResult.json(.object(["text": .string(result["text"]?.stringValue ?? label), "backend": .string("webkit")]))
        case "screenshot_element":
            let rect = try await page.script(WebKitScripts.elementRect, arguments: args)
            try fail(rect)
            guard let x = rect["x"]?.doubleValue, let y = rect["y"]?.doubleValue,
                  let w = rect["w"]?.doubleValue, let h = rect["h"]?.doubleValue else { throw WebKitBackend.Failure.stale }
            let viewport = page.viewport
            let clipped = CGRect(x: x, y: y, width: w, height: h).intersection(CGRect(origin: .zero, size: viewport))
            guard clipped.width >= 1, clipped.height >= 1 else {
                throw Refusal(message: "The element lies outside the viewport or has no area, so there is nothing to crop. Scroll it into view first.")
            }
            return try await screenshot(page, arguments: arguments, rect: clipped, note: nil)
        default:
            throw Refusal(message: CapabilityRecord.unsupportedMessage(tool: name, backend: .webkit) + " Pass app:\"webkit\" with a selector for the page-level tools.")
        }
    }

    // MARK: - Snapshots

    struct Collected {
        var refs: [RoutedRef]
        var elements: [JSONValue]
        var total: Int
        var raw: [JSONValue]
    }

    @MainActor
    private static func collect(_ page: WebKitPage, interactiveOnly: Bool, limit: Int, identifier: String?) async throws -> Collected {
        try page.requireUsable()
        let result = try await page.script(WebKitScripts.snapshot, arguments: [
            "interactiveOnly": interactiveOnly, "max": limit,
            "identifier": identifier.map { CDPSelector.cssSelector(forIdentifier: $0) } ?? NSNull(),
        ])
        guard let generation = result["gen"]?.intValue, let items = result["elements"]?.arrayValue else {
            throw WebKitBackend.Failure(message: "The page returned no element list.")
        }
        let document = "\(page.epoch).\(generation)"
        var refs: [RoutedRef] = []
        var elements: [JSONValue] = []
        for item in items {
            guard let index = item["i"]?.intValue else { continue }
            let role = item["role"]?.stringValue ?? "generic"
            let label = item["label"]?.stringValue ?? ""
            refs.append(.webkit(page: page.key, document: document, index: index, role: role, label: label))
            var fields: [String: JSONValue] = [
                "role": .string(role),
                "enabled": .bool(item["enabled"]?.boolValue ?? true),
                "frame": .object([
                    "x": item["x"] ?? .double(0), "y": item["y"] ?? .double(0),
                    "w": item["w"] ?? .double(0), "h": item["h"] ?? .double(0),
                ]),
            ]
            if !label.isEmpty { fields["label"] = .string(label) }
            if let value = item["value"], value != .string("") { fields["value"] = value }
            if let checked = item["checked"] { fields["checked"] = checked }
            elements.append(.object(fields))
        }
        return Collected(refs: refs, elements: elements, total: result["total"]?.intValue ?? elements.count, raw: items)
    }

    // MARK: - Selector tools

    @MainActor
    private static func query(name: String, arguments: JSONValue, page: WebKitPage) async throws -> JSONValue {
        let selector = try CDPSelector.parse(arguments)
        if selector.isEmpty && name != "find_elements" {
            throw ToolError.invalidParameter("\(name) needs a selector: role, identifier, title, titleContains, description, descriptionContains or labelContains")
        }
        let defaultTimeout: Double = name == "wait_for_element" ? 10 : name == "find_elements" ? 0 : 7
        let timeout = min(max(arguments["timeout"]?.doubleValue ?? defaultTimeout, 0), 300)
        let pollInterval = max(arguments["pollInterval"]?.doubleValue ?? 0.5, 0.1)
        let started = Date()
        var collected: Collected
        var matched: [Int]
        let wantPresent = name != "assert_not_visible"
        while true {
            collected = try await collect(page, interactiveOnly: false, limit: 2000, identifier: selector.identifier)
            matched = select(collected, selector: selector)
            let satisfied = wantPresent ? !matched.isEmpty : matched.isEmpty
            let elapsed = Date().timeIntervalSince(started)
            if satisfied || elapsed >= timeout { break }
            try await AXExecutor.pause(min(pollInterval, max(timeout - elapsed, 0.05)))
        }
        let elapsed = Date().timeIntervalSince(started)
        let backend = JSONValue.string("webkit")
        switch name {
        case "assert_not_visible":
            guard matched.isEmpty else {
                return ToolResult.error("assert_not_visible FAILED: element matching \(selector.summary) was still present after \(timeout)s")
            }
            return ToolResult.json(.object(["passed": .bool(true), "elapsed": .double(elapsed), "backend": backend]))
        case "assert_visible", "wait_for_element":
            guard let first = matched.first else {
                if name == "assert_visible" { return ToolResult.error("assert_visible FAILED: no element matched \(selector.summary) within \(timeout)s") }
                return ToolResult.json(.object(["found": .bool(false), "elapsed": .double(elapsed),
                                                "message": .string("Element not found within \(timeout)s timeout"), "backend": backend]))
            }
            let ids = await RoutedHandleStore.shared.replace(refs: collected.refs, scope: .webkit(page.key))
            var fields: [String: JSONValue] = [
                name == "assert_visible" ? "passed" : "found": .bool(true),
                "id": .string(ids[first]), "elapsed": .double(elapsed), "backend": backend,
            ]
            if case .webkit(_, _, _, let role, let label) = collected.refs[first] {
                fields["role"] = .string(role)
                if !label.isEmpty { fields["label"] = .string(label) }
            }
            return ToolResult.json(.object(fields))
        default:
            let ids = await RoutedHandleStore.shared.replace(refs: collected.refs, scope: .webkit(page.key))
            let limit = max(arguments["maxResults"]?.intValue ?? 20, 0)
            let shown = Array(matched.prefix(limit))
            return ToolResult.json(.object([
                "backend": backend, "count": .int(matched.count),
                "elements": .array(shown.map { collected.elements[$0].withId(ids[$0]) }),
            ]))
        }
    }

    /// Same rules as the CDP selector: role (aliases normalised), exact and contains text on the
    /// label, an identifier the page marked, then `index`.
    static func select(_ collected: Collected, selector: CDPSelector) -> [Int] {
        var hits: [Int] = []
        for (position, ref) in collected.refs.enumerated() {
            guard case .webkit(_, _, _, let role, let label) = ref else { continue }
            if let wanted = selector.role, CDPSelector.normalizedRole(wanted) != CDPSelector.normalizedRole(role) { continue }
            if selector.identifier != nil, collected.raw[position]["ident"]?.boolValue != true { continue }
            if selector.exactText.contains(where: { $0.caseInsensitiveCompare(label) != .orderedSame }) { continue }
            if selector.containsText.contains(where: { !label.localizedCaseInsensitiveContains($0) }) { continue }
            hits.append(position)
        }
        guard let index = selector.index else { return hits }
        return hits.indices.contains(index) ? [hits[index]] : []
    }

    // MARK: - Screenshots

    @MainActor
    private static func screenshot(_ page: WebKitPage, arguments: JSONValue, rect: CGRect?, note: String?) async throws -> JSONValue {
        var notes: [String] = []
        if let note { notes.append(note) }
        let encoding = CaptureTools.encodingParams(from: arguments)
        var original: CGSize?
        if rect == nil, arguments["fullPage"]?.boolValue == true {
            let state = try await page.script(WebKitScripts.pageState, inPageWorld: true)
            let content = CGFloat(state["scrollHeight"]?.doubleValue ?? Double(page.viewport.height))
            // Four bytes a pixel: keep the capture under what a snapshot can hold.
            let budget = 60_000_000 / (page.viewport.width * page.scale * page.scale * 4)
            let height = min(max(content, page.viewport.height), budget.rounded(.down), WebKitBackend.maxViewportSide * 4)
            if height > page.viewport.height {
                original = page.viewport
                page.apply(.init(height: min(height, WebKitBackend.maxViewportSide)))
                if height > WebKitBackend.maxViewportSide { notes.append("Full page capped at \(Int(WebKitBackend.maxViewportSide)) CSS px tall.") }
                await page.settle(0.4)
            }
        }
        defer { if let original { page.apply(.init(width: original.width, height: original.height)) } }
        let image = try await page.image(rect: rect)
        let encoded = try ImageEncoder.encode(image, maxLongestSide: encoding.maxLongestSide, format: encoding.format, quality: encoding.quality)
        var result = ToolResult.image(base64: encoded.data.base64EncodedString(), mimeType: encoded.mimeType)
        let state = await page.state()
        if state["visibility"]?.stringValue == "hidden" {
            notes.append("This page reports document.hidden=true (the visibility SPI is unavailable), so pages that stop polling while hidden may show skeletons.")
        }
        notes.append(contentsOf: page.takeDialogs().map { "Dialog answered for the page: \($0)" })
        for text in notes { result = ToolResult.appendingNotice(text, to: result) }
        return result
    }

    // MARK: - Shared

    @MainActor
    private static func pageInfo(_ page: WebKitPage, note: String?) async -> [String: JSONValue] {
        let state = await page.state()
        var fields: [String: JSONValue] = [
            "backend": .string("webkit"),
            "page": .string(page.key),
            "url": .string(page.currentURL ?? ""),
            "title": state["title"] ?? .string(""),
            "loaded": .bool(page.loaded),
            "viewport": .object([
                "width": .double(Double(page.viewport.width)), "height": .double(Double(page.viewport.height)),
                "deviceScaleFactor": .double(Double(page.scale)), "colorScheme": .string(page.colorScheme.rawValue),
            ]),
            "visibility": state["visibility"] ?? .string("unknown"),
        ]
        if let status = page.statusCode { fields["status"] = .int(status) }
        var notes: [String] = []
        if let note { notes.append(note) }
        if state["visibility"]?.stringValue == "hidden" {
            notes.append("The page reports document.hidden=true: WebKit's visibility override is unavailable on this macOS, so polling pages may stall and screenshots may show skeletons.")
        }
        if !page.scaleSPI { notes.append("deviceScaleFactor is not available on this macOS; the display's scale is used.") }
        let dialogs = page.takeDialogs()
        if !dialogs.isEmpty { fields["dialogs"] = .array(dialogs.map { .string($0) }) }
        notes.append("Pages close after \(Int(WebKitBackend.idleLimit / 60)) minutes without a call.")
        fields["note"] = .string(notes.joined(separator: " "))
        return fields
    }

    @MainActor
    private static func withDialogs(_ result: JSONValue, _ page: WebKitPage) -> JSONValue {
        let dialogs = page.takeDialogs()
        guard !dialogs.isEmpty else { return result }
        return ToolResult.appendingNotice("Dialog answered for the page: " + dialogs.joined(separator: "; "), to: result)
    }

    private static func split(_ document: String) throws -> (Int, Int) {
        let parts = document.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 2 else { throw WebKitBackend.Failure.stale }
        return (parts[0], parts[1])
    }

    /// The page-side scripts answer `{stale:true}` when the node or its snapshot is gone.
    private static func fail(_ result: JSONValue) throws {
        if result["stale"]?.boolValue == true { throw WebKitBackend.Failure.stale }
    }

    private static func requireConsent(arguments: JSONValue) throws {
        if CodeExecConsent.shared.isGranted("webkit") { return }
        if arguments["consent"]?.boolValue == true {
            CodeExecConsent.shared.grant("webkit")
            return
        }
        throw Refusal(message: "Code execution (JavaScript inside the page) requires consent:true once per machine.")
    }
}

private struct Refusal: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private extension JSONValue {
    func withId(_ id: String) -> JSONValue {
        guard case .object(var fields) = self else { return self }
        fields["id"] = .string(id)
        return .object(fields)
    }
}
