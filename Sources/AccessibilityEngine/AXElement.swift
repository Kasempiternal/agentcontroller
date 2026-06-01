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

    /// Unwrap a CF array of AXUIElement refs into Swift `AXElement` wrappers.
    /// Shared helper for `children`, `windows`, and batched tree reads.
    static func elements(fromCFArray cf: CFTypeRef?) -> [AXElement] {
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

    /// Bounded retry for transient AX failures. `AXUIElementCopyAttributeValue` /
    /// `AXUIElementCopyMultipleAttributeValues` return `.cannotComplete` when the
    /// target app is momentarily busy (mid-layout, main thread blocked) — a one-shot
    /// read then sees nil and callers report a phantom "element not found". We retry
    /// ONLY `.cannotComplete` (never `.attributeUnsupported` / `.noValue` /
    /// `.invalidUIElement`, which are stable answers) with a short backoff. The first
    /// attempt is unconditional, so success-path latency is unchanged.
    private static let transientRetryAttempts = 3
    private static let transientRetryBackoffMicros: useconds_t = 18_000  // ~18ms

    public func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(ref, name as CFString, &value)
        var attempt = 1
        while result == .cannotComplete && attempt < Self.transientRetryAttempts {
            usleep(Self.transientRetryBackoffMicros)
            value = nil
            result = AXUIElementCopyAttributeValue(ref, name as CFString, &value)
            attempt += 1
        }
        guard result == .success, let value else { return nil }
        return value as? T
    }

    public func setAttribute(_ name: String, value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(ref, name as CFString, value) == .success
    }

    /// Batched multi-attribute read via AXUIElementCopyMultipleAttributeValues.
    /// Missing and unsupported attributes are absent from the returned dict.
    public func readAttributes(_ names: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        // rawValue 0: return CFError markers for missing attrs instead of bailing on first error
        var result = AXUIElementCopyMultipleAttributeValues(
            ref, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values
        )
        // Same transient-busy retry as `attribute(_:)`. This is the hot path (one call
        // per node in tree/search), so a flaky `.cannotComplete` here would otherwise
        // drop a whole node's attributes.
        var attempt = 1
        while result == .cannotComplete && attempt < Self.transientRetryAttempts {
            usleep(Self.transientRetryBackoffMicros)
            values = nil
            result = AXUIElementCopyMultipleAttributeValues(
                ref, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values
            )
            attempt += 1
        }
        guard result == .success, let values else { return [:] }
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
        var raw: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(ref, kAXValueAttribute as CFString, &raw)
        var attempt = 1
        while result == .cannotComplete && attempt < Self.transientRetryAttempts {
            usleep(Self.transientRetryBackoffMicros)
            raw = nil
            result = AXUIElementCopyAttributeValue(ref, kAXValueAttribute as CFString, &raw)
            attempt += 1
        }
        guard result == .success, let raw else { return nil }
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
        var names: CFArray?
        let result = AXUIElementCopyActionNames(ref, &names)
        guard result == .success, let names else { return [] }
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
