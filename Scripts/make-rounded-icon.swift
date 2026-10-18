// Rounds the corners of an image and writes a transparent PNG.
//
// Usage:
//     swift Scripts/make-rounded-icon.swift <input> <output> [size] [radius-ratio]
//
// `size` is the output square edge in pixels (defaults to the source width).
// `radius-ratio` is the corner radius as a fraction of the edge; 0.2237 matches
// the macOS Big Sur app-icon mask.
//
// Handles anything ImageIO can decode, including HEIC, so artwork straight out
// of Photos can be turned into a README/site asset in one step.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-rounded-icon <input> <output> [size] [radius-ratio]\n".utf8))
    exit(2)
}

let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])

guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, [
          kCGImageSourceShouldCacheImmediately: true
      ] as CFDictionary) else {
    FileHandle.standardError.write(Data("cannot read \(input.path)\n".utf8))
    exit(1)
}

let side = arguments.count > 3 ? Int(arguments[3]) ?? image.width : image.width
let ratio = arguments.count > 4 ? Double(arguments[4]) ?? 0.2237 : 0.2237
let radius = CGFloat(Double(side) * ratio)

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
          data: nil,
          width: side,
          height: side,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else {
    FileHandle.standardError.write(Data("cannot create a bitmap context\n".utf8))
    exit(1)
}

let rect = CGRect(x: 0, y: 0, width: side, height: side)
context.clear(rect)
context.interpolationQuality = .high
context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
context.clip()
context.draw(image, in: rect)

guard let rounded = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          output as CFURL,
          UTType.png.identifier as CFString,
          1,
          nil
      ) else {
    FileHandle.standardError.write(Data("cannot encode \(output.path)\n".utf8))
    exit(1)
}

CGImageDestinationAddImage(destination, rounded, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("cannot write \(output.path)\n".utf8))
    exit(1)
}

print("wrote \(output.path) (\(side)x\(side), radius \(Int(radius)) px)")
