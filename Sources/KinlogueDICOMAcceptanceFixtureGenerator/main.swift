import CryptoKit
import Foundation
import KinlogueDICOMTestSupport

@main
struct KinlogueDICOMAcceptanceFixtureGenerator {
    private static let seriesCount = 3
    private static let slicesPerSeries = 72
    private static let rows: UInt16 = 64
    private static let columns: UInt16 = 64

    static func main() throws {
        guard CommandLine.arguments.count == 3,
              CommandLine.arguments[1] == "--output-directory" else {
            throw GeneratorError.invalidArguments
        }
        let output = URL(
            fileURLWithPath: CommandLine.arguments[2],
            isDirectory: true
        ).standardizedFileURL
        guard output.path.hasPrefix("/"), output.lastPathComponent == "DICOMInput" else {
            throw GeneratorError.invalidArguments
        }

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard !manager.fileExists(atPath: output.path, isDirectory: &isDirectory) else {
            throw GeneratorError.outputExists
        }
        try manager.createDirectory(
            at: output,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var created = false
        defer {
            if !created { try? manager.removeItem(at: output) }
        }

        let studyUID = "2.25.710000000000000000000000000000000001"
        var aggregate = SHA256()
        var totalBytes = 0
        var objectCount = 0
        let pixels = (0..<(Int(rows) * Int(columns))).map { UInt16($0 % 4_096) }
        for seriesOrdinal in 0..<seriesCount {
            let seriesUID = "2.25.71000000000000000000000000000001\(seriesOrdinal + 1)"
            for sliceOrdinal in 0..<slicesPerSeries {
                let sopUID = "2.25.710000000000000000000\(seriesOrdinal + 1)\(String(format: "%04d", sliceOrdinal + 1))"
                let data = GeneratedDICOMFixture.explicitVRLittleEndianMR(
                    rows: rows,
                    columns: columns,
                    studyInstanceUID: studyUID,
                    seriesInstanceUID: seriesUID,
                    sopInstanceUID: sopUID,
                    instanceNumber: sliceOrdinal + 1,
                    imagePositionPatient: "0\\0\\\(sliceOrdinal)",
                    pixels: pixels
                )
                try write(data, ordinal: objectCount, to: output)
                aggregate.update(data: data)
                totalBytes += data.count
                objectCount += 1
            }
        }
        let inert = GeneratedDICOMFixture.explicitVRLittleEndianInertObject(
            studyInstanceUID: studyUID,
            seriesInstanceUID: "2.25.7100000000000000000000000000000199",
            sopInstanceUID: "2.25.7100000000000000000000000000000299"
        )
        try write(inert, ordinal: objectCount, to: output)
        aggregate.update(data: inert)
        totalBytes += inert.count
        objectCount += 1

        let event = GeneratorEvent(
            byteCount: totalBytes,
            code: "KLA_DICOM_FIXTURE_COMPLETE",
            inertObjectCount: 1,
            objectCount: objectCount,
            ok: true,
            seriesCount: seriesCount,
            summarySHA256: aggregate.finalize().map { String(format: "%02x", $0) }.joined(),
            viewableInstanceCount: seriesCount * slicesPerSeries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(event))
        FileHandle.standardOutput.write(Data([0x0A]))
        created = true
    }

    private static func write(_ data: Data, ordinal: Int, to directory: URL) throws {
        let name = String(format: "object-%04d.bin", ordinal + 1)
        try data.write(
            to: directory.appendingPathComponent(name, isDirectory: false),
            options: .withoutOverwriting
        )
    }
}

private enum GeneratorError: Error {
    case invalidArguments
    case outputExists
}

private struct GeneratorEvent: Encodable {
    let byteCount: Int
    let code: String
    let inertObjectCount: Int
    let objectCount: Int
    let ok: Bool
    let seriesCount: Int
    let summarySHA256: String
    let viewableInstanceCount: Int
}
