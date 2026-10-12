import Foundation
import GRDB
import KinlogueCore

/// Decoded search fields and their coarse keys, kept while one database stays open.
///
/// Nothing here is trusted on its own: a query hashes the bytes it reads from every search row and
/// uses an entry only when that digest equals the one the entry was built from. The cache saves the
/// decoding and key derivation of identical verified bytes, not the verification.
// SAFETY: `entries` and `cost` are only touched while `lock` is held.
final class SQLiteReportSearchCache: @unchecked Sendable {
    struct Entry: Sendable {
        let fieldsHash: Data
        let fields: [String]
        let key: [UInt8]

        var cost: Int { fields.reduce(key.count + 96 + fields.count * 32) { $0 + $1.utf8.count } }
    }

    /// Rows beyond this budget stay correct; they are decoded again by each query.
    static let costLimit = 64 * 1_024 * 1_024

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var cost = 0

    func snapshot() -> [UUID: Entry] { lock.withLock { entries } }

    /// `present`, when a scan of the whole library supplies it, names every report that still
    /// exists, so the entries of deleted reports go away.
    func update(_ fresh: [(UUID, Entry)], present: Set<UUID>?) {
        lock.withLock {
            if let present {
                for id in entries.keys where !present.contains(id) {
                    cost -= entries.removeValue(forKey: id)?.cost ?? 0
                }
            }
            for (id, entry) in fresh {
                // The row's bytes changed, so its previous entry can never be used again.
                cost -= entries.removeValue(forKey: id)?.cost ?? 0
                guard cost + entry.cost <= Self.costLimit else { continue }
                entries[id] = entry
                cost += entry.cost
            }
        }
    }

    func removeAll() { lock.withLock { entries = [:]; cost = 0 } }
}

/// The rows and database stay on the GRDB queue. Workers receive only owned immutable values.
enum SQLiteReportSearch {
    static let batchByteLimit = 2 * 1_024 * 1_024
    static let batchRowLimit = 512
    static let laneLimit = 8

    struct Candidate: Sendable {
        let ordinal: Int
        let id: UUID
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
        var cachedRowCount = 0
        var directoryMilliseconds = 0.0
    }

    /// One query's term, locale and coarse key. The Foundation search is the only thing that
    /// decides a match; the key only removes fields that cannot match.
    struct Predicate: Sendable {
        let term: String
        let locale: Locale
        let needle: [UInt8]

        init(_ term: String, locale: Locale = .current) {
            self.term = term; self.locale = locale
            needle = SQLiteReportSearchKey.key(term)
        }

        func matches(_ fields: [String], prefilter: Bool) -> Bool {
            prefilter ? matches(fields, key: SQLiteReportSearchKey.key(fields: fields)) : fields.contains { found(in: $0) }
        }

        /// `key` must be `SQLiteReportSearchKey.key(fields:)` of these exact fields.
        func matches(_ fields: [String], key: [UInt8]) -> Bool {
            if term.isEmpty { return true }
            // A term without letters or numbers has no key; every field stays a candidate.
            guard !needle.isEmpty else { return fields.contains { found(in: $0) } }
            guard SQLiteReportSearchKey.contains(needle, in: key) else { return false }
            return SQLiteReportSearchKey.matchingFields(needle, in: key).contains { $0 < fields.count && found(in: fields[$0]) }
        }

        private func found(in field: String) -> Bool {
            RecordQuery.localizedContains(term, in: field, locale: locale)
        }
    }

    private struct Report {
        let id: UUID
        let time: Double?
        let fieldsHash: Data?
        let memberMatches: Bool
        let idHigh: UInt64
        let idLow: UInt64

        init(id: UUID, time: Double?, fieldsHash: Data?, memberMatches: Bool) {
            self.id = id; self.time = time; self.fieldsHash = fieldsHash; self.memberMatches = memberMatches
            (idHigh, idLow) = withUnsafeBytes(of: id.uuid) {
                ($0.loadUnaligned(as: UInt64.self).bigEndian, $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self).bigEndian)
            }
        }

        var date: Date? { time.map(Date.init(timeIntervalSince1970:)) }

