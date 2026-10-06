import CoreGraphics
import Foundation

/// Size and crop geometry for ScreenCaptureKit requests. Asking SCK for the FINAL size lets
/// its GPU scaler do the work; the old path captured at a fixed 2x (a 1728x1080pt window
/// became a 3456x2160 BGRA surface, ~30MB) and then shrank it to 1400px on the CPU in
/// `ImageEncoder.downscaled`.
public enum CaptureSizing {
    /// H.264 level 5.1 tops out at 4096x2304 (36864 macroblocks). A 5K display's
    /// full-screen window at 2x is 5120x2880 and would exceed it.
    public static let h264MaxLongestSide = 4096
    public static let h264MaxPixelCount = 4096 * 2304

    /// Pixel dimensions to request for content measuring `points`. The scale is the
    /// display's backing scale, reduced so the longest side stays within
    /// `maxLongestSide` and the area within `maxPixelCount`. Never above the backing
    /// scale: SCK would only interpolate, and the extra pixels carry no detail.
    public static func pixelSize(
        points: CGSize,
        backingScale: CGFloat,
        maxLongestSide: Int? = nil,
        maxPixelCount: Int? = nil
    ) -> (width: Int, height: Int) {
        let longestPoints = max(points.width, points.height)
        guard longestPoints > 0 else { return (1, 1) }

        var scale = backingScale > 0 ? backingScale : 1
        if let cap = maxLongestSide, cap > 0 {
            scale = min(scale, CGFloat(cap) / longestPoints)
        }
        if let budget = maxPixelCount, budget > 0 {
            scale = min(scale, (CGFloat(budget) / (points.width * points.height)).squareRoot())
        }

        var width = max(1, Int((points.width * scale).rounded()))
        var height = max(1, Int((points.height * scale).rounded()))
        // `rounded()` can land one pixel past a cap that the scale hit exactly.
        if let cap = maxLongestSide, cap > 0 {
            width = min(width, cap)
            height = min(height, cap)
        }
        return (width, height)
    }

    /// `element` clipped to `window` (both in global top-left points, as AX reports
    /// them), re-expressed in the window's own space: what `sourceRect` expects. Nil when
    /// no part of the element lies inside the window, e.g. scrolled out of view, where a
    /// crop would read outside the capture rather than show the element.
    public static func localRegion(of element: CGRect, in window: CGRect) -> CGRect? {
        let visible = element.intersection(window)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return CGRect(x: visible.minX - window.minX, y: visible.minY - window.minY,
                      width: visible.width, height: visible.height)
    }
}
