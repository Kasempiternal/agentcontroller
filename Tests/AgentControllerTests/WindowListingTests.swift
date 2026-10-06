import XCTest
import ApplicationServices
@testable import AccessibilityEngine

/// list_windows ran every app's AX reads serially on the MainActor, five single reads per
/// window; one hung app froze the menu bar. These cover the pure pieces of the replacement
/// (batched-read decoding, the per-app deadline) and one live call.
final class WindowListingTests: XCTestCase {

    private let app = WindowManager.AppIdentity(pid: 321, name: "Notes", bundleId: "com.apple.Notes")

    private func axPoint(_ x: Double, _ y: Double) -> CFTypeRef {
        var p = CGPoint(x: x, y: y)
        return AXValueCreate(.cgPoint, &p)!
    }

    private func axSize(_ w: Double, _ h: Double) -> CFTypeRef {
        var s = CGSize(width: w, height: h)
        return AXValueCreate(.cgSize, &s)!
    }

    func testBatchedAttributesDecodeIntoAWindowInfo() {
        let attrs: [String: CFTypeRef] = [
            kAXTitleAttribute: "Inbox" as CFString,
            kAXPositionAttribute: axPoint(10, 20),
            kAXSizeAttribute: axSize(800, 600),
            kAXMinimizedAttribute: kCFBooleanTrue,
            "AXFullScreen": kCFBooleanFalse,
        ]
        let info = WindowManager.windowInfo(attributes: attrs, app: app, source: .accessibility(index: 2))
        XCTAssertEqual(info.title, "Inbox")
        XCTAssertEqual(info.bounds, CGRect(x: 10, y: 20, width: 800, height: 600))
        XCTAssertTrue(info.isMinimized)
        XCTAssertFalse(info.isFullScreen)
        XCTAssertEqual(info.appName, "Notes")
        XCTAssertEqual(info.appBundleId, "com.apple.Notes")
        XCTAssertEqual(info.pid, 321)
        XCTAssertEqual(info.source, .accessibility(index: 2))
    }

    func testMissingAttributesFallBackToTheDocumentedDefaults() {
        let info = WindowManager.windowInfo(attributes: [:], app: app, source: .focusedWindow)
        XCTAssertEqual(info.title, "Untitled")
        XCTAssertEqual(info.bounds, .zero)
        XCTAssertFalse(info.isMinimized)
        XCTAssertFalse(info.isFullScreen)
        XCTAssertNil(info.source.index)
    }

    // MARK: - Deadline

    func testFastWorkWinsTheRace() async {
        let value = await WindowManager.withDeadline(5, fallback: "fallback") {
            try? await AXExecutor.pause(0.01)
            return "work"
        }
        XCTAssertEqual(value, "work")
    }

    func testSlowWorkLosesToTheFallbackAtTheDeadline() async {
        let start = Date()
        let value = await WindowManager.withDeadline(0.1, fallback: "fallback") {
            try? await AXExecutor.pause(2)
            return "work"
        }
        XCTAssertEqual(value, "fallback")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "the caller waited on the hung work instead of the deadline")
    }

    func testListingOneAppCompletesAndStaysInsideThatApp() async {
        // The test process itself: no windows, but a real pid through the real code path.
        let windows = await WindowManager.listWindows(pid: getpid())
        XCTAssertTrue(windows.allSatisfy { $0.pid == getpid() })
    }

    func testListingEveryAppCompletesWithinTheDeadlineBudget() async {
        let start = Date()
        _ = await WindowManager.listWindows()
        // Apps run in parallel, each capped at perAppDeadline; serial-on-main would scale
        // with the app count instead.
        XCTAssertLessThan(Date().timeIntervalSince(start), WindowManager.perAppDeadline + 5)
    }
}
