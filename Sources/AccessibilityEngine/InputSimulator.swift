import CoreGraphics
import Foundation
import Carbon.HIToolbox

public struct InputSimulator {
    // MARK: - Event delivery

    /// Deliver a synthetic CGEvent either to ONE target process (background-safe) or to
    /// the global HID stream (intrusive).
    ///
    /// - When `pid` is non-nil we call `CGEvent.postToPid(_:)` — the event object is
    ///   handed directly to that process's event queue. This does NOT move the system
    ///   mouse cursor and does NOT require the target to be frontmost, so it never
    ///   disturbs the user's focus or pointer. This is the default for all tool input.
    /// - When `pid` is nil we fall back to `post(tap: .cghidEventTap)`, which injects
    ///   into the system-wide HID stream: it moves the real cursor for mouse events and
    ///   is delivered to whatever app is frontmost. Only used behind an explicit
    ///   `foreground:true` escape hatch for apps that ignore per-process delivery
    ///   (Electron / games / Secure-Input contexts).
    @inline(__always)
    private static func deliver(_ event: CGEvent, toPid pid: pid_t?) {
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Mouse

    /// Click at a point. When `pid` is provided (default for tool use) the down/up
    /// events go to that process via `postToPid` — no cursor warp, no frontmost
    /// requirement. Pass `pid: nil` only for the explicit global/foreground path.
    public static func click(at point: CGPoint, button: CGMouseButton = .left, clickCount: Int = 1, pid: pid_t? = nil) {
        let downType: CGEventType
        let upType: CGEventType

        switch button {
        case .left:
            downType = .leftMouseDown
            upType = .leftMouseUp
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
        default:
            downType = .otherMouseDown
            upType = .otherMouseUp
        }

        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: button),
              let mouseUp = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: button) else {
            return
        }

