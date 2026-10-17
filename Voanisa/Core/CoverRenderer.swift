import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image loading, square cropping and JPEG encoding.
///
/// The UI works with CGImage; the core stores only bytes, so the same operations
/// can move to the portable core later without pulling in AppKit.
enum CoverRenderer {
    /// Loads an image with EXIF orientation applied and downsamples it for the
    /// crop editor. The original file is not modified.
    static func loadOrientedImage(url: URL, maxPixelSize: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = rect.intersection(bounds)
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped.integral)
    }

    static func resizedSquare(_ image: CGImage, side: Int) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    static func jpegData(_ image: CGImage, quality: CGFloat = 0.9) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func squareCoverJPEG(from image: CGImage, cropRect: CGRect, side: Int = 1024) -> Data? {
        guard let cropped = crop(image, to: cropRect),
              let resized = resizedSquare(cropped, side: side) else { return nil }
        return jpegData(resized)
    }
}
