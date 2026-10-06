import ApplicationServices
import Foundation

/// What an element looked like when it was handed out: enough to tell, later, whether the
/// ref still points at the same control.
///
/// Liveness alone (`role != nil`) is not identity. Table and collection views recycle their
/// cells: the AXUIElement a snapshot registered as the "Delete" button of row 3 keeps
/// answering `role` after a reload, but now belongs to a different row — a click through
/// the old handle lands on the wrong item and reports success.
public struct AXElementFingerprint: Equatable, Sendable {
    public let role: String?
    /// Title, falling back to description — SwiftUI and AppKit put a control's name in
    /// either, depending on the control.
    public let name: String?
    public let identifier: String?

    /// One batched read is enough to build (and later re-check) a fingerprint.
    public static let attributeNames: [String] = [
        kAXRoleAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXIdentifierAttribute as String,
    ]

    public init(role: String?, name: String?, identifier: String?) {
        self.role = role
        self.name = Self.normalized(name)
        self.identifier = Self.normalized(identifier)
    }

    /// From an attribute dictionary that already carries `attributeNames` (a walk that
    /// read them for its own purposes registers fingerprints at no extra IPC cost).
    public init(attributes: [String: CFTypeRef]) {
        let title = attributes[kAXTitleAttribute as String] as? String
        let description = attributes[kAXDescriptionAttribute as String] as? String
        self.init(
            role: attributes[kAXRoleAttribute as String] as? String,
            name: Self.normalized(title) ?? description,
            identifier: attributes[kAXIdentifierAttribute as String] as? String
        )
    }

    /// Nil when the element answers nothing (dead ref, hung or gone app).
    public init?(reading element: AXElement) {
        let attributes = element.readAttributes(Self.attributeNames)
        guard attributes[kAXRoleAttribute as String] != nil else { return nil }
        self.init(attributes: attributes)
    }

    /// Any of the three changing means the ref was recycled or the control was rebuilt;
    /// a stale verdict costs the caller one re-snapshot, a wrong match costs a wrong click.
    public func isStale(comparedTo live: AXElementFingerprint) -> Bool {
        self != live
    }

    /// Same role and identifier: only the visible name differs. What a toggle looks like
    /// after it is pressed (Play -> Pause), and also what a recycled table cell looks like,
    /// so on its own it proves nothing — see `ElementHandleStore.verdict`.
    public func isSameControl(as live: AXElementFingerprint) -> Bool {
        role == live.role && identifier == live.identifier
    }

