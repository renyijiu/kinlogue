import Darwin
import Foundation
import GRDB
import KinlogueCore
import Testing
@testable import KinloguePlatform

@Test
func sqliteKernelCreatesStrictSchemaAndVerifiesActualEngineConfiguration() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    let first = try store.state()
    let configuration = try store.engineConfiguration()
    #expect(configuration.journalMode == "delete")
    #expect(configuration.synchronous == 3)
    #expect(configuration.fullfsync == 1)
    #expect(configuration.foreignKeys == 1)
    #expect(configuration.trustedSchema == 0)
    #expect(configuration.defensive == 1)
    #expect(configuration.extensionLoading == 0)
    #expect(configuration.sqliteVersion > 0)
    let strictTables = try store.read { db in
        try Set(String.fetchAll(db, sql: "SELECT name FROM pragma_table_list WHERE schema = 'main' AND name NOT LIKE 'sqlite_%' AND strict = 1"))
    }
    #expect(strictTables == ["library_state", "members", "originals", "ocr_documents", "reports", "report_details", "report_search",
        "import_drafts", "report_sources", "inbox_items", "inbox_content_terminals", "inbox_transport_receipts", "inbox_uploads", "inbox_archive_receipts",
        "dicom_studies", "dicom_objects", "dicom_series", "dicom_instances"])
    try store.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    #expect(try reopened.state() == first)
    try reopened.close()
}

@Test
func sqliteKernelRejectsSecondOwnerBeforeOpeningDatabaseAndReleasesAfterClose() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let first = try SQLiteLibraryStore(rootURL: root)
    let databaseURL = root.appendingPathComponent(SQLiteLibraryStore.databaseFilename)
    let bytes = try Data(contentsOf: databaseURL)
    #expect(throws: SQLiteLibraryError.occupied) { _ = try SQLiteLibraryStore(rootURL: root) }
    #expect(try Data(contentsOf: databaseURL) == bytes)
    try first.close()
    let next = try SQLiteLibraryStore(rootURL: root)
    try next.close()
}

@Test
func sqliteKernelUnknownRootsAndVersionsRemainUntouched() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let legacy = root.appendingPathComponent("library.json")
    let legacyBytes = Data("synthetic old library".utf8)
    try legacyBytes.write(to: legacy)
    #expect(throws: SQLiteLibraryError.unsupportedFormat) { _ = try SQLiteLibraryStore(rootURL: root) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["library.json"])
    #expect(try Data(contentsOf: legacy) == legacyBytes)
    try FileManager.default.removeItem(at: legacy)
    let store = try SQLiteLibraryStore(rootURL: root)
    try store.close()
    let databaseURL = root.appendingPathComponent(SQLiteLibraryStore.databaseFilename)
    var bytes = try Data(contentsOf: databaseURL)
    bytes.replaceSubrange(60..<64, with: [0, 0, 0, 99])
    try bytes.write(to: databaseURL)
    #expect(throws: SQLiteLibraryError.unsupportedFormat) { _ = try SQLiteLibraryStore(rootURL: root) }
    #expect(try Data(contentsOf: databaseURL) == bytes)
    #expect(!FileManager.default.fileExists(atPath: databaseURL.path + "-journal"))
}

@Test
func sqliteKernelTransactionsRollbackAndForeignKeysAreEnforced() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let member = try FamilyMember(displayName: "Synthetic")
    #expect(throws: SQLiteLibraryError.self) {
        try store.write { db in
            try SQLiteReportRows.saveMember(member, revision: 0, db)
            throw SQLiteLibraryError.invalidOriginal
        }
    }
    #expect(try store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM members") } == 0)
    #expect(throws: SQLiteLibraryError.self) {
        try store.write { db in
            try db.execute(sql: "INSERT INTO report_details(record_id,payload,content_hash) VALUES (?, ?, ?)", arguments: [UUID().sqliteBytes, Data(), Data(repeating: 0, count: 32)])
        }
    }
}

