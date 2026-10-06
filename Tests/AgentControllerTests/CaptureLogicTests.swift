import CoreGraphics
import ScreenCaptureKit
import XCTest
@testable import MCPTools
@testable import ScreenCapture

/// The capture path's decisions that can be checked without a screen: how big to ask
/// ScreenCaptureKit for, which window a hint means, when a cached window listing may be
/// trusted, and the small concurrency primitives the recorder leans on.
final class CaptureSizingTests: XCTestCase {

    // MARK: - Output size

    /// The case that motivated asking for the final size: a full-width window on a
    /// 1728x1117pt retina display was captured at 3456x2160 then shrunk on the CPU.
    func testLargeWindowIsRequestedAtTheCapNotAtNativeResolution() {
        let size = CaptureSizing.pixelSize(points: CGSize(width: 1728, height: 1080), backingScale: 2, maxLongestSide: 1400)
        XCTAssertEqual(size.width, 1400)
        XCTAssertEqual(size.height, 875)
    }

    func testWindowSmallerThanTheCapKeepsNativeRetinaResolution() {
        let size = CaptureSizing.pixelSize(points: CGSize(width: 600, height: 400), backingScale: 2, maxLongestSide: 1400)
        XCTAssertEqual(size.width, 1200)
        XCTAssertEqual(size.height, 800)
    }

    func testWindowBetweenOneAndTwoTimesTheCapIsReducedBelowBackingScale() {
        let size = CaptureSizing.pixelSize(points: CGSize(width: 800, height: 600), backingScale: 2, maxLongestSide: 1400)
        XCTAssertEqual(size.width, 1400)
        XCTAssertEqual(size.height, 1050)
    }

    /// Asking for more than the display has would only interpolate.
    func testNeverRequestsMoreThanTheBackingScale() {
        let size = CaptureSizing.pixelSize(points: CGSize(width: 500, height: 300), backingScale: 2, maxLongestSide: 4000)
        XCTAssertEqual(size.width, 1000)
        XCTAssertEqual(size.height, 600)
    }

    func testNoCapMeansBackingScale() {
        let size = CaptureSizing.pixelSize(points: CGSize(width: 1000, height: 500), backingScale: 2, maxLongestSide: nil)
        XCTAssertEqual(size.width, 2000)
        XCTAssertEqual(size.height, 1000)
    }

    func testNonPositiveCapMeansNoCap() {
        let size = CaptureSizing.pixelSize(points: CGSize(width: 1000, height: 500), backingScale: 2, maxLongestSide: 0)
        XCTAssertEqual(size.width, 2000)
    }

    func testStandardDensityDisplayIsOneToOne() {
        let size = CaptureSizing.pixelSize(points: CGSize(width: 1000, height: 700), backingScale: 1, maxLongestSide: 1400)
        XCTAssertEqual(size.width, 1000)
        XCTAssertEqual(size.height, 700)
    }

    func testUnknownBackingScaleFallsBackToOne() {
        let size = CaptureSizing.pixelSize(points: CGSize(width: 1000, height: 700), backingScale: 0, maxLongestSide: nil)
        XCTAssertEqual(size.width, 1000)
        XCTAssertEqual(size.height, 700)
    }

    func testDegenerateWindowStillYieldsAPositiveSize() {
        let size = CaptureSizing.pixelSize(points: .zero, backingScale: 2, maxLongestSide: 1400)
        XCTAssertEqual(size.width, 1)
        XCTAssertEqual(size.height, 1)
    }

    /// Whatever the window shape, the longest side must not exceed the cap — otherwise
    /// `ImageEncoder.downscaled` has to redraw on the CPU after all.
    func testLongestSideNeverExceedsTheCapAcrossWindowShapes() {
        for width in stride(from: 40, through: 3400, by: 37) {
            for height in stride(from: 40, through: 2200, by: 61) {
                let size = CaptureSizing.pixelSize(
                    points: CGSize(width: width, height: height), backingScale: 2, maxLongestSide: 1400
                )
                XCTAssertLessThanOrEqual(max(size.width, size.height), 1400, "\(width)x\(height)pt")
                XCTAssertGreaterThanOrEqual(min(size.width, size.height), 1)
            }
        }
    }

