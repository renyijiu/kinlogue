import Foundation
import KinlogueCore

/// Admission checks before allocating canonical JSON; the final encoding remains authoritative.
enum SQLiteEntityBudget {
    static func consumeText(_ text: String?, remaining: inout Int) throws {
        guard let text else { return }
        // Matches JSONEncoder's withoutEscapingSlashes string content (excluding quotes).
        for byte in text.utf8 {
            let count: Int
            switch byte {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x5C: count = 2
            case 0x00...0x1F: count = 6
            default: count = 1
            }
            guard remaining >= count else { throw LibraryReportError.resourceLimit }
            remaining -= count
        }
    }

    static func encode<T: Encodable>(_ value: T, maximum: Int = LibraryStorageLimits.maximumEntityJSONBytes) throws -> Data {
        let data = try CanonicalVaultJSON.encode(value)
        guard data.count <= maximum else { throw LibraryReportError.resourceLimit }
        return data
    }

    static func memberData(_ member: FamilyMember) throws -> Data {
        var remaining = LibraryStorageLimits.maximumEntityJSONBytes
        try consumeText(member.displayName, remaining: &remaining)
        try consumeText(member.disambiguationLabel, remaining: &remaining)
        let validated = try FamilyMember(id: member.id, displayName: member.displayName,
            disambiguationLabel: member.disambiguationLabel, isArchived: member.isArchived)
        guard validated == member else { throw LibraryReportError.invalidDocument }
        return try encode(member)
    }

    static func sourcesData(_ sources: ReportSources, maximum: Int = LibraryStorageLimits.maximumEntityJSONBytes) throws -> Data {
        guard sources.count <= 20_000 else { throw LibraryReportError.resourceLimit }
        var remaining = maximum
        for source in sources.elements { try consumeText(source.displayName, remaining: &remaining) }
        return try encode(sources, maximum: maximum)
    }

    // Reserve exactly the largest legal header so immutable sources remain writable through
    // processing/review/failure, later member selection, and revision digit growth.
    static let maximumDraftHeaderBytes: Result<Int, any Error> = Result {
        let id = UUID()
        let sources = try ReportSources([ReportSource(attachmentID: id, pageCount: 1)])
        let sourceBytes = try CanonicalVaultJSON.encode(sources).count
        let states: [(ImportState, UUID?, UUID?, ImportFailureCode?)] = [
            (.staging, nil, nil, nil), (.processing, id, nil, nil), (.needsReview, nil, id, nil)
        ] + ImportFailureCode.allCases.map { (.failed, nil, nil, $0) }
        return try states.map { state, attempt, document, failure in
            let draft = ImportDraft(id: id, sources: sources, state: state, revision: UInt64(Int64.max),
                attemptID: attempt, documentObjectID: document, failureCode: failure, memberID: id)
            guard draft.isStructurallyValid else { throw LibraryReportError.invalidDocument }
            return try CanonicalVaultJSON.encode(draft).count - sourceBytes
        }.max() ?? 0
    }

    static func draftData(_ draft: ImportDraft) throws -> Data {
        _ = try sourcesData(draft.sources, maximum: LibraryStorageLimits.maximumEntityJSONBytes - maximumDraftHeaderBytes.get())
        return try encode(draft)
    }
}