@Test
func sqliteKernelRejectsChangedSchemaAndDamagedLibraryIdentity() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    var store: SQLiteLibraryStore? = try SQLiteLibraryStore(rootURL: root)
    try store?.close()
    store = nil
    // Simulate external damage; business transactions now verify state before and after commit.
    let connection = try DatabaseQueue(path: root.appendingPathComponent(SQLiteLibraryStore.databaseFilename).path)
    try connection.write { db in try db.execute(sql: "UPDATE library_state SET generation = 42") }
    try connection.close()
    #expect(throws: SQLiteLibraryError.damaged) { _ = try SQLiteLibraryStore(rootURL: root) }
}

@Test
func sqliteKernelKeepsOwnerWhileClosedForRootReplacement() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    try store.closeDatabaseForReplacement()
    #expect(throws: SQLiteLibraryError.occupied) { _ = try SQLiteLibraryStore(rootURL: root) }
    let oldRoot = root.deletingLastPathComponent().appendingPathComponent("OldVault")
    try FileManager.default.moveItem(at: root, to: oldRoot)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    #expect(throws: SQLiteLibraryError.occupied) { _ = try SQLiteLibraryStore(rootURL: root) }
    try store.reopenAfterReplacement()
    #expect(try store.state().generation == 0)
    try store.close()
}

@Test
func sqliteKernelRootReplacementInvalidatesAnOpenConnection() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    try FileManager.default.moveItem(at: root, to: root.deletingLastPathComponent().appendingPathComponent("OldVault"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    #expect(throws: SQLiteLibraryError.staleRoot) { _ = try store.state() }
}

func sqliteTestRoot() throws -> URL {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("kinlogue-sqlite-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return parent.appendingPathComponent("Vault", isDirectory: true)
}

@Test
func sqliteKernelSourceIDsRemainScopedToTheirOwners() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let operation = UUID()
    let original = try sqliteStage(Data("synthetic original".utf8), in: store, operationID: operation)
    try store.publishOriginal(original, operationID: operation)
    let first = UUID().sqliteBytes
    let second = UUID().sqliteBytes
    let source = UUID().sqliteBytes
    let hash = Data(repeating: 0, count: 32)
    try store.write { db in
        for owner in [first, second] {
            try db.execute(sql: "INSERT INTO import_drafts(draft_id,state,revision,sources_hash,source_count,content_hash) VALUES (?, 'staging', 0, zeroblob(32), 1, ?)", arguments: [owner, hash])
            try db.execute(sql: "INSERT INTO report_sources(row_id,source_id,draft_id,position,original_id,page_count,display_name,content_hash) VALUES (?, ?, ?, 0, ?, 1, 'Synthetic', ?)", arguments: [UUID().sqliteBytes, source, owner, original.sqliteBytes, hash])
        }
    }
    #expect(try store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM report_sources") } == 2)
    #expect(throws: SQLiteLibraryError.self) {
        try store.write { db in
            try db.execute(sql: "INSERT INTO report_sources(row_id,source_id,draft_id,position,original_id,page_count,display_name,content_hash) VALUES (?, ?, ?, 1, ?, 1, 'Synthetic', ?)", arguments: [UUID().sqliteBytes, source, first, original.sqliteBytes, hash])
        }
    }
    #expect(throws: SQLiteLibraryError.invalidOriginal) { try store.deleteOriginal(original) }
}

@Test
func sqliteKernelRejectsSchemaDriftBeforeReady() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    try store.write { db in try db.execute(sql: "CREATE TABLE unexpected(payload BLOB) STRICT") }
    try store.close()
    #expect(throws: SQLiteLibraryError.damaged) { _ = try SQLiteLibraryStore(rootURL: root) }
}

@Test
func sqliteKernelChecksForeignKeysAtStartup() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    try store.close()
    var configuration = Configuration()
    configuration.foreignKeysEnabled = false
    let connection = try DatabaseQueue(path: root.appendingPathComponent(SQLiteLibraryStore.databaseFilename).path, configuration: configuration)
    try connection.write { db in
        try db.execute(sql: "INSERT INTO report_details VALUES (?, ?, ?)", arguments: [UUID().sqliteBytes, Data(), Data(repeating: 0, count: 32)])
    }
    try connection.close()
    #expect(throws: SQLiteLibraryError.damaged) { _ = try SQLiteLibraryStore(rootURL: root) }
}

