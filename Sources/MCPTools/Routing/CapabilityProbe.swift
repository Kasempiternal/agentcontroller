import Foundation
import MCPServer

/// Identity → candidate backends → handshake. Never asks except multi-instance,
/// missing add-on, or code-exec consent.
public enum CapabilityProbe {
    public static func classify(_ identity: TargetIdentity) -> CapabilityRecord {
        if identity.kind == .url && identity.isHTTP {
            return CapabilityRecord(
                target: identity.raw,
                backend: .cdp,
                reason: "URL identity — CDP/Playwright-class compact a11y refs; headless unless a user Chrome debug port is already open.",
                headless: true
            )
        }
        if identity.kind == .iosSimulator {
            return CapabilityRecord(
                target: identity.raw,
                backend: .iosSim,
                reason: "iOS simulator UDID — idb/WDA path.",
                extras: ["udid": .string(identity.udid ?? identity.raw)]
            )
        }
        if AppCatalog.isBlender(identity) {
            return CapabilityRecord(
                target: identity.raw,
                backend: .blenderLab,
                reason: "Blender identity — in-process bpy if a socket handshakes, AX for chrome otherwise."
            )
        }
        if AppCatalog.isChromium(identity) {
            return CapabilityRecord(
                target: identity.raw,
                backend: .cdp,
                reason: "Chromium-family browser — CDP for page content when a debug port is reachable; AX for browser chrome otherwise.",
                headless: false
            )
        }
        if AppCatalog.isBrowser(identity) {
            return CapabilityRecord(
                target: identity.raw,
                backend: .ax,
                reason: "Browser without a CDP attach path (e.g. Safari). Native AX of the window, including web content where the tree is honest."
            )
        }
        return CapabilityRecord(
            target: identity.raw,
            backend: .ax,
            reason: "Native app — Accessibility (AX / UIA / AT-SPI) with postToPid; HID/focus only as escape hatch."
        )
    }

    public static func probe(_ identity: TargetIdentity) async -> CapabilityRecord {
        if var cached = await ProbeCache.shared.get(identity.raw) {
            // Blender records live 30s; consent granted since then must not keep showing as owed.
            if cached.ask == .codeExecConsent, CodeExecConsent.shared.isGranted("bpy") {
                cached.ask = nil
                cached.askDetail = nil
            }
            return cached
        }
        var record = classify(identity)
        switch record.backend {
        case .cdp:
            record = await probeCDP(identity, seed: record)
        case .blenderLab, .blenderWS:
            record = await probeBlender(seed: record)
        case .iosSim:
            record = await probeIOS(identity, seed: record)
        case .ax, .hid:
            record = enrichAX(identity, seed: record)
        }
        await ProbeCache.shared.set(identity.raw, record)
        return record
    }

    private static func probeCDP(_ identity: TargetIdentity, seed: CapabilityRecord) async -> CapabilityRecord {
        var record = seed
        let avail = await WebCDPBackend.shared.inspectAvailability()
        if let binary = avail.binary {
            record.extras["chromeBinary"] = .string(binary)
        }
        // `attached` is a user's Chrome. The headless Chromium this app owns also has a
        // debug port, but reporting it as "attached" sent app identities like
        // com.google.Chrome at the private browser instead of the user's.
        if avail.attached, let port = avail.debugPort {
            record.endpoint = "127.0.0.1:\(port)"
            record.protocolName = "cdp"
            record.headless = false
            record.extras["attached"] = .bool(true)
            record.reason = "Attached to an existing Chrome DevTools port — driving the live page, not AX of the browser window."
            return record
        }
        if identity.kind == .url && identity.isHTTP {
            if avail.binary == nil {
                record.backend = .ax
                record.ask = .missingAddon
                record.askDetail = "No Chromium browser found. Install Chrome/Chromium/Edge, or launch Chrome with --remote-debugging-port=9222."
                record.reason = "URL target but no CDP browser is available; refusing to AX-drive a web page."
                record.extras["available"] = .bool(false)
                return record
            }
            record.headless = true
            record.protocolName = "cdp"
            record.extras["available"] = .bool(true)
            if let port = avail.debugPort {
                record.endpoint = "127.0.0.1:\(port)"
                record.reason = "Reusing the dedicated headless Chromium already launched for this app (separate profile); each URL gets its own tab."
            } else {
                record.reason = "Will launch a dedicated headless Chromium (separate profile) for this URL. Pass a live --remote-debugging-port=9222 Chrome to reuse a logged-in user session."
            }
            return record
        }
        record.backend = .ax
        record.reason = "Chrome is running without a DevTools port — using AX for browser chrome. Relaunch with --remote-debugging-port=9222 (or snapshot a URL) for page content."
        record.extras["hint"] = .string("cdp-attach")
        return record
    }

