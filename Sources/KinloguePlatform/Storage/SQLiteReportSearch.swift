import CoreFoundation
import Foundation
import GRDB
import KinlogueCore

/// The rows and database stay on the GRDB queue. Workers receive only owned immutable values.
enum SQLiteReportSearch {
    static let batchByteLimit = 2 * 1_024 * 1_024
    static let batchRowLimit = 512
    static let laneLimit = 8

    struct Candidate: Sendable {
        let id: UUID
        let date: Date?
        let fields: Data?
        let fieldsHash: Data?
        let rowHash: Data?
        let memberMatches: Bool
    }
    struct Match: Sendable {
        let id: UUID
        let date: Date?
        let damaged: Bool
    }
    struct Scan: Sendable {
        var matches: [Match] = []
        var damagedMemberIDs: [UUID] = []
        var readMilliseconds = 0.0
        var peakBatchBytes = 0
        var maximumLanes = 0
        var candidateCount = 0
    }

    // SAFETY: CF strings/locales are immutable retained values shared read-only by synchronous
    // worker lanes. The Foundation and CF predicates capture the same locale for the whole query.
    final class Predicate: @unchecked Sendable {
        let term: String
        let locale: Locale
        let cfLocale: CFLocale
        let needle: CFString
        init(_ term: String, locale: Locale = .current) {
            self.term = term; self.locale = locale
            cfLocale = CFLocaleCreate(nil, CFLocaleIdentifier(rawValue: locale.identifier as CFString))
            needle = term as CFString
        }
        func matches(_ fields: [String], prefilter: Bool) -> Bool {
            if term.isEmpty { return true }
            if prefilter {
                let joined = fields.joined(separator: "\u{0}") as CFString
                guard CFStringFindWithOptionsAndLocale(joined, needle,
                    CFRange(location: 0, length: CFStringGetLength(joined)),
                    [.compareCaseInsensitive, .compareNonliteral], cfLocale, nil) else { return false }
            }
            // Foundation is the final predicate; a cross-field prefilter match never becomes a result.
            return fields.contains { $0.range(of: term, options: .caseInsensitive, locale: locale) != nil }
        }
    }

    // SAFETY: workers publish one independent result per lane under a lock. concurrentPerform
    // drains every lane before results are consumed or the read transaction is allowed to finish.
    private final class LaneResults: @unchecked Sendable {
        let lock = NSLock()
        var values: [Int: Result<[Match], Error>] = [:]
        func put(_ value: Result<[Match], Error>, lane: Int) { lock.withLock { values[lane] = value } }
        func collected(lanes: Int) throws -> [Match] {
            try lock.withLock { try (0..<lanes).flatMap { try values[$0]!.get() } }
        }
    }