@Test
func sqliteKernelStartupDoesNotReadOriginalBytesAndCorruptionStaysLocal() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    let operation = UUID()
    let bytes = Data("synthetic original".utf8)
    let bad = try sqliteStage(bytes, in: store, operationID: operation)
    let good = try sqliteStage(bytes, in: store, operationID: operation)
    try store.publishOriginal(bad, operationID: operation)
    try store.publishOriginal(good, operationID: operation)
    try store.close()
    let badURL = root.appendingPathComponent("originals/\(bad.uuidString.lowercased()).data")
    let descriptor = Darwin.open(badURL.path, O_WRONLY | O_NOFOLLOW)
    #expect(descriptor >= 0)
    let replacement = [UInt8](repeating: 42, count: bytes.count)
    #expect(Darwin.write(descriptor, replacement, replacement.count) == replacement.count)
    Darwin.close(descriptor)
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    _ = try reopened.state()
    let badPin = try reopened.pinOriginal(bad)
    #expect(throws: SQLiteLibraryError.invalidOriginal) { try badPin.withVerifiedDescriptor { _ in Issue.record("Corrupted bytes reached the consumer") } }
    badPin.release()
    let pin = try reopened.pinOriginal(good)
    defer { pin.release() }
    let recovered = try pin.withVerifiedDescriptor { fd in
        var buffer = [UInt8](repeating: 0, count: bytes.count)
        #expect(pread(fd, &buffer, buffer.count, 0) == bytes.count)
        return Data(buffer)
    }
    #expect(recovered == bytes)
    #expect(try Data(contentsOf: badURL) == Data(replacement))
}

@Test(arguments: [SQLiteOriginalFaultPoint.afterRegistration, .afterIdentityCommit, .afterFileSync, .afterRename, .afterLiveCommit])
func sqliteKernelRecoversInterruptedOriginalPublication(point: SQLiteOriginalFaultPoint) throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { $0 == point })
    let operation = UUID()
    do {
        let id = try sqliteStage(Data("synthetic staged bytes".utf8), in: store, operationID: operation)
        try store.publishOriginal(id, operationID: operation)
        Issue.record("Fault point did not interrupt the operation")
    } catch {
        #expect(error as? SQLiteLibraryError == .injectedFailure)
    }
    try store.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    let live = point == .afterLiveCommit ? 1 : 0
    #expect(try reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM originals") } == live)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path).count == live)
}

@Test(arguments: [SQLiteOriginalFaultPoint.afterDeletingCommit, .afterUnlink])
func sqliteKernelRecoversInterruptedOriginalDeletion(point: SQLiteOriginalFaultPoint) throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { $0 == point })
    let operation = UUID()
    let original = try sqliteStage(Data("synthetic deleted bytes".utf8), in: store, operationID: operation)
    try store.publishOriginal(original, operationID: operation)
    #expect(throws: SQLiteLibraryError.injectedFailure) { try store.deleteOriginal(original) }
    try store.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    #expect(try reopened.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM originals") } == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path).isEmpty)
}

@Test
func sqliteKernelPinsPreventDeletionAndDatabaseOwnerRelease() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let operation = UUID()
    let original = try sqliteStage(Data("synthetic pinned bytes".utf8), in: store, operationID: operation)
    try store.publishOriginal(original, operationID: operation)
    let pin = try store.pinOriginal(original)
    #expect(throws: SQLiteLibraryError.originalPinned) { try store.deleteOriginal(original) }
    #expect(throws: SQLiteLibraryError.originalPinned) { try store.closeDatabaseForReplacement() }
    #expect(throws: SQLiteLibraryError.originalPinned) { try store.close() }
    #expect(throws: SQLiteLibraryError.occupied) { _ = try SQLiteLibraryStore(rootURL: root) }
    pin.release()
    pin.release()
    try store.deleteOriginal(original)
    #expect(try store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM originals") } == 0)
}