        /// `ORDER BY timeline_date DESC, record_id`: undated reports last, equal dates by ID bytes.
        static func precedes(_ left: Self, _ right: Self) -> Bool {
            switch (left.time, right.time) {
            case let (leftTime?, rightTime?) where leftTime != rightTime: leftTime > rightTime
            case (_?, nil): true
            case (nil, _?): false
            default: (left.idHigh, left.idLow) < (right.idHigh, right.idLow)
            }
        }
    }

    /// Reads a 16-byte ID without allocating; the cursor's row is valid only until the next step.
    private static func uuid(_ row: Row, _ index: Int) throws -> UUID {
        try row.withUnsafeData(atIndex: index) { data in
            guard let data, data.count == 16 else { throw SQLiteLibraryError.damaged }
            return data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        }
    }

    private struct LaneOutput: Sendable {
        var found: [(ordinal: Int, damaged: Bool)] = []
        var fresh: [(UUID, SQLiteReportSearchCache.Entry)] = []
        var cached = 0
    }

    // SAFETY: workers publish one independent result per lane under a lock. concurrentPerform
    // drains every lane before results are consumed or the read transaction is allowed to finish.
    private final class LaneResults: @unchecked Sendable {
        let lock = NSLock()
        var values: [Int: Result<LaneOutput, Error>] = [:]
        func put(_ value: Result<LaneOutput, Error>, lane: Int) { lock.withLock { values[lane] = value } }
        func collected(lanes: Int) throws -> [LaneOutput] {
            try lock.withLock { try (0..<lanes).map { try values[$0]!.get() } }
        }
    }

    /// Returns the matching reports in timeline order. Every search row in scope is read and hashed
    /// on every call, so the result is complete and a damaged row is reported whether or not it
    /// would have matched. `prefilter: false` is the independent reference used by tests and the
    /// scale probe: it decodes every row and applies the Core predicate without keys or the cache.
    static func scan(_ db: Database, term: String, memberID: UUID?, cursor: LibraryQueryCursor?,
                     maximumMatches: Int, cancellation: SQLiteReportQueryCancellation,
                     prefilter: Bool = true, cache: SQLiteReportSearchCache? = nil) throws -> Scan {
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
            if prefilter ? predicate.matches(fields, prefilter: true) : RecordQuery.matchesSearchTerm(term, fields: fields) { matchingMembers.insert(id) }
        }

        // The reports in scope. Their search text is not read here, and storage order keeps the read
        // sequential; the order the result must have is applied in memory.
        var clauses: [String] = [], arguments: [DatabaseValue] = []
        if let memberID { clauses.append("member_id=?"); arguments.append(memberID.sqliteBytes.databaseValue) }
        if let cursor {
            if let date = cursor.lastDate {
                clauses.append("(timeline_date < ? OR timeline_date IS NULL OR (timeline_date = ? AND record_id > ?))")
                arguments += [date.timeIntervalSince1970.databaseValue, date.timeIntervalSince1970.databaseValue, cursor.lastID.sqliteBytes.databaseValue]
            } else { clauses.append("timeline_date IS NULL AND record_id > ?"); arguments.append(cursor.lastID.sqliteBytes.databaseValue) }
        }
        let condition = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        var readStart = DispatchTime.now().uptimeNanoseconds
        let directory = try Row.fetchCursor(db, sql: "SELECT record_id, member_id, timeline_date, search_hash FROM reports\(condition)",
            arguments: StatementArguments(arguments))
        var reports: [Report] = []
        while let row = try directory.next() {
            if reports.count % batchRowLimit == 0 { try cancellation.check() }
            reports.append(Report(id: try uuid(row, 0), time: row[2], fieldsHash: row[3],
                memberMatches: matchingMembers.contains(try uuid(row, 1))))
            guard reports.count <= 20_000 else { throw LibraryReportError.resourceLimit }
        }
        reports.sort(by: Report.precedes)
        var ordinals = [UUID: Int](minimumCapacity: reports.count)
        for (ordinal, report) in reports.enumerated() { ordinals[report.id] = ordinal }
        result.readMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1_000_000
        result.directoryMilliseconds = result.readMilliseconds
        result.candidateCount = reports.count

        let cached = prefilter ? (cache?.snapshot() ?? [:]) : [:]
        var seen = [Bool](repeating: false, count: reports.count)
        var found: [(ordinal: Int, damaged: Bool)] = [], fresh: [(UUID, SQLiteReportSearchCache.Entry)] = []
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
                    var output = LaneOutput()
                    for index in (lane * candidates.count / lanes)..<((lane + 1) * candidates.count / lanes) {
                        try cancellation.check()
                        let candidate = candidates[index]
                        autoreleasepool {
                            guard let data = candidate.fields, let fieldsHash = candidate.fieldsHash,
                                  ContentDigest.sha256(data) == fieldsHash,
                                  SQLiteContentHash.hash(domain: "report_search:1", values: [.blob(candidate.id.sqliteBytes), .blob(data)]) == candidate.rowHash else {
                                output.found.append((candidate.ordinal, true)); return
                            }
                            guard prefilter else {
                                guard let fields = try? CanonicalVaultJSON.decode([String].self, from: data) else {
                                    output.found.append((candidate.ordinal, true)); return
                                }
                                if term.isEmpty || candidate.memberMatches || RecordQuery.matchesSearchTerm(term, fields: fields) {
                                    output.found.append((candidate.ordinal, false))
                                }
                                return
                            }
                            let entry: SQLiteReportSearchCache.Entry
                            if let hit = cached[candidate.id], hit.fieldsHash == candidate.fieldsHash {
                                entry = hit; output.cached += 1
                            } else {
                                guard let fields = try? CanonicalVaultJSON.decode([String].self, from: data) else {
                                    output.found.append((candidate.ordinal, true)); return
                                }
                                entry = .init(fieldsHash: fieldsHash, fields: fields, key: SQLiteReportSearchKey.key(fields: fields))
                                output.fresh.append((candidate.id, entry))
                            }
                            if term.isEmpty || candidate.memberMatches || predicate.matches(entry.fields, key: entry.key) {
                                output.found.append((candidate.ordinal, false))
                            }
                        }
                    }
                    return output
                }, lane: lane)
            }
            for output in try outputs.collected(lanes: lanes) {
                found.append(contentsOf: output.found); fresh.append(contentsOf: output.fresh)
                result.cachedRowCount += output.cached
            }
            try cancellation.check()
            batch.removeAll(keepingCapacity: true); byteCount = 0
        }

        // Storage order keeps this a sequential pass; the directory supplies the order afterwards.
        let rows = try Row.fetchCursor(db, sql: """
            SELECT record_id, length(fields) AS field_bytes,
                CASE WHEN length(fields) <= \(LibraryStorageLimits.maximumEntityJSONBytes) THEN fields ELSE NULL END AS search_fields,
                content_hash AS row_hash
            FROM report_search
            """)
        while true {
            try cancellation.check()
            readStart = DispatchTime.now().uptimeNanoseconds
            guard let row = try rows.next() else {
                result.readMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1_000_000
                break
            }
            let id = try uuid(row, 0)
            guard let ordinal = ordinals[id] else {
                result.readMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1_000_000
                continue
            }
            seen[ordinal] = true
            // Row is cursor-backed: length is read before asking GRDB to copy the BLOB.
            let size: Int? = row[1]
            let validSize = size.map { $0 >= 0 && $0 <= LibraryStorageLimits.maximumEntityJSONBytes } == true
            let retainedSize = validSize ? size! : 0
            result.readMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1_000_000
            if !batch.isEmpty, batch.count == batchRowLimit || byteCount + retainedSize > batchByteLimit { try flush() }
            readStart = DispatchTime.now().uptimeNanoseconds
            let report = reports[ordinal]
            batch.append(Candidate(ordinal: ordinal, id: id, fields: validSize ? row[2] : nil,
                fieldsHash: report.fieldsHash, rowHash: row[3], memberMatches: report.memberMatches))
            result.readMilliseconds += Double(DispatchTime.now().uptimeNanoseconds - readStart) / 1_000_000
            byteCount += retainedSize
            // A legal oversized entity is processed alone, never alongside eight large entities.
            if retainedSize > batchByteLimit { try flush() }
        }
        try flush()
        try cancellation.check()
        // A report without its search row cannot be searched, so it is reported rather than skipped.
        for (ordinal, wasSeen) in seen.enumerated() where !wasSeen { found.append((ordinal, true)) }
        found.sort { $0.ordinal < $1.ordinal }
        result.matches = found.prefix(maximumMatches).map {
            Match(id: reports[$0.ordinal].id, date: reports[$0.ordinal].date, damaged: $0.damaged)
        }
        if prefilter, let cache {
            // Only a scan of every report can tell which entries no longer have one.
            let stale = memberID == nil && cursor == nil && result.cachedRowCount != cached.count
            cache.update(fresh, present: stale ? Set(reports.map(\.id)) : nil)
        }
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
    package let cachedRowCount: Int
    package let directoryMilliseconds: Double
}