    private static func normalized(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

/// Server-side table of stable element handles.
///
/// Previously every interaction tool re-ran a full `AXElementSearch` BFS by
/// role/title/labelContains on each call, and the `path` string returned by
/// `find_elements`/`wait_for_element` was decorative — no tool consumed it.
///
/// `snapshot`/`describe_screen` walks the tree once, hands the model a flat list of
/// numbered elements (`e1`, `e2`, …), and caches the live `AXElement` refs here. The
/// interaction tools then accept an optional `elementId` and do an O(1) lookup instead
/// of another BFS. Ids are monotonic across snapshots so a stale id never silently
/// resolves to a different element after a re-snapshot.
public actor ElementHandleStore {
    public static let shared = ElementHandleStore()

    private struct Entry {
        let pid: pid_t
        let element: AXElement
        /// Nil for handles registered without one; those are checked for liveness only.
        var fingerprint: AXElementFingerprint?
        /// When the agent last acted through this handle.
        var actedAt: Date?
    }

    /// What `lookup` found.
    public enum Resolution: Sendable {
        case live(AXElement)
        /// Unknown id, app gone, element destroyed, or the ref now belongs to a different
        /// control. The recovery is a re-snapshot.
        case stale
        /// The app did not answer the identity check (busy, hung, or its stall breaker is
        /// open). Nothing is known about the element; the recovery is to try again.
        case busy
    }

    /// How a handle's registered fingerprint compares with what the element reads now.
    enum Verdict: Equatable {
        case current
        /// The control renamed itself after the agent acted on it: follow it.
        case refresh
        case stale
    }

    /// How long after the agent's own action a name-only change on that very handle counts
    /// as the control's response to it (a toggle relabelling, a SwiftUI re-render a frame
    /// or two later) rather than as a recycled ref.
    static let selfChangeWindow: TimeInterval = 2

    static func verdict(
        registered: AXElementFingerprint,
        live: AXElementFingerprint,
        actedAt: Date?,
        now: Date
    ) -> Verdict {
        guard registered.isStale(comparedTo: live) else { return .current }
        guard let actedAt, now.timeIntervalSince(actedAt) <= selfChangeWindow, registered.isSameControl(as: live) else {
            return .stale
        }
        return .refresh
    }

    private var handles: [String: Entry] = [:]
    private var seq = 0

    private init() {}

    /// Mint ids from the same monotonic sequence AX snapshots use, so a CDP/bpy/idb
    /// `e12` can never collide with an AX `e12` from a later snapshot.
    public func allocateIDs(count: Int) -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(count)
        for _ in 0..<count {
            seq += 1
            ids.append("e\(seq)")
        }
        return ids
    }

    /// Replace ONE app's handles with a fresh snapshot (other apps' handles survive, so
    /// interleaved two-app testing doesn't churn ids). Returns the assigned ids, in
    /// input order. `fingerprints` is parallel to `elements`; a nil or missing entry
    /// registers the handle without identity checking.
    @discardableResult
    public func replace(with elements: [AXElement], fingerprints: [AXElementFingerprint?] = [], pid: pid_t) -> [String] {
        handles = handles.filter { $0.value.pid != pid && AXElement.isProcessAlive($0.value.pid) }
        let ids = allocateIDs(count: elements.count)
        for (i, (id, element)) in zip(ids, elements).enumerated() {
            let fingerprint = i < fingerprints.count ? fingerprints[i] : nil
            handles[id] = Entry(pid: pid, element: element, fingerprint: fingerprint)
        }
        return ids
    }

    /// Resolve a handle id to its element, or nil if unknown, its app is gone, or the ref
    /// no longer points at the control that was registered.
    public func resolve(_ id: String) async -> AXElement? {
        if case .live(let element) = await lookup(id) { return element }
        return nil
    }

    /// `resolve`, additionally requiring the handle to belong to `pid` — an id minted for
    /// one app must not drive another because the caller passed a different `app`.
    public func resolve(_ id: String, pid: pid_t) async -> AXElement? {
        if case .live(let element) = await lookup(id, expectedPID: pid) { return element }
        return nil
    }

    /// `resolve` that says WHY a handle did not resolve: dead (re-snapshot) or not answering
    /// (try again).
    public func lookup(_ id: String, expectedPID: pid_t? = nil) async -> Resolution {
        guard let entry = handles[id] else { return .stale }
        if let expectedPID, entry.pid != expectedPID { return .stale }
        guard AXElement.isProcessAlive(entry.pid) else {
            handles = handles.filter { $0.value.pid != entry.pid }
            return .stale
        }
        // The comparison read is AX IPC, so it runs on the app's lane rather than on this
        // actor's cooperative thread.
        let element = entry.element
        enum Reading: Sendable {
            case live(AXElementFingerprint)
            case unresponsive
            case gone
        }
        let reading: Reading = await AXExecutor.app(entry.pid).run {
            if let live = AXElementFingerprint(reading: element) { return .live(live) }
            return element.liveness() == .gone ? .gone : .unresponsive
        }
        let live: AXElementFingerprint
        switch reading {
        case .unresponsive: return .busy
        case .gone: return .stale
        case .live(let fingerprint): live = fingerprint
        }
        // Reentrancy: another call may have replaced the handles while the read was out.
        guard var current = handles[id], current.pid == entry.pid else { return .stale }
        if let registered = current.fingerprint {
            switch Self.verdict(registered: registered, live: live, actedAt: current.actedAt, now: Date()) {
            case .current:
                break
            case .refresh:
                current.fingerprint = live
                handles[id] = current
            case .stale:
                handles[id] = nil
                return .stale
            }
        }
        return .live(element)
    }

    /// The agent just acted through `id`. Re-reads the control straight away so a relabel
    /// that has already happened is not mistaken for a recycled ref on the next step, and
    /// stamps the time so one that lands a moment later (see `verdict`) is followed too.
    public func noteActed(_ id: String) async {
        guard let entry = handles[id] else { return }
        let element = entry.element
        let live = await AXExecutor.app(entry.pid).run { AXElementFingerprint(reading: element) }
        guard var current = handles[id], current.pid == entry.pid else { return }
        current.actedAt = Date()
        if current.fingerprint != nil, let live { current.fingerprint = live }
        handles[id] = current
    }
}