@Test
func sqliteKernelDoesNotReclaimReplacedStagedFiles() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    let operation = UUID()
    let id = try sqliteStage(Data("synthetic staged bytes".utf8), in: store, operationID: operation)
    try store.close()
    let file = root.appendingPathComponent("originals/\(id.uuidString.lowercased()).staged")
    let retained = root.deletingLastPathComponent().appendingPathComponent("retained-staged")
    try FileManager.default.moveItem(at: file, to: retained)
    try Data("unrelated synthetic replacement".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    #expect(try reopened.recoverOriginals() == [id])
    #expect(try reopened.reclaimOriginals(operationID: operation) == [id])
    #expect(try Data(contentsOf: file) == Data("unrelated synthetic replacement".utf8))
    #expect(try Data(contentsOf: retained) == Data("synthetic staged bytes".utf8))
}

@Test
func sqliteKernelContentHashSeparatesTypesLengthsAndDomain() {
    #expect(SQLiteContentHash.hash(domain: "a", values: [.text("bc")]) != SQLiteContentHash.hash(domain: "ab", values: [.text("c")]))
    #expect(SQLiteContentHash.hash(domain: "a", values: [.text("bc")]) != SQLiteContentHash.hash(domain: "a", values: [.blob(Data("bc".utf8))]))
    #expect(SQLiteContentHash.hash(domain: "a", values: [.text("a"), .text("bc")]) != SQLiteContentHash.hash(domain: "a", values: [.text("ab"), .text("c")]))
}

func sqliteStage(_ bytes: Data, in store: SQLiteLibraryStore, operationID: UUID) throws -> UUID {
    let url = store.rootURL.deletingLastPathComponent().appendingPathComponent("synthetic-source-\(UUID().uuidString)")
    try bytes.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw SQLiteLibraryError.ioFailure(errno) }
    defer { Darwin.close(descriptor) }
    return try store.stageOriginal(copyingFrom: descriptor, byteCount: bytes.count,
        sha256: ContentDigest.sha256(bytes), contentType: "public.data", operationID: operationID)
}

@Test(arguments: [SQLiteInitializationFaultPoint.afterReceipt, .afterOriginalsDirectory, .afterDatabaseCreation, .afterSchemaCommit])
func sqliteKernelRecoversOwnedPartialInitialization(point: SQLiteInitializationFaultPoint) throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    #expect(throws: SQLiteLibraryError.injectedFailure) {
        _ = try SQLiteLibraryStore(rootURL: root, initializationFault: { $0 == point })
    }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    #expect(try store.state().generation == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(SQLiteLibraryInitialization.filename).path))
}

@Test
func sqliteKernelRejectsInitializationReceiptFromAnotherRoot() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    #expect(throws: SQLiteLibraryError.injectedFailure) {
        _ = try SQLiteLibraryStore(rootURL: root, initializationFault: { $0 == .afterReceipt })
    }
    let oldRoot = root.deletingLastPathComponent().appendingPathComponent("OldRoot")
    try FileManager.default.moveItem(at: root, to: oldRoot)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.copyItem(at: oldRoot.appendingPathComponent(SQLiteLibraryInitialization.filename), to: root.appendingPathComponent(SQLiteLibraryInitialization.filename))
    #expect(throws: SQLiteLibraryError.unsupportedFormat) { _ = try SQLiteLibraryStore(rootURL: root) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [SQLiteLibraryInitialization.filename])
}

