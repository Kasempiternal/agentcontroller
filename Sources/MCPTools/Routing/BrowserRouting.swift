import Foundation
import MCPServer

/// Runs before `BackendRouter`: when a call carries a page URL, decide WHICH browser gets
/// it, put the page there, and rewrite the arguments so everything downstream drives that
/// browser. This is the only place the browser is chosen.
enum BrowserRouting {
    enum Prepared {
        /// Not a web call, or one the existing pipeline already handles.
        case unchanged
        /// Use these arguments instead; append `notice` to the tool result.
        case rewritten(JSONValue, notice: String?)
        /// Stop and return this result (e.g. the agent named a browser that isn't installed).
        case failed(JSONValue)
    }

    /// Private argument carrying the page URL across the rewrite below, which drops `url`
    /// (downstream drives the app, not a URL identity). `BackendRouter` reads it to pick the
    /// right tab in an attached Chrome; nothing may use it to navigate.
    static let pageURLKey = "_pageURL"

    /// Private argument: the DevTools port of the user's own browser a page went into as a
    /// background tab (`AttachedChrome`). The CDP backend opens it on that port and no other.
    static let attachedPortKey = "_cdpPort"

    /// Keys only this router sets. A client that sends them has them dropped (`ToolRegistry`):
    /// `_cdpPort` would pin the CDP backend to any local port, past the check that the port is the
    /// named browser's.
    static let privateKeys: Set<String> = [pageURLKey, attachedPortKey]

    static func strippingPrivateKeys(_ arguments: JSONValue) -> JSONValue {
        guard var object = arguments.objectValue, privateKeys.contains(where: { object[$0] != nil }) else { return arguments }
        for key in privateKeys { object.removeValue(forKey: key) }
        return .object(object)
    }

    /// Tools where "app + url" means "show me that page": navigate first, then act.
    static let navigatingTools: Set<String> = [
        "snapshot", "describe_screen", "screenshot_window", "read_all_text",
    ]

    static func prepare(name: String, arguments: JSONValue) async throws -> Prepared {
        // elementId calls already know exactly which element and backend they target.
        if arguments["elementId"]?.stringValue != nil { return .unchanged }
        if name == "open_url" { return await prepareOpenURL(arguments) }
        guard let page = TargetIdentity.pageURL(arguments: arguments) else { return .unchanged }

        let appArg = arguments["app"]?.stringValue ?? arguments["target"]?.stringValue
        let explicitBrowser = arguments["browser"]?.stringValue
        // An `app` that is neither a browser nor the URL itself (e.g. an Electron app
        // with a url field) is not ours to reinterpret.
        if let appArg, TargetIdentity.splitBrowserPrefix(appArg) == nil,
           TargetIdentity.parseURL(appArg) == nil, !BrowserResolver.isBrowserName(appArg),
           explicitBrowser == nil {
            return .unchanged
        }
        let browserAppArg = appArg.flatMap { TargetIdentity.splitBrowserPrefix($0)?.0 }
            ?? appArg.flatMap { BrowserResolver.isBrowserName($0) ? $0 : nil }

        let choice: BrowserChoice
        do {
            choice = try BrowserResolver.choose(
                browser: explicitBrowser,
                app: browserAppArg,
                headless: arguments["headless"]?.boolValue
            )
        } catch {
            return .failed(ToolResult.error(error.localizedDescription))
        }

        switch choice {
        case .headless:
            return .rewritten(headlessArguments(arguments, page: page), notice: nil)

        case .browser(let browser):
            // That browser publishes a debug port: the page goes in as a background tab over CDP,
            // never through LaunchServices (Chrome comes to the front on every hand-off). Calls
            // that act (click, type) keep naming the app + page below, so they never open a tab.
            if navigatingTools.contains(name), let port = await AttachedChrome.port(for: browser) {
                return .rewritten(attachedArguments(arguments, page: page, port: port), notice: nil)
            }
            let args = browserArguments(arguments, browser: browser, page: page)
            guard navigatingTools.contains(name) else {
                return .rewritten(args, notice: nil)
            }
            do {
                let outcome = try await BrowserNavigator.navigate(page, in: browser)
                return .rewritten(args, notice: navigationNotice(page: page, browser: browser.name, outcome: outcome))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .failed(ToolResult.error(error.localizedDescription))
            }
        }
    }

