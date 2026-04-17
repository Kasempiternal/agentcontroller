import ApplicationServices
import Foundation

public final class AXElement: @unchecked Sendable {
    public let ref: AXUIElement

    public init(_ ref: AXUIElement) {
        self.ref = ref
    }

    public static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }

    public static func systemWide() -> AXElement {
        AXElement(AXUIElementCreateSystemWide())
    }

    // MARK: - Attributes

    public func attribute<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(ref, name as CFString, &value)
        guard result == .success, let value else { return nil }
        return value as? T
    }

    public func setAttribute(_ name: String, value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(ref, name as CFString, value) == .success
    }

    /// Batched read — single XPC round-trip for N attributes instead of N.
    /// Returns a dict keyed by attribute name; missing/unsupported attributes are absent.
    public func readAttributes(_ names: [String]) -> [String: CFTypeRef] {
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            ref,
            names as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), // don't stop on error; return markers
            &values
        )
        guard result == .success, let values else { return [:] }
        let count = CFArrayGetCount(values)
        var out: [String: CFTypeRef] = [:]
        for i in 0..<min(count, names.count) {
            guard let ptr = CFArrayGetValueAtIndex(values, i) else { continue }
            let value = Unmanaged<CFTypeRef>.fromOpaque(ptr).takeUnretainedValue()
            // Skip AXValueAttributeUnsupported / AXValueIllegalArgument markers (they're CFError)
            if CFGetTypeID(value) == CFErrorGetTypeID() { continue }
            out[names[i]] = value
        }
        return out
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
        guard let children: CFArray = attribute(kAXChildrenAttribute) else { return [] }
        let count = CFArrayGetCount(children)
        return (0..<count).compactMap { i in
            guard let ptr = CFArrayGetValueAtIndex(children, i) else { return nil }
            let element = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
            return AXElement(element)
        }
    }

    public var parent: AXElement? {
        guard let p: AXUIElement = attribute(kAXParentAttribute) else { return nil }
        return AXElement(p)
    }

    public var windows: [AXElement] {
        guard let windows: CFArray = attribute(kAXWindowsAttribute) else { return [] }
        let count = CFArrayGetCount(windows)
        return (0..<count).compactMap { i in
            guard let ptr = CFArrayGetValueAtIndex(windows, i) else { return nil }
            let element = Unmanaged<AXUIElement>.fromOpaque(ptr).takeUnretainedValue()
            return AXElement(element)
        }
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
