// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Deskestro",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Deskestro", targets: ["App"]),
    ],
    targets: [
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
            dependencies: ["AccessibilityEngine", "ScreenCapture", "MCPServer"],
            path: "Sources/MCPTools"
        ),
        .testTarget(
            name: "DeskestroTests",
            dependencies: ["MCPServer", "AccessibilityEngine", "MCPTools", "ScreenCapture"],
            path: "Tests/DeskestroTests"
        ),
    ]
)