        mouseDown.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        mouseUp.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))

        deliver(mouseDown, toPid: pid)
        deliver(mouseUp, toPid: pid)
    }

    public static func doubleClick(at point: CGPoint, pid: pid_t? = nil) {
        click(at: point, clickCount: 1, pid: pid)
        usleep(50_000) // 50ms
        click(at: point, clickCount: 2, pid: pid)
    }

    public static func rightClick(at point: CGPoint, pid: pid_t? = nil) {
        click(at: point, button: .right, pid: pid)
    }

    // MARK: - Keyboard

    /// Type text. When `pid` is provided (default for tool use) each character's
    /// key-down/up is delivered to that process via `postToPid` — no global HID
    /// injection, no frontmost requirement (the target control must already hold the
    /// app's internal focus). Pass `pid: nil` for the explicit global/foreground path.
    public static func typeText(_ text: String, pid: pid_t? = nil) {
        // Per-char posting because some text targets (Electron, legacy Carbon) drop
        // bursts of Unicode events. 1ms pacer is defensive; modern AppKit handles zero-gap.
        // NOTE: the per-char `usleep` is intentional and now runs on the AXExecutor
        // serial thread (never the MainActor), so it no longer freezes the menu-bar UI.
        for char in text {
            let chars = Array(String(char).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
            deliver(down, toPid: pid)
            deliver(up, toPid: pid)
            usleep(1_000)
        }
    }

    /// Clear the focused text field before typing so a re-run replaces rather than
    /// appends (the CGEvent type path otherwise inserts at the caret, doubling text on
    /// repeat). Select-all (Cmd+A) then forward-delete leaves an empty field. When `pid`
    /// is provided the keystrokes are delivered to that process via `postToPid` (no
    /// global tap, no frontmost requirement).
    public static func clearFocusedField(pid: pid_t? = nil) {
        sendShortcut(keyCode: CGKeyCode(kVK_ANSI_A), modifiers: .maskCommand, pid: pid)
        usleep(5_000)
        pressKey(CGKeyCode(kVK_ForwardDelete), pid: pid)
    }

    /// Send a key chord. When `pid` is provided (default for tool use) the events are
    /// delivered to that process via `postToPid` so the chord lands in its queue without
    /// activating it or touching the global HID stream. Pass `pid: nil` for the explicit
    /// global/foreground path (system-wide hotkeys).
    public static func sendShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags, pid: pid_t? = nil) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }

        keyDown.flags = modifiers
        keyUp.flags = modifiers

        deliver(keyDown, toPid: pid)
        deliver(keyUp, toPid: pid)
    }

    public static func pressKey(_ keyCode: CGKeyCode, pid: pid_t? = nil) {
        sendShortcut(keyCode: keyCode, modifiers: [], pid: pid)
    }

    public static func pressEnter(pid: pid_t? = nil) { pressKey(CGKeyCode(kVK_Return), pid: pid) }
    public static func pressEscape(pid: pid_t? = nil) { pressKey(CGKeyCode(kVK_Escape), pid: pid) }
    public static func pressTab(pid: pid_t? = nil) { pressKey(CGKeyCode(kVK_Tab), pid: pid) }
    public static func pressDelete(pid: pid_t? = nil) { pressKey(CGKeyCode(kVK_Delete), pid: pid) }

    // MARK: - Scroll

    /// Scroll at a point. When `pid` is provided (default for tool use) the scroll-wheel
    /// event is delivered to that process via `postToPid` and NO `mouseMoved` warp is
    /// posted — the real cursor never moves. Only the global/foreground path (`pid: nil`)
    /// warps the cursor to the scroll point first, because the global HID scroll lands
    /// on whatever window is under the pointer.
    public static func scroll(at point: CGPoint, deltaX: Int32 = 0, deltaY: Int32, pid: pid_t? = nil) {
        // Global path only: the HID scroll lands under the cursor, so move it there.
        // The PID-targeted path skips this entirely — no cursor movement.
        if pid == nil,
           let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else {
            return
        }
        scrollEvent.location = point
        deliver(scrollEvent, toPid: pid)
    }

    // MARK: - Drag

    /// Drag from `start` to `end`. When `pid` is provided the down/drag/up events are
    /// delivered to that process via `postToPid`, so the real cursor is NOT warped and
    /// the app is not activated. NOTE: a drag inherently carries a cursor position, and
    /// many apps poll the real OS pointer mid-drag, so a PID-targeted drag with a
    /// stationary real pointer can desync — drags are the least reliable synthetic
    /// gesture and should be gated behind explicit user intent.
    public static func drag(from start: CGPoint, to end: CGPoint, duration: TimeInterval = 0.3, pid: pid_t? = nil) {
        let steps = max(Int(duration * 60), 10) // ~60fps

        // Mouse down at start
        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) else { return }
        deliver(mouseDown, toPid: pid)

        // Drag
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            let point = CGPoint(x: x, y: y)

            guard let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) else { continue }
            deliver(drag, toPid: pid)
            usleep(UInt32(duration / Double(steps) * 1_000_000))
        }

        // Mouse up at end
        guard let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else { return }
        deliver(mouseUp, toPid: pid)
    }

    // MARK: - Key Code Mapping

    public static func keyCode(for key: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A), "b": CGKeyCode(kVK_ANSI_B), "c": CGKeyCode(kVK_ANSI_C),
            "d": CGKeyCode(kVK_ANSI_D), "e": CGKeyCode(kVK_ANSI_E), "f": CGKeyCode(kVK_ANSI_F),
            "g": CGKeyCode(kVK_ANSI_G), "h": CGKeyCode(kVK_ANSI_H), "i": CGKeyCode(kVK_ANSI_I),
            "j": CGKeyCode(kVK_ANSI_J), "k": CGKeyCode(kVK_ANSI_K), "l": CGKeyCode(kVK_ANSI_L),
            "m": CGKeyCode(kVK_ANSI_M), "n": CGKeyCode(kVK_ANSI_N), "o": CGKeyCode(kVK_ANSI_O),
            "p": CGKeyCode(kVK_ANSI_P), "q": CGKeyCode(kVK_ANSI_Q), "r": CGKeyCode(kVK_ANSI_R),
            "s": CGKeyCode(kVK_ANSI_S), "t": CGKeyCode(kVK_ANSI_T), "u": CGKeyCode(kVK_ANSI_U),
            "v": CGKeyCode(kVK_ANSI_V), "w": CGKeyCode(kVK_ANSI_W), "x": CGKeyCode(kVK_ANSI_X),
            "y": CGKeyCode(kVK_ANSI_Y), "z": CGKeyCode(kVK_ANSI_Z),
            "0": CGKeyCode(kVK_ANSI_0), "1": CGKeyCode(kVK_ANSI_1), "2": CGKeyCode(kVK_ANSI_2),
            "3": CGKeyCode(kVK_ANSI_3), "4": CGKeyCode(kVK_ANSI_4), "5": CGKeyCode(kVK_ANSI_5),
            "6": CGKeyCode(kVK_ANSI_6), "7": CGKeyCode(kVK_ANSI_7), "8": CGKeyCode(kVK_ANSI_8),
            "9": CGKeyCode(kVK_ANSI_9),
            "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
            "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
            "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
            "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
            "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
            "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
            "f1": CGKeyCode(kVK_F1), "f2": CGKeyCode(kVK_F2), "f3": CGKeyCode(kVK_F3),
            "f4": CGKeyCode(kVK_F4), "f5": CGKeyCode(kVK_F5), "f6": CGKeyCode(kVK_F6),
            "f7": CGKeyCode(kVK_F7), "f8": CGKeyCode(kVK_F8), "f9": CGKeyCode(kVK_F9),
            "f10": CGKeyCode(kVK_F10), "f11": CGKeyCode(kVK_F11), "f12": CGKeyCode(kVK_F12),
            "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
            "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
            "forwarddelete": CGKeyCode(kVK_ForwardDelete),
            "-": CGKeyCode(kVK_ANSI_Minus), "=": CGKeyCode(kVK_ANSI_Equal),
            "[": CGKeyCode(kVK_ANSI_LeftBracket), "]": CGKeyCode(kVK_ANSI_RightBracket),
            ";": CGKeyCode(kVK_ANSI_Semicolon), "'": CGKeyCode(kVK_ANSI_Quote),
            ",": CGKeyCode(kVK_ANSI_Comma), ".": CGKeyCode(kVK_ANSI_Period),
            "/": CGKeyCode(kVK_ANSI_Slash), "\\": CGKeyCode(kVK_ANSI_Backslash),
            "`": CGKeyCode(kVK_ANSI_Grave),
        ]
        return map[key.lowercased()]
    }

    public static func modifierFlags(from names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }
}