@Test
func sqliteKernelDICOMCompositeRelationshipsRejectCrossStudyInstances() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let operation = UUID()
    let original = try sqliteStage(Data("synthetic DICOM metadata test".utf8), in: store, operationID: operation)
    try store.publishOriginal(original, operationID: operation)
    let firstStudy = UUID().sqliteBytes
    let secondStudy = UUID().sqliteBytes
    let series = UUID().sqliteBytes
    let digest = Data(repeating: 7, count: 32)
    try store.write { db in
        for study in [firstStudy, secondStudy] {
            try db.execute(sql: """
                INSERT INTO dicom_studies(id,state,operation_id,fingerprint,fingerprint_version,study_uid_digest,uid_domain,uid_version,content_revision,index_version,ordering_policy,logical_byte_count,object_count,instance_count,series_count,objects_hash,series_hash,content_hash)
                VALUES (?, 'needsReview', ?, ?, 1, ?, 'synthetic', 1, 0, 1, 2, 0, 1, 1, 1, ?, ?, ?)
                """, arguments: [study, operation.sqliteBytes, digest, ContentDigest.sha256(study), digest, digest, digest])
        }
        try db.execute(sql: "INSERT INTO dicom_series VALUES (?, ?, ?, 1, 'stableContentFallback', 0, 1, 1, 1, ?, ?)", arguments: [firstStudy, series, digest, digest, digest])
        try db.execute(sql: "INSERT INTO dicom_objects VALUES (?, ?, 'viewableImage', 1, ?, ?)", arguments: [secondStudy, original.sqliteBytes, digest, digest])
    }
    #expect(throws: SQLiteLibraryError.self) {
        try store.write { db in
            try db.execute(sql: """
                INSERT INTO dicom_instances(study_id,series_id,instance_id,original_id,sop_uid_digest,ordinal,sop_class,transfer_syntax,modality,
                    rows,columns,samples_per_pixel,bits_allocated,bits_stored,high_bit,pixel_representation,photometric_interpretation,
                    rescale_slope,rescale_intercept,content_hash)
                VALUES (?, ?, ?, ?, ?, 0, 'mrImageStorage', 'explicitVRLittleEndian', 'mr', 1, 1, 1, 16, 12, 11, 'unsigned', 'monochrome2', 1, 0, ?)
                """, arguments: [firstStudy, series, UUID().sqliteBytes, original.sqliteBytes, digest, digest])
        }
    }
    #expect(try store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM dicom_instances") } == 0)
}

@Test(arguments: [SQLiteOriginalFaultPoint.afterIdentityCommit, .afterRename])
func sqliteKernelOriginalIOAllowsUnrelatedDatabaseWork(point: SQLiteOriginalFaultPoint) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let progressed = DispatchSemaphore(value: 0)
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { current in
        guard current == point else { return false }
        entered.signal()
        #expect(resume.wait(timeout: .now() + 10) == .success)
        return false
    })
    defer { try? store.close() }
    let operation = UUID()
    let copying = sqliteRunOnDedicatedThread {
        let id = try sqliteStage(Data("synthetic concurrent original".utf8), in: store, operationID: operation)
        if point == .afterRename { try store.publishOriginal(id, operationID: operation) }
        return id
    }
    #expect(try await sqliteRunOnDedicatedThread { entered.wait(timeout: .now() + 5) == .success }.value)
    let databaseWork = sqliteRunOnDedicatedThread {
        defer { progressed.signal() }
        let state = try store.state()
        #expect(state.generation == 0)
        try store.write { db in
            try SQLiteReportRows.saveMember(FamilyMember(displayName: "Synthetic"), revision: 0, db)
        }
    }
    let didProgress = try await sqliteRunOnDedicatedThread { progressed.wait(timeout: .now() + 2) == .success }.value
    #expect(didProgress)
    if didProgress {
        let id = try store.read { db in
            let value = try Data.fetchOne(db, sql: "SELECT id FROM originals")
            let bytes = try #require(value)
            return try #require(UUID(sqliteBytes: bytes))
        }
        #expect(throws: SQLiteLibraryError.originalBusy) { try store.publishOriginal(id, operationID: operation) }
        #expect(throws: SQLiteLibraryError.originalBusy) { try store.deleteOriginal(id) }
        #expect(throws: SQLiteLibraryError.originalBusy) { try store.close() }
        #expect(throws: SQLiteLibraryError.originalBusy) { try store.closeDatabaseForReplacement() }
        #expect(throws: SQLiteLibraryError.occupied) { _ = try SQLiteLibraryStore(rootURL: root) }
        #expect(try store.recoverOriginals().isEmpty)
        #expect(try store.reclaimOriginals(operationID: operation) == [id])
        #expect(try store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM originals") } == 1)
    }
    resume.signal()
    let id = try await copying.value
    try await databaseWork.value
    if point == .afterIdentityCommit { try store.publishOriginal(id, operationID: operation) }
    let pin = try store.pinOriginal(id)
    try pin.withVerifiedDescriptor { _ in () }
    pin.release()
    try store.deleteOriginal(id)
    try store.closeDatabaseForReplacement()
    try store.reopenAfterReplacement()
}

