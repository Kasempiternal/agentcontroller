import ApplicationServices
import Foundation
import MCPServer

public final class AXElement: @unchecked Sendable {
    /// Default AX messaging timeout for tool-handler app elements. Low enough that a
    /// hung target app fails fast instead of blocking the MCP server at the 6s default.
    public static let defaultToolTimeout: Float = 2.0

    public let ref: AXUIElement

    public init(_ ref: AXUIElement) {
        self.ref = ref
    }

    public static func application(pid: pid_t, timeout: Float? = nil) -> AXElement {
        let element = AXElement(AXUIElementCreateApplication(pid))
        if let timeout {
            _ = AXUIElementSetMessagingTimeout(element.ref, timeout)
        }
        return element
    }

    public static func systemWide() -> AXElement {
        AXElement(AXUIElementCreateSystemWide())
    }

    /// Install a process-wide AX messaging-timeout floor. Setting the timeout on
    /// the system-wide element makes it the default for every AXUIElementRef this
    /// process touches (per-element overrides still win). Without it, only the
    /// app roots created via `application(pid:timeout:)` are bounded — every
    /// child ref produced during tree walks and searches runs at the ~6s system
    /// default, so a single hung target app could stall a whole snapshot/find.
    /// Call once at app startup.
    public static func installProcessWideTimeoutFloor(_ seconds: Float = defaultToolTimeout) {
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    /// Unwrap a CF array of AXUIElement refs into Swift `AXElement` wrappers.
    /// Shared helper for `children`, `windows`, and batched tree reads.
    public static func elements(fromCFArray cf: CFTypeRef?) -> [AXElement] {
        guard let cf, CFGetTypeID(cf) == CFArrayGetTypeID() else { return [] }
        let array = cf as! CFArray
        let count = CFArrayGetCount(array)
        return (0..<count).compactMap { i in
            guard let ptr = CFArrayGetValueAtIndex(array, i) else { return nil }
            let ref = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
            return AXElement(ref)
        }
    }

    // MARK: - Attributes

    /// Every read funnels through here so the busy-retry and the stall breaker are
    /// decided in one place. `call` performs one AX copy and reports its `AXError`.
    ///
    /// `.cannotComplete` means two different things and they need opposite answers:
    /// - it comes back in a few ms when the target is momentarily busy (mid-layout,
    ///   main thread blocked) — worth a short retry, or callers report a phantom
    ///   "element not found";
    /// - it comes back only after the whole messaging timeout when the target is hung —
    ///   retrying that three times turned the 2s timeout into ~6s per attribute, and a
    ///   walk reads thousands of attributes.
    /// The elapsed time of the failed call tells them apart (`AXTransientRetry`). A stall
    /// also opens the per-pid `AXStallBreaker`, so the rest of a walk against a hung app
    /// fails in microseconds instead of paying the timeout once per node.
    private func guardedRead<V>(_ call: (inout V?) -> AXError) -> V? {
        let pid = breakerPID
        if let pid, AXStallBreaker.shared.isOpen(pid: pid) { return nil }
        var attempt = 1
        while true {
            var out: V?
            let started = AXTransientRetry.nowNanos()
            let result = call(&out)
            if result == .success { return out }
            let elapsed = AXTransientRetry.nowNanos() &- started
            if AXTransientRetry.isStall(result: result, elapsedNanos: elapsed) {
                if let pid { AXStallBreaker.shared.trip(pid: pid) }
                return nil
            }
            guard AXTransientRetry.shouldRetry(result: result, elapsedNanos: elapsed, attempt: attempt) else {
                return nil
            }
            usleep(AXTransientRetry.backoffMicros)
            attempt += 1
        }
    }

    /// The owning process, for breaker bookkeeping. Nil for the system-wide element,
    /// which has no single pid to quarantine.
    private var breakerPID: pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(ref, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    public enum Liveness: Sendable, Equatable {
        case alive
        /// The app answered that this element no longer exists (`.invalidUIElement` and kin).
        case gone
        /// The app did not answer: its stall breaker is open, or it replied `.cannotComplete`
        /// (busy mid-layout, or hung). Says nothing about the element itself.
        case unresponsive
    }

    /// Why a read of this element came back empty, from one role read with no retry.
    /// The retrying reads cannot tell a destroyed element from an app that did not answer,
    /// and the two need opposite recoveries (re-snapshot vs. try again).
    public func liveness() -> Liveness {
        if let pid = breakerPID, AXStallBreaker.shared.isOpen(pid: pid) { return .unresponsive }
        var out: CFTypeRef?
        switch AXUIElementCopyAttributeValue(ref, kAXRoleAttribute as CFString, &out) {
        case .success: return .alive
        case .cannotComplete: return .unresponsive
        default: return .gone
        }
    }

    /// False once the process has exited. `EPERM` still means "exists".
    public static func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    public func attribute<T>(_ name: String) -> T? {
        let value: CFTypeRef? = guardedRead { AXUIElementCopyAttributeValue(ref, name as CFString, &$0) }
        return value as? T
    }

    public func setAttribute(_ name: String, value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(ref, name as CFString, value) == .success
    }

    /// Batched multi-attribute read via AXUIElementCopyMultipleAttributeValues.
    /// Missing and unsupported attributes are absent from the returned dict.
    public func readAttributes(_ names: [String]) -> [String: CFTypeRef] {
        // rawValue 0: return CFError markers for missing attrs instead of bailing on first error.
        // This is the hot path (one call per node in tree/search), so a flaky
        // `.cannotComplete` here would otherwise drop a whole node's attributes.
        let values: CFArray? = guardedRead {
            AXUIElementCopyMultipleAttributeValues(
                ref, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &$0
            )
        }
        guard let values else { return [:] }
        let count = CFArrayGetCount(values)
        var out: [String: CFTypeRef] = [:]
        for i in 0..<min(count, names.count) {
            guard let ptr = CFArrayGetValueAtIndex(values, i) else { continue }
            let value = Unmanaged<CFTypeRef>.fromOpaque(ptr).takeUnretainedValue()
            if CFGetTypeID(value) == CFErrorGetTypeID() { continue }
            out[names[i]] = value
        }
        return out
    }

    /// The element's `kAXValueAttribute` classified into a `JSONValue`, regardless of
    /// the underlying CF type. `stringValue` only surfaces `String` values, so
    /// checkbox / radio / disclosure state (NSNumber 0/1), slider / stepper positions
    /// (NSNumber double) and Bool toggles are silently dropped — a real gap for a QA
    /// tool that needs to assert toggle / slider state. This reads the raw CFTypeRef
    /// once and maps it: String → .string, Bool → .bool, integral number → .int,
    /// fractional number → .double. AXValue point/size and other types yield nil.
    /// `stringValue: String?` is unchanged for back-compat.
    public var valueJSON: JSONValue? {
        let raw: CFTypeRef? = guardedRead { AXUIElementCopyAttributeValue(ref, kAXValueAttribute as CFString, &$0) }
        return AXValueExtract.jsonValue(raw)
    }

    public var role: String? { attribute(kAXRoleAttribute) }
    public var subrole: String? { attribute(kAXSubroleAttribute) }
    public var title: String? { attribute(kAXTitleAttribute) }
    public var value: CFTypeRef? { attribute(kAXValueAttribute) }
    public var stringValue: String? { attribute(kAXValueAttribute) }
    public var roleDescription: String? { attribute(kAXRoleDescriptionAttribute) }
    public var identifier: String? { attribute(kAXIdentifierAttribute) }
    public var help: String? { attribute(kAXHelpAttribute) }
    public var label: String? { attribute(kAXDescriptionAttribute) }
    public var isEnabled: Bool { (attribute(kAXEnabledAttribute) as Bool?) ?? true }
    public var isFocused: Bool { (attribute(kAXFocusedAttribute) as Bool?) ?? false }

    public var position: CGPoint? {
        guard let value: AXValue = attribute(kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value, .cgPoint, &point)
        return point
    }

    public var size: CGSize? {
        guard let value: AXValue = attribute(kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value, .cgSize, &size)
        return size
    }

    public var frame: CGRect? {
        guard let pos = position, let sz = size else { return nil }
        return CGRect(origin: pos, size: sz)
    }

    public func setPosition(_ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return setAttribute(kAXPositionAttribute, value: value)
    }

    public func setSize(_ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return setAttribute(kAXSizeAttribute, value: value)
    }

    // MARK: - Children

    public var children: [AXElement] {
        Self.elements(fromCFArray: attribute(kAXChildrenAttribute) as CFTypeRef?)
    }

    public var parent: AXElement? {
        guard let p: AXUIElement = attribute(kAXParentAttribute) else { return nil }
        return AXElement(p)
    }

    public var windows: [AXElement] {
        Self.elements(fromCFArray: attribute(kAXWindowsAttribute) as CFTypeRef?)
    }

    public var focusedWindow: AXElement? {
        guard let w: AXUIElement = attribute(kAXFocusedWindowAttribute) else { return nil }
        return AXElement(w)
    }

    public var menuBar: AXElement? {
        guard let m: AXUIElement = attribute(kAXMenuBarAttribute) else { return nil }
        return AXElement(m)
    }

    // MARK: - Actions

    public var actionNames: [String] {
        let names: CFArray? = guardedRead { AXUIElementCopyActionNames(ref, &$0) }
        return names as? [String] ?? []
    }

    public func performAction(_ name: String) -> Bool {
        AXUIElementPerformAction(ref, name as CFString) == .success
    }

    public func press() -> Bool { performAction(kAXPressAction) }
    public func showMenu() -> Bool { performAction(kAXShowMenuAction) }
    public func raise() -> Bool { performAction(kAXRaiseAction) }
    public func confirm() -> Bool { performAction(kAXConfirmAction) }
    public func cancel() -> Bool { performAction(kAXCancelAction) }

    // MARK: - Attribute Names

    public var attributeNames: [String] {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(ref, &names)
        guard result == .success, let names else { return [] }
        return names as? [String] ?? []
    }

    // MARK: - JSON Serialization

    public func toJSON(maxDepth: Int = 3, currentDepth: Int = 0) -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["role"] = role ?? "unknown"
        if let t = title, !t.isEmpty { dict["title"] = t }
        if let id = identifier, !id.isEmpty { dict["identifier"] = id }
        if let v = stringValue, !v.isEmpty { dict["value"] = v }
        if let l = label, !l.isEmpty { dict["description"] = l }
        if let rd = roleDescription, !rd.isEmpty { dict["roleDescription"] = rd }
        if let pos = position { dict["position"] = ["x": pos.x, "y": pos.y] }
        if let sz = size { dict["size"] = ["width": sz.width, "height": sz.height] }
        dict["enabled"] = isEnabled
        if isFocused { dict["focused"] = true }

        let actions = actionNames
        if !actions.isEmpty { dict["actions"] = actions }

        if currentDepth < maxDepth {
            let kids = children
            if !kids.isEmpty {
                dict["children"] = kids.map { $0.toJSON(maxDepth: maxDepth, currentDepth: currentDepth + 1) }
            }
        }

        return dict
    }
}

/// Extract `CGPoint` / `CGSize` from raw AXValue CFTypeRefs returned by batched
/// reads. Swift rejects `as? AXValue` (CF downcasts always succeed syntactically),
/// so the guard uses `CFGetTypeID`.
public enum AXValueExtract {
    public static func point(_ cf: CFTypeRef?) -> CGPoint? {
        guard let cf, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        let ax = cf as! AXValue
        guard AXValueGetType(ax) == .cgPoint else { return nil }
        var p = CGPoint.zero
        AXValueGetValue(ax, .cgPoint, &p)
        return p
    }

