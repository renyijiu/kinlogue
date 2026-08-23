import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite("LAN report selection archive", .serialized)
struct LANReportArchiveTests {
    @Test
    func orderedItemsCreateOneDatedReviewDraftAndDrainOnlySelection() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let vault = try PlaintextVault(rootURL: fixture.rootURL)
        let member = try await addMember("成员甲", to: vault)
        let extractor = ItemCountingTextExtractor()
        let preprocessor = LANItemPreprocessor(
            inbox: fixture.store,
            textExtractor: extractor
        )
        let coordinator = try LANReportArchiveCoordinator(
            rootURL: fixture.rootURL,
            inbox: fixture.store,
            vault: vault,
            preprocessor: preprocessor
        )
        try await upload(
            try image(red: 220, green: 20, blue: 20),
            name: "first.png",
            sessionID: UUID(),
            store: fixture.store
        )
        try await upload(
            try image(red: 20, green: 20, blue: 220),
            name: "second.png",
            sessionID: UUID(),
            store: fixture.store
        )
        let initial = try await fixture.store.loadSnapshot()
        let orderedIDs = initial.items.map(\.id).reversed()
        let date = Date(timeIntervalSinceReferenceDate: 800_000)

        guard case let .accepted(draftID) = try await coordinator.archive(
            itemIDs: Array(orderedIDs),
            memberID: member.id,
            canonicalReportDate: date
        ) else {
            Issue.record("Expected one accepted draft")
            return
        }