    /// `open_url` resolves its own browser in AppTools: it is a launch, not a drive. The one case
    /// taken over here is a web page for a Chrome that publishes a debug port, which goes in as a
    /// background tab instead of through LaunchServices. `foreground:true` keeps the old path,
    /// because there the agent wants the browser in front.
    static func prepareOpenURL(_ arguments: JSONValue) async -> Prepared {
        guard arguments["headless"]?.boolValue != true, arguments["foreground"]?.boolValue != true,
              let raw = arguments["url"]?.stringValue, let page = URL(string: raw),
              ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { return .unchanged }
        let named = arguments["browser"]?.stringValue
            ?? arguments["app"]?.stringValue.flatMap { BrowserResolver.isBrowserName($0) ? $0 : nil }
        guard let browser = named.map(BrowserResolver.named) ?? BrowserResolver.systemDefault(),
              let port = await AttachedChrome.port(for: browser) else { return .unchanged }
        return .rewritten(attachedArguments(arguments, page: page, port: port), notice: nil)
    }

    /// A page for the user's own Chrome, put in by the CDP backend on `port`.
    static func attachedArguments(_ arguments: JSONValue, page: URL, port: UInt16) -> JSONValue {
        var args = arguments.objectValue ?? [:]
        args.removeValue(forKey: "app")
        args.removeValue(forKey: "target")
        args.removeValue(forKey: "browser")
        args["url"] = .string(page.absoluteString)
        args["headless"] = .bool(false)
        args[attachedPortKey] = .int(Int(port))
        return .object(args)
    }

    /// Hand the existing CDP path a pure URL identity.
    static func headlessArguments(_ arguments: JSONValue, page: URL) -> JSONValue {
        var args = arguments.objectValue ?? [:]
        args.removeValue(forKey: "app")
        args.removeValue(forKey: "target")
        args["url"] = .string(page.absoluteString)
        // Explicit even when the agent chose the private browser via `browser:"headless"`
        // rather than the flag: the CDP backend must not fall back to attaching to the
        // user's own Chrome.
        args["headless"] = .bool(true)
        return .object(args)
    }

    /// Drive the user's browser by app: the page URL leaves the arguments, because
    /// downstream addresses the app, not a URL. It travels on as `_pageURL` so an attached
    /// Chrome can still be asked for the tab that page is in.
    static func browserArguments(_ arguments: JSONValue, browser: BrowserTarget, page: URL) -> JSONValue {
        var args = arguments.objectValue ?? [:]
        args["app"] = .string(browser.bundleId)
        args.removeValue(forKey: "target")
        args.removeValue(forKey: "url")
        args.removeValue(forKey: "browser")
        args[pageURLKey] = .string(page.absoluteString)
        return .object(args)
    }

    static func navigationNotice(page: URL, browser: String, outcome: BrowserNavigator.Outcome) -> String {
        if outcome.reused {
            let notice = "\(page.absoluteString) is already the front tab in \(browser); used as it is, no new tab."
            return outcome.wasFrontmost ? notice + " " + frontmostNotice(browser: browser) : notice
        }
        let state = outcome.loaded
            ? "loaded in \(outcome.waitedMs)ms"
            : "NOT confirmed loaded after \(outcome.waitedMs)ms (page reports \(outcome.pageURL ?? "no URL")) — re-snapshot if content looks stale"
        var notice = "Opened \(page.absoluteString) in \(browser) (background, \(state))."
        if outcome.wasFrontmost { notice += " " + frontmostNotice(browser: browser) }
        return notice
    }

    /// The navigation still happens — refusing would leave the agent with no way to read
    /// the page — but the agent is told the tab it opened is where the user is looking.
    static func frontmostNotice(browser: String) -> String {
        "\(browser) was frontmost — the new tab is in the user's view; prefer driving it only while the user isn't using it."
    }
}