    public static func size(_ cf: CFTypeRef?) -> CGSize? {
        guard let cf, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        let ax = cf as! AXValue
        guard AXValueGetType(ax) == .cgSize else { return nil }
        var s = CGSize.zero
        AXValueGetValue(ax, .cgSize, &s)
        return s
    }

    /// Classify a raw `kAXValueAttribute` CFTypeRef into a `JSONValue`. Used by
    /// `AXElement.valueJSON` and by `AXElementTree.nodeToJSON` so that non-string
    /// values (toggle / radio / slider / stepper state arriving as CFBoolean /
    /// CFNumber) surface instead of being dropped.
    /// - String → `.string`
    /// - CFBoolean → `.bool`
    /// - CFNumber → `.int` (integral) or `.double` (fractional)
    /// - AXValue point / size → `.object` describing the geometry
    /// - anything else → nil
    public static func jsonValue(_ cf: CFTypeRef?) -> JSONValue? {
        guard let cf else { return nil }
        let typeID = CFGetTypeID(cf)

        if typeID == CFStringGetTypeID() {
            return .string(cf as! String)
        }
        if typeID == CFBooleanGetTypeID() {
            return .bool(CFBooleanGetValue((cf as! CFBoolean)))
        }
        if typeID == CFNumberGetTypeID() {
            let num = cf as! CFNumber
            if CFNumberIsFloatType(num) {
                var d = 0.0
                CFNumberGetValue(num, .doubleType, &d)
                return .double(d)
            } else {
                var i = 0
                CFNumberGetValue(num, .nsIntegerType, &i)
                return .int(i)
            }
        }
        if typeID == AXValueGetTypeID() {
            if let p = point(cf) {
                return .object(["x": .double(p.x), "y": .double(p.y)])
            }
            if let s = size(cf) {
                return .object(["width": .double(s.width), "height": .double(s.height)])
            }
            return nil
        }
        return nil
    }
}

/// When a failed AX read is worth repeating, decided from how long the failed call took.
/// Pure so the thresholds are testable without a hung app.
enum AXTransientRetry {
    static let maxAttempts = 3
    static let backoffMicros: useconds_t = 18_000

