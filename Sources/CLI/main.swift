import Foundation
import CLICore

/// `agentcontroller` — drive the running AgentController app from a shell, with no MCP
/// client in the loop. Same 49 tools, same Focus Guard, same permissions grant.
///
/// Exit codes are the contract that makes it scriptable: 0 for a tool that did what it
/// was asked, 1 for a tool that ran and reported failure (`isError`), 2 for a usage or
/// transport problem. A QA check in a shell script can branch on that without parsing
/// prose, which is the same reason the assertion tools return MCP `isError`.
enum Exit: Int32 {
    case ok = 0
    case toolFailed = 1
    case usage = 2
}

func fail(_ message: String, _ code: Exit = .usage) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code.rawValue)
}

let usage = """
agentcontroller — drive native apps from the shell through the AgentController app.

USAGE
  agentcontroller <tool> [key=value ...]   call a tool
  agentcontroller tools [filter]           list tools (optionally filtered by substring)
  agentcontroller describe <tool>          show one tool's description and parameters
  agentcontroller status                   check the app is running and permissions are granted

ARGUMENTS
  key=value      typed from the tool's own schema, so app=1234 stays the string a PID needs
  key:=<json>    literal JSON, for arrays and objects: menuPath:='["File","Open…"]'

OPTIONS
  -o, --out <file>   write a screenshot to <file> instead of a temp path
  --json             print the raw MCP result instead of the unwrapped payload
  -h, --help         this text

EXAMPLES
  agentcontroller list_apps
  agentcontroller snapshot app=com.apple.TextEdit
  agentcontroller click app=com.apple.TextEdit role=AXButton title=Save
  agentcontroller navigate_menu app=com.apple.TextEdit menuPath:='["Format","Make Plain Text"]'
  agentcontroller screenshot_window app=com.apple.Safari -o shot.jpg
  agentcontroller assert_visible app=com.example.App labelContains=Welcome && echo PASS

Every tool is background-safe by default: driving an app from here does not take your
focus, move your cursor, or change your frontmost window.
"""

var words = Array(CommandLine.arguments.dropFirst())
guard !words.isEmpty else { print(usage); exit(Exit.ok.rawValue) }

var outputPath: String?
var rawJSON = false
var filtered: [String] = []
var index = 0
while index < words.count {
    switch words[index] {
    case "-h", "--help":
        print(usage)
        exit(Exit.ok.rawValue)
    case "--json":
        rawJSON = true
    case "-o", "--out":
        index += 1
        guard index < words.count else { fail("-o needs a file path") }
        outputPath = words[index]
    default:
        filtered.append(words[index])
    }
    index += 1
}
words = filtered
guard let command = words.first else { print(usage); exit(Exit.ok.rawValue) }
let rest = Array(words.dropFirst())

func connect() -> Endpoint {
    do { return try Endpoint.discover() } catch { fail("\(error)") }
}

/// Pretty-print JSON so a human reading the terminal gets something legible. The MCP
/// server deliberately emits compact JSON to save an agent's tokens; a shell user pays no
/// token cost and wants the newlines.
func printJSON(_ value: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print(value)
    }
}

/// One line out of a paragraph written for an agent. Splitting on "." alone cuts
/// "(e.g. 'com.apple.TextEdit')" down to "(e", so the break is a period followed by a
/// space and a capital — and the line is truncated rather than wrapped, because the whole
/// point of the listing is one tool per row.
func summarize(_ description: String) -> String {
    let limit = 96
    var sentence = description
    let characters = Array(description)
    for i in 0..<max(0, characters.count - 2) where characters[i] == "." && characters[i + 1] == " " {
        if characters[i + 2].isUppercase {
            sentence = String(characters[0...i])
            break
        }
    }
    guard sentence.count > limit else { return sentence }
    return String(sentence.prefix(limit - 1)) + "…"
}

func listTools(_ endpoint: Endpoint, filter: String?) {
    let tools: [[String: Any]]
    do { tools = try endpoint.tools() } catch { fail("\(error)") }
    let matching = tools.filter { tool in
        guard let filter else { return true }
        let name = tool["name"] as? String ?? ""
        let description = tool["description"] as? String ?? ""
        return name.localizedCaseInsensitiveContains(filter)
            || description.localizedCaseInsensitiveContains(filter)
    }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

    guard !matching.isEmpty else { fail("No tool matches '\(filter ?? "")'.", .toolFailed) }
    for tool in matching {
        let name = tool["name"] as? String ?? "?"
        print("\(name.padding(toLength: max(24, name.count + 1), withPad: " ", startingAt: 0))\(summarize(tool["description"] as? String ?? ""))")
    }
}

