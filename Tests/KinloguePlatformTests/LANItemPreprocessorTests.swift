import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("LAN item preprocessing", .serialized)
struct LANItemPreprocessorTests {

    @Test
    func changingMacOrderReusesPerItemOCR() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let extractor = ItemCountingTextExtractor()
        let preprocessor = LANItemPreprocessor(
            inbox: fixture.store,
            textExtractor: extractor
        )
        try await upload(
            try image(red: 10, green: 40, blue: 80),
            name: "one.png",
            sessionID: UUID(),
            store: fixture.store
        )
        try await upload(
            try image(red: 80, green: 40, blue: 10),
            name: "two.png",
            sessionID: UUID(),
            store: fixture.store
        )
        let ids = try await fixture.store.loadSnapshot().items.map(\.id)
        _ = try await preprocessor.preprocess(itemIDs: ids)
        let first = try await preprocessor.preparedSelection(
            itemIDs: ids,
            canonicalReportDate: Date(timeIntervalSinceReferenceDate: 10)
        )
        let second = try await preprocessor.preparedSelection(
            itemIDs: Array(ids.reversed()),
            canonicalReportDate: Date(timeIntervalSinceReferenceDate: 20)
        )

        #expect(await extractor.callCount == 2)
        #expect(second.sources.elements.map(\.id)
            == Array(first.sources.elements.map(\.id).reversed()))
        #expect(second.document.reviewState?.timelineDateSelection
            == .manual(Date(timeIntervalSinceReferenceDate: 20)))
    }

    @Test
    func preprocessingPersistsUnsupportedAndOCRFailureStatesThenRetriesIndependently() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        try await upload(
            Data("not an image or PDF".utf8),
            name: "unsupported.bin",
            sessionID: UUID(),
            store: fixture.store
        )
        try await upload(
            try image(red: 35, green: 70, blue: 105),
            name: "ocr-failure.png",
            sessionID: UUID(),
            store: fixture.store
        )
        let initial = try await fixture.store.loadSnapshot()
        let unsupportedID = try #require(
            initial.items.first { $0.displayName.rawValue == "unsupported.bin" }?.id
        )
        let failureID = try #require(
            initial.items.first { $0.displayName.rawValue == "ocr-failure.png" }?.id
        )

        let validator = LANItemPreprocessor(
            inbox: fixture.store,
            textExtractor: ItemCountingTextExtractor()
        )
        let unsupported = try await validator.preprocess(itemID: unsupportedID)
        guard case .unsupported(_, .unsupportedContent) = unsupported.state else {
            Issue.record("Expected an unsupported-content queue state")
            return
        }

        let failing = LANItemPreprocessor(
            inbox: fixture.store,
            textExtractor: AlwaysFailingTextExtractor()
        )
        let failed = try await failing.preprocess(itemID: failureID)
        guard case .failed(_, .preprocessingFailed) = failed.state else {
            Issue.record("Expected a retryable preprocessing failure")
            return
        }

        let retried = try await validator.preprocess(itemID: failureID)
        #expect(retried.isReviewable)
        let final = try await fixture.store.loadSnapshot()
        #expect(final.item(id: unsupportedID)?.isReviewable == false)
        #expect(final.item(id: failureID)?.isReviewable == true)
    }

    private func upload(
        _ bytes: Data,
        name: String,
        sessionID: UUID,
        store: SQLiteLANInboxStore
    ) async throws {
        let metadata = try LANInboxTransportMetadata(
            displayName: LANInboxDisplayName(rawValue: name),
            declaredByteCount: bytes.count,
            mediaType: "image/png"
        )
        let outcome = try await store.startItemUpload(
            transport: LANInboxTransportIdentity(
                sessionID: sessionID,
                remoteFileID: UUID()
            ),
            metadata: metadata,
            attemptRevision: 0,
            admissionGeneration: try await store.itemAdmissionGeneration()
        )
        guard case let .sink(sink) = outcome else {
            throw LANInboxError.invalidState
        }
        try await sink.write(bytes).value
        _ = try await sink.finish()
    }

    private func image(red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = red
            pixels[offset + 1] = green
            pixels[offset + 2] = blue
            pixels[offset + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.last.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw LANInboxError.storageFailure
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw LANInboxError.storageFailure }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw LANInboxError.storageFailure
        }
        return data as Data
    }
}

private actor ItemCountingTextExtractor: TextExtractionService {
    private(set) var callCount = 0

    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        callCount += 1
        return [try OCRBlock(
            pageNumber: 1,
            text: "标题: 合成报告",
            boundingBox: NormalizedRect(
                x: 0.1,
                y: 0.1,
                width: 0.5,
                height: 0.1
            ),
            confidence: 0.99,
            method: .vision,
            engineVersion: "synthetic-item-1"
        )]
    }
}

private struct SyntheticTextExtractionFailure: Error {}

private actor AlwaysFailingTextExtractor: TextExtractionService {
    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        _ = file
        throw SyntheticTextExtractionFailure()
    }
}
