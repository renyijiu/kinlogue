import Foundation

public enum DuplicateImport: Equatable, Sendable {
    case record(HealthRecord.ID)
    case draft(ImportDraft.ID)
}

public enum DuplicateDetector {
    public static func find(
        fingerprint: ReportFingerprint,
        attachments: [Attachment],
        records: [HealthRecord],
        drafts: [ImportDraft]
    ) -> DuplicateImport? {
        let record = records
            .filter { $0.importState == .confirmed }
            .filter { (try? ReportFingerprint(
                sources: $0.sources,
                attachments: attachments
            )) == fingerprint }
            .sorted(by: stableIDPrecedes)
            .first
        if let record {
            return .record(record.id)
        }
        let draft = drafts
            .filter { $0.state == .needsReview }
            .filter { (try? ReportFingerprint(
                sources: $0.sources,
                attachments: attachments
            )) == fingerprint }
            .sorted(by: stableIDPrecedes)
            .first
        if let draft {
            return .draft(draft.id)
        }
        return nil
    }

    private static func stableIDPrecedes<T: Identifiable>(_ lhs: T, _ rhs: T) -> Bool
    where T.ID == UUID {
        lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}
