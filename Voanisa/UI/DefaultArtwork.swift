import AppKit
import CoreGraphics

/// The artwork shown when a song has no cover of its own.
///
/// Drawn with Core Graphics so it can be created from a background task.
enum DefaultArtwork {
    static let image = render()

    private static func render() -> NSImage {
        let side = 1024
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: NSSize(width: side, height: side))
        }

        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let grayColors = [
            CGColor(gray: 0.80, alpha: 1),
            CGColor(gray: 0.64, alpha: 1)
        ] as CFArray

        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: grayColors,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: side),
                end: CGPoint(x: side, y: 0),
                options: []
            )
        } else {
            context.setFillColor(CGColor(gray: 0.72, alpha: 1))
            context.fill(bounds)
        }

        // A single eighth note: elliptical head, stem and a curved flag.
        context.setFillColor(CGColor(gray: 0.26, alpha: 1))

        let note = CGMutablePath()
        let head = CGMutablePath()
        head.addEllipse(in: CGRect(x: -140, y: -105, width: 280, height: 210))
        let transform = CGAffineTransform(translationX: 410, y: 360)
            .rotated(by: -0.22)
        note.addPath(head, transform: transform)

        note.addRect(CGRect(x: 530, y: 360, width: 44, height: 400))
        note.move(to: CGPoint(x: 574, y: 760))
        note.addCurve(
            to: CGPoint(x: 735, y: 610),
            control1: CGPoint(x: 770, y: 755),
            control2: CGPoint(x: 790, y: 665)
        )
        note.addCurve(
            to: CGPoint(x: 574, y: 675),
            control1: CGPoint(x: 685, y: 610),
            control2: CGPoint(x: 615, y: 640)
        )
        note.closeSubpath()

        context.addPath(note)
        context.fillPath()

        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: side, height: side)
        )
    }
}

enum Artwork {
    /// Loads a rendered cover, falling back to the default artwork when the
    /// name is missing or its file cannot be read.
    static func image(
        for coverFileName: String?,
        directory: URL = LibraryLocation.renderedCoversURL
    ) -> NSImage {
        guard let coverFileName,
              let data = try? Data(
                  contentsOf: directory.appendingPathComponent(coverFileName)
              ),
              let image = NSImage(data: data) else {
            return DefaultArtwork.image
        }
        return image
    }
}