func describeTool(_ endpoint: Endpoint, name: String) {
    let tools: [[String: Any]]
    do { tools = try endpoint.tools() } catch { fail("\(error)") }
    let names = tools.compactMap { $0["name"] as? String }
    guard let tool = tools.first(where: { ($0["name"] as? String) == name }) else {
        fail("\(Arguments.Failure.unknownTool(name, suggestions: Arguments.suggestions(for: name, among: names)))")
    }
    print(name)
    print("")
    print(tool["description"] as? String ?? "")
    print("")
    guard let schema = tool["inputSchema"] as? [String: Any],
          let properties = schema["properties"] as? [String: Any], !properties.isEmpty else {
        print("No parameters.")
        return
    }
    let required = Set((schema["required"] as? [String] ?? []))
    for key in properties.keys.sorted() {
        let property = properties[key] as? [String: Any] ?? [:]
        let type = property["type"] as? String ?? "any"
        let mark = required.contains(key) ? "*" : " "
        let description = property["description"] as? String ?? ""
        print("  \(mark) \(key.padding(toLength: max(20, key.count + 1), withPad: " ", startingAt: 0))\(type)  \(description)")
    }
    print("\n  * required")
}

func status(_ endpoint: Endpoint) {
    do {
        let result = try endpoint.call(method: "tools/call", params: [
            "name": "check_permissions", "arguments": [:],
        ])
        print("AgentController is running on 127.0.0.1:\(endpoint.port)")
        let content = result["content"] as? [[String: Any]] ?? []
        for item in content where item["type"] as? String == "text" {
            if let text = item["text"] as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                printJSON(parsed)
            }
        }
        exit(Exit.ok.rawValue)
    } catch { fail("\(error)") }
}

/// Unwrap an MCP tool result for a terminal. A single JSON text block is the common case
/// and is reprinted as formatted JSON; an image block is written to a file, because a
/// megabyte of base64 in a scrollback helps nobody.
func present(_ result: [String: Any], outputPath: String?) -> Exit {
    let isError = result["isError"] as? Bool ?? false
    let content = result["content"] as? [[String: Any]] ?? []

    for item in content {
        switch item["type"] as? String {
        case "image":
            guard let base64 = item["data"] as? String, let bytes = Data(base64Encoded: base64) else {
                print("(image block was not decodable)")
                continue
            }
            let mime = item["mimeType"] as? String ?? "image/png"
            let suffix = mime.hasSuffix("png") ? "png" : "jpg"
            let path = outputPath ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("agentcontroller-\(Int(Date().timeIntervalSince1970)).\(suffix)")
                .path
            do {
                try bytes.write(to: URL(fileURLWithPath: path))
                print("\(path)  (\(bytes.count) bytes, \(mime))")
            } catch {
                return .toolFailed
            }
        default:
            let text = item["text"] as? String ?? ""
            // Most results are a JSON object serialized into a text block. Reformat it
            // when it parses, print it verbatim when it does not (errors are prose).
            if let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                printJSON(parsed)
            } else {
                print(text)
            }
        }
    }
    return isError ? .toolFailed : .ok
}

switch command {
case "tools":
    listTools(connect(), filter: rest.first)
    exit(Exit.ok.rawValue)

case "describe":
    guard let name = rest.first else { fail("describe needs a tool name") }
    describeTool(connect(), name: name)
    exit(Exit.ok.rawValue)

case "status":
    status(connect())

default:
    let endpoint = connect()
    let tools: [[String: Any]]
    do { tools = try endpoint.tools() } catch { fail("\(error)") }
    let names = tools.compactMap { $0["name"] as? String }
    guard let tool = tools.first(where: { ($0["name"] as? String) == command }) else {
        fail("\(Arguments.Failure.unknownTool(command, suggestions: Arguments.suggestions(for: command, among: names)))")
    }

    let arguments: [String: Any]
    do {
        arguments = try Arguments.parse(rest, types: Arguments.declaredTypes(of: tool))
    } catch { fail("\(error)") }

    do {
        let result = try endpoint.call(method: "tools/call", params: [
            "name": command, "arguments": arguments,
        ])
        if rawJSON {
            printJSON(result)
            exit(((result["isError"] as? Bool) == true ? Exit.toolFailed : Exit.ok).rawValue)
        }
        exit(present(result, outputPath: outputPath).rawValue)
    } catch { fail("\(error)", .toolFailed) }
}
