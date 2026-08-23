import Foundation
import Testing
@testable import KinlogueCore

@Suite("LAN inbox pending items")
struct LANInboxItemTests {
    @Test
    func itemUsesContentIdentityAndStableSequence() throws {
        let blobID = uuid(1)
        let identity = try LANInboxContentIdentity(
            sha256Digest: Data(repeating: 7, count: 32),
            byteCount: 42
        )
        let item = try LANInboxItem(
            id: uuid(2),
            originatingSessionID: uuid(3),
            displayName: LANInboxDisplayName(rawValue: "report.pdf"),
            receivedAt: fixtureDate,
            sequence: 9,
            contentIdentity: identity,
            state: .stored(blobID: blobID)
        )

        #expect(item.blobID == blobID)
        #expect(item.sequence == 9)
        #expect(!item.isReviewable)

        let preprocessing = try item.transitioning(
            to: .preprocessing(blobID: blobID, attemptID: uuid(4)),
            expectedRevision: 0
        )
        #expect(preprocessing.revision == 1)
        #expect(preprocessing.sequence == item.sequence)
        #expect(preprocessing.contentIdentity == identity)
        #expect(throws: LANInboxError.staleRevision) {
            _ = try item.transitioning(
                to: .preprocessing(blobID: blobID, attemptID: uuid(5)),
                expectedRevision: 1
            )
        }
        #expect(throws: LANInboxError.invalidState) {
            _ = try item.transitioning(
                to: .preprocessing(blobID: uuid(6), attemptID: uuid(7)),
                expectedRevision: 0
            )
        }
    }

    @Test
    func contentIdentityRejectsMalformedDigestAndLength() {
        #expect(throws: LANInboxError.invalidDigest) {
            _ = try LANInboxContentIdentity(
                sha256Digest: Data(repeating: 1, count: 31),
                byteCount: 1
            )
        }
        #expect(throws: LANInboxError.invalidByteCount) {
            _ = try LANInboxContentIdentity(
                sha256Digest: Data(repeating: 1, count: 32),
                byteCount: -1
            )
        }
    }

    @Test
    func deleteTerminalFencesOnlyAlreadyAdmittedBodies() throws {
        let identity = try contentIdentity(8)
        let terminal = try LANInboxContentTerminal(
            id: uuid(10),
            sessionID: uuid(11),
            contentIdentity: identity,
            createdAt: fixtureDate,
            kind: .deleted(admissionGenerationCutoff: 12)
        )

        #expect(terminal.applies(sessionID: uuid(11), admissionGeneration: 12))
        #expect(!terminal.applies(sessionID: uuid(11), admissionGeneration: 13))
        #expect(!terminal.applies(sessionID: uuid(99), admissionGeneration: 1))
    }

    @Test
    func archiveTerminalFencesTheRestOfTheSession() throws {
        let terminal = try LANInboxContentTerminal(
            id: uuid(20),
            sessionID: uuid(21),
            contentIdentity: contentIdentity(9),
            createdAt: fixtureDate,
            kind: .archived
        )

        #expect(terminal.applies(sessionID: uuid(21), admissionGeneration: 0))
        #expect(terminal.applies(sessionID: uuid(21), admissionGeneration: .max))
        #expect(!terminal.applies(sessionID: uuid(22), admissionGeneration: 0))
    }

    @Test
    func transportReceiptIsMetadataOnlyAndDetectsConflicts() throws {
        let transport = LANInboxTransportIdentity(
            sessionID: uuid(30),
            remoteFileID: uuid(31)
        )
        let metadata = try LANInboxTransportMetadata(
            displayName: LANInboxDisplayName(rawValue: "scan.jpg"),
            declaredByteCount: 10,
            mediaType: "image/jpeg"
        )
        let receipt = try LANInboxTransportReceipt(
            id: uuid(32),
            transport: transport,
            metadata: metadata,
            attemptRevision: 2,
            contentIdentity: contentIdentity(10),
            completedAt: fixtureDate,
            outcome: .published(itemID: uuid(33))
        )

        #expect(receipt.matches(transport: transport, metadata: metadata))
        #expect(!receipt.matches(
            transport: transport,
            metadata: try LANInboxTransportMetadata(
                displayName: LANInboxDisplayName(rawValue: "other.jpg"),
                declaredByteCount: 10,
                mediaType: "image/jpeg"
            )
        ))
        #expect(receipt.blobID == nil)
    }

    @Test
    func archiveIntentFreezesOrderMemberDateAndFingerprint() throws {
        let first = try LANArchiveSource(
            itemID: uuid(40),
            itemRevision: 1,
            contentIdentity: contentIdentity(40),
            reportSourceID: uuid(41),
            attachmentID: uuid(42)
        )
        let second = try LANArchiveSource(
            itemID: uuid(43),
            itemRevision: 2,
            contentIdentity: contentIdentity(43),
            reportSourceID: uuid(44),
            attachmentID: uuid(45)
        )
        let intent = try LANArchiveIntent(
            id: uuid(46),
            vaultID: uuid(47),
            orderedSources: [first, second],
            memberID: uuid(48),
            canonicalReportDate: fixtureDate,
            draftID: uuid(49),
            documentObjectID: uuid(50)
        )

        #expect(intent.orderedSources.map(\.itemID) == [first.itemID, second.itemID])
        let expectedFingerprint = try ReportFingerprint(sources: [
            first.contentIdentity.reportSourceDigest,
            second.contentIdentity.reportSourceDigest,
        ])
        #expect(intent.fingerprint == expectedFingerprint)
    }

    private var fixtureDate: Date { Date(timeIntervalSinceReferenceDate: 123) }

    private func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, value
        ))
    }

    private func contentIdentity(_ value: UInt8) throws -> LANInboxContentIdentity {
        try LANInboxContentIdentity(
            sha256Digest: Data(repeating: value, count: 32),
            byteCount: Int(value)
        )
    }
}
