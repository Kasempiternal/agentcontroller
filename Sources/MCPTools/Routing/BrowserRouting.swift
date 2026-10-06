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

    /// Tools where "app + url" means "show me that page": navigate first, then act.
    static let navigatingTools: Set<String> = [
        "snapshot", "describe_screen", "screenshot_window", "read_all_text",
    ]

    static func prepare(name: String, arguments: JSONValue) async throws -> Prepared {
        // open_url resolves its own browser (it's a launch, not a drive), and elementId
        // calls already know exactly which element and backend they target.
        if name == "open_url" || arguments["elementId"]?.stringValue != nil { return .unchanged }
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
