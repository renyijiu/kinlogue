import Darwin
import Foundation
import os
import GRDB
import KinlogueCore
import KinlogueSQLiteConfiguration

package enum SQLiteLibraryError: Error, Equatable {
    case occupied
    case unsupportedFormat
    case unsupportedConfiguration
    case invalidPath
    case staleRoot
    case damaged
    case databaseUnavailable
    case closed
    case invalidOriginal
    case originalPinned
    case originalBusy
    case injectedFailure
    case ioFailure(Int32)
}

package struct SQLiteLibraryState: Equatable, Sendable {
    package let libraryID: UUID
    package let generation: Int64
    package let commitID: UUID

    var contentHash: Data {
        SQLiteContentHash.hash(domain: "library_state:1", values: [
            .blob(libraryID.sqliteBytes), .integer(generation), .blob(commitID.sqliteBytes),
            .blob(SQLiteLibrarySchema.identity)
        ])
    }

    @discardableResult
    static func advance(in db: Database) throws -> Self {
        let current = try read(from: db)
        guard current.generation < Int64.max else { throw CatalogDeletionError.generationExhausted }
        let next = Self(libraryID: current.libraryID, generation: current.generation + 1, commitID: UUID())
        try db.execute(sql: "UPDATE library_state SET generation = ?, commit_id = ?, content_hash = ? WHERE singleton = 1",
                       arguments: [next.generation, next.commitID.sqliteBytes, next.contentHash])
        return next
    }

    static func read(from db: Database) throws -> Self {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM library_state LIMIT 2")
        guard rows.count == 1, let row = rows.first,
              row["singleton"] as Int == 1,
              let libraryID = UUID(sqliteBytes: row["library_id"]),
              let commitID = UUID(sqliteBytes: row["commit_id"]),
              row["schema_identity"] as Data == SQLiteLibrarySchema.identity else {
            throw SQLiteLibraryError.damaged
        }
        let state = Self(libraryID: libraryID, generation: row["generation"], commitID: commitID)
        guard state.generation >= 0, state.contentHash == row["content_hash"] as Data else {
            throw SQLiteLibraryError.damaged
        }
        return state
    }
}

package struct SQLiteEngineConfiguration: Sendable {
    package let sqliteVersion: Int32
    package let journalMode: String
    package let synchronous: Int
    package let fullfsync: Int
    package let foreignKeys: Int
    package let trustedSchema: Int
    package let defensive: Int32
    package let extensionLoading: Int32

    static func read(from db: Database) throws -> Self {
        // Direct column octet_length is required by bounded hot TEXT projections. Verify
        // actual UTF-8/NUL/blob semantics instead of inferring capability from an OS version.
        do {
            guard let row = try Row.fetchOne(db, sql: "SELECT octet_length(CAST(X'e5908800c3a9' AS TEXT)) AS text_bytes, octet_length(X'00ff') AS blob_bytes, octet_length(NULL) IS NULL AS null_ok"),
                  row["text_bytes"] as Int == 6, row["blob_bytes"] as Int == 2, row["null_ok"] as Bool else {
                throw SQLiteLibraryError.unsupportedConfiguration
            }
        } catch { throw SQLiteLibraryError.unsupportedConfiguration }
        var defensive: Int32 = 0
        var extensions: Int32 = 1
        guard kinlogue_sqlite_configuration(db.sqliteConnection, &defensive, &extensions) == SQLITE_OK,
              try String.fetchOne(db, sql: "PRAGMA encoding") == "UTF-8",
              let journal = try String.fetchOne(db, sql: "PRAGMA journal_mode"),
              let synchronous = try Int.fetchOne(db, sql: "PRAGMA synchronous"),
              let fullfsync = try Int.fetchOne(db, sql: "PRAGMA fullfsync"),
              let foreignKeys = try Int.fetchOne(db, sql: "PRAGMA foreign_keys"),
              let trustedSchema = try Int.fetchOne(db, sql: "PRAGMA trusted_schema") else {
            throw SQLiteLibraryError.unsupportedConfiguration
        }
        return Self(sqliteVersion: Database.sqliteLibVersionNumber, journalMode: journal,
                    synchronous: synchronous, fullfsync: fullfsync, foreignKeys: foreignKeys,
                    trustedSchema: trustedSchema, defensive: defensive, extensionLoading: extensions)
    }

    func validate() throws {
        guard journalMode == "delete", synchronous == 3, fullfsync == 1,
              foreignKeys == 1, trustedSchema == 0, defensive == 1, extensionLoading == 0 else {
            throw SQLiteLibraryError.unsupportedConfiguration
        }
    }
}

