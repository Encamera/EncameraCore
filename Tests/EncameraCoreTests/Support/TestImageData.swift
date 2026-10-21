import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small solid-colour images encoded with ImageIO, so fixtures build the same
/// way on iOS and in the native macOS `swift test` run.
enum TestImageData {

    static func png(width: Int = 2, height: Int = 2) -> Data {
        encode(width: width, height: height, as: .png, quality: nil)
    }

    static func jpeg(width: Int = 2, height: Int = 2, quality: CGFloat = 0.9) -> Data {
        encode(width: width, height: height, as: .jpeg, quality: quality)
    }

    private static func encode(width: Int, height: Int, as type: UTType, quality: CGFloat?) -> Data {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            preconditionFailure("Could not create a \(width)x\(height) bitmap context")
        }
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            preconditionFailure("Could not render the test image")
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            preconditionFailure("Could not create an image destination for \(type.identifier)")
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            preconditionFailure("Could not encode the test image as \(type.identifier)")
        }
        return data as Data
    }
}
