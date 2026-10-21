import Foundation

// The payload version is independent of the SQLite schema and encrypted-container capacity version.
package enum BackupLogicalKind: UInt8, CaseIterable, Sendable {
    case member = 1, original, reportDocument, lanDocument, report, draft, inbox, terminal, receipt, archiveReceipt, dicom
    /// Logical version 2: one record per saved member chat, holding its turns and their sources.
    case assistantConversation

    /// The kinds a stream of `version` may contain; the footer counts exactly these.
    package static func kinds(forVersion version: Int) -> [BackupLogicalKind] {
        version >= 2 ? allCases : allCases.filter { $0 != .assistantConversation }
    }

    package var maximumCount: Int {
        switch self {
        case .member: 256
        case .original: 25_000
        case .reportDocument: 40_000
        case .report, .draft: 20_000
        case .lanDocument, .inbox, .terminal, .receipt, .archiveReceipt: 5_000
        case .dicom: 256
        case .assistantConversation: 256 * AssistantLimits.maxConversationsPerMember
        }
    }
    package var maximumPayloadBytes: Int {
        // DICOM adds at most 2,000 fingerprint entries (each <128 bytes) to its 16 MiB index.
        if self == .dicom { return 16 * 1_024 * 1_024 + 256 * 1_024 + 1_024 }
        return self == .lanDocument ? 32 * 1_024 * 1_024 + 1_024 : LibraryStorageLimits.maximumEntityJSONBytes + 1_024
    }
}

/// The stream header. Version 1 is the original format; version 2 adds saved member chats; version 3
/// lets a saved turn keep up to `AssistantLimits.maxTurnSources` sources instead of 20, matching
/// library schema v3. Writers produce the current version; readers accept every version, since a
/// backup is how an older library reaches the current schema.
package struct BackupLogicalHeaderV1: Codable, Equatable, Sendable {
    package static let currentVersion = 3
    package static let supportedVersions = 1...3

    package let version: Int
    package let libraryID: UUID
    package let generation: Int64
    package let commitID: UUID
    /// Sources one saved turn may keep in a stream of `version`: 20 before version 3.
    package static func maximumTurnSources(forVersion version: Int) -> Int {
        version >= 3 ? AssistantLimits.maxTurnSources : 20
    }

    package init(version: Int = currentVersion, libraryID: UUID, generation: Int64, commitID: UUID) throws {
        guard generation >= 0, Self.supportedVersions.contains(version) else { throw BackupContractError.invalidField }
        self.version = version; self.libraryID = libraryID; self.generation = generation; self.commitID = commitID
    }
}

package struct BackupLogicalOriginalV1: Codable, Equatable, Sendable {
    package let id: UUID
    package let byteCount: Int
    package let sha256: Data
    package let contentType: String
    package init(id: UUID, byteCount: Int, sha256: Data, contentType: String) throws {
        guard byteCount >= 0, sha256.count == 32, !contentType.isEmpty, contentType.utf8.count <= 256 else { throw BackupContractError.invalidField }
        self.id = id; self.byteCount = byteCount; self.sha256 = sha256; self.contentType = contentType
    }
}

package struct BackupLogicalReportDocumentV1: Codable, Sendable {
    package let revision: UInt64
    package let document: ImportDraftDocument
    package init(revision: UInt64, document: ImportDraftDocument) { self.revision = revision; self.document = document }
}

package struct BackupLogicalLANDocumentV1: Codable, Sendable {
    package let revision: UInt64
    package let source: ReportSource
    package let contentType: String
    package let blocks: [OCRBlock]
    package init(revision: UInt64, source: ReportSource, contentType: String, blocks: [OCRBlock]) {
        self.revision = revision; self.source = source; self.contentType = contentType; self.blocks = blocks
    }
}

package struct BackupLogicalArchiveReceiptV1: Codable, Sendable {
    package let itemIDs: [UUID]
    package let memberID: UUID
    package let date: Date
    package let intent: LANArchiveIntent
    package let outcome: LANArchiveOutcome
    package let generation: Int64
    package init(itemIDs: [UUID], memberID: UUID, date: Date, intent: LANArchiveIntent, outcome: LANArchiveOutcome, generation: Int64) {
        self.itemIDs = itemIDs; self.memberID = memberID; self.date = date; self.intent = intent; self.outcome = outcome; self.generation = generation
    }
}

package struct BackupLogicalDICOMV1: Codable, Sendable {
    package let state: DICOMStudyState
    package let memberID: UUID?
    package let date: Date?
    package let revision: UInt64
    package let fingerprint: DICOMStudyFingerprint
    package let index: DICOMStudyIndex
    package init(header: DICOMStudyHeader, index: DICOMStudyIndex) {
        state = header.state; memberID = header.confirmedMemberID; date = header.effectiveDate
        revision = header.contentRevision; fingerprint = header.fingerprint; self.index = index
    }
    package func header() throws -> DICOMStudyHeader {
        try DICOMStudyHeader(id: index.studyID, state: state, fingerprint: fingerprint,
            attachmentIDs: index.retainedObjects.map(\.attachmentID), confirmedMemberID: memberID, effectiveDate: date, contentRevision: revision)
    }
}