    // MARK: - H.264 limit

    func testFullScreenWindowOnA5KDisplayIsClampedToTheEncoderLimit() {
        let size = CaptureSizing.pixelSize(
            points: CGSize(width: 2560, height: 1440), backingScale: 2,
            maxLongestSide: CaptureSizing.h264MaxLongestSide, maxPixelCount: CaptureSizing.h264MaxPixelCount
        )
        XCTAssertEqual(size.width, 4096)
        XCTAssertEqual(size.height, 2304)
    }

    func testPortraitWindowIsClampedOnItsLongEdge() {
        let size = CaptureSizing.pixelSize(
            points: CGSize(width: 1440, height: 2560), backingScale: 2,
            maxLongestSide: CaptureSizing.h264MaxLongestSide, maxPixelCount: CaptureSizing.h264MaxPixelCount
        )
        XCTAssertEqual(size.width, 2304)
        XCTAssertEqual(size.height, 4096)
    }

    /// A square window passes the long-edge test (4096) at 16.7M pixels, 78% more than
    /// level 5.1 allows, so the area budget has to bind as well.
    func testSquareWindowIsHeldToThePixelBudget() {
        let size = CaptureSizing.pixelSize(
            points: CGSize(width: 2500, height: 2500), backingScale: 2,
            maxLongestSide: CaptureSizing.h264MaxLongestSide, maxPixelCount: CaptureSizing.h264MaxPixelCount
        )
        XCTAssertLessThanOrEqual(size.width * size.height, CaptureSizing.h264MaxPixelCount)
        XCTAssertEqual(size.width, size.height)
    }

    func testWindowWithinTheEncoderLimitIsUntouched() {
        let size = CaptureSizing.pixelSize(
            points: CGSize(width: 1200, height: 800), backingScale: 2,
            maxLongestSide: CaptureSizing.h264MaxLongestSide, maxPixelCount: CaptureSizing.h264MaxPixelCount
        )
        XCTAssertEqual(size.width, 2400)
        XCTAssertEqual(size.height, 1600)
    }

    // MARK: - No CPU resample when the capture already fits

    func testDownscaleLeavesAnImageThatAlreadyFitsUntouched() throws {
        let image = try XCTUnwrap(Self.makeImage(width: 1400, height: 875))
        XCTAssertTrue(ImageEncoder.downscaled(image, longestSide: 1400) === image)
    }