extension SQLiteReportRepository {
    /// Standalone scale probe only; uses the identical scan and retains at most the format's 20k IDs.
    @concurrent package nonisolated func measureReportSearch(_ query: String, prefilter: Bool = true) async throws -> SQLiteReportSearchMeasurement {
        try await LibraryStorageExecutor.run {
            let cancellation = SQLiteReportQueryCancellation()
            return try await withTaskCancellationHandler {
                try store.read { db in
                    let scan = try SQLiteReportSearch.scan(db, term: query.trimmingCharacters(in: .whitespacesAndNewlines),
                        memberID: nil, cursor: nil, maximumMatches: 20_001, cancellation: cancellation, prefilter: prefilter,
                        cache: store.reportSearchCache)
                    guard scan.matches.count <= 20_000 else { throw LibraryReportError.resourceLimit }
                    return SQLiteReportSearchMeasurement(ids: scan.matches.filter { !$0.damaged }.map(\.id),
                        damagedIDs: scan.matches.filter(\.damaged).map(\.id), sqlReadMilliseconds: scan.readMilliseconds,
                        peakBatchBytes: scan.peakBatchBytes, maximumLanes: scan.maximumLanes, candidateCount: scan.candidateCount,
                        cachedRowCount: scan.cachedRowCount, directoryMilliseconds: scan.directoryMilliseconds)
                }
            } onCancel: { cancellation.cancel() }
        }
    }
}
