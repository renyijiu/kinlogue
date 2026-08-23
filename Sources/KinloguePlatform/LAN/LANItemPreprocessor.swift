import CryptoKit
import Foundation
import KinlogueCore

public enum LANItemPreprocessorError: Error, Equatable, Sendable {
    case itemNotFound
    case sourceTooLarge
    case invalidDerivedDocument
}

/// Cached, source-local validation and OCR result. Report pages and
/// candidates are rebuilt from the Mac's current explicit selection order.
public struct LANPreprocessedSourceDocument: Codable, Equatable, Sendable {
    public static let maximumEncodedByteCount = 32 * 1_024 * 1_024

    public let source: ReportSource
    public let contentTypeIdentifier: String
    public let blocks: [OCRBlock]

    public init(
        source: ReportSource,
        contentTypeIdentifier: String,
        blocks: [OCRBlock]
    ) throws {
        guard !contentTypeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(blocks.map(\.id)).count == blocks.count else {
            throw LANItemPreprocessorError.invalidDerivedDocument
        }
        let sources = try ReportSources([source])
        guard try blocks.allSatisfy({
            try $0.attributedAndValidated(for: sources) == $0
        }) else {
            throw LANItemPreprocessorError.invalidDerivedDocument
        }
        self.source = source
        self.contentTypeIdentifier = contentTypeIdentifier
        self.blocks = blocks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                source: container.decode(ReportSource.self, forKey: .source),
                contentTypeIdentifier: container.decode(
                    String.self,
                    forKey: .contentTypeIdentifier
                ),
                blocks: container.decode([OCRBlock].self, forKey: .blocks)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid cached OCR source")
            )
        }
    }
}

public struct LANPreparedItemSelection: Equatable, Sendable {
    public let items: [LANInboxItem]
    public let sourceDocuments: [LANPreprocessedSourceDocument]
    public let sources: ReportSources
    public let document: ImportDraftDocument

    public init(
        items: [LANInboxItem],
        sourceDocuments: [LANPreprocessedSourceDocument],
        sources: ReportSources,
        document: ImportDraftDocument
    ) {
        self.items = items
        self.sourceDocuments = sourceDocuments
        self.sources = sources
        self.document = document
    }
}