package enum SQLiteLibraryOpenMode: Sendable { case normal, strictExisting }

/// Serializes the connection, owner, pin and active-original state of one store.
final class SQLiteAdmission: Sendable {
    private let lock = NSLock()
#if DEBUG
    private let observer = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    /// Called when admission is requested on a cooperative-pool thread, where waiting for it
    /// holds up unrelated tasks. Tests install it to prove that an entry point left the pool.
    var onCooperativePoolEntry: (@Sendable () -> Void)? {
        get { observer.withLock { $0 } }
        set { observer.withLock { $0 = newValue } }
    }
#endif

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
#if DEBUG
        if let onCooperativePoolEntry, LibraryStorageExecutor.callerIsOnCooperativePool { onCooperativePoolEntry() }
#endif
        return try lock.withLock(body)
    }
}

/// The library's storage kernel: one owner, one SQLite connection and the originals directory.
// SAFETY: admission serializes connection, owner, pin and active-original state. GRDB owns its serial DB queue.
package final class SQLiteLibraryStore: @unchecked Sendable {
    package static let databaseFilename = "library.sqlite"
    let admission = SQLiteAdmission()
    let notifications = SQLiteCommitNotifications()
    private var owner: SQLiteLibraryOwner?
    private var ownerClaim: UUID?
    var queue: DatabaseQueue?
    private var rootIdentity: SQLiteFileIdentity?
    private var databaseIdentity: SQLiteFileIdentity?
    private var originalsIdentity: SQLiteFileIdentity?
    var pins: [UUID: Int] = [:]
    var activeOriginals: Set<UUID> = []
    var activeDICOMImports: Set<UUID> = []
    package let originalReadMetrics = SQLiteOriginalReadMetrics()
    let reportSearchCache = SQLiteReportSearchCache()
    let integrityProgress = SQLiteIntegrityProgress()
    var quarantinedTargets: Set<SQLiteIntegrityTarget> = [] // Protected by admission, scoped to openEpoch.
    private(set) var openEpoch = UUID()
    let originalFault: (@Sendable (SQLiteOriginalFaultPoint) -> Bool)?
    private let initializationFault: (@Sendable (SQLiteInitializationFaultPoint) -> Bool)?
    package let rootURL: URL

    package convenience init(
        rootURL: URL, originalFault: (@Sendable (SQLiteOriginalFaultPoint) -> Bool)? = nil,
        initializationFault: (@Sendable (SQLiteInitializationFaultPoint) -> Bool)? = nil
    ) throws {
        try self.init(owner: SQLiteLibraryOwner(rootURL: rootURL), mode: .normal,
                      originalFault: originalFault, initializationFault: initializationFault)
    }

    package init(owner: SQLiteLibraryOwner, mode: SQLiteLibraryOpenMode = .normal,
                 originalFault: (@Sendable (SQLiteOriginalFaultPoint) -> Bool)? = nil,
                 initializationFault: (@Sendable (SQLiteInitializationFaultPoint) -> Bool)? = nil) throws {
        self.originalFault = originalFault
        self.initializationFault = initializationFault
        self.owner = owner
        rootURL = owner.rootURL
        do { try openDatabase(mode: mode) } catch {
            try? queue?.close(); queue = nil; self.owner = nil
            throw Self.sanitized(error)
        }
    }

    package func state() throws -> SQLiteLibraryState { try read(SQLiteLibraryState.read) }
    package func engineConfiguration() throws -> SQLiteEngineConfiguration { try read(SQLiteEngineConfiguration.read) }

    func read<T: Sendable>(_ body: (Database) throws -> T) throws -> T {
        try admission.withLock {
            do {
                try validateRoot()
                guard let queue else { throw SQLiteLibraryError.closed }
                return try queue.read(body)
            } catch { throw Self.sanitized(error) }
        }
    }

    func readWithEpoch<T: Sendable>(_ body: (Database) throws -> T) throws -> (T, UUID) {
        try read { db in (try body(db), openEpoch) }
    }

    func read<T: Sendable>(epoch: UUID, _ body: (Database) throws -> T) throws -> T {
        try read { db in
            guard openEpoch == epoch else { throw SQLiteLibraryError.staleRoot }
            return try body(db)
        }
    }

    /// U4/U5 commands own the semantic row hashes and revision update within this transaction.
    func write<T: Sendable>(_ body: (Database) throws -> T) throws -> T {
        var committed: LibraryRevision?
        defer { notifications.publish(committed) }
        return try admission.withLock {
            do {
                try validateRoot()
                guard let queue else { throw SQLiteLibraryError.closed }
                return try commitTransaction(queue, capture: &committed) { db in
                    let value = try body(db)
                    try validateRoot()
                    return value
                }
            } catch { throw Self.sanitized(error) }
        }
    }

    /// Called only after the App has drained every owner of database work and original pins.
    package func destroyLibrary() throws {
        _ = try state()
        guard let owner else { throw SQLiteLibraryError.closed }
        try owner.validate()
        try closeDatabaseForReplacement()
        try owner.validate()
        try LibraryDeletionTransaction(rootURL: rootURL, strictReceipt: true).begin()
    }

    package func closeDatabaseForReplacement() throws {
        try admission.withLock {
            guard pins.isEmpty else { throw SQLiteLibraryError.originalPinned }
            guard activeOriginals.isEmpty, activeDICOMImports.isEmpty else { throw SQLiteLibraryError.originalBusy }
            try queue?.close()
            queue = nil
            releaseDatabaseClaim()
            rootIdentity = nil
            databaseIdentity = nil
            originalsIdentity = nil
        }
        reportSearchCache.removeAll()
        integrityProgress.removeAll()
        notifications.finish()
    }

    package func reopenAfterReplacement() throws {
        try admission.withLock {
            guard owner != nil, queue == nil else { throw SQLiteLibraryError.closed }
            try openDatabase()
        }
    }

    package func close() throws {
        try admission.withLock {
            guard pins.isEmpty else { throw SQLiteLibraryError.originalPinned }
            guard activeOriginals.isEmpty, activeDICOMImports.isEmpty else { throw SQLiteLibraryError.originalBusy }
            try queue?.close()
            queue = nil
            releaseDatabaseClaim()
            owner = nil
        }
        reportSearchCache.removeAll()
        integrityProgress.removeAll()
        notifications.finish()
    }

    deinit {
        // No DB statements escape this kernel's synchronous closures.
        try? queue?.close()
        queue = nil
        releaseDatabaseClaim()
        owner = nil
        notifications.finish()
    }

    private func releaseDatabaseClaim() {
        if let ownerClaim { owner?.releaseDatabase(ownerClaim); self.ownerClaim = nil }
    }

    func validateRoot() throws {
        guard let owner, let rootIdentity, let databaseIdentity, let originalsIdentity else {
            throw SQLiteLibraryError.closed
        }
        try owner.validate()
        guard try SQLiteFileIdentity.directory(at: rootURL) == rootIdentity,
              try SQLiteFileIdentity.regular(at: databaseURL) == databaseIdentity,
              try SQLiteFileIdentity.directory(at: originalsURL) == originalsIdentity else {
            throw SQLiteLibraryError.staleRoot
        }
    }

    var databaseURL: URL { rootURL.appendingPathComponent(Self.databaseFilename) }
    var originalsURL: URL { rootURL.appendingPathComponent("originals", isDirectory: true) }

    private func openDatabase(mode: SQLiteLibraryOpenMode = .normal) throws {
        guard let owner else { throw SQLiteLibraryError.closed }
        ownerClaim = try owner.claimDatabase()
        var completed = false
        defer { if !completed { releaseDatabaseClaim() } }
        try owner.validate()
        var metadata = stat()
        if lstat(rootURL.path, &metadata) != 0 {
            guard errno == ENOENT, mode == .normal else { throw SQLiteLibraryError.invalidPath }
            guard mkdir(rootURL.path, 0o700) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
            try syncDirectory(rootURL.deletingLastPathComponent())
        }
        let currentRootIdentity = try SQLiteFileIdentity.directory(at: rootURL)
        rootIdentity = currentRootIdentity
        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: rootURL.path))
        guard mode == .normal || !entries.contains(Self.databaseFilename + "-journal") else { throw SQLiteLibraryError.damaged }
        let initializing = entries.isEmpty || entries.contains(SQLiteLibraryInitialization.filename)
        guard mode == .normal || !initializing else { throw SQLiteLibraryError.damaged }
        if entries.isEmpty {
            try SQLiteLibraryInitialization(rootIdentity: currentRootIdentity).write(to: rootURL)
            try failInitialization(.afterReceipt)
        }
        if initializing {
            try SQLiteLibraryInitialization.validate(at: rootURL, rootIdentity: currentRootIdentity)
            guard entries.isSubset(of: [Self.databaseFilename, Self.databaseFilename + "-journal", "originals", SQLiteLibraryInitialization.filename]) else {
                throw SQLiteLibraryError.unsupportedFormat
            }
            if !entries.contains("originals") {
                guard mkdir(originalsURL.path, 0o700) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
                try syncDirectory(rootURL)
                try failInitialization(.afterOriginalsDirectory)
            }
            if !entries.contains(Self.databaseFilename) {
                let descriptor = Darwin.open(databaseURL.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw SQLiteLibraryError.ioFailure(errno) }
                Darwin.close(descriptor)
                try syncDirectory(rootURL)
                try failInitialization(.afterDatabaseCreation)
            }
            try preflightHeader(allowInitialization: true)
        } else {
            guard entries.isSubset(of: [Self.databaseFilename, Self.databaseFilename + "-journal", "originals", "dicom-import-journals", "dicom-import-staging"]),
                  entries.contains(Self.databaseFilename), entries.contains("originals") else {
                throw SQLiteLibraryError.unsupportedFormat
            }
            try preflightHeader()
        }
        if entries.contains(Self.databaseFilename + "-journal") {
            _ = try SQLiteFileIdentity.regular(at: URL(fileURLWithPath: databaseURL.path + "-journal"))
        }
        originalsIdentity = try SQLiteFileIdentity.directory(at: originalsURL)
        databaseIdentity = try SQLiteFileIdentity.regular(at: databaseURL)
        var configuration = Configuration()
        configuration.busyMode = .immediateError
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            guard kinlogue_sqlite_configure(db.sqliteConnection) == SQLITE_OK else {
                throw SQLiteLibraryError.unsupportedConfiguration
            }
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
            try db.execute(sql: "PRAGMA synchronous = EXTRA")
            try db.execute(sql: "PRAGMA fullfsync = ON")
            // 32 MiB of pages. A near-limit library's report and search tables then stay in the
            // connection's cache between searches; the 8 MiB default re-read them from the system.
            try db.execute(sql: "PRAGMA cache_size = -32768")
        }
        let opened = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        do {
            let needsSchema = try opened.read { db in
                if initializing,
                   try Int.fetchOne(db, sql: "PRAGMA application_id") == 0,
                   try Int.fetchOne(db, sql: "PRAGMA user_version") == 0 {
                    guard try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_schema") == 0 else {
                        throw SQLiteLibraryError.unsupportedFormat
                    }
                    return true
                }
                // A supported file may recover its DELETE journal; reject schema drift before app SQL.
                try SQLiteLibrarySchema.validate(in: db)
                return false
            }
            try opened.writeWithoutTransaction { db in
                guard try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE") == "delete" else {
                    throw SQLiteLibraryError.unsupportedConfiguration
                }
                try SQLiteEngineConfiguration.read(from: db).validate()
            }
            if needsSchema { try opened.write(SQLiteLibrarySchema.create) }
            if initializing { try failInitialization(.afterSchemaCommit) }
            if needsSchema { try opened.read(SQLiteLibrarySchema.validate) }
            try owner.validate()
            queue = opened
            openEpoch = UUID()
            quarantinedTargets.removeAll()
            integrityProgress.removeAll()
            try validateRoot()
            if initializing {
                let receiptURL = rootURL.appendingPathComponent(SQLiteLibraryInitialization.filename)
                try SQLiteLibraryInitialization.validate(at: rootURL, rootIdentity: currentRootIdentity)
                guard unlink(receiptURL.path) == 0 else { throw SQLiteLibraryError.ioFailure(errno) }
                try syncDirectory(rootURL)
            }
            if mode == .normal { _ = try recoverOriginalsLocked() }
            completed = true
        } catch {
            try? opened.close()
            queue = nil
            throw Self.sanitized(error)
        }
    }

    /// Header reads never open SQLite or recover journals belonging to an unknown format.
    private func preflightHeader(allowInitialization: Bool = false) throws {
        let descriptor = Darwin.open(databaseURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SQLiteLibraryError.invalidPath }
        defer { Darwin.close(descriptor) }
        _ = try SQLiteFileIdentity.regular(descriptor: descriptor)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw SQLiteLibraryError.invalidPath }
        if allowInitialization, metadata.st_size == 0 { return }
        var header = [UInt8](repeating: 0, count: 100)
        guard pread(descriptor, &header, header.count, 0) == header.count,
              Array(header.prefix(16)) == Array("SQLite format 3\0".utf8) else {
            throw SQLiteLibraryError.unsupportedFormat
        }
        func integer(_ offset: Int) -> Int {
            header[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        let known = integer(60) == SQLiteLibrarySchema.version && integer(68) == SQLiteLibrarySchema.applicationID
        let unfinished = allowInitialization && integer(60) == 0 && integer(68) == 0
        guard (known || unfinished), header[18] == 1, header[19] == 1 else { throw SQLiteLibraryError.unsupportedFormat }
    }

    private func failInitialization(_ point: SQLiteInitializationFaultPoint) throws {
        if initializationFault?(point) == true { throw SQLiteLibraryError.injectedFailure }
    }

    func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SQLiteLibraryError.invalidPath }
        defer { Darwin.close(descriptor) }
        if fsync(descriptor) != 0, errno != EINVAL, errno != ENOTSUP { throw SQLiteLibraryError.ioFailure(errno) }
    }

    static func sanitized(_ error: Error) -> Error {
        // SQLite diagnostics can include SQL arguments; expose only fixed semantic failures.
        if let database = error as? DatabaseError {
            return database.resultCode == .SQLITE_FULL ? SQLiteLibraryError.ioFailure(ENOSPC) : SQLiteLibraryError.databaseUnavailable
        }
        switch error {
        case is SQLiteLibraryError, is SQLiteLogicalBackupError, is LibraryReportError, is ImportDraftError,
             is CatalogDeletionError, is DomainValidationError, is LANInboxError, is LANItemPreprocessorError, is DICOMImportError, is DICOMSliceServiceError, is CancellationError:
            return error
        default: return SQLiteLibraryError.damaged
        }
    }
}