    static func scan(_ db: Database, term: String, memberID: UUID?, cursor: LibraryQueryCursor?,
                     maximumMatches: Int, cancellation: SQLiteReportQueryCancellation,
                     prefilter: Bool = true) throws -> Scan {
        let predicate = Predicate(term)
        var result = Scan(), matchingMembers: Set<UUID> = []
        let memberKeys = try Row.fetchAll(db, sql: "SELECT id, \(SQLiteReportRows.memberTextBytesSQL) AS bytes FROM members ORDER BY id LIMIT 257")
        guard memberKeys.count <= 256 else { throw LibraryReportError.resourceLimit }
        for key in memberKeys {
            try cancellation.check()
            let id = try SQLiteReportRows.uuid(key, "id")
            guard (key["bytes"] as Int) <= LibraryStorageLimits.maximumEntityJSONBytes else { result.damagedMemberIDs.append(id); continue }
            let member: FamilyMember
            do { member = try SQLiteReportRows.member(id, db) }
            catch let error as DatabaseError { throw error }
            catch { result.damagedMemberIDs.append(id); continue }
            let fields = [member.displayName, member.disambiguationLabel].compactMap { $0 }
            if prefilter ? predicate.matches(fields, prefilter: false) : RecordQuery.matchesSearchTerm(term, fields: fields) { matchingMembers.insert(id) }
        }
        var clauses: [String] = [], arguments: [DatabaseValue] = []
        if let memberID { clauses.append("r.member_id=?"); arguments.append(memberID.sqliteBytes.databaseValue) }
        if let cursor {
            if let date = cursor.lastDate {
                clauses.append("(r.timeline_date < ? OR r.timeline_date IS NULL OR (r.timeline_date = ? AND r.record_id > ?))")
                arguments += [date.timeIntervalSince1970.databaseValue, date.timeIntervalSince1970.databaseValue, cursor.lastID.sqliteBytes.databaseValue]
            } else { clauses.append("r.timeline_date IS NULL AND r.record_id > ?"); arguments.append(cursor.lastID.sqliteBytes.databaseValue) }
        }
        let condition = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let rows = try Row.fetchCursor(db, sql: """
            SELECT r.record_id, r.member_id, r.timeline_date, r.search_hash,
                length(s.fields) AS field_bytes,
                CASE WHEN length(s.fields) <= \(LibraryStorageLimits.maximumEntityJSONBytes) THEN s.fields ELSE NULL END AS search_fields, s.content_hash AS row_hash
            FROM reports r LEFT JOIN report_search s ON s.record_id=r.record_id\(condition)
            ORDER BY r.timeline_date DESC, r.record_id
            """, arguments: StatementArguments(arguments))
        var batch: [Candidate] = [], byteCount = 0
        func flush() throws {
            guard !batch.isEmpty else { return }
            let candidates = batch
            let lanes = byteCount > batchByteLimit ? 1 : min(laneLimit, candidates.count)
            result.peakBatchBytes = max(result.peakBatchBytes, byteCount)
            result.maximumLanes = max(result.maximumLanes, lanes)
            let outputs = LaneResults()
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                outputs.put(Result {
                    var found: [Match] = []
                    for index in (lane * candidates.count / lanes)..<((lane + 1) * candidates.count / lanes) {
                        try cancellation.check()
                        let candidate = candidates[index]
                        let value: Match? = autoreleasepool {
                            guard let data = candidate.fields, ContentDigest.sha256(data) == candidate.fieldsHash,
                                  SQLiteContentHash.hash(domain: "report_search:1", values: [.blob(candidate.id.sqliteBytes), .blob(data)]) == candidate.rowHash,
                                  let fields = try? CanonicalVaultJSON.decode([String].self, from: data) else {
                                return Match(id: candidate.id, date: candidate.date, damaged: true)
                            }
                            return term.isEmpty || candidate.memberMatches || (prefilter ? predicate.matches(fields, prefilter: true) : RecordQuery.matchesSearchTerm(term, fields: fields))
                                ? Match(id: candidate.id, date: candidate.date, damaged: false) : nil
                        }
                        if let value { found.append(value) }
                    }
                    return found
                }, lane: lane)
            }
            let found = try outputs.collected(lanes: lanes)
            try cancellation.check()
            result.matches.append(contentsOf: found.prefix(maximumMatches - result.matches.count))
            batch.removeAll(keepingCapacity: true); byteCount = 0
        }
        while result.matches.count < maximumMatches {
            try cancellation.check()
            let readStart = DispatchTime.now().uptimeNanoseconds
            guard let row = try rows.next() else {
                result.readMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1_000_000
                break
            }
            // Row is cursor-backed: length is read before asking GRDB to copy the BLOB.
            let size: Int? = row["field_bytes"]
            result.readMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1_000_000
            let validSize = size.map { $0 >= 0 && $0 <= LibraryStorageLimits.maximumEntityJSONBytes } == true
            let retainedSize = validSize ? size! : 0
            if !batch.isEmpty, batch.count == batchRowLimit || byteCount + retainedSize > batchByteLimit {
                try flush()
                if result.matches.count >= maximumMatches { break }
            }
            let copyStart = DispatchTime.now().uptimeNanoseconds
            let id = try SQLiteReportRows.uuid(row, "record_id")
            let candidate = Candidate(id: id, date: (row["timeline_date"] as Double?).map(Date.init(timeIntervalSince1970:)),
                fields: validSize ? row["search_fields"] : nil, fieldsHash: row["search_hash"], rowHash: row["row_hash"],
                memberMatches: matchingMembers.contains(try SQLiteReportRows.uuid(row, "member_id")))
            result.readMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - copyStart) / 1_000_000
            result.candidateCount += 1
            guard result.candidateCount <= 20_000 else { throw LibraryReportError.resourceLimit }
            batch.append(candidate); byteCount += retainedSize
            // A legal oversized entity is processed alone, never alongside eight large entities.
            if retainedSize > batchByteLimit { try flush() }
        }
        if result.matches.count < maximumMatches { try flush() }
        try cancellation.check()
        return result
    }
}

package struct SQLiteReportSearchMeasurement: Sendable {
    package let ids: [UUID]
    package let damagedIDs: [UUID]
    package let sqlReadMilliseconds: Double
    package let peakBatchBytes: Int
    package let maximumLanes: Int
    package let candidateCount: Int
}

extension SQLiteReportRepository {
    /// Standalone scale probe only; uses the identical scan and retains at most the format's 20k IDs.
    @concurrent package nonisolated func measureReportSearch(_ query: String, prefilter: Bool = true) async throws -> SQLiteReportSearchMeasurement {
        let cancellation = SQLiteReportQueryCancellation()
        return try await withTaskCancellationHandler {
            try store.read { db in
                let scan = try SQLiteReportSearch.scan(db, term: query.trimmingCharacters(in: .whitespacesAndNewlines),
                    memberID: nil, cursor: nil, maximumMatches: 20_001, cancellation: cancellation, prefilter: prefilter)
                guard scan.matches.count <= 20_000 else { throw LibraryReportError.resourceLimit }
                return SQLiteReportSearchMeasurement(ids: scan.matches.filter { !$0.damaged }.map(\.id),
                    damagedIDs: scan.matches.filter(\.damaged).map(\.id), sqlReadMilliseconds: scan.readMilliseconds,
                    peakBatchBytes: scan.peakBatchBytes, maximumLanes: scan.maximumLanes, candidateCount: scan.candidateCount)
            }
        } onCancel: { cancellation.cancel() }
    }
}