private actor LANItemPreprocessingGate {
    static let shared = LANItemPreprocessingGate()

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isOccupied = false
    private var nextWaiterID: UInt64 = 0
    private var waiters: [Waiter] = []

    func run<Result: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let waiterID = nextWaiterID
        nextWaiterID &+= 1
        try await acquire(waiterID: waiterID)
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(waiterID: UInt64) async throws {
        try Task.checkCancellation()
        guard isOccupied else {
            isOccupied = true
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    private func cancel(waiterID: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !waiters.isEmpty else {
            isOccupied = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }
}

/// Validates and OCRs canonical pending items one at a time. Successful OCR
/// is persisted per item; assembling a different report order only rebuilds
/// the logical source list and never repeats unchanged OCR work.
public actor LANItemPreprocessor {
    public typealias IDGenerator = @Sendable () -> UUID

    private let inbox: PlaintextLANInboxStore
    private let validator: ImportedFileValidator
    private let textExtractor: any TextExtractionService
    private let candidateExtractor: ReportCandidateExtractor
    private let makeID: IDGenerator

    public init(
        inbox: PlaintextLANInboxStore,
        validator: ImportedFileValidator = ImportedFileValidator(),
        textExtractor: any TextExtractionService = OnDeviceTextExtractionService(),
        candidateExtractor: ReportCandidateExtractor = ReportCandidateExtractor(),
        makeID: @escaping IDGenerator = { UUID() }
    ) {
        self.inbox = inbox
        self.validator = validator
        self.textExtractor = textExtractor
        self.candidateExtractor = candidateExtractor
        self.makeID = makeID
    }

    @discardableResult
    public func preprocess(itemID: LANInboxItem.ID) async throws -> LANInboxItem {
        try await LANItemPreprocessingGate.shared.run { [self] in
            try await performPreprocessing(itemID: itemID)
        }
    }

    @discardableResult
    public func preprocess(itemIDs: [LANInboxItem.ID]) async throws -> [LANInboxItem] {
        guard !itemIDs.isEmpty,
              itemIDs.count <= LANArchiveIntent.maximumSourceCount,
              Set(itemIDs).count == itemIDs.count else {
            throw LANInboxError.invalidModel
        }
        let initialSnapshot = try await inbox.loadSnapshot()
        for itemID in itemIDs {
            guard let item = initialSnapshot.item(id: itemID) else {
                throw LANItemPreprocessorError.itemNotFound
            }
            switch item.state {
            case .stored:
                _ = try await preprocess(itemID: itemID)
            case .reviewable, .failed, .unsupported:
                continue
            case .preprocessing, .integrityFailed:
                continue
            }
        }
        let snapshot = try await inbox.loadSnapshot()
        return try itemIDs.map { itemID in
            guard let item = snapshot.item(id: itemID) else {
                throw LANItemPreprocessorError.itemNotFound
            }
            return item
        }
    }

    public func preparedSelection(
        itemIDs: [LANInboxItem.ID],
        canonicalReportDate: Date
    ) async throws -> LANPreparedItemSelection {
        guard !itemIDs.isEmpty,
              itemIDs.count <= LANArchiveIntent.maximumSourceCount,
              Set(itemIDs).count == itemIDs.count,
              canonicalReportDate.timeIntervalSinceReferenceDate.isFinite else {
            throw LANInboxError.invalidModel
        }
        let snapshot = try await inbox.loadSnapshot()
        let items = try itemIDs.map { itemID in
            guard let item = snapshot.item(id: itemID) else {
                throw LANItemPreprocessorError.itemNotFound
            }
            guard item.isReviewable else { throw LANInboxError.invalidState }
            return item
        }
        var sourceDocuments: [LANPreprocessedSourceDocument] = []
        sourceDocuments.reserveCapacity(items.count)
        for item in items {
            let sourceDocument = try await inbox.withVerifiedItemDerivedContent(
                itemID: item.id
            ) { descriptor in
                let data = try BoundedRegularFileReader.read(
                    descriptor: descriptor,
                    maximumByteCount: LANPreprocessedSourceDocument.maximumEncodedByteCount,
                    oversizeError: LANItemPreprocessorError.sourceTooLarge,
                    checksCancellation: true
                )
                do {
                    return try CanonicalVaultJSON.decode(
                        LANPreprocessedSourceDocument.self,
                        from: data
                    )
                } catch {
                    throw LANItemPreprocessorError.invalidDerivedDocument
                }
            }
            sourceDocuments.append(sourceDocument)
        }
        let sources = try ReportSources(sourceDocuments.map(\.source))
        let blocks = sourceDocuments.flatMap(\.blocks)
        let candidates = try candidateExtractor.extract(from: blocks, sources: sources)
        let reviewState = ImportDraftReviewState(
            timelineDateSelection: .manual(canonicalReportDate),
            title: candidates.title?.transcription ?? "",
            organization: candidates.organization?.transcription ?? "",
            department: candidates.department?.transcription ?? "",
            reportType: candidates.reportType?.transcription ?? "",
            reportedResults: candidates.reportedResults?.transcription ?? "",
            conclusion: candidates.conclusion?.transcription ?? "",
            abnormalItems: candidates.abnormalItems.map(\.transcription),
            userNote: ""
        )
        let document = try ImportDraftDocument(
            blocks: blocks,
            candidates: candidates,
            reviewState: reviewState
        ).attributedAndValidated(for: sources)
        return LANPreparedItemSelection(
            items: items,
            sourceDocuments: sourceDocuments,
            sources: sources,
            document: document
        )
    }

    private func performPreprocessing(
        itemID: LANInboxItem.ID
    ) async throws -> LANInboxItem {
        try Task.checkCancellation()
        let snapshot = try await inbox.loadSnapshot()
        guard let item = snapshot.item(id: itemID) else {
            throw LANItemPreprocessorError.itemNotFound
        }
        if item.isReviewable { return item }
        switch item.state {
        case .stored, .failed, .unsupported:
            break
        case .reviewable:
            return item
        case .preprocessing, .integrityFailed:
            throw LANInboxError.invalidState
        }

        let validated: ValidatedImportedFile
        do {
            let validator = validator
            validated = try await inbox.withVerifiedItemSourceContent(
                itemID: itemID
            ) { descriptor in
                try validator.validate(data: BoundedRegularFileReader.read(
                    descriptor: descriptor,
                    maximumByteCount: validator.limits.maximumFileBytes,
                    oversizeError: LANItemPreprocessorError.sourceTooLarge,
                    checksCancellation: true
                ))
            }
        } catch is ImportedFileValidationError {
            return try await inbox.markItemPreprocessingIssue(
                itemID: itemID,
                expectedRevision: item.revision,
                issue: .unsupportedContent
            )
        } catch LANItemPreprocessorError.sourceTooLarge {
            return try await inbox.markItemPreprocessingIssue(
                itemID: itemID,
                expectedRevision: item.revision,
                issue: .unsupportedContent
            )
        }

        let rawBlocks: [OCRBlock]
        do {
            try Task.checkCancellation()
            rawBlocks = try await textExtractor.extractText(from: validated)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await inbox.markItemPreprocessingIssue(
                itemID: itemID,
                expectedRevision: item.revision,
                issue: .preprocessingFailed
            )
        }

        guard let blob = snapshot.blobs.first(where: { $0.id == item.blobID }) else {
            throw LANInboxError.invalidReference
        }
        let encoded: Data
        do {
            let sourceID = makeID()
            let attachmentID = Self.attachmentID(
                digest: blob.sha256Digest,
                byteCount: blob.byteCount
            )
            let source = try ReportSource(
                id: sourceID,
                attachmentID: attachmentID,
                displayName: item.displayName.rawValue,
                pageCount: validated.pageCount
            )
            let blocks = try rawBlocks.map { block in
                try OCRBlock(
                    id: makeID(),
                    sourceID: sourceID,
                    attachmentID: attachmentID,
                    filePageNumber: block.filePageNumber,
                    text: block.text,
                    boundingBox: block.boundingBox,
                    confidence: block.confidence,
                    method: block.method,
                    engineVersion: block.engineVersion
                )
            }
            encoded = try CanonicalVaultJSON.encode(
                try LANPreprocessedSourceDocument(
                    source: source,
                    contentTypeIdentifier: validated.contentTypeIdentifier,
                    blocks: blocks
                )
            )
        } catch {
            return try await inbox.markItemPreprocessingIssue(
                itemID: itemID,
                expectedRevision: item.revision,
                issue: .preprocessingFailed
            )
        }
        guard encoded.count <= LANPreprocessedSourceDocument.maximumEncodedByteCount else {
            return try await inbox.markItemPreprocessingIssue(
                itemID: itemID,
                expectedRevision: item.revision,
                issue: .preprocessingFailed
            )
        }

        let sink = try await inbox.beginItemDerivedArtifact(
            itemID: itemID,
            expectedRevision: item.revision
        )
        do {
            try await sink.write(encoded).value
            _ = try await sink.finish()
        } catch {
            await sink.abort()
            throw error
        }
        return try await currentItem(itemID: itemID)
    }

    private func currentItem(itemID: LANInboxItem.ID) async throws -> LANInboxItem {
        let snapshot = try await inbox.loadSnapshot()
        guard let item = snapshot.item(id: itemID) else {
            throw LANItemPreprocessorError.itemNotFound
        }
        return item
    }

    private nonisolated static func attachmentID(
        digest: Data,
        byteCount: Int
    ) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data("Kinlogue-LAN-attachment-v1".utf8))
        hasher.update(data: digest)
        var count = UInt64(byteCount).bigEndian
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