        let catalog = try await vault.loadCatalog()
        let draft = try #require(catalog.importDrafts.first { $0.id == draftID })
        #expect(catalog.importDrafts.count == 1)
        #expect(draft.memberID == member.id)
        #expect(draft.sources.elements.map(\.displayName) == ["second.png", "first.png"])
        let document = try await VaultImportDraftStore(vault: vault).loadDocument(
            draftID: draftID
        )
        #expect(document.reviewState?.timelineDateSelection == .manual(date))
        #expect(document.reviewState?.title == "合成报告")
        #expect(await extractor.callCount == 2)
        let drained = try await fixture.store.loadSnapshot()
        #expect(drained.items.isEmpty)
        #expect(drained.archiveTerminals.isEmpty)
        #expect(drained.transportReceipts.allSatisfy {
            if case .archived = $0.outcome { true } else { false }
        })
    }

    @Test
    func recoveredReviewableItemWithoutReceiptArchivesAHighPrecisionDate() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let vault = try PlaintextVault(rootURL: fixture.rootURL)
        let member = try await addMember("成员甲", to: vault)
        let preprocessor = LANItemPreprocessor(
            inbox: fixture.store,
            textExtractor: ItemCountingTextExtractor()
        )
        let coordinator = try LANReportArchiveCoordinator(
            rootURL: fixture.rootURL,
            inbox: fixture.store,
            vault: vault,
            preprocessor: preprocessor
        )
        let sessionID = UUID()
        try await upload(
            try image(red: 80, green: 160, blue: 220),
            name: "recovered.png",
            sessionID: sessionID,
            store: fixture.store
        )
        let uploaded = try await fixture.store.loadSnapshot()
        let itemID = try #require(uploaded.items.first?.id)
        _ = try await preprocessor.preprocess(itemID: itemID)
        try await fixture.store.endItemSession(sessionID: sessionID)
        let recovered = try await fixture.store.loadSnapshot()
        #expect(recovered.transportReceipts.isEmpty)
        #expect(recovered.items.first?.isReviewable == true)

        let selectedDate = Date(timeIntervalSince1970: 1_786_000_000.0056)
        guard case let .accepted(draftID) = try await coordinator.archive(
            itemIDs: [itemID],
            memberID: member.id,
            canonicalReportDate: selectedDate
        ) else {
            Issue.record("Expected the recovered item to create a review draft")
            return
        }

        let catalog = try await vault.loadCatalog()
        let draft = try #require(catalog.importDrafts.first { $0.id == draftID })
        let document = try await VaultImportDraftStore(vault: vault).loadDocument(
            draftID: draft.id
        )
        let persistenceStableDate = CanonicalVaultJSON.persistenceStableDate(selectedDate)
        #expect(document.reviewState?.timelineDateSelection == .manual(persistenceStableDate))
        #expect((try await fixture.store.loadSnapshot()).items.isEmpty)
    }

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
    func exactReportMatchIgnoresNewMemberDateAndNameAndDrainsItem() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let vault = try PlaintextVault(rootURL: fixture.rootURL)
        let firstMember = try await addMember("成员甲", to: vault)
        let secondMember = try await addMember("成员乙", to: vault)
        let preprocessor = LANItemPreprocessor(
            inbox: fixture.store,
            textExtractor: ItemCountingTextExtractor()
        )
        let coordinator = try LANReportArchiveCoordinator(
            rootURL: fixture.rootURL,
            inbox: fixture.store,
            vault: vault,
            preprocessor: preprocessor
        )
        let bytes = try image(red: 70, green: 90, blue: 110)
        try await upload(
            bytes,
            name: "original.png",
            sessionID: UUID(),
            store: fixture.store
        )
        let firstID = try #require(
            try await fixture.store.loadSnapshot().items.first?.id
        )
        guard case let .accepted(draftID) = try await coordinator.archive(
            itemIDs: [firstID],
            memberID: firstMember.id,
            canonicalReportDate: Date(timeIntervalSinceReferenceDate: 100)
        ) else {
            Issue.record("Expected initial draft")
            return
        }

        try await upload(
            bytes,
            name: "renamed.png",
            sessionID: UUID(),
            store: fixture.store
        )
        let duplicateID = try #require(
            try await fixture.store.loadSnapshot().items.first?.id
        )
        guard case let .duplicateSkipped(destination) = try await coordinator.archive(
            itemIDs: [duplicateID],
            memberID: secondMember.id,
            canonicalReportDate: Date(timeIntervalSinceReferenceDate: 999)
        ) else {
            Issue.record("Expected exact duplicate")
            return
        }

        #expect(destination == .init(kind: .importDraft, id: draftID))
        let catalog = try await vault.loadCatalog()
        #expect(catalog.importDrafts.count == 1)
        #expect(catalog.importDrafts.first?.memberID == firstMember.id)
        #expect(try await fixture.store.loadSnapshot().items.isEmpty)
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

    @Test
    func startupResumesDurableIntentAndRemovesTerminalStagingDebt() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let vault = try PlaintextVault(rootURL: fixture.rootURL)
        let member = try await addMember("成员甲", to: vault)
        let firstBytes = try image(red: 120, green: 30, blue: 60)
        try await upload(
            firstBytes,
            name: "resume.png",
            sessionID: UUID(),
            store: fixture.store
        )
        try await upload(
            try image(red: 60, green: 30, blue: 120),
            name: "retained.png",
            sessionID: UUID(),
            store: fixture.store
        )
        let preprocessor = LANItemPreprocessor(
            inbox: fixture.store,
            textExtractor: ItemCountingTextExtractor()
        )
        let initial = try await fixture.store.loadSnapshot()
        let selected = try #require(
            initial.items.first { $0.displayName.rawValue == "resume.png" }
        )
        _ = try await preprocessor.preprocess(itemID: selected.id)
        let prepared = try await preprocessor.preparedSelection(
            itemIDs: [selected.id],
            canonicalReportDate: Date(timeIntervalSinceReferenceDate: 444)
        )
        let current = try await fixture.store.loadSnapshot()
        let preparedItem = try #require(prepared.items.first)
        let preparedSource = try #require(prepared.sourceDocuments.first?.source)
        let intent = try LANArchiveIntent(
            vaultID: current.vaultID,
            orderedSources: [try LANArchiveSource(
                itemID: preparedItem.id,
                itemRevision: preparedItem.revision,
                contentIdentity: preparedItem.contentIdentity,
                reportSourceID: preparedSource.id,
                attachmentID: preparedSource.attachmentID
            )],
            memberID: member.id,
            canonicalReportDate: Date(timeIntervalSinceReferenceDate: 444),
            draftID: UUID(),
            documentObjectID: UUID()
        )
        guard case .active = try await fixture.store.prepareArchive(intent) else {
            Issue.record("Expected a durable active archive intent")
            return
        }

        let recoveredStore = try PlaintextLANInboxStore(rootURL: fixture.rootURL)
        _ = try await recoveredStore.initialize()
        let recoveredPreprocessor = LANItemPreprocessor(
            inbox: recoveredStore,
            textExtractor: ItemCountingTextExtractor()
        )
        let recoveredCoordinator = try LANReportArchiveCoordinator(
            rootURL: fixture.rootURL,
            inbox: recoveredStore,
            vault: vault,
            preprocessor: recoveredPreprocessor,
            failureInjector: { $0 == .beforeTerminalCleanup }
        )
        let workflow = LANPendingQueueWorkflow(
            inbox: recoveredStore,
            preprocessor: recoveredPreprocessor,
            archiveCoordinator: recoveredCoordinator
        )
        await workflow.resumeInterruptedWork()

        let resumed = try await recoveredStore.loadSnapshot()
        #expect(resumed.archiveIntents.isEmpty)
        #expect(resumed.archiveTerminals.contains { $0.intent.id == intent.id })
        #expect(resumed.items.map(\.displayName.rawValue) == ["retained.png"])
        #expect(try await vault.loadCatalog().importDrafts.contains {
            $0.id == intent.draftID
        })

        let stagingPath = PlaintextVault.stagingPath(
            intentID: intent.id,
            attachmentID: preparedSource.attachmentID
        )
        let files = try AtomicFileStore(rootURL: fixture.rootURL)
        #expect(files.exists(relativePath: stagingPath))
        let terminal = try #require(resumed.archiveTerminal(intentID: intent.id))
        let replayed = try await recoveredStore.recordArchiveOutcome(
            intentID: intent.id,
            outcome: terminal.receipt.outcome,
            vaultRevision: terminal.receipt.vaultRevision
        )
        #expect(replayed == terminal)

        let secondRecoveredStore = try PlaintextLANInboxStore(rootURL: fixture.rootURL)
        _ = try await secondRecoveredStore.initialize()
        let secondPreprocessor = LANItemPreprocessor(
            inbox: secondRecoveredStore,
            textExtractor: ItemCountingTextExtractor()
        )
        let secondCoordinator = try LANReportArchiveCoordinator(
            rootURL: fixture.rootURL,
            inbox: secondRecoveredStore,
            vault: vault,
            preprocessor: secondPreprocessor
        )
        await LANPendingQueueWorkflow(
            inbox: secondRecoveredStore,
            preprocessor: secondPreprocessor,
            archiveCoordinator: secondCoordinator
        ).resumeInterruptedWork()
        #expect(!files.exists(relativePath: stagingPath))
        #expect(try await secondRecoveredStore.loadSnapshot().archiveTerminals.isEmpty)
    }

    @Test
    func successfulArchiveAcknowledgementsDoNotAccumulateLifetimeTerminals() async throws {
        let fixture = try await LANInboxStoreTestFixture.make()
        defer { fixture.destroy() }
        let vault = try PlaintextVault(rootURL: fixture.rootURL)
        let member = try await addMember("成员甲", to: vault)
        let preprocessor = LANItemPreprocessor(
            inbox: fixture.store,
            textExtractor: ItemCountingTextExtractor()
        )
        let coordinator = try LANReportArchiveCoordinator(
            rootURL: fixture.rootURL,
            inbox: fixture.store,
            vault: vault,
            preprocessor: preprocessor
        )

        for index in 0..<3 {
            try await upload(
                try image(
                    red: UInt8(40 + index * 30),
                    green: UInt8(90 + index * 20),
                    blue: UInt8(150 + index * 10)
                ),
                name: "rollover-\(index).png",
                sessionID: UUID(),
                store: fixture.store
            )
            let itemID = try #require(
                try await fixture.store.loadSnapshot().items.first?.id
            )
            _ = try await coordinator.archive(
                itemIDs: [itemID],
                memberID: member.id,
                canonicalReportDate: Date(timeIntervalSinceReferenceDate: Double(900 + index))
            )
            let snapshot = try await fixture.store.loadSnapshot()
            #expect(snapshot.archiveTerminals.isEmpty)
        }
    }

    private func upload(
        _ bytes: Data,
        name: String,
        sessionID: UUID,
        store: PlaintextLANInboxStore
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

    private func addMember(
        _ name: String,
        to vault: PlaintextVault
    ) async throws -> FamilyMember {
        let catalog = try await vault.loadCatalog()
        let member = try FamilyMember(displayName: name)
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: try VaultCatalog(
                formatVersion: catalog.formatVersion,
                vaultID: catalog.vaultID,
                generation: catalog.generation + 1,
                members: catalog.members + [member],
                records: catalog.records,
                attachments: catalog.attachments,
                importDrafts: catalog.importDrafts
            ),
            writes: []
        ))
        return member
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