    func testEncodeProducesJPEGAndPNGAtTheCapturedSize() throws {
        let image = try XCTUnwrap(Self.makeImage(width: 700, height: 400))
        let jpeg = try ImageEncoder.encode(image, maxLongestSide: 1400, format: .jpeg, quality: 0.7)
        XCTAssertEqual(jpeg.mimeType, "image/jpeg")
        XCTAssertEqual(Array(jpeg.data.prefix(2)), [0xFF, 0xD8])
        let png = try ImageEncoder.encode(image, maxLongestSide: 1400, format: .png, quality: 0.7)
        XCTAssertEqual(png.mimeType, "image/png")
        XCTAssertEqual(Array(png.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    private static func makeImage(width: Int, height: Int) -> CGImage? {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.5, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx?.makeImage()
    }

    // MARK: - Element crop region

    func testElementInsideTheWindowIsMadeWindowRelative() {
        let region = CaptureSizing.localRegion(
            of: CGRect(x: 300, y: 250, width: 100, height: 40),
            in: CGRect(x: 200, y: 100, width: 800, height: 600)
        )
        XCTAssertEqual(region, CGRect(x: 100, y: 150, width: 100, height: 40))
    }

    func testElementHangingOutOfTheWindowIsClippedToTheVisiblePart() {
        let region = CaptureSizing.localRegion(
            of: CGRect(x: 950, y: 650, width: 200, height: 200),
            in: CGRect(x: 200, y: 100, width: 800, height: 600)
        )
        XCTAssertEqual(region, CGRect(x: 750, y: 550, width: 50, height: 50))
    }

    /// A scrolled-out row still has AX bounds, just outside the window.
    func testElementEntirelyOutsideTheWindowHasNoRegion() {
        XCTAssertNil(CaptureSizing.localRegion(
            of: CGRect(x: 300, y: 900, width: 100, height: 40),
            in: CGRect(x: 200, y: 100, width: 800, height: 600)
        ))
    }

    func testElementOnlyTouchingTheWindowEdgeHasNoRegion() {
        XCTAssertNil(CaptureSizing.localRegion(
            of: CGRect(x: 1000, y: 200, width: 50, height: 50),
            in: CGRect(x: 200, y: 100, width: 800, height: 600)
        ))
    }
}

final class WindowPickerTests: XCTestCase {

    private func window(
        _ id: CGWindowID, _ title: String?, x: CGFloat, y: CGFloat, w: CGFloat = 800, h: CGFloat = 600,
        layer: Int = 0, onScreen: Bool = true
    ) -> WindowCandidate {
        WindowCandidate(id: id, title: title, frame: CGRect(x: x, y: y, width: w, height: h), layer: layer, isOnScreen: onScreen)
    }

    /// Two untitled documents: taking the first title match captured whichever the
    /// window server listed first, whatever the caller meant.
    func testSameTitleIsResolvedByNearestOrigin() throws {
        let owned = [window(1, "Untitled", x: 100, y: 100), window(2, "Untitled", x: 130, y: 130)]
        let pick = try XCTUnwrap(WindowPicker.pick(from: owned, title: "Untitled", origin: CGPoint(x: 130, y: 130)))
        XCTAssertEqual(pick.window.id, 2)
        XCTAssertTrue(pick.isExact)
    }

    func testOriginOnlyPicksTheNearestWindow() throws {
        let owned = [window(1, "A", x: 0, y: 0), window(2, "B", x: 500, y: 400)]
        let pick = try XCTUnwrap(WindowPicker.pick(from: owned, origin: CGPoint(x: 498, y: 401)))
        XCTAssertEqual(pick.window.id, 2)
    }

    func testTitleNarrowsBeforeOriginSoAnotherWindowAtTheOriginLoses() throws {
        let owned = [window(1, "Inspector", x: 100, y: 100), window(2, "Document", x: 400, y: 100)]
        let pick = try XCTUnwrap(WindowPicker.pick(from: owned, title: "Document", origin: CGPoint(x: 100, y: 100)))
        XCTAssertEqual(pick.window.id, 2)
        XCTAssertFalse(pick.isExact, "the origin matches no Document window, which is what a stale listing looks like")
    }

    func testTitleMissIsAnErrorWhenItIsTheOnlyHint() {
        let owned = [window(1, "Doc", x: 0, y: 0)]
        XCTAssertNil(WindowPicker.pick(from: owned, title: "Docc"))
    }

    /// AX says "Untitled" where the window server reports an empty title; with an origin
    /// from the same AX window the title miss must not abort the capture.
    func testTitleMissFallsThroughToOriginWhenOneIsGiven() throws {
        let owned = [window(1, "", x: 0, y: 0), window(2, "", x: 300, y: 200)]
        let pick = try XCTUnwrap(WindowPicker.pick(from: owned, title: "Untitled", origin: CGPoint(x: 300, y: 200)))
        XCTAssertEqual(pick.window.id, 2)
        XCTAssertTrue(pick.isExact)
    }

    func testWindowIDBeatsEveryOtherHint() throws {
        let owned = [window(7, "A", x: 0, y: 0), window(8, "B", x: 500, y: 500)]
        let pick = try XCTUnwrap(WindowPicker.pick(from: owned, windowID: 7, title: "B", origin: CGPoint(x: 500, y: 500)))
        XCTAssertEqual(pick.window.id, 7)
    }

    func testOriginWithinTolerancePicksExactlyAndBeyondItDoesNot() throws {
        let owned = [window(1, "A", x: 100, y: 100)]
        XCTAssertTrue(try XCTUnwrap(WindowPicker.pick(from: owned, origin: CGPoint(x: 101, y: 101))).isExact)
        XCTAssertFalse(try XCTUnwrap(WindowPicker.pick(from: owned, origin: CGPoint(x: 160, y: 100))).isExact)
    }

    // MARK: - No hints

    /// The old default took the largest on-screen window; with no hint at all that is
    /// still the fallback (the tool now supplies the focused window's hints before this).
    func testNoHintsPicksTheLargestOnScreenRealWindow() throws {
        let owned = [
            window(1, "small", x: 0, y: 0, w: 400, h: 300),
            window(2, "big", x: 0, y: 0, w: 1200, h: 900),
            window(3, "tooltip", x: 0, y: 0, w: 2000, h: 20, layer: 0),
            window(4, "panel", x: 0, y: 0, w: 1500, h: 1000, layer: 25),
            window(5, "offscreen", x: 0, y: 0, w: 1600, h: 1100, onScreen: false),
        ]
        XCTAssertEqual(WindowPicker.pick(from: owned)?.window.id, 2)
    }

    func testWhenNothingIsPlausibleItStillReturnsAWindow() {
        let owned = [window(1, nil, x: 0, y: 0, w: 10, h: 10)]
        XCTAssertEqual(WindowPicker.pick(from: owned)?.window.id, 1)
    }

    func testEmptyListYieldsNothing() {
        XCTAssertNil(WindowPicker.pick(from: [], title: "A", origin: .zero))
    }

    func testEqualDistanceTiePrefersTheOnScreenWindow() throws {
        let owned = [window(1, "A", x: 100, y: 100, onScreen: false), window(2, "A", x: 100, y: 100)]
        XCTAssertEqual(WindowPicker.pick(from: owned, origin: CGPoint(x: 100, y: 100))?.window.id, 2)
    }
}

final class TTLCacheTests: XCTestCase {

    /// A fetch that blocks until the test releases it, so tests can place `invalidate()`
    /// and concurrent callers at exact points of an in-flight enumeration.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<Int> = []

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

        func enter() async -> Int {
            lock.lock()
            calls += 1
            let n = calls
            lock.unlock()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released.contains(n) {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting[n] = continuation
                    lock.unlock()
                }
            }
            return n
        }

        func release(_ n: Int) {
            lock.lock()
            released.insert(n)
            let continuation = waiting.removeValue(forKey: n)
            lock.unlock()
            continuation?.resume()
        }

        func waitForCalls(_ n: Int) async {
            for _ in 0..<500 where callCount < n { try? await Task.sleep(for: .milliseconds(4)) }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000)
        var date: Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) { lock.lock(); current += seconds; lock.unlock() }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testSecondCallWithinTheTTLIsServedFromCache() async throws {
        let counter = Counter()
        let clock = Clock()
        let cache = TTLCache<Int>(ttl: 2.5, now: { clock.date }, fetch: { counter.next() })
        let first = try await cache.snapshot()
        clock.advance(2.4)
        let second = try await cache.snapshot()
        XCTAssertEqual(first.value, 1)
        XCTAssertFalse(first.wasCached)
        XCTAssertEqual(second.value, 1)
        XCTAssertTrue(second.wasCached)
        XCTAssertEqual(counter.value, 1)
    }

    func testEntryExpiresAfterTheTTL() async throws {
        let counter = Counter()
        let clock = Clock()
        let cache = TTLCache<Int>(ttl: 2.5, now: { clock.date }, fetch: { counter.next() })
        _ = try await cache.snapshot()
        clock.advance(2.6)
        let again = try await cache.snapshot()
        XCTAssertEqual(again.value, 2)
        XCTAssertFalse(again.wasCached)
    }

    func testInvalidateForcesANewFetch() async throws {
        let counter = Counter()
        let cache = TTLCache<Int>(ttl: 60, fetch: { counter.next() })
        _ = try await cache.snapshot()
        await cache.invalidate()
        let again = try await cache.snapshot()
        XCTAssertEqual(again.value, 2)
    }

    func testConcurrentCallersShareOneFetch() async throws {
        let gate = Gate()
        let cache = TTLCache<Int>(ttl: 60, fetch: { await gate.enter() })
        async let a = cache.snapshot()
        await gate.waitForCalls(1)
        async let b = cache.snapshot()
        try? await Task.sleep(for: .milliseconds(30))
        gate.release(1)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(second.value, 1)
        XCTAssertEqual(gate.callCount, 1)
    }

    /// The bug the generation counter closes: a window opens during an enumeration, the
    /// tool calls `invalidate()`, then the enumeration finishes — and without the counter
    /// its pre-window listing would be stored and served as fresh for the whole TTL.
    func testInvalidateDuringAFetchDiscardsThatFetchsResult() async throws {
        let gate = Gate()
        let cache = TTLCache<Int>(ttl: 60, fetch: { await gate.enter() })

        let stale = Task { try await cache.snapshot() }
        await gate.waitForCalls(1)
        await cache.invalidate()
        gate.release(1)
        let staleResult = try await stale.value
        XCTAssertEqual(staleResult.value, 1, "the caller that was already waiting still receives its own fetch")

        let next = Task { try await cache.snapshot() }
        await gate.waitForCalls(2)
        gate.release(2)
        let fresh = try await next.value
        XCTAssertEqual(fresh.value, 2, "the discarded result must not have been cached")
        XCTAssertFalse(fresh.wasCached)
    }

    /// A caller arriving after `invalidate()` must not join the fetch that predates it.
    func testCallerAfterInvalidateDoesNotJoinTheOrphanedFetch() async throws {
        let gate = Gate()
        let cache = TTLCache<Int>(ttl: 60, fetch: { await gate.enter() })

        let orphan = Task { try await cache.snapshot() }
        await gate.waitForCalls(1)
        await cache.invalidate()

        let successor = Task { try await cache.snapshot() }
        await gate.waitForCalls(2)
        gate.release(1)
        let orphanResult = try await orphan.value
        XCTAssertEqual(orphanResult.value, 1)

        // The orphan finishing must not have cleared the successor's in-flight slot:
        // a third caller still joins fetch 2 instead of starting a fetch 3.
        let joiner = Task { try await cache.snapshot() }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(gate.callCount, 2)
        gate.release(2)
        let successorResult = try await successor.value
        let joinerResult = try await joiner.value
        XCTAssertEqual(successorResult.value, 2)
        XCTAssertEqual(joinerResult.value, 2)
        XCTAssertEqual(gate.callCount, 2)
    }

    func testFailedFetchLeavesTheCacheEmptyForTheNextCaller() async throws {
        struct Boom: Error {}
        let counter = Counter()
        let cache = TTLCache<Int>(ttl: 60, fetch: {
            let n = counter.next()
            if n == 1 { throw Boom() }
            return n
        })
        do {
            _ = try await cache.snapshot()
            XCTFail("first fetch should have thrown")
        } catch is Boom {}
        let retry = try await cache.snapshot()
        XCTAssertEqual(retry.value, 2)
    }
}

final class CaptureErrorTests: XCTestCase {