extension UUID {
    var sqliteBytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }

    init?(sqliteBytes: Data) {
        guard sqliteBytes.count == 16 else { return nil }
        self = sqliteBytes.withUnsafeBytes { bytes in
            UUID(uuid: bytes.loadUnaligned(as: uuid_t.self))
        }
    }
}

/// Domain separation, type tags and byte lengths prevent ambiguous field concatenation.
/// Semantic field order/version is owned by each command's codec, not by SQLite row order.
enum SQLiteContentHash {
    enum Value { case null, integer(Int64), text(String), blob(Data) }

    static func hash(domain: String, values: [Value]) -> Data {
        var bytes = Data("KLG-SQL-ROW-1\0".utf8)
        append(Data(domain.utf8), to: &bytes)
        for value in values {
            switch value {
            case .null: bytes.append(0)
            case let .integer(value):
                bytes.append(1)
                var bigEndian = value.bigEndian
                withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
            case let .text(value): bytes.append(2); append(Data(value.utf8), to: &bytes)
            case let .blob(value): bytes.append(3); append(value, to: &bytes)
            }
        }
        return ContentDigest.sha256(bytes)
    }

    private static func append(_ value: Data, to bytes: inout Data) {
        var count = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &count) { bytes.append(contentsOf: $0) }
        bytes.append(value)
    }
}
