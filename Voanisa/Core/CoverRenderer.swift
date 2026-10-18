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
        return load(source: source, maxPixelSize: maxPixelSize)
    }

    static func loadOrientedImage(data: Data, maxPixelSize: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return load(source: source, maxPixelSize: maxPixelSize)
    }

    private static func load(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
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

    /// Embedded artwork has no crop editor, so take the largest centred square.
    static func centeredSquareCoverJPEG(from image: CGImage, side: Int = 1024) -> Data? {
        let edge = CGFloat(min(image.width, image.height))
        guard edge >= 1 else { return nil }

        let rect = CGRect(
            x: (CGFloat(image.width) - edge) / 2,
            y: (CGFloat(image.height) - edge) / 2,
            width: edge,
            height: edge
        )
        return squareCoverJPEG(from: image, cropRect: rect, side: side)
    }

    /// The same centre-square crop, decoded and encoded by the Rust core.
    ///
    /// ImageIO stays as the fallback because `image` does not decode HEIC, which
    /// is what photos and some artwork use.
    static func centeredSquareCoverJPEG(from data: Data, side: Int = 1024) -> Data? {
        let directory = FileManager.default.temporaryDirectory
        let identifier = UUID().uuidString
        let source = directory.appendingPathComponent("voanisa-cover-\(identifier).img")
        let out = directory.appendingPathComponent("voanisa-cover-\(identifier).jpg")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: out)
        }

        do {
            try data.write(to: source, options: .atomic)
        } catch {
            return nil
        }

        if RustCore.writeSquareCover(source: source, to: out, side: side),
           let jpeg = try? Data(contentsOf: out) {
            return jpeg
        }

        guard let image = loadOrientedImage(data: data) else { return nil }
        return centeredSquareCoverJPEG(from: image, side: side)
    }

    static func imageFileExtension(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return nil
        }
        return UTType(type as String)?.preferredFilenameExtension
    }
}