@Test(arguments: [SQLiteOriginalFaultPoint.afterIdentityCommit, .afterRename])
func sqliteKernelCancelledOriginalIOReleasesOwnershipForRecovery(point: SQLiteOriginalFaultPoint) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { current in
        if current == point { withUnsafeCurrentTask { $0?.cancel() } }
        return false
    })
    let operation = UUID()
    let copying = Task {
        let id = try sqliteStage(Data("synthetic cancelled original".utf8), in: store, operationID: operation)
        if point == .afterRename { try store.publishOriginal(id, operationID: operation) }
    }
    do {
        try await copying.value
        Issue.record("Cancelled original operation committed")
    } catch { #expect(error is CancellationError) }
    try store.closeDatabaseForReplacement()
    try store.reopenAfterReplacement()
    #expect(try store.recoverOriginals().isEmpty)
    #expect(try store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM originals") } == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path).isEmpty)
    try store.close()
}

// Synchronous fault gates must not occupy the cooperative executor needed to release them.
private func sqliteRunOnDedicatedThread<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T
) -> Task<T, Error> {
    Task {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread { continuation.resume(with: Result(catching: body)) }
        }
    }
}

@Test(arguments: [SQLiteOriginalFaultPoint.afterFileSync, .afterRename], ["root", "row", "path"])
func sqliteKernelOriginalIORejectsChangedOwnership(point: SQLiteOriginalFaultPoint, change: String) async throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { current in
        guard current == point else { return false }
        entered.signal()
        #expect(resume.wait(timeout: .now() + 10) == .success)
        return false
    })
    let operation = UUID()
    let bytes = Data("synthetic ownership fence".utf8)
    let copying = sqliteRunOnDedicatedThread {
        let id = try sqliteStage(bytes, in: store, operationID: operation)
        if point == .afterRename { try store.publishOriginal(id, operationID: operation) }
    }
    #expect(try await sqliteRunOnDedicatedThread { entered.wait(timeout: .now() + 5) == .success }.value)
    let original = try store.read { db in
        let value = try Data.fetchOne(db, sql: "SELECT id FROM originals")
        let idBytes = try #require(value)
        let id = try #require(UUID(sqliteBytes: idBytes))
        return try SQLiteOriginal.read(id, from: db)
    }
    let path = root.appendingPathComponent("originals")
        .appendingPathComponent(original.id.uuidString.lowercased() + (point == .afterFileSync ? ".staged" : ".data"))
    let retained = root.deletingLastPathComponent().appendingPathComponent("RetainedOriginal")
    switch change {
    case "root":
        try FileManager.default.moveItem(at: root, to: root.deletingLastPathComponent().appendingPathComponent("OldVault"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    case "row":
        let replacement = SQLiteOriginal(id: original.id, byteCount: original.byteCount,
            sha256: original.sha256, contentType: original.contentType, lifecycle: original.lifecycle,
            operationID: UUID(), identity: original.identity)
        try store.write { db in
            try db.execute(sql: "UPDATE originals SET operation_id = ?, content_hash = ? WHERE id = ?",
                arguments: [replacement.operationID.sqliteBytes, replacement.contentHash, original.id.sqliteBytes])
        }
    default:
        try FileManager.default.moveItem(at: path, to: retained)
        try Data(repeating: 42, count: bytes.count).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    resume.signal()
    do {
        try await copying.value
        Issue.record("Changed original ownership was accepted")
    } catch { #expect(error as? SQLiteLibraryError == (change == "root" ? .staleRoot : .invalidOriginal)) }
    if change == "root" {
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    } else if change == "path" {
        #expect(try store.recoverOriginals() == [original.id])
        #expect(try Data(contentsOf: path) == Data(repeating: 42, count: bytes.count))
        #expect(try Data(contentsOf: retained) == bytes)
    } else {
        #expect(try store.recoverOriginals().isEmpty)
    }
    try store.close()
}

@Test
func sqliteKernelStageRejectsBytesChangedAfterFileSync() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root, originalFault: { point in
        guard point == .afterFileSync else { return false }
        do { try sqliteMutateOriginal(root: root, extension: "staged", mutation: "overwrite") }
        catch { Issue.record(error) }
        return false
    })
    defer { try? store.close() }
    #expect(throws: SQLiteLibraryError.invalidOriginal) {
        _ = try sqliteStage(Data("synthetic post-hash stage".utf8), in: store, operationID: UUID())
    }
    #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals WHERE lifecycle='live'") } == 0)
}

