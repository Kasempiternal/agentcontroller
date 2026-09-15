import Foundation
import AccessibilityEngine

/// Element ids issued by non-AX backends (CDP, bpy, idb). Ids share the AX
/// monotonic sequence so `eN` never silently aliases a different backend.
public enum RoutedRef: Sendable, Equatable {
    case cdp(sessionKey: String, backendNodeId: Int, role: String, label: String)
    case blender(name: String, kind: String)
    case ios(udid: String, uid: String, x: Double, y: Double, width: Double, height: Double)
}

public actor RoutedHandleStore {
    public static let shared = RoutedHandleStore()

    private var handles: [String: RoutedRef] = [:]

    public func replace(refs: [RoutedRef]) async -> [String] {
        let ids = await ElementHandleStore.shared.allocateIDs(count: refs.count)
        if let first = refs.first {
            let key = sessionKey(for: first)
            let stale = handles.filter { sessionKey(for: $0.value) == key }.map(\.key)
            for id in stale { handles.removeValue(forKey: id) }
        }
        for (id, ref) in zip(ids, refs) {
            handles[id] = ref
        }
        return ids
    }

    public func resolve(_ id: String) -> RoutedRef? {
        handles[id]
    }

    private func sessionKey(for ref: RoutedRef) -> String {
        switch ref {
        case .cdp(let sessionKey, _, _, _): return "cdp:\(sessionKey)"
        case .blender: return "blender"
        case .ios(let udid, _, _, _, _, _): return "ios:\(udid)"
        }
    }
}
