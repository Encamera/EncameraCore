import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum ImageResizingError: Error {
    case cannotRetrieveFromURL
    case cannotRetrieveFromData
}

public struct ImageResizer {
    var targetWidth: CGFloat

    public func resize(at url: URL, quality: CGFloat) -> PlatformImage? {
        guard let image = PlatformImage(contentsOfFile: url.path) else {
            return nil
        }

        return self.resize(image: image, quality: quality)
    }

    public func resize(image: PlatformImage, quality: CGFloat) -> PlatformImage? {
        let originalSize = image.size
        let targetSize = CGSize(width: targetWidth, height: targetWidth * originalSize.height / originalSize.width)
        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { (context) in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        #else
        guard let source = image.cgImage,
              let resizedImage = PlatformImage.rendered(size: targetSize, { context in
                  context.interpolationQuality = .high
                  context.draw(source, in: CGRect(origin: .zero, size: targetSize))
              }) else {
            return nil
        }
        #endif
        guard let jpegData = resizedImage.jpegData(compressionQuality: quality) else {
            return nil
        }
        return PlatformImage(data: jpegData)
    }

    public func resize(data: Data, quality: CGFloat) -> PlatformImage? {
        guard let image = PlatformImage(data: data) else {
            return nil
        }
        return resize(image: image, quality: quality)
    }
}

struct MemorySizer {
    static func size(of data: Data) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useMB] // optional: restricts the units to MB only
        bcf.countStyle = .file
        let string = bcf.string(fromByteCount: Int64(data.count))
        return string
    }
}
