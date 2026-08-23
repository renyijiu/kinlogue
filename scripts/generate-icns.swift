#!/usr/bin/env swift

import Foundation

private struct IconRepresentation {
    let type: String
    let filename: String
    let pixelSize: UInt32
}

private let representations = [
    IconRepresentation(type: "icp4", filename: "icon_16x16.png", pixelSize: 16),
    IconRepresentation(type: "ic11", filename: "icon_16x16@2x.png", pixelSize: 32),
    IconRepresentation(type: "icp5", filename: "icon_32x32.png", pixelSize: 32),
    IconRepresentation(type: "ic12", filename: "icon_32x32@2x.png", pixelSize: 64),
    IconRepresentation(type: "ic07", filename: "icon_128x128.png", pixelSize: 128),
    IconRepresentation(type: "ic13", filename: "icon_128x128@2x.png", pixelSize: 256),
    IconRepresentation(type: "ic08", filename: "icon_256x256.png", pixelSize: 256),
    IconRepresentation(type: "ic14", filename: "icon_256x256@2x.png", pixelSize: 512),
    IconRepresentation(type: "ic09", filename: "icon_512x512.png", pixelSize: 512),
    IconRepresentation(type: "ic10", filename: "icon_512x512@2x.png", pixelSize: 1_024),
]

private enum IconGenerationError: LocalizedError {
    case usage
    case invalidType(String)
    case invalidPNG(String)
    case unexpectedSize(filename: String, expected: UInt32, width: UInt32, height: UInt32)
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: generate-icns.swift ICONSET_DIRECTORY OUTPUT_ICNS"
        case let .invalidType(type):
            return "invalid four-character icon type: \(type)"
        case let .invalidPNG(filename):
            return "invalid PNG icon representation: \(filename)"
        case let .unexpectedSize(filename, expected, width, height):
            return "\(filename) must be \(expected)x\(expected), got \(width)x\(height)"
        case .outputTooLarge:
            return "the generated ICNS container exceeds the format size limit"
        }
    }
}

private func bigEndianData(_ value: UInt32) -> Data {
    var bigEndianValue = value.bigEndian
    return withUnsafeBytes(of: &bigEndianValue) { Data($0) }
}

private func pngDimensions(_ data: Data, filename: String) throws -> (UInt32, UInt32) {
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard data.count >= 24,
          Array(data.prefix(signature.count)) == signature,
          String(decoding: data[12..<16], as: UTF8.self) == "IHDR" else {
        throw IconGenerationError.invalidPNG(filename)
    }

    func value(at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    return (value(at: 16), value(at: 20))
}

private func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw IconGenerationError.usage
    }

    let fileManager = FileManager.default
    let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        .standardizedFileURL
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: false)
        .standardizedFileURL

    var chunks = Data()
    for representation in representations {
        guard representation.type.utf8.count == 4 else {
            throw IconGenerationError.invalidType(representation.type)
        }

        let sourceURL = iconsetURL.appendingPathComponent(representation.filename)
        let pngData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let (width, height) = try pngDimensions(pngData, filename: representation.filename)
        guard width == representation.pixelSize, height == representation.pixelSize else {
            throw IconGenerationError.unexpectedSize(
                filename: representation.filename,
                expected: representation.pixelSize,
                width: width,
                height: height
            )
        }
        guard pngData.count <= Int(UInt32.max) - 8 else {
            throw IconGenerationError.outputTooLarge
        }

        chunks.append(contentsOf: representation.type.utf8)
        chunks.append(bigEndianData(UInt32(pngData.count + 8)))
        chunks.append(pngData)
    }

    guard chunks.count <= Int(UInt32.max) - 8 else {
        throw IconGenerationError.outputTooLarge
    }

    var container = Data("icns".utf8)
    container.append(bigEndianData(UInt32(chunks.count + 8)))
    container.append(chunks)

    try fileManager.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try container.write(to: outputURL, options: .atomic)
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Icon generation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
