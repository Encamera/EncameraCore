import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit

/// The image type EncameraCore hands back from its thumbnail and decode APIs:
/// `UIImage` on iOS and `NSImage` on macOS, where the package is built for its
/// native `swift test` run.
public typealias PlatformImage = UIImage

#elseif canImport(AppKit)
import AppKit

public typealias PlatformImage = NSImage

/// The slice of `UIImage`'s API that EncameraCore calls, so the same call
/// sites compile against `NSImage` on macOS.
extension NSImage {

    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        cgImage.flatMap { PlatformImageEncoding.encode($0, as: .jpeg, quality: compressionQuality) }
    }

    func pngData() -> Data? {
        cgImage.flatMap { PlatformImageEncoding.encode($0, as: .png, quality: nil) }
    }

    /// Draws into a fresh bitmap of `size` pixels. The context uses
    /// CoreGraphics' native bottom-left origin.
    static func rendered(size: CGSize, _ draw: (CGContext) -> Void) -> NSImage? {
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        draw(context)
        return context.makeImage().map { NSImage(cgImage: $0) }
    }
}

enum PlatformImageEncoding {
    static func encode(_ image: CGImage, as type: UTType, quality: CGFloat?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
