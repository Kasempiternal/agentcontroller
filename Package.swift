// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AgentController",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentController", targets: ["App"]),
        // NOT "agentcontroller": SwiftPM writes every product into the same build
        // directory, and macOS ships a case-INSENSITIVE filesystem, so a product
        // differing from "AgentController" only in case is literally the same file —
        // whichever links last silently overwrites the other. It presents as the CLI
        // hanging forever, because the binary you invoke is the menu-bar app starting a
        // SwiftUI run loop. build.sh installs this product under the name users type.
        .executable(name: "agentcontroller-cli", targets: ["CLI"]),
    ],
    targets: [
        // Foundation only (plus PortOwnership, which is Darwin only), and no dependency on
        // the tool targets: the CLI is a client of the running app's loopback endpoint,
        // not a second implementation of the tools. One process owns the Accessibility and
        // Screen Recording grants and enforces Focus Guard, and it stays that way.
        //
        // Split in two so the parts worth testing are reachable: `main.swift` is
        // top-level code, which a test target cannot import, so argument parsing and the
        // transport live in a library and the executable is only the command dispatch.
        .target(
            name: "CLICore",
            dependencies: ["PortOwnership"],
            path: "Sources/CLICore"
        ),
        // Who is listening on a loopback port. Shared by the CLI (before it sends the
        // bearer token) and the CDP backend (before it attaches to a "user's Chrome").
        .target(
            name: "PortOwnership",
            path: "Sources/PortOwnership"
        ),
        .executableTarget(
            name: "CLI",
            dependencies: ["CLICore"],
            path: "Sources/CLI"
        ),
        .executableTarget(
            name: "App",
            dependencies: ["MCPServer", "AccessibilityEngine", "ScreenCapture", "MCPTools"],
            path: "Sources/App",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"]),
            ]
        ),
        .target(
            name: "MCPServer",
            path: "Sources/MCPServer"
        ),
        .target(
            name: "AccessibilityEngine",
            dependencies: ["MCPServer"],
            path: "Sources/AccessibilityEngine"
        ),
        .target(
            name: "ScreenCapture",
            dependencies: ["AccessibilityEngine"],
            path: "Sources/ScreenCapture"
        ),
        .target(
            name: "MCPTools",
            dependencies: ["AccessibilityEngine", "ScreenCapture", "MCPServer", "PortOwnership"],
            path: "Sources/MCPTools"
        ),
        .testTarget(
            name: "AgentControllerTests",
            dependencies: ["MCPServer", "AccessibilityEngine", "MCPTools", "ScreenCapture", "CLICore", "PortOwnership"],
            path: "Tests/AgentControllerTests"
        ),
    ]
)