    func testUserDeclinedBecomesPermissionDenied() {
        let sck = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        guard case CaptureError.permissionDenied = CaptureError.classify(sck) else {
            return XCTFail("-3801 must classify as permissionDenied")
        }
    }

    func testOtherCaptureErrorsPassThroughUnchanged() {
        let internalError = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue)
        XCTAssertEqual((CaptureError.classify(internalError) as NSError).code, SCStreamError.Code.internalError.rawValue)
        let foreign = NSError(domain: "other", code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertEqual((CaptureError.classify(foreign) as NSError).domain, "other")
    }

    /// One actionable message: where to grant it, what to enable, and that a relaunch is needed.
    func testPermissionMessageSaysHowToFixIt() throws {
        let message = try XCTUnwrap(CaptureError.permissionDenied.errorDescription)
        XCTAssertTrue(message.contains("System Settings > Privacy & Security > Screen Recording"))
        XCTAssertTrue(message.contains("AgentController"))
        XCTAssertTrue(message.contains("reopen"))
    }

    func testRetryingCannotFixAMissingGrantOrACancellation() {
        XCTAssertFalse(ShareableContentCache.refreshCanHelp(CaptureError.permissionDenied))
        XCTAssertFalse(ShareableContentCache.refreshCanHelp(CancellationError()))
        XCTAssertTrue(ShareableContentCache.refreshCanHelp(CaptureError.windowNotFound))
        XCTAssertTrue(ShareableContentCache.refreshCanHelp(
            CaptureError.surfaceUnavailable(title: "", onScreen: false, underlying: "")
        ))
    }
}

final class RecordingPrimitivesTests: XCTestCase {