    /// A `.cannotComplete` that came back faster than this was the target being busy
    /// right now; one that took longer was waiting on the messaging timeout.
    static let busyCeilingNanos: UInt64 = 50_000_000

    /// A `.cannotComplete` that took at least this long counts as a stall: 90% of the
    /// default tool timeout (2s). A hung app only answers when the messaging timeout
    /// expires, so it still trips the breaker on its first read. The old floor (0.5s)
    /// also caught apps that were merely SLOW — Safari mid-page-load answers in 0.5-1.9s —
    /// and the open breaker then failed every read for 1.5s: a snapshot taken right after
    /// opening a page came back with 0 elements, not even the menu bar.
    static let stallFloorNanos: UInt64 = 1_800_000_000

    static func nowNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Only `.cannotComplete` is ever retried; `.attributeUnsupported` / `.noValue` /
    /// `.invalidUIElement` are stable answers.
    static func shouldRetry(result: AXError, elapsedNanos: UInt64, attempt: Int) -> Bool {
        result == .cannotComplete && elapsedNanos < busyCeilingNanos && attempt < maxAttempts
    }

    static func isStall(result: AXError, elapsedNanos: UInt64) -> Bool {
        result == .cannotComplete && elapsedNanos >= stallFloorNanos
    }
}

/// Per-pid circuit breaker for hung target apps.
///
/// A hung app answers every read only after the messaging timeout, so a 600-node walk
/// costs 600 x 2s. After one stall, reads against that pid return nothing immediately for
/// `window` seconds; the first read after the window is the probe that finds out whether
/// the app recovered. Callers already treat an empty read as "unreadable", so no new
/// failure mode is introduced — the walk just ends quickly instead of eventually.
final class AXStallBreaker: @unchecked Sendable {
    static let shared = AXStallBreaker()
    static let windowNanos: UInt64 = 1_500_000_000

    private let lock = NSLock()
    private var openUntil: [pid_t: UInt64] = [:]
    private let clock: @Sendable () -> UInt64

    init(clock: @escaping @Sendable () -> UInt64 = { AXTransientRetry.nowNanos() }) {
        self.clock = clock
    }

    func isOpen(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = openUntil[pid] else { return false }
        if clock() < until { return true }
        openUntil[pid] = nil
        return false
    }

    func trip(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        // Expired entries for other pids would otherwise accumulate across a long session.
        openUntil = openUntil.filter { $0.value > now }
        openUntil[pid] = now &+ Self.windowNanos
    }
}
