import Foundation
import AccessibilityEngine

/// Element ids issued by non-AX backends (CDP, bpy, idb). Ids share the AX
/// monotonic sequence so `eN` never silently aliases a different backend.
public enum RoutedRef: Sendable, Equatable {
    /// `document` is the main frame's loaderId when the node was read. A backendNodeId
    /// means nothing outside that document: see `WebCDPBackend.requireDocument`.
    case cdp(sessionKey: String, document: String, backendNodeId: Int, role: String, label: String)
    /// Carries the endpoint the snapshot was taken from, so an elementId acts on that
    /// exact Blender instead of re-handshaking and re-picking.
    case blender(name: String, kind: String, endpoint: BlenderEndpoint)
    case ios(udid: String, identifier: String, role: String, label: String, x: Double, y: Double, width: Double, height: Double)

    /// The backend a handle belongs to; decides which tools may act on it.
    public var backend: CapabilityRecord.Backend {
        switch self {
        case .cdp: return .cdp
        case .blender(_, _, let endpoint): return endpoint.kind
        case .ios: return .iosSim
        }
    }
}

/// What one snapshot owns. Re-snapshotting a scope retires every id it issued before.
public enum RoutedScope: Sendable, Hashable {
    case cdp(String)
    case blender(String)
    case ios(String)
}

public actor RoutedHandleStore {
    public static let shared = RoutedHandleStore()

    private var handles: [String: (ref: RoutedRef, scope: RoutedScope)] = [:]

    /// The scope is passed in rather than derived from `refs.first`: a snapshot that
    /// finds nothing (an emptied page, a cleared scene) must still retire the ids it
    /// issued last time, and an empty list has no first element to read a scope from.
    public func replace(refs: [RoutedRef], scope: RoutedScope) async -> [String] {
        let ids = refs.isEmpty ? [] : await ElementHandleStore.shared.allocateIDs(count: refs.count)
        // No suspension point from here on: retire-then-insert is one atomic step, so a
        // concurrent snapshot of the same scope can't have its fresh ids retired.
        let stale = handles.filter { $0.value.scope == scope }.map(\.key)
        for id in stale { handles.removeValue(forKey: id) }
        for (id, ref) in zip(ids, refs) {
            handles[id] = (ref, scope)
        }
        return ids
    }

    public func resolve(_ id: String) -> RoutedRef? {
        handles[id]?.ref
    }
}
