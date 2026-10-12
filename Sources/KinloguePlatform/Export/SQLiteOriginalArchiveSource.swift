import Foundation
import GRDB
import KinlogueCore
import UniformTypeIdentifiers

/// Captures confirmed namespace projections and metadata pins, without loading OCR or report detail payloads.
struct SQLiteOriginalArchiveSource: Sendable {
    let store: SQLiteLibraryStore
    @concurrent func prepare(undatedToken: String) async throws -> PlaintextOriginalArchiveSnapshot {
        let cancellation = SQLiteLogicalCancellation()
        return try await withTaskCancellationHandler {
            let captured = try store.read { db in
                try cancellation.check()
                guard try Int.fetchOne(db, sql: "SELECT count(*) FROM reports")! <= 20_000,
                      try Int.fetchOne(db, sql: "SELECT count(*) FROM dicom_studies")! <= 256,
                      try SQLiteRows.fetchOne(db, sql: "SELECT 1 FROM members WHERE length(CAST(display_name AS BLOB))+coalesce(length(CAST(disambiguation AS BLOB)),0)>16777216 LIMIT 1") == nil,
                      try SQLiteRows.fetchOne(db, sql: "SELECT 1 FROM report_sources WHERE report_id IS NOT NULL GROUP BY report_id HAVING sum(coalesce(length(CAST(display_name AS BLOB)),0))>16777216 OR count(*)>20000 LIMIT 1") == nil else { throw SQLiteLogicalBackupError.resourceLimit }
                var members: [OriginalArchiveMemberProjection] = []
                let memberRows = try SQLiteRows.fetchCursor(db, sql: "SELECT * FROM members ORDER BY id")
                while let row = try memberRows.next() {
                    guard members.count < 256 else { throw SQLiteLogicalBackupError.resourceLimit }
                    try store.requireUnquarantined(.member, SQLiteReportRows.uuid(row, "id"))
                    members.append(OriginalArchiveMemberProjection(member: try SQLiteReportRows.member(row)))
                }
                var entryCount = 0
                var originals: [UUID: SQLiteOriginal] = [:]
                var reports: [OriginalArchiveReportProjection] = []
                let rows = try SQLiteRows.fetchCursor(db, sql: "SELECT * FROM reports ORDER BY record_id")
                while let row = try rows.next() {
                    try cancellation.check()
                    let summary = try SQLiteReportRows.summary(row)
                    try store.requireUnquarantined(.report, summary.id)
                    let count: Int = row["source_count"]
                    guard count <= OriginalArchivePlan.maximumEntryCount - entryCount else { throw OriginalArchivePlanError.maximumEntryCountExceeded }
                    entryCount += count
                    let sources = try SQLiteReportRows.sources(summary.id, report: true, db)
                    guard sources.count == row["source_count"] as Int,
                          try SQLiteReportRows.sourcesHash(sources) == row["sources_hash"] as Data,
                          try SQLiteReportRows.fingerprint(sources, db) == row["fingerprint"] as Data? else { throw SQLiteLibraryError.damaged }
                    for source in sources.elements {
                        try store.requireUnquarantined(.original, source.attachmentID)
                        originals[source.attachmentID] = try SQLiteOriginal.read(source.attachmentID, from: db)
                    }
                    reports.append(.init(id: summary.id, memberID: summary.memberID, sources: sources, timelineDate: summary.timelineDate))
                }
                var studies: [OriginalArchiveStudyProjection] = []
                var dicomIDs: Set<UUID> = []
                let studyRows = try SQLiteRows.fetchCursor(db, sql: "SELECT \(SQLiteDICOMRows.studyProjection) FROM dicom_studies WHERE state='confirmed' ORDER BY id")
                while let row = try studyRows.next() {
                    try cancellation.check()
                    let summary = try SQLiteDICOMRows.summary(row)
                    try store.requireUnquarantined(.study, summary.id)
                    guard let member = summary.confirmedMemberID, let date = summary.effectiveDate else { throw SQLiteLibraryError.damaged }
                    guard summary.retainedObjectCount <= OriginalArchivePlan.maximumEntryCount - entryCount else { throw OriginalArchivePlanError.maximumEntryCountExceeded }
                    entryCount += summary.retainedObjectCount
                    let objects = try SQLiteRows.fetchAll(db, sql: "SELECT * FROM dicom_objects WHERE study_id=? ORDER BY original_id LIMIT 2001", arguments: [summary.id.sqliteBytes])
                    guard objects.count == summary.retainedObjectCount,
                          SQLiteDICOMRows.collectionHash("dicom-study-objects", objects.map { $0["content_hash"] }) == row["objects_hash"] as Data else { throw SQLiteLibraryError.damaged }
                    let values = try objects.map { try SQLiteDICOMRows.object($0, db).1 }
                    for value in values {
                        try store.requireUnquarantined(.original, value.id)
                        originals[value.id] = value; dicomIDs.insert(value.id)
                    }
                    studies.append(.init(id: summary.id, memberID: member, date: date, attachmentIDs: values.map(\.id)))
                }
                guard originals.count <= 20_000 else { throw SQLiteLogicalBackupError.resourceLimit }
                return (members, reports, studies, dicomIDs, SQLiteLogicalOriginalPins(store: store, originals: originals))
            }
            let pins = captured.4
            do {
                try cancellation.check()
                let attachments = try pins.originals.values.map { try Attachment(id: $0.id, contentTypeIdentifier: $0.contentType, byteCount: $0.byteCount, sha256Digest: $0.sha256) }
                let extensions = Dictionary(uniqueKeysWithValues: attachments.map {
                    ($0.id, captured.3.contains($0.id) ? "dcm" : UTType($0.contentTypeIdentifier)?.preferredFilenameExtension ?? "bin")
                })
                let plan = try OriginalArchivePlan.make(members: captured.0, attachments: attachments, reports: captured.1,
                    studies: captured.2, preferredExtensions: extensions, undatedToken: undatedToken)
                return PlaintextOriginalArchiveSnapshot(plan: plan, pins: pins, rootURL: store.rootURL)
            } catch { pins.release(); throw error }
        } onCancel: { cancellation.cancel() }
    }
}
