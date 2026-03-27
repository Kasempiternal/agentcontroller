import AppKit
import Foundation

public struct ImageEncoder {
    public static func pngData(from image: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    public static func base64PNG(from image: CGImage) -> String {
        pngData(from: image).base64EncodedString()
    }

    public static func base64PNG(from data: Data) -> String {
        data.base64EncodedString()
    }
}
