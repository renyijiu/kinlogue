#!/usr/bin/env swift

import AppKit

private enum Artwork: String {
    case regular = "AppIcon.svg"
    case small = "AppIcon-small.svg"
}

private struct IconRendition {
    let relativePath: String
    let pixelSize: Int
    let artwork: Artwork
}

// 16 and 32 pixel representations use the heavier small-size drawing; every
// larger representation is rendered from the regular master.
private let renditions = [
    IconRendition(relativePath: "AppIcon.png", pixelSize: 1_024, artwork: .regular),
    IconRendition(relativePath: "Kinlogue.iconset/icon_16x16.png", pixelSize: 16, artwork: .small),
    IconRendition(relativePath: "Kinlogue.iconset/icon_16x16@2x.png", pixelSize: 32, artwork: .small),
    IconRendition(relativePath: "Kinlogue.iconset/icon_32x32.png", pixelSize: 32, artwork: .small),
    IconRendition(relativePath: "Kinlogue.iconset/icon_32x32@2x.png", pixelSize: 64, artwork: .regular),
    IconRendition(relativePath: "Kinlogue.iconset/icon_128x128.png", pixelSize: 128, artwork: .regular),
    IconRendition(relativePath: "Kinlogue.iconset/icon_128x128@2x.png", pixelSize: 256, artwork: .regular),
    IconRendition(relativePath: "Kinlogue.iconset/icon_256x256.png", pixelSize: 256, artwork: .regular),
    IconRendition(relativePath: "Kinlogue.iconset/icon_256x256@2x.png", pixelSize: 512, artwork: .regular),
    IconRendition(relativePath: "Kinlogue.iconset/icon_512x512.png", pixelSize: 512, artwork: .regular),
    IconRendition(relativePath: "Kinlogue.iconset/icon_512x512@2x.png", pixelSize: 1_024, artwork: .regular),
]

private enum IconRenderingError: LocalizedError {
    case usage
    case unreadableArtwork(String)
    case bitmapUnavailable(Int)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: render-app-icon.swift PACKAGING_DIRECTORY"
        case let .unreadableArtwork(filename):
            return "the vector master could not be read: \(filename)"
        case let .bitmapUnavailable(pixelSize):
            return "a \(pixelSize)x\(pixelSize) bitmap could not be created"
        case let .encodingFailed(path):
            return "the PNG representation could not be encoded: \(path)"
        }
    }
}

private func renderPNG(_ image: NSImage, pixelSize: Int, path: String) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconRenderingError.bitmapUnavailable(pixelSize)
    }
    bitmap.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconRenderingError.encodingFailed(path)
    }
    return data
}

private func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw IconRenderingError.usage
    }

    let fileManager = FileManager.default
    let packagingURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        .standardizedFileURL

    var masters: [Artwork: NSImage] = [:]
    for artwork in [Artwork.regular, .small] {
        let masterURL = packagingURL.appendingPathComponent(artwork.rawValue)
        guard let image = NSImage(contentsOf: masterURL), image.isValid else {
            throw IconRenderingError.unreadableArtwork(artwork.rawValue)
        }
        masters[artwork] = image
    }

    // Identical pixel sizes of the same artwork share one encoded PNG so the
    // paired representations stay byte-identical.
    var encoded: [String: Data] = [:]
    for rendition in renditions {
        let key = "\(rendition.artwork.rawValue)@\(rendition.pixelSize)"
        let data: Data
        if let cached = encoded[key] {
            data = cached
        } else if let master = masters[rendition.artwork] {
            data = try renderPNG(master, pixelSize: rendition.pixelSize, path: rendition.relativePath)
            encoded[key] = data
        } else {
            throw IconRenderingError.unreadableArtwork(rendition.artwork.rawValue)
        }

        let outputURL = packagingURL.appendingPathComponent(rendition.relativePath)
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Icon rendering failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