@Test(arguments: [false, true])
func sqliteKernelPinRejectsTemporaryContentChangesDuringConsumer(mutate: Bool) throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let operation = UUID(), bytes = Data("synthetic pin contents".utf8)
    let id = try sqliteStage(bytes, in: store, operationID: operation)
    try store.publishOriginal(id, operationID: operation)
    let pin = try store.pinOriginal(id)
    defer { pin.release() }
    let path = store.originalsURL.appendingPathComponent(store.originalFilename(id))
    let consume = {
        try pin.withVerifiedDescriptor { fd in
            var first: UInt8 = 0
            #expect(pread(fd, &first, 1, 0) == 1)
            #expect(first == bytes[0])
            if mutate {
                let writer = Darwin.open(path.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                guard writer >= 0 else { throw SQLiteLibraryError.ioFailure(errno) }
                defer { Darwin.close(writer) }
                var changed: UInt8 = 0xff
                #expect(pwrite(writer, &changed, 1, 0) == 1)
                #expect(pwrite(writer, &first, 1, 0) == 1)
            }
        }
    }
    if mutate { #expect(throws: SQLiteLibraryError.invalidOriginal) { try consume() } }
    else { try consume() }
    #expect(try Data(contentsOf: path) == bytes)
}

func sqliteMutateOriginal(root: URL, extension suffix: String, mutation: String) throws {
    let directory = root.appendingPathComponent("originals")
    let candidate = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == suffix }
    let path = try #require(candidate)
    if mutation == "replace" {
        try FileManager.default.moveItem(at: path, to: root.deletingLastPathComponent().appendingPathComponent("displaced-original"))
        try Data("unowned replacement".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return
    }
    let descriptor = Darwin.open(path.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw SQLiteLibraryError.ioFailure(errno) }
    defer { Darwin.close(descriptor) }
    let offset = mutation == "append" ? lseek(descriptor, 0, SEEK_END) : 0
    var byte: UInt8 = 0xff
    guard offset >= 0, pwrite(descriptor, &byte, 1, offset) == 1 else { throw SQLiteLibraryError.ioFailure(errno) }
}

@Test
func sqliteTextFidelityOriginalMetadataPreservesAllUTF8Bytes() throws {
    let root = try sqliteTestRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try SQLiteLibraryStore(rootURL: root)
    defer { try? store.close() }
    let data = Data("Synthetic original".utf8)
    let source = root.deletingLastPathComponent().appendingPathComponent("synthetic-source")
    try data.write(to: source)
    let fd = open(source.path, O_RDONLY | O_CLOEXEC)
    defer { close(fd) }
    let operation = UUID()
    let type = "public.data\0synthetic"
    let id = try store.stageOriginal(copyingFrom: fd, byteCount: data.count, sha256: ContentDigest.sha256(data), contentType: type, operationID: operation)
    try store.publishOriginal(id, operationID: operation)
    #expect(try store.read { try SQLiteOriginal.read(id, from: $0).contentType } == type)
    try store.close()
    let reopened = try SQLiteLibraryStore(rootURL: root)
    defer { try? reopened.close() }
    #expect(try reopened.read { try SQLiteOriginal.read(id, from: $0).contentType } == type)
}
