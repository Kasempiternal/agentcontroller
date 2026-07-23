import XCTest
import CoreGraphics
import Carbon.HIToolbox
@testable import AccessibilityEngine

/// Pure mapping tests for `InputSimulator.keyCode(for:)` and `.modifierFlags(from:)`.
/// These never post events — they only exercise the lookup tables, so no permissions needed.
final class InputSimulatorTests: XCTestCase {

    // MARK: - keyCode(for:)

    func testLetters() {
        XCTAssertEqual(InputSimulator.keyCode(for: "a"), CGKeyCode(kVK_ANSI_A))
        XCTAssertEqual(InputSimulator.keyCode(for: "z"), CGKeyCode(kVK_ANSI_Z))
        XCTAssertEqual(InputSimulator.keyCode(for: "m"), CGKeyCode(kVK_ANSI_M))
    }

    func testDigits() {
        XCTAssertEqual(InputSimulator.keyCode(for: "0"), CGKeyCode(kVK_ANSI_0))
        XCTAssertEqual(InputSimulator.keyCode(for: "5"), CGKeyCode(kVK_ANSI_5))
        XCTAssertEqual(InputSimulator.keyCode(for: "9"), CGKeyCode(kVK_ANSI_9))
    }

    func testNamedKeys() {
        XCTAssertEqual(InputSimulator.keyCode(for: "return"), CGKeyCode(kVK_Return))
        XCTAssertEqual(InputSimulator.keyCode(for: "enter"), CGKeyCode(kVK_Return))
        XCTAssertEqual(InputSimulator.keyCode(for: "tab"), CGKeyCode(kVK_Tab))
        XCTAssertEqual(InputSimulator.keyCode(for: "space"), CGKeyCode(kVK_Space))
        XCTAssertEqual(InputSimulator.keyCode(for: "escape"), CGKeyCode(kVK_Escape))
        XCTAssertEqual(InputSimulator.keyCode(for: "esc"), CGKeyCode(kVK_Escape))
        XCTAssertEqual(InputSimulator.keyCode(for: "delete"), CGKeyCode(kVK_Delete))
        XCTAssertEqual(InputSimulator.keyCode(for: "backspace"), CGKeyCode(kVK_Delete))
    }

    func testArrowAndNavKeys() {
        XCTAssertEqual(InputSimulator.keyCode(for: "up"), CGKeyCode(kVK_UpArrow))
        XCTAssertEqual(InputSimulator.keyCode(for: "down"), CGKeyCode(kVK_DownArrow))
        XCTAssertEqual(InputSimulator.keyCode(for: "left"), CGKeyCode(kVK_LeftArrow))
        XCTAssertEqual(InputSimulator.keyCode(for: "right"), CGKeyCode(kVK_RightArrow))
        XCTAssertEqual(InputSimulator.keyCode(for: "home"), CGKeyCode(kVK_Home))
        XCTAssertEqual(InputSimulator.keyCode(for: "end"), CGKeyCode(kVK_End))
        XCTAssertEqual(InputSimulator.keyCode(for: "pageup"), CGKeyCode(kVK_PageUp))
        XCTAssertEqual(InputSimulator.keyCode(for: "pagedown"), CGKeyCode(kVK_PageDown))
    }

    func testFunctionKeys() {
        XCTAssertEqual(InputSimulator.keyCode(for: "f1"), CGKeyCode(kVK_F1))
        XCTAssertEqual(InputSimulator.keyCode(for: "f12"), CGKeyCode(kVK_F12))
    }

    func testPunctuation() {
        XCTAssertEqual(InputSimulator.keyCode(for: "-"), CGKeyCode(kVK_ANSI_Minus))
        XCTAssertEqual(InputSimulator.keyCode(for: "="), CGKeyCode(kVK_ANSI_Equal))
        XCTAssertEqual(InputSimulator.keyCode(for: "["), CGKeyCode(kVK_ANSI_LeftBracket))
        XCTAssertEqual(InputSimulator.keyCode(for: "]"), CGKeyCode(kVK_ANSI_RightBracket))
        XCTAssertEqual(InputSimulator.keyCode(for: ";"), CGKeyCode(kVK_ANSI_Semicolon))
        XCTAssertEqual(InputSimulator.keyCode(for: "'"), CGKeyCode(kVK_ANSI_Quote))
        XCTAssertEqual(InputSimulator.keyCode(for: ","), CGKeyCode(kVK_ANSI_Comma))
        XCTAssertEqual(InputSimulator.keyCode(for: "."), CGKeyCode(kVK_ANSI_Period))
        XCTAssertEqual(InputSimulator.keyCode(for: "/"), CGKeyCode(kVK_ANSI_Slash))
        XCTAssertEqual(InputSimulator.keyCode(for: "\\"), CGKeyCode(kVK_ANSI_Backslash))
        XCTAssertEqual(InputSimulator.keyCode(for: "`"), CGKeyCode(kVK_ANSI_Grave))
    }

    func testCaseInsensitivity() {
        XCTAssertEqual(InputSimulator.keyCode(for: "A"), InputSimulator.keyCode(for: "a"))
        XCTAssertEqual(InputSimulator.keyCode(for: "RETURN"), CGKeyCode(kVK_Return))
        XCTAssertEqual(InputSimulator.keyCode(for: "Esc"), CGKeyCode(kVK_Escape))
        XCTAssertEqual(InputSimulator.keyCode(for: "F1"), CGKeyCode(kVK_F1))
    }

    func testUnknownKeyReturnsNil() {
        XCTAssertNil(InputSimulator.keyCode(for: ""))
        XCTAssertNil(InputSimulator.keyCode(for: "notakey"))
        XCTAssertNil(InputSimulator.keyCode(for: "f99"))
        XCTAssertNil(InputSimulator.keyCode(for: "ctrl"))
    }

    // MARK: - modifierFlags(from:)

    func testCommandAliases() {
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["cmd"]), .maskCommand)
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["command"]), .maskCommand)
    }

    func testShift() {
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["shift"]), .maskShift)
    }

    func testOptionAliases() {
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["opt"]), .maskAlternate)
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["option"]), .maskAlternate)
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["alt"]), .maskAlternate)
    }

    func testControlAliases() {
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["ctrl"]), .maskControl)
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["control"]), .maskControl)
    }

    func testFunction() {
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["fn"]), .maskSecondaryFn)
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["function"]), .maskSecondaryFn)
    }

    func testCaseInsensitiveModifiers() {
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["CMD"]), .maskCommand)
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["Shift"]), .maskShift)
    }

    func testUnknownModifierIsEmpty() {
        XCTAssertEqual(InputSimulator.modifierFlags(from: []), [])
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["nope"]), [])
        // Unknown entries are silently ignored, valid ones still apply.
        XCTAssertEqual(InputSimulator.modifierFlags(from: ["nope", "cmd"]), .maskCommand)
    }

    func testCombinations() {
        let cmdShift = InputSimulator.modifierFlags(from: ["cmd", "shift"])
        XCTAssertEqual(cmdShift, [.maskCommand, .maskShift])

        let all = InputSimulator.modifierFlags(from: ["command", "shift", "option", "control"])
        XCTAssertEqual(all, [.maskCommand, .maskShift, .maskAlternate, .maskControl])

        // Order independence.
        XCTAssertEqual(
            InputSimulator.modifierFlags(from: ["shift", "cmd"]),
            InputSimulator.modifierFlags(from: ["cmd", "shift"])
        )
    }
}