    private static func probeBlender(seed: CapabilityRecord) async -> CapabilityRecord {
        var record = seed
        let endpoints = await BlenderBackend.handshake()
        if endpoints.isEmpty {
            record.backend = .ax
            record.ask = .missingAddon
            record.askDetail = "Blender is identified but no Lab/community socket answered on 127.0.0.1:9876-9896. Enable the MCP add-on / click Start MCP Server."
            record.reason = "ax-fallback: blender addon not listening"
            return record
        }
        if endpoints.count > 1 {
            record.ask = .multiInstance
            record.askDetail = "Multiple Blender sockets answered. Pass a pid or port to pick one; until then AX chrome still works and run_app_code is refused."
            record.candidates = endpoints.map {
                .object([
                    "port": .int(Int($0.port)),
                    "backend": .string($0.kind.rawValue),
                    "detail": .string($0.detail),
                ])
            }
            record.backend = .ax
            record.reason = "ax-fallback until the Blender instance is disambiguated"
            return record
        }
        let hit = endpoints[0]
        record.backend = hit.kind
        record.endpoint = "\(hit.host):\(hit.port)"
        record.protocolName = hit.kind == .blenderLab ? "blender-lab" : "blender-ws"
        record.reason = "Blender socket handshake succeeded — document/scene ops go through bpy, menus through AX."
        if !CodeExecConsent.shared.isGranted("bpy") {
            record.ask = .codeExecConsent
            record.askDetail = "run_app_code executes Python inside Blender. Pass consent:true once to allow it."
        }
        return record
    }

    private static func probeIOS(_ identity: TargetIdentity, seed: CapabilityRecord) async -> CapabilityRecord {
        var record = seed
        let resolved = await IOSSimBackend.shared.resolveUDID(identity.udid ?? identity.raw)
        record.extras["udid"] = .string(resolved.udid)
        record.ask = resolved.ask
        record.askDetail = resolved.detail
        if await IOSSimBackend.shared.idbBinary() == nil {
            record.backend = .ax
            record.ask = .missingAddon
            record.askDetail = "No idb binary. Run agentcontroller-ios --setup (or brew install idb-companion) so this MCP can drive the simulator."
            record.reason = "ax-fallback: idb missing"
            return record
        }
        if resolved.ask == .multiInstance || resolved.ask == .missingAddon {
            record.backend = .ax
            record.reason = resolved.detail ?? "iOS simulator not uniquely identified"
            return record
        }
        record.backend = .iosSim
        record.protocolName = "idb"
        record.reason = "Booted simulator — idb UI describe/tap (same path as the iOS MCP)."
        return record
    }

    private static func enrichAX(_ identity: TargetIdentity, seed: CapabilityRecord) -> CapabilityRecord {
        var record = seed
        if identity.kind == .processID, let pid = identity.pid {
            record.pid = Int(pid)
        }
        return record
    }
}

actor ProbeCache {
    static let shared = ProbeCache()
    private var items: [String: (Date, CapabilityRecord)] = [:]

    /// A verdict is only as stale as the thing it measured can change. A Blender socket or
    /// a booted simulator is stable for as long as the user leaves it (and callers
    /// `invalidate` on the first failure), so re-handshaking 21 ports or re-running
    /// simctl every 2s was pure cost. Fallbacks and web verdicts stay short: they are how
    /// a just-started Blender or Chrome gets noticed.
    static func lifetime(for backend: CapabilityRecord.Backend) -> TimeInterval {
        switch backend {
        case .blenderLab, .blenderWS, .iosSim: return 30
        case .cdp, .ax, .hid: return 2
        }
    }

    func get(_ key: String, now: Date = Date()) -> CapabilityRecord? {
        guard let item = items[key], now.timeIntervalSince(item.0) < Self.lifetime(for: item.1.backend) else { return nil }
        return item.1
    }

    func set(_ key: String, _ value: CapabilityRecord, at date: Date = Date()) {
        items[key] = (date, value)
    }

    func invalidate(_ key: String) {
        items.removeValue(forKey: key)
    }

    /// Drop every verdict for one kind of backend — a failure on one Blender or simulator
    /// call says nothing about which cache key (alias, UDID, name) the next call will use.
    func invalidate(backend: CapabilityRecord.Backend) {
        items = items.filter { Self.family($0.value.1.backend) != Self.family(backend) }
    }

    private static func family(_ backend: CapabilityRecord.Backend) -> String {
        switch backend {
        case .blenderLab, .blenderWS: return "blender"
        default: return backend.rawValue
        }
    }

    func reset() {
        items.removeAll()
    }
}
