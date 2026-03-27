import Foundation
import MCPServer
import AccessibilityEngine

struct SystemTools {
    static func register(in registry: ToolRegistry) {
        registry.register(.init(
            name: "check_permissions",
            description: "Check if Macoestro has the required macOS permissions (Accessibility and Screen Recording)",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            handler: { _ in
                let ax = PermissionChecker.isAccessibilityGranted
                let sr = PermissionChecker.isScreenRecordingGranted
                return ToolResult.json(.object([
                    "accessibility": .bool(ax),
                    "screenRecording": .bool(sr),
                    "allGranted": .bool(ax && sr),
                    "instructions": .string(
                        !ax ? "Grant Accessibility: System Settings > Privacy & Security > Accessibility > Enable Macoestro" :
                        !sr ? "Grant Screen Recording: System Settings > Privacy & Security > Screen Recording > Enable Macoestro" :
                        "All permissions granted"
                    ),
                ]))
            }
        ))

        registry.register(.init(
            name: "get_frontmost_app",
            description: "Get information about the currently frontmost (active) macOS application",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
            ]),
            handler: { _ in
                guard let app = await MainActor.run(body: { AppManager.frontmostApp() }) else {
                    return ToolResult.error("No frontmost application found")
                }
                return ToolResult.json(.object([
                    "name": .string(app.name),
                    "bundleId": .string(app.bundleIdentifier ?? ""),
                    "pid": .int(Int(app.pid)),
                ]))
            }
        ))
    }
}
