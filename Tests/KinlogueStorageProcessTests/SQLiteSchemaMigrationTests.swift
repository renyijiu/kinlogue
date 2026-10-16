import Foundation
import GRDB
import Testing
@testable import KinloguePlatform

/// The library's one schema migration, v1 to v2, run on the frozen v1 bytes in
/// `SQLiteLibraryV1Fixture.swift` (member chat plan, section 4.9).
@Suite(.serialized)
struct SQLiteSchemaMigrationTests {
    static let assistantTables: Set<String> = ["assistant_conversations", "assistant_turns", "assistant_turn_sources"]

    @Test
    func openingAFrozenV1LibraryAddsOnlyTheAssistantTables() throws {
        let fixture = try StorageProcessVaultFixture()
        defer { try? fixture.removeOwnedParent() }
        try materializeFrozenV1Library(at: fixture.rootURL)
        let before = try RawLibrarySnapshot(root: fixture.rootURL)
        #expect(before.userVersion == 1)
        #expect(before.tables["members"]?.count == 2 && before.tables["reports"]?.count == 1)

        let store = try SQLiteLibraryStore(rootURL: fixture.rootURL)
        let state = try store.state()
        try store.close()
        let after = try RawLibrarySnapshot(root: fixture.rootURL)

        #expect(after.userVersion == 2)
        #expect(Set(after.tables.keys).subtracting(before.tables.keys) == Self.assistantTables)
        #expect(Self.assistantTables.allSatisfy { after.tables[$0] == [] })
        for (table, rows) in before.tables where table != "library_state" {
            #expect(after.tables[table] == rows, "\(table) changed")
        }
        let old = try #require(before.tables["library_state"]?.first)
        let new = try #require(after.tables["library_state"]?.first)
        for column in ["singleton", "library_id", "generation", "commit_id"] {
            #expect(old[column] == new[column], "library_state.\(column) changed")
        }
        #expect(old["schema_identity"] != new["schema_identity"])
        #expect(old["content_hash"] != new["content_hash"])
        #expect(state.generation == before.generation)

        // A v2 library opens without any write.
        let migrated = try Data(contentsOf: fixture.rootURL.appendingPathComponent(SQLiteLibraryStore.databaseFilename))
        try SQLiteLibraryStore(rootURL: fixture.rootURL).close()
        #expect(try Data(contentsOf: fixture.rootURL.appendingPathComponent(SQLiteLibraryStore.databaseFilename)) == migrated)
    }

    @Test
    func theMigratedLibraryServesItsExistingRecords() async throws {
        let fixture = try StorageProcessVaultFixture()
        defer { try? fixture.removeOwnedParent() }
        try materializeFrozenV1Library(at: fixture.rootURL)
        let store = try SQLiteLibraryStore(rootURL: fixture.rootURL)
        defer { try? store.close() }
        let repository = SQLiteReportRepository(store: store)

        let member = try await repository.member(UUID(uuidString: "6E1D3C2A-0F0B-4E7D-9C11-3A1B2C3D4E5F")!)
        #expect(member.displayName == "Synthetic v1 member")
        let record = try await repository.record(UUID(uuidString: "8A3F5E4C-2B2D-4A9F-9E33-5C3D4E5F6071")!)
        #expect(record.reportedResults?.transcription == "Glucose\t5.1\tmmol/L")
        #expect(record.notes.map(\.text) == ["Synthetic v1 note"])
        // Every row passes inspection. The frozen originals rows record the inodes of the files on
        // the machine that wrote them, so the copies made here read as replaced originals.
        let report = try await SQLiteLibraryIntegrityScrubber(store: store).run()
        #expect(report.completed)
        #expect(report.damagedTargets.allSatisfy { $0.kind == .original })
    }

    @Test(arguments: [0, 3, 99])
    func otherVersionsAreRefusedWithoutRewriting(version: Int) throws {
        let fixture = try StorageProcessVaultFixture()
        defer { try? fixture.removeOwnedParent() }
        try materializeFrozenV1Library(at: fixture.rootURL)
        try rawWrite(fixture.rootURL) { db in try db.execute(sql: "PRAGMA user_version = \(version)") }
        let database = fixture.rootURL.appendingPathComponent(SQLiteLibraryStore.databaseFilename)
        let bytes = try Data(contentsOf: database)

        #expect(throws: SQLiteLibraryError.unsupportedFormat) { _ = try SQLiteLibraryStore(rootURL: fixture.rootURL) }
        #expect(try Data(contentsOf: database) == bytes)
    }

    @Test
    func aV1LibraryThatFailsItsOwnChecksIsNotMigrated() throws {
        let fixture = try StorageProcessVaultFixture()
        defer { try? fixture.removeOwnedParent() }
        try materializeFrozenV1Library(at: fixture.rootURL)
        try rawWrite(fixture.rootURL) { db in try db.execute(sql: "CREATE TABLE stray (id INTEGER) STRICT") }

        #expect(throws: SQLiteLibraryError.damaged) { _ = try SQLiteLibraryStore(rootURL: fixture.rootURL) }
        #expect(try RawLibrarySnapshot(root: fixture.rootURL).userVersion == 1)
    }