    func testLimitDefaultsAndClamps() {
        XCTAssertEqual(RecordingLimit.seconds(requested: nil), 600)
        XCTAssertEqual(RecordingLimit.seconds(requested: 30), 30)
        XCTAssertEqual(RecordingLimit.seconds(requested: 0), 1)
        XCTAssertEqual(RecordingLimit.seconds(requested: -5), 1)
        XCTAssertEqual(RecordingLimit.seconds(requested: 999_999), 3600)
        XCTAssertEqual(RecordingLimit.seconds(requested: .nan), 600)
        XCTAssertEqual(RecordingLimit.seconds(requested: .infinity), 600)
    }

    func testSignalBeforeWaitReturnsImmediately() async {
        let signal = FinishSignal()
        signal.signal()
        let started = Date()
        let finished = await signal.wait(timeout: 5)
        XCTAssertTrue(finished)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testSignalAfterWaitBeginsResumesTheWaiter() async {
        let signal = FinishSignal()
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            signal.signal()
        }
        let started = Date()
        let finished = await signal.wait(timeout: 5)
        XCTAssertTrue(finished)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testWaitTimesOutWhenNeverSignaled() async {
        let signal = FinishSignal()
        let started = Date()
        let finished = await signal.wait(timeout: 0.15)
        XCTAssertFalse(finished)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.14)
    }

