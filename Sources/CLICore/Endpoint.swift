import Foundation
import PortOwnership

/// Talks to the AgentController menu-bar app over the same loopback JSON-RPC endpoint the
/// MCP bridge uses. The CLI is deliberately a *client* of the running app rather than a
/// second implementation of the tools: there is one Accessibility grant, one Screen
/// Recording grant, and one Focus Guard, and they belong to the app. A CLI that drove
/// AXUIElement itself would need its own TCC grants and would sit outside Focus Guard —
/// which is the one thing this project promises never to happen.
public struct Endpoint: Equatable {
    public let port: UInt16
    public let token: String

    /// Always 127.0.0.1: the port is a number by construction, so the file's contents can
    /// only ever choose which loopback port, never which host.
    var url: URL {
        URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    public static let portFile = "\(NSHomeDirectory())/.agentcontroller/mcp-port"
    public static let tokenFile = "\(NSHomeDirectory())/.agentcontroller/mcp-token"

    public enum Failure: Error, CustomStringConvertible {
        case notRunning
        case unreachable(String)
        case rejected(Int)
        case badResponse
        case rpc(String)

        public var description: String {
            switch self {
            case .notRunning:
                return """
                AgentController is not running.

                Start the menu-bar app first:
                    open -a AgentController

                If it is not installed, build it from a checkout with ./build.sh
                """
            case .unreachable(let detail):
                return "Cannot reach AgentController on localhost: \(detail)\nThe app may have just restarted — try again."
            case .rejected(let code):
                return code == 401
                    ? "AgentController rejected the auth token (HTTP 401). Restart the app to reissue one."
                    : "AgentController rejected the request (HTTP \(code))."
            case .badResponse:
                return "AgentController returned a response this CLI could not parse."
            case .rpc(let message):
                return message
            }
        }
    }

    /// Read the port and token the app writes on launch. Both are rewritten on every
    /// restart, so they are read per invocation and never cached to disk by the CLI.
    public static func discover(portFile: String = Endpoint.portFile,
                                tokenFile: String = Endpoint.tokenFile) throws -> Endpoint {
        guard let port = try? String(contentsOfFile: portFile, encoding: .utf8),
              let token = try? String(contentsOfFile: tokenFile, encoding: .utf8)
        else { throw Failure.notRunning }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Parsed, not pasted into the URL: a port file reading "80@attacker.example" made
        // the request — bearer token included — go to attacker.example.
        guard let number = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0,
              !trimmedToken.isEmpty else { throw Failure.notRunning }
        return Endpoint(port: number, token: trimmedToken)
    }

    /// Proxy-free, cache-free: this request carries the bearer token, and
    /// `URLSession.shared` would hand it to any system proxy that doesn't exempt 127.0.0.1.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    /// One JSON-RPC round trip. Synchronous on purpose: a CLI process does one thing and
    /// exits, so a semaphore around URLSession is simpler than making main async and
    /// costs nothing here.
    ///
    /// `listenerIsOurs` is the check that the process on the port runs as this user; tests
    /// stand in another user's listener, which they cannot create.
    public func call(
        method: String,
        params: [String: Any]?,
        listenerIsOurs: (UInt16) -> Bool = { LoopbackListener.owner(port: $0) != nil }
    ) throws -> [String: Any] {
        var body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method]
        if let params { body["params"] = params }

        // A port the app gave up (it restarted, or its listener died) can be taken by any
        // account on the Mac, which would then receive the token and the request.
        guard listenerIsOurs(port) else {
            throw Failure.unreachable("nothing running as you is listening on 127.0.0.1:\(port), so the request and its token were not sent")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Matches the bridge's ceiling: the longest legitimate calls (wait_for_element,
        // scroll_until_visible) finish well inside it.
        request.timeoutInterval = 180

        var result: Result<(Data, HTTPURLResponse), Error>?
        let done = DispatchSemaphore(value: 0)
        Self.session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(Failure.unreachable(error.localizedDescription))
            } else if let data, let http = response as? HTTPURLResponse {
                result = .success((data, http))
            } else {
                result = .failure(Failure.badResponse)
            }
            done.signal()
        }.resume()
        done.wait()

        guard let result else { throw Failure.badResponse }
        let (data, http) = try result.get()
        guard http.statusCode == 200 else { throw Failure.rejected(http.statusCode) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw Failure.rpc(error["message"] as? String ?? "unknown JSON-RPC error")
        }
        guard let payload = object["result"] as? [String: Any] else { throw Failure.badResponse }
        return payload
    }

    /// Every registered tool, as `tools/list` returns it.
    public func tools() throws -> [[String: Any]] {
        let result = try call(method: "tools/list", params: nil)
        return result["tools"] as? [[String: Any]] ?? []
    }
}