    @Test(arguments: SQLiteMigrationFaultPoint.allCases)
    func aFailedMigrationLeavesV1AndTheNextOpenMigrates(point: SQLiteMigrationFaultPoint) throws {
        let fixture = try StorageProcessVaultFixture()
        defer { try? fixture.removeOwnedParent() }
        try materializeFrozenV1Library(at: fixture.rootURL)
        let before = try RawLibrarySnapshot(root: fixture.rootURL)

        #expect(throws: SQLiteLibraryError.injectedFailure) {
            _ = try SQLiteLibraryStore(rootURL: fixture.rootURL, migrationFault: { $0 == point })
        }
        let failed = try RawLibrarySnapshot(root: fixture.rootURL)
        #expect(failed.userVersion == (point == .afterCommit ? 2 : 1))
        try failed.expectComplete()

        try SQLiteLibraryStore(rootURL: fixture.rootURL).close()
        let after = try RawLibrarySnapshot(root: fixture.rootURL)
        #expect(after.userVersion == 2)
        for (table, rows) in before.tables where table != "library_state" { #expect(after.tables[table] == rows) }
    }
}

@Test(arguments: Array(1...SQLiteMigrationFaultPoint.allCases.count))
func sqliteSchemaMigrationLeavesACompleteVersionAfterARealProcessCrash(point: Int) async throws {
    try await withOwnedVaultFixture { fixture in
        try materializeFrozenV1Library(at: fixture.rootURL)
        let before = try RawLibrarySnapshot(root: fixture.rootURL)
        try await withStorageProcessFixture(processCount: 1) { processes in
            let process = processes[0]
            try process.send(.init(operation: "holdSQLiteMigration", rootURL: fixture.rootURL, variant: point))
            #expect(try await process.nextResponse().event == "leaseHeld")
            try await process.crash()
        }
        // Whatever the crash interrupted, SQLite's own recovery yields all of v1 or all of v2.
        let crashed = try RawLibrarySnapshot(root: fixture.rootURL)
        try crashed.expectComplete()
        #expect(crashed.userVersion == (SQLiteMigrationFaultPoint.allCases[point - 1] == .afterCommit ? 2 : 1))

        try SQLiteLibraryStore(rootURL: fixture.rootURL).close()
        let after = try RawLibrarySnapshot(root: fixture.rootURL)
        #expect(after.userVersion == 2)
        for (table, rows) in before.tables where table != "library_state" { #expect(after.tables[table] == rows) }
    }
}

// MARK: - Helpers

func materializeFrozenV1Library(at root: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try manager.createDirectory(at: root.appendingPathComponent("originals"), withIntermediateDirectories: false,
                                attributes: [.posixPermissions: 0o700])
    for (path, encoded) in sqliteLibraryV1FrozenFiles {
        let compressed = try #require(Data(base64Encoded: encoded.filter { !$0.isWhitespace }))
        let data = try (compressed as NSData).decompressed(using: .zlib) as Data
        let url = root.appendingPathComponent(path)
        try data.write(to: url, options: .withoutOverwriting)
        #expect(chmod(url.path, 0o600) == 0)
    }
}

/// Every row of every table through a plain SQLite connection, independent of the App's schema code.
struct RawLibrarySnapshot {
    let userVersion: Int
    let tables: [String: [[String: DatabaseValue]]]
    let schema: [String: String]
    let root: URL

    init(root: URL) throws {
        self.root = root
        let queue = try DatabaseQueue(path: root.appendingPathComponent(SQLiteLibraryStore.databaseFilename).path)
        defer { try? queue.close() }
        (userVersion, tables, schema) = try queue.read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
            var schema: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_schema WHERE sql IS NOT NULL") {
                schema[row["name"]] = row["sql"]
            }
            var tables: [String: [[String: DatabaseValue]]] = [:]
            for name in try String.fetchAll(db, sql: "SELECT name FROM sqlite_schema WHERE type = 'table'") {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(name) ORDER BY rowid")
                tables[name] = rows.map { row in
                    Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, row[$0] as DatabaseValue) })
                }
            }
            return (version, tables, schema)
        }
    }

    var generation: Int64 {
        (tables["library_state"]?.first?["generation"]).flatMap { Int64.fromDatabaseValue($0) } ?? -1
    }

    /// The schema is exactly v1 or exactly v2.
    func expectComplete() throws {
        let expected = Dictionary(uniqueKeysWithValues: SQLiteLibrarySchema.statements(forVersion: userVersion))
        #expect(schema == expected, "schema is neither complete v1 nor complete v2")
    }
}

private func rawWrite(_ root: URL, _ body: (Database) throws -> Void) throws {
    let queue = try DatabaseQueue(path: root.appendingPathComponent(SQLiteLibraryStore.databaseFilename).path)
    defer { try? queue.close() }
    try queue.writeWithoutTransaction(body)
}
