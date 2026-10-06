import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The slice of an `SCWindow` that window selection reads. SCWindow cannot be built
/// outside ScreenCaptureKit, so selection runs on this and the tests can drive it.
public struct WindowCandidate: Equatable, Sendable {
    public let id: CGWindowID
    public let title: String?
    public let frame: CGRect
    public let layer: Int
    public let isOnScreen: Bool

    public init(id: CGWindowID, title: String?, frame: CGRect, layer: Int, isOnScreen: Bool) {
        self.id = id
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
    }

    init(_ window: SCWindow) {
        self.init(id: window.windowID, title: window.title, frame: window.frame,
                  layer: window.windowLayer, isOnScreen: window.isOnScreen)
    }

    /// Enumeration includes tooltips, status-item panels, and zero-sized helpers; only
    /// a layer-0 window of real size is something a caller means by "the window".
    /// Same floor as `WindowManager`'s window listing.
    var isPlausible: Bool { layer == 0 && frame.width >= 40 && frame.height >= 40 }
}

public struct WindowPick: Equatable, Sendable {
    public let window: WindowCandidate
    /// False only when the caller gave an origin and no window sits within
    /// `WindowPicker.originTolerance` of it — the nearest-window fallback fired, which is
    /// also what a stale enumeration looks like (the window moved, or is not listed yet).
    /// Hints that cannot be checked against a frame (title alone, no hints) never fail it.
    public let isExact: Bool
}

public enum WindowPicker {
    /// AX positions and SCWindow frames agree to well under this; the same figure
    /// `WindowManager.sameWindow` uses to treat two readings as one window.
    static let originTolerance: CGFloat = 2

    /// Picks the window of `owned` (already filtered to one app) the hints describe.
    /// Priority: window id, then title narrowed by nearest origin, then nearest origin
    /// alone, then the most plausible main window.
    ///
    /// A title that matches nothing is an error when it is the only hint (a typo must
    /// not silently capture a different window). With an origin as well, both derived
    /// from one AX window, a title miss falls through to nearest-origin matching: the
    /// window server reports an empty title where AX says "Untitled".
    public static func pick(
        from owned: [WindowCandidate],
        windowID: CGWindowID? = nil,
        title: String? = nil,
        origin: CGPoint? = nil
    ) -> WindowPick? {
        guard !owned.isEmpty else { return nil }

        if let windowID, let exact = owned.first(where: { $0.id == windowID }) {
            return WindowPick(window: exact, isExact: true)
        }

        var pool = owned
        if let title, !title.isEmpty {
            let matches = owned.filter { $0.title == title }
            if !matches.isEmpty {
                pool = matches
            } else if origin == nil {
                return nil
            }
        }

        if let origin, let nearest = nearest(to: origin, in: pool) {
            let aligned = distance(from: origin, to: nearest) <= originTolerance
            return WindowPick(window: nearest, isExact: aligned)
        }

        guard let best = best(in: pool) else { return nil }
        return WindowPick(window: best, isExact: true)
    }

    static func nearest(to origin: CGPoint, in windows: [WindowCandidate]) -> WindowCandidate? {
        windows.min { lhs, rhs in
            let l = distance(from: origin, to: lhs)
            let r = distance(from: origin, to: rhs)
            return l != r ? l < r : outranks(lhs, rhs)
        }
    }

    /// The most plausible "main" window when nothing disambiguates: real-sized layer-0
    /// windows first, on-screen before off-screen, then the largest area.
    static func best(in windows: [WindowCandidate]) -> WindowCandidate? {
        windows.min { outranks($0, $1) }
    }

    private static func outranks(_ lhs: WindowCandidate, _ rhs: WindowCandidate) -> Bool {
        if lhs.isPlausible != rhs.isPlausible { return lhs.isPlausible }
        if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
        return lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
    }

    private static func distance(from origin: CGPoint, to window: WindowCandidate) -> CGFloat {
        hypot(window.frame.origin.x - origin.x, window.frame.origin.y - origin.y)
    }
}
