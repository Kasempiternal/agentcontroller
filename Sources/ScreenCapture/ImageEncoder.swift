import AppKit
import Foundation

public struct ImageEncoder {
    public static func pngData(from image: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    /// JPEG encode at `quality` (0...1). Much smaller than PNG for screenshots, which
    /// keeps base64 payloads from flooding an LLM's context window.
    public static func jpegData(from image: CGImage, quality: CGFloat) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        let q = max(0, min(1, quality))
        return rep.representation(using: .jpeg, properties: [.compressionFactor: q]) ?? Data()
    }

    public static func base64PNG(from image: CGImage) -> String {
        pngData(from: image).base64EncodedString()
    }

    public static func base64PNG(from data: Data) -> String {
        data.base64EncodedString()
    }

    /// Downscale so the longest side is at most `longestSide` px, preserving aspect ratio.
    /// Returns the original image untouched when it already fits (no needless redraw).
    public static func downscaled(_ image: CGImage, longestSide: Int) -> CGImage {
        guard longestSide > 0 else { return image }
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > longestSide else { return image }

        let scale = CGFloat(longestSide) / CGFloat(longest)
        let newW = max(1, Int((CGFloat(w) * scale).rounded()))
        let newH = max(1, Int((CGFloat(h) * scale).rounded()))

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return image }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    /// Encode a captured image with the agent-friendly defaults applied: optional
    /// downscale to a max longest side, then JPEG (smaller) or PNG. Returns the encoded
    /// bytes plus the matching MIME type for `ToolResult.image`.
    public static func encode(
        _ image: CGImage,
        maxLongestSide: Int?,
        format: ImageFormat,
        quality: CGFloat
    ) -> (data: Data, mimeType: String) {
        var img = image
        if let cap = maxLongestSide {
            img = downscaled(img, longestSide: cap)
        }
        switch format {
        case .png:
            return (pngData(from: img), "image/png")
        case .jpeg:
            return (jpegData(from: img, quality: quality), "image/jpeg")
        }
    }
}

public enum ImageFormat: Sendable {
    case png
    case jpeg

    /// Parse a tool-supplied format string. Defaults to JPEG (the agent-friendly choice).
    public static func parse(_ raw: String?) -> ImageFormat {
        switch raw?.lowercased() {
        case "png": return .png
        case "jpeg", "jpg": return .jpeg
        default: return .jpeg
        }
    }
}