    /// The timeout and the delegate callback can land together; each waiter must be
    /// resumed once — a second resume of a checked continuation traps.
    func testSignalArrivingAfterTheTimeoutIsHarmless() async {
        let signal = FinishSignal()
        let finished = await signal.wait(timeout: 0.05)
        XCTAssertFalse(finished)
        signal.signal()
        signal.signal()
        let again = await signal.wait(timeout: 1)
        XCTAssertTrue(again)
    }

    func testRacingSignalAndTimeoutNeverDoubleResumes() async {
        for _ in 0..<200 {
            let signal = FinishSignal()
            Task { signal.signal() }
            _ = await signal.wait(timeout: 0.001)
        }
    }
}

final class QuitPollingTests: XCTestCase {

    func testWaitUntilReturnsTrueAsSoonAsTheConditionHolds() async throws {
        var polls = 0
        let held = try await AppTools.waitUntil(timeout: 5, interval: 0.01) {
            polls += 1
            return polls >= 3
        }
        XCTAssertTrue(held)
        XCTAssertEqual(polls, 3)
    }

    /// The reset_app_state hazard: an app held open by a "Save changes?" sheet never
    /// exits, and the caller must learn that instead of proceeding to delete its data.
    func testWaitUntilReportsFalseWhenTheConditionNeverHolds() async throws {
        let started = Date()
        let held = try await AppTools.waitUntil(timeout: 0.2, interval: 0.02) { false }
        XCTAssertFalse(held)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2)
    }

    func testWaitUntilWithZeroTimeoutStillChecksOnce() async throws {
        let held = try await AppTools.waitUntil(timeout: 0, interval: 0.01) { true }
        XCTAssertTrue(held)
    }
}
