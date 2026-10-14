import Darwin
import Foundation
import GRDB
import KinlogueCore
import KinlogueSQLiteConfiguration
import KinlogueDICOMIPC
import KinlogueDICOMTestSupport
import Testing
@testable import KinloguePlatform

@Test
func sqliteDICOMWorkflowPublishesNormalizedGraphConfirmsReimportsAndDeletes() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let workflow = try DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder())
    let result = try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    #expect(!result.wasExisting)
    #expect(try fixture.store.state().generation == 1)
    let details = try await repository.details(result.studyID)
    #expect(details.study.state == .needsReview)
    #expect(details.series.count == 1)
    #expect(details.study.retainedObjectCount == 1)
    let entries = Set(try FileManager.default.contentsOfDirectory(atPath: fixture.store.rootURL.path))
    #expect(entries == ["originals", "library.sqlite", "dicom-import-staging"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.rootURL.appendingPathComponent("dicom-import-staging").path) == [".metadata_never_index"])
    let member = try FamilyMember(displayName: "Synthetic DICOM member")
    try await SQLiteReportRepository(store: fixture.store).saveMember(member, replacing: nil)
    let date = Date(timeIntervalSince1970: 1_786_000_000.0056)
    let confirmed = try await repository.confirm(result.studyID, expectedRevision: details.study.contentRevision, memberID: member.id, effectiveDate: date)
    #expect(confirmed.state == .confirmed)
    #expect(try fixture.store.state().generation == 3)
    #expect(confirmed.effectiveDate == date)
    let duplicate = try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    #expect(duplicate.studyID == result.studyID && duplicate.wasExisting)
    #expect(try fixture.store.state().generation == 3)
    try await repository.delete(result.studyID, expectedRevision: confirmed.contentRevision)
    #expect(try await repository.summaries().items.isEmpty)
    #expect(try fixture.store.state().generation == 4)
    #expect(try fixture.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals") } == 0)
}

private struct SQLiteDICOMFixture {
    let base: URL
    let source: URL
    let store: SQLiteLibraryStore
    init(base: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
         fault: (@Sendable (SQLiteOriginalFaultPoint) -> Bool)? = nil) throws {
        self.base = base
        source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        store = try SQLiteLibraryStore(rootURL: base.appendingPathComponent("vault"), originalFault: fault)
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(to: source.appendingPathComponent("synthetic.dcm"))
    }
    func cleanup() { try? store.close(); try? FileManager.default.removeItem(at: base) }
}

struct SQLiteDICOMDecoder: DICOMFrameDecoding {
    func decode(descriptor: FileHandle, declaredByteCount: Int) async throws -> KinlogueDICOMDecodedFrame {
        try descriptor.seek(toOffset: 0)
        let data = try descriptor.readToEnd() ?? Data()
        try descriptor.seek(toOffset: 0)
        func uid(_ group: UInt16, _ element: UInt16) throws -> String {
            let needle: [UInt8] = [UInt8(group & 0xff), UInt8(group >> 8), UInt8(element & 0xff), UInt8(element >> 8)]
            for offset in 0..<(data.count - 8) where data[offset..<(offset + 4)].elementsEqual(needle) {
                let length = Int(data[offset + 6]) | Int(data[offset + 7]) << 8
                guard offset + 8 + length <= data.count else { throw DICOMImportError.integrityFailure }
                return String(decoding: data[(offset + 8)..<(offset + 8 + length)], as: UTF8.self).trimmingCharacters(in: .init(charactersIn: " \0"))
            }
            throw DICOMImportError.integrityFailure
        }
        return try KinlogueDICOMDecodedFrame(transferSyntaxUID: KinlogueDICOMSupportedObject.explicitVRLittleEndian,
            sopClassUID: KinlogueDICOMSupportedObject.mrImageStorage,
            studyInstanceUID: uid(0x0020, 0x000d), seriesInstanceUID: uid(0x0020, 0x000e), sopInstanceUID: uid(0x0008, 0x0018),
            modality: "MR", instanceNumber: nil, rows: 2, columns: 2, samplesPerPixel: 1,
            bitsAllocated: 16, bitsStored: 12, highBit: 11, pixelRepresentation: 0,
            photometricInterpretation: "MONOCHROME2", numberOfFrames: 1,
            imagePositionPatient: nil, imageOrientationPatient: nil,
            windowCenter: 128, windowWidth: 256, rescaleIntercept: 0, rescaleSlope: 1,
            sampleBytes: Data([0, 0, 64, 0, 128, 0, 255, 0]))
    }
}

@Test(arguments: [SQLiteOriginalFaultPoint.afterRegistration, .afterIdentityCommit, .afterRename, .afterLiveCommit])
func sqliteDICOMPromotionFailurePublishesWholeGraphOrNothing(point: SQLiteOriginalFaultPoint) async throws {
    let fixture = try SQLiteDICOMFixture(fault: { $0 == point })
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let workflow = try DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder())
    do {
        _ = try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting)
        #expect(point == .afterLiveCommit)
    } catch { #expect(point != .afterLiveCommit) }
    let count = try await repository.summaries().items.count
    #expect(count == (point == .afterLiveCommit ? 1 : 0))
    #expect(try fixture.store.recoverOriginals().isEmpty)
    #expect(try DICOMImportJournal(rootURL: fixture.store.rootURL).pendingOperationCount() == 0)
    #expect(fixture.store.activeDICOMImports.isEmpty)
    try fixture.store.close()
    let reopened = try SQLiteLibraryStore(rootURL: fixture.store.rootURL)
    defer { try? reopened.close() }
    #expect(try await SQLiteDICOMRepository(store: reopened).summaries().items.count == count)
}

@Test
func sqliteDICOMConcurrentExactImportsConverge() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let first = try DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder())
    let second = try DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder())
    async let a = first.importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    async let b = second.importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let results = try await [a, b]
    #expect(results[0].studyID == results[1].studyID)
    #expect(results.filter(\.wasExisting).count == 1)
    #expect(try await repository.summaries().items.count == 1)
}

@Test
func sqliteDICOMViewerKeepsUnrelatedWritesAndFencesTargetAndEpoch() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let details = try await repository.details(imported.studyID)
    let service = DICOMSliceService(repository: repository, decoder: SQLiteDICOMDecoder())
    let session = try await service.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
    _ = try await service.render(session: session, instanceID: session.instances[0].id)
    let member = try FamilyMember(displayName: "Synthetic unrelated member")
    try await SQLiteReportRepository(store: fixture.store).saveMember(member, replacing: nil)
    let image = try await service.render(session: session, instanceID: session.instances[0].id)
    #expect(try image.withGrayscaleBytes { $0.count } == 4)
    _ = try await repository.confirm(imported.studyID, expectedRevision: 0, memberID: member.id, effectiveDate: Date())
    await #expect(throws: DICOMSliceServiceError.staleSession) { _ = try await service.render(session: session, instanceID: session.instances[0].id) }
    let current = try await service.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
    _ = try await service.render(session: current, instanceID: current.instances[0].id)
    try fixture.store.closeDatabaseForReplacement()
    try fixture.store.reopenAfterReplacement()
    await #expect(throws: (any Error).self) { _ = try await service.render(session: current, instanceID: current.instances[0].id) }
    await service.close()
}

@Test
func sqliteDICOMAsyncDecoderPinAllowsWritesAndRejectsDeletedTarget() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let details = try await repository.details(imported.studyID)
    let gate = SQLiteDICOMGateDecoder()
    let source = SQLiteDICOMSliceSource(repository: repository, decoder: gate)
    let session = try await source.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
    let task = Task { try await source.decode(session.instances[0], in: session) }
    try await gate.waitUntilStarted()
    #expect(throws: SQLiteLibraryError.originalPinned) { try fixture.store.closeDatabaseForReplacement() }
    try await SQLiteReportRepository(store: fixture.store).saveMember(FamilyMember(displayName: "Synthetic member during decode"), replacing: nil)
    try await repository.delete(imported.studyID, expectedRevision: 0)
    #expect(try fixture.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals WHERE lifecycle='deleting'") } == 1)
    await gate.release()
    await #expect(throws: (any Error).self) { _ = try await task.value }
    #expect(try fixture.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals") } == 0)
}

private actor SQLiteDICOMGateDecoder: DICOMFrameDecoding {
    var started = false
    var released = false
    func decode(descriptor: FileHandle, declaredByteCount: Int) async throws -> KinlogueDICOMDecodedFrame {
        started = true
        while !released { try await Task.sleep(for: .milliseconds(5)) }
        return try await SQLiteDICOMDecoder().decode(descriptor: descriptor, declaredByteCount: declaredByteCount)
    }
    func release() { released = true }
    func waitUntilStarted() async throws {
        for _ in 0..<1_000 {
            if started { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DICOMImportError.decoderUnavailable
    }
}

@Test
func sqliteDICOMActiveImportProtectsOwnerAndCancellationCleansStaging() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let decoder = SQLiteDICOMGateDecoder()
    let workflow = try DICOMImportWorkflow(repository: repository, decoder: decoder)
    let task = Task { try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting) }
    try await decoder.waitUntilStarted()
    #expect(throws: SQLiteLibraryError.originalBusy) { try fixture.store.close() }
    #expect(throws: SQLiteLibraryError.originalBusy) { try fixture.store.closeDatabaseForReplacement() }
    _ = try await SQLiteDICOMRepository(store: fixture.store).summaries()
    try await SQLiteReportRepository(store: fixture.store).saveMember(FamilyMember(displayName: "Synthetic member during import"), replacing: nil)
    #expect(try await workflow.cancelCurrentImport() == nil)
    await #expect(throws: DICOMImportError.cancelled) { _ = try await task.value }
    #expect(fixture.store.activeDICOMImports.isEmpty)
    #expect(try DICOMImportJournal(rootURL: fixture.store.rootURL).pendingOperationCount() == 0)
}

@Test
func sqliteDICOMSeriesReadIgnoresOtherCorruptSeriesAndStrictReadRejectsIt() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    try GeneratedDICOMFixture.explicitVRLittleEndianMR(seriesInstanceUID: "2.25.9922", sopInstanceUID: "2.25.9923").write(to: fixture.source.appendingPathComponent("second.dcm"))
    try GeneratedDICOMFixture.explicitVRLittleEndianInertObject().write(to: fixture.source.appendingPathComponent("inert.dcm"))
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let details = try await repository.details(imported.studyID)
    #expect(details.study.inertObjectCount == 1)
    #expect(details.series.count == 2)
    try fixture.store.write { db in
        try db.execute(sql: "UPDATE dicom_instances SET content_hash = zeroblob(32) WHERE study_id = ? AND series_id = ?", arguments: [imported.studyID.sqliteBytes, details.series[1].id.sqliteBytes])
    }
    let source = SQLiteDICOMSliceSource(repository: repository, decoder: SQLiteDICOMDecoder())
    let session = try await source.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
    _ = try await source.decode(session.instances[0], in: session)
    #expect(try await repository.details(imported.studyID).series.count == 2)
    #expect(throws: DICOMSliceServiceError.integrityFailure) { _ = try fixture.store.read { try SQLiteDICOMRows.strictStudy(imported.studyID, $0) } }
}

@Test
func sqliteDICOMHundredsOfObjectsPreserveImportBudgets() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("synthetic.dcm"))
    var bytes = 0
    for ordinal in 0..<220 {
        let data = GeneratedDICOMFixture.explicitVRLittleEndianMR(sopInstanceUID: "2.25.\(100_000 + ordinal)", imagePositionPatient: nil, imageOrientationPatient: nil)
        bytes += data.count
        try data.write(to: fixture.source.appendingPathComponent("synthetic-\(ordinal).dcm"))
    }
    let metrics = DICOMImportMetricsRecorder()
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let result = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder(), metrics: metrics).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let snapshot = await metrics.snapshot()
    #expect(result.viewableInstanceCount == 220)
    #expect(snapshot.maximumConcurrentWorkers <= 2)
    #expect(snapshot.maximumQueueDepth <= 2)
    #expect(snapshot.maximumLiveSourceAndStagingDescriptors <= 8)
    #expect(snapshot.liveSourceAndStagingDescriptorCount == 0)
    #expect(snapshot.maximumManagedFullReadsPerObject <= 3)
    #expect(snapshot.maximumWritesPerObject <= 2)
    #expect(snapshot.managedFullReadBytes == bytes * 3)
    #expect(snapshot.promotedAttachmentBytes == bytes)
    #expect(snapshot.peakAddedDiskBytes <= bytes * 2 + 256 * 1_024 * 1_024)
}

@Test(arguments: [false, true])
func sqliteDICOMOriginalDamageRejectsUncachedAndCachedPixels(cached: Bool) async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let details = try await repository.details(imported.studyID)
    let decoder = SQLiteDICOMCountingDecoder()
    let service = DICOMSliceService(repository: repository, decoder: decoder)
    let session = try await service.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
    if cached { _ = try await service.render(session: session, instanceID: session.instances[0].id) }
    let path = fixture.store.originalsURL.appendingPathComponent(fixture.store.originalFilename(session.instances[0].attachmentID))
    let handle = try FileHandle(forWritingTo: path)
    try handle.seek(toOffset: UInt64(session.instances[0].objectByteCount - 1))
    try handle.write(contentsOf: Data([0xfe]))
    try handle.close()
    await #expect(throws: DICOMSliceServiceError.integrityFailure) { _ = try await service.render(session: session, instanceID: session.instances[0].id) }
    #expect(await decoder.calls == (cached ? 1 : 0))
    await service.close()
}

private actor SQLiteDICOMCountingDecoder: DICOMFrameDecoding {
    var calls = 0
    func decode(descriptor: FileHandle, declaredByteCount: Int) async throws -> KinlogueDICOMDecodedFrame {
        calls += 1
        return try await SQLiteDICOMDecoder().decode(descriptor: descriptor, declaredByteCount: declaredByteCount)
    }
}

@Test
func sqliteDICOMGeometryValidationRejectsSelfConsistentHashesWithInvalidOrder() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    try GeneratedDICOMFixture.explicitVRLittleEndianMR(sopInstanceUID: "2.25.9933").write(to: fixture.source.appendingPathComponent("second.dcm"))
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let details = try await repository.details(imported.studyID)
    try fixture.store.write { db in
        try db.execute(sql: "UPDATE dicom_instances SET position_x=0,position_y=0,position_z=0,orientation_row_x=1,orientation_row_y=0,orientation_row_z=0,orientation_column_x=0,orientation_column_y=1,orientation_column_z=0")
        try sqliteDICOMRehash("dicom_instances", SQLiteDICOMRows.instanceColumns, db)
        let hashes = try Data.fetchAll(db, sql: "SELECT content_hash FROM dicom_instances ORDER BY ordinal")
        try db.execute(sql: "UPDATE dicom_series SET ordering_provenance='geometryProjection',instances_hash=?", arguments: [SQLiteDICOMRows.collectionHash("dicom-series-instances", hashes)])
        try sqliteDICOMRehash("dicom_series", SQLiteDICOMRows.seriesColumns, db)
        let series = try Data.fetchAll(db, sql: "SELECT content_hash FROM dicom_series ORDER BY ordinal")
        try db.execute(sql: "UPDATE dicom_studies SET series_hash=?", arguments: [SQLiteDICOMRows.collectionHash("dicom-study-series", series)])
        try sqliteDICOMRehash("dicom_studies", SQLiteDICOMRows.studyColumns, db)
    }
    let source = SQLiteDICOMSliceSource(repository: repository, decoder: SQLiteDICOMDecoder())
    await #expect(throws: DICOMImportError.corruptImage) { _ = try await source.openSeries(studyID: imported.studyID, seriesID: details.series[0].id) }
}

private func sqliteDICOMRehash(_ table: String, _ columns: [String], _ db: Database) throws {
    for row in try Row.fetchAll(db, sql: "SELECT rowid,* FROM \(table)") {
        try db.execute(sql: "UPDATE \(table) SET content_hash=? WHERE rowid=?", arguments: [try SQLiteDICOMRows.hash(table, columns.map { row[$0] }), row["rowid"] as Int64])
    }
}

@Test
func sqliteDICOMConfirmationRejectsDamagedTargetGraph() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let member = try FamilyMember(displayName: "Synthetic member")
    try await SQLiteReportRepository(store: fixture.store).saveMember(member, replacing: nil)
    try fixture.store.write { try $0.execute(sql: "UPDATE dicom_instances SET content_hash=zeroblob(32)") }
    await #expect(throws: DICOMSliceServiceError.integrityFailure) {
        _ = try await repository.confirm(imported.studyID, expectedRevision: 0, memberID: member.id, effectiveDate: Date())
    }
    #expect(try await repository.summaries().items.first?.state == .needsReview)
}

@Test(arguments: [false, true])
func sqliteDICOMTargetSeriesDamageFencesCachedAndFinalPixels(cached: Bool) async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let details = try await repository.details(imported.studyID)
    if cached {
        let service = DICOMSliceService(repository: repository, decoder: SQLiteDICOMDecoder())
        let session = try await service.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
        _ = try await service.render(session: session, instanceID: session.instances[0].id)
        try fixture.store.write { try $0.execute(sql: "UPDATE dicom_series SET content_hash=zeroblob(32)") }
        await #expect(throws: DICOMSliceServiceError.integrityFailure) { _ = try await service.render(session: session, instanceID: session.instances[0].id) }
        await service.close()
    } else {
        let gate = SQLiteDICOMGateDecoder()
        let source = SQLiteDICOMSliceSource(repository: repository, decoder: gate)
        let session = try await source.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
        let task = Task { try await source.decode(session.instances[0], in: session) }
        try await gate.waitUntilStarted()
        try fixture.store.write { try $0.execute(sql: "UPDATE dicom_series SET content_hash=zeroblob(32)") }
        await gate.release()
        await #expect(throws: DICOMSliceServiceError.integrityFailure) { _ = try await task.value }
    }
}

@Test
func sqliteDICOMOwnedDuplicateClosesWhenPinPostvalidationFails() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let id = try fixture.store.read { try SQLiteDICOMRows.strictStudy(imported.studyID, $0).0.attachmentIDs[0] }
    let pin = try fixture.store.pinOriginal(id)
    defer { pin.release() }
    let writer = try FileHandle(forWritingTo: fixture.store.originalsURL.appendingPathComponent(fixture.store.originalFilename(id)))
    defer { try? writer.close() }
    var duplicated: Int32 = -1
    #expect(throws: SQLiteLibraryError.invalidOriginal) {
        _ = try pin.withVerifiedDescriptor { fd in
            duplicated = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            #expect(duplicated >= 0)
            let owned = FileHandle(fileDescriptor: duplicated, closeOnDealloc: true)
            try writer.seek(toOffset: 0)
            try writer.write(contentsOf: Data([0xff]))
            return owned
        }
    }
    #expect(fcntl(duplicated, F_GETFD) == -1)
    #expect(errno == EBADF)
}

@Test(arguments: [false, true])
func sqliteDICOMListingIsolatesBadHeaderWithoutHidingItsID(oversizedDomain: Bool) async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let workflow = try DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder())
    let first = try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    try GeneratedDICOMFixture.explicitVRLittleEndianMR(studyInstanceUID: "2.25.9991", seriesInstanceUID: "2.25.9992", sopInstanceUID: "2.25.9993").write(to: fixture.source.appendingPathComponent("synthetic.dcm"))
    let second = try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    try fixture.store.write { db in
        if oversizedDomain {
            try db.execute(sql: "UPDATE dicom_studies SET uid_domain=CAST(zeroblob(1048576) AS TEXT) WHERE id=?", arguments: [first.studyID.sqliteBytes])
        } else {
            try db.execute(sql: "UPDATE dicom_studies SET content_hash=zeroblob(32) WHERE id=?", arguments: [first.studyID.sqliteBytes])
        }
    }
    // A connection limit makes copying the damaged field fail deterministically before Swift allocation.
    let previousLimit = try fixture.store.read { sqlite3_limit($0.sqliteConnection, SQLITE_LIMIT_LENGTH, 4_096) }
    defer { _ = try? fixture.store.read { sqlite3_limit($0.sqliteConnection, SQLITE_LIMIT_LENGTH, previousLimit) } }
    let listing = try await repository.summaries()
    #expect(listing.items.map(\.id) == [second.studyID])
    #expect(listing.damagedIDs == [first.studyID])
    let header = try await SQLiteReportRepository(store: fixture.store).header()
    #expect(header.studies.map(\.id) == [second.studyID])
    #expect(header.damagedStudyIDs == [first.studyID])
    #expect(try await repository.details(second.studyID).study.id == second.studyID)
    await #expect(throws: DICOMSliceServiceError.integrityFailure) { _ = try await repository.details(first.studyID) }
    #expect(throws: DICOMSliceServiceError.integrityFailure) { _ = try fixture.store.read { try SQLiteDICOMRows.strictStudy(first.studyID, $0) } }
}

@Test
func sqliteDICOMStagedFIFOIsRejectedWithoutBlockingAdoption() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let staging = try DICOMStudyStaging(rootURL: fixture.store.rootURL)
    let session = try await repository.beginImport(operationID: UUID(), staging: staging)
    let scan = try await DICOMFolderScanner().scan(directoryURL: fixture.source, operationID: session.ownership.operationID,
        securityScope: .notRequiredForTesting, staging: staging, ownership: session.ownership)
    let object = try #require(scan.stagedObjects.first)
    let path = fixture.store.rootURL.appendingPathComponent(object.relativePath)
    try FileManager.default.removeItem(at: path)
    #expect(mkfifo(path.path, 0o600) == 0)
    // A regressed blocking reader gets released, so this fails instead of hanging.
    let rescue = Task.detached {
        do { try await Task.sleep(for: .seconds(2)) } catch { return false }
        let fd = open(path.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 { Darwin.close(fd) }
        return true
    }
    #expect(throws: DICOMImportError.integrityFailure) {
        _ = try staging.withOwnedStagedDescriptor(object) { _, _, _ in true }
    }
    rescue.cancel()
    #expect(await rescue.value == false)
    try FileManager.default.removeItem(at: path)
    try await repository.abortImport(session)
}

/// What an import leaves when the process dies while copying: a journal entry bound to a staging
/// directory with a file in it. Opening the repository is what the next launch does, and a
/// journal entry it cannot settle stops it. In the second case that launch finds the volume under
/// another device number than the journal recorded.
@Test(arguments: [false, true])
func sqliteDICOMImportLeftBehindIsReclaimedWhenTheRepositoryOpens(afterTheVolumeWasRenumbered: Bool) throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let root = fixture.store.rootURL
    let staging = try DICOMStudyStaging(rootURL: root)
    let journal = try DICOMImportJournal(rootURL: root)
    let operationID = UUID()
    try journal.begin(operationID: operationID, vaultID: try fixture.store.state().libraryID)
    let ownership = try staging.prepare(operationID: operationID)
    try journal.bindStagingOwnership(ownership, operationID: operationID)
    let source = fixture.source.appendingPathComponent("synthetic.dcm")
    let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(descriptor >= 0)
    defer { Darwin.close(descriptor) }
    var metadata = stat()
    #expect(fstat(descriptor, &metadata) == 0)
    _ = try staging.stage(sourceDescriptor: descriptor, declaredByteCount: Int(metadata.st_size),
                          ownership: ownership, stagedByteCountBeforeCopy: 0)
    #expect(try journal.pendingOperationCount() == 1)
    func leftovers() throws -> [String] {
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return enumerator.compactMap { ($0 as? URL)?.path }.filter { $0.contains(operationID.uuidString) || $0.contains(operationID.uuidString.lowercased()) }
    }
    #expect(try !leftovers().isEmpty)
    if afterTheVolumeWasRenumbered {
        let record = URL(fileURLWithPath: try #require(try leftovers().first { $0.hasSuffix(".json") }))
        let text = try String(contentsOf: record, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #""device":(\d+)"#)
        let match = try #require(pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let digits = try #require(Range(match.range(at: 1), in: text))
        let handle = try FileHandle(forWritingTo: record)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.replacingCharacters(in: digits, with: String(try #require(Int(text[digits])) + 3)).utf8))
        try handle.close()
    }

    _ = try SQLiteDICOMRepository(store: fixture.store)

    #expect(try journal.pendingOperationCount() == 0)
    #expect(try leftovers().isEmpty)
}

@Test(arguments: [false, true])
func sqliteDICOMAdoptionGapProtectsOwnedBytesAndPreservesReplacedInode(replaced: Bool) async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let staging = try DICOMStudyStaging(rootURL: fixture.store.rootURL)
    let session = try await repository.beginImport(operationID: UUID(), staging: staging)
    let scan = try await DICOMFolderScanner().scan(directoryURL: fixture.source, operationID: session.ownership.operationID,
        securityScope: .notRequiredForTesting, staging: staging, ownership: session.ownership)
    let proposal = try await DICOMStudyIndexer(decoder: SQLiteDICOMDecoder()).index(stagedObjects: scan.stagedObjects, vaultID: session.libraryID, staging: staging)
    let object = try #require(proposal.objects.first)
    try fixture.store.adoptDICOMOriginal(object, session: session, staging: staging)
    let path = fixture.store.originalsURL.appendingPathComponent(fixture.store.originalFilename(object.attachment.id, staged: true))
    #expect(fixture.store.activeOriginals.isEmpty)
    #expect(try fixture.store.recoverOriginals().isEmpty)
    #expect(try fixture.store.reclaimOriginals(operationID: session.operationID) == [object.attachment.id])
    #expect(FileManager.default.fileExists(atPath: path.path))
    #expect(throws: SQLiteLibraryError.originalBusy) { try fixture.store.close() }
    #expect(throws: SQLiteLibraryError.originalBusy) { try fixture.store.closeDatabaseForReplacement() }
    _ = try await SQLiteDICOMRepository(store: fixture.store).summaries()
    try await SQLiteReportRepository(store: fixture.store).saveMember(FamilyMember(displayName: "Synthetic member in adoption gap"), replacing: nil)
    if replaced {
        try FileManager.default.moveItem(at: path, to: fixture.base.appendingPathComponent("owned-inode"))
        let foreign = Data("synthetic replacement that this operation does not own".utf8)
        try foreign.write(to: path)
        await #expect(throws: DICOMImportError.integrityFailure) { try await repository.abortImport(session) }
        #expect(try fixture.store.recoverOriginals() == [object.attachment.id])
        #expect(try Data(contentsOf: path) == foreign)
        try fixture.store.close()
        let reopened = try SQLiteLibraryStore(rootURL: fixture.store.rootURL)
        defer { try? reopened.close() }
        _ = try SQLiteDICOMRepository(store: reopened)
        #expect(try reopened.recoverOriginals() == [object.attachment.id])
        #expect(try Data(contentsOf: path) == foreign)
    } else {
        try await repository.abortImport(session)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try fixture.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals") } == 0)
        #expect(try DICOMImportJournal(rootURL: fixture.store.rootURL).pendingOperationCount() == 0)
    }
    #expect(fixture.store.activeDICOMImports.isEmpty)
}

@Test(arguments: [false, true])
func sqliteDICOMCancellationAfterCommitWaitsForTerminalResultAndRecoversLostResponse(loseResponse: Bool) async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let gate = SQLiteDICOMCommitResultGate(repository: repository, loseResponse: loseResponse)
    let workflow = try DICOMImportWorkflow(rootURL: fixture.store.rootURL, vault: gate, decoder: SQLiteDICOMDecoder(), metrics: nil, scannerControl: nil)
    let importing = Task { try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting) }
    try await gate.waitUntilCommitted()
    let cancelling = Task { try await workflow.cancelCurrentImport() }
    for _ in 0..<1_000 {
        if await workflow.state == .cancelling { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await workflow.state == .cancelling)
    await gate.release()
    let result = try await importing.value
    #expect(try await cancelling.value == result)
    #expect(try await repository.summaries().items.map(\.id) == [result.studyID])
    #expect(await workflow.state == .completed)
    #expect(fixture.store.activeDICOMImports.isEmpty)
}

private actor SQLiteDICOMCommitResultGate: DICOMImportStoring {
    let repository: SQLiteDICOMRepository
    let loseResponse: Bool
    var continuation: CheckedContinuation<Void, Never>?
    init(repository: SQLiteDICOMRepository, loseResponse: Bool) { self.repository = repository; self.loseResponse = loseResponse }
    func beginImport(operationID: UUID, staging: DICOMStudyStaging) async throws -> DICOMImportSession {
        try await repository.beginImport(operationID: operationID, staging: staging)
    }
    func commitImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession, staging: DICOMStudyStaging,
                      metrics: DICOMImportMetricsRecorder?) async throws -> DICOMImportCommit {
        let result = try await repository.commitImport(proposal, session: session, staging: staging, metrics: metrics)
        await withCheckedContinuation { continuation = $0 }
        if loseResponse { throw SQLiteLibraryError.injectedFailure }
        return result
    }
    func abortImport(_ session: DICOMImportSession) async throws { try await repository.abortImport(session) }
    func committedImport(_ proposal: DICOMIndexedStudyProposal, session: DICOMImportSession) async throws -> DICOMImportCommit? {
        try await repository.committedImport(proposal, session: session)
    }
    func waitUntilCommitted() async throws {
        for _ in 0..<1_000 {
            if continuation != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw DICOMImportError.decoderUnavailable
    }
    func release() { continuation?.resume(); continuation = nil }
}


@Test
func sqliteDICOMSeriesSemanticChangeRevokesCapturedSession() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let details = try await repository.details(imported.studyID)
    let service = DICOMSliceService(repository: repository, decoder: SQLiteDICOMDecoder())
    let session = try await service.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
    _ = try await service.render(session: session, instanceID: session.instances[0].id)
    try fixture.store.write { db in
        try db.execute(sql: "UPDATE dicom_series SET revision=revision+1")
        try sqliteDICOMRehash("dicom_series", SQLiteDICOMRows.seriesColumns, db)
        let hashes = try Data.fetchAll(db, sql: "SELECT content_hash FROM dicom_series ORDER BY ordinal")
        try db.execute(sql: "UPDATE dicom_studies SET series_hash=?", arguments: [SQLiteDICOMRows.collectionHash("dicom-study-series", hashes)])
        try sqliteDICOMRehash("dicom_studies", SQLiteDICOMRows.studyColumns, db)
    }
    await #expect(throws: DICOMSliceServiceError.staleSession) { _ = try await service.render(session: session, instanceID: session.instances[0].id) }
    await service.close()
}

@Test
func sqliteDICOMViewerPreservesGlobalOwnerFailureClassification() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let details = try await repository.details(imported.studyID)
    let service = DICOMSliceService(repository: repository, decoder: SQLiteDICOMDecoder())
    let session = try await service.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
    _ = try await service.render(session: session, instanceID: session.instances[0].id)
    try fixture.store.closeDatabaseForReplacement()
    try fixture.store.reopenAfterReplacement()
    await #expect(throws: SQLiteLibraryError.staleRoot) { _ = try await service.render(session: session, instanceID: session.instances[0].id) }
    await service.close()
}

@Test
func sqliteDICOMBatchRejectsBytesChangedAfterTheirPublicationHash() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let originals = base.appendingPathComponent("vault/originals")
    let fixture = try SQLiteDICOMFixture(base: base, fault: { point in
        guard point == .afterRename else { return false }
        do {
            let path = try #require(FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil).first { $0.pathExtension == "data" })
            let writer = try FileHandle(forWritingTo: path)
            try writer.write(contentsOf: Data([0xff]))
            try writer.close()
        } catch { Issue.record(error) }
        return false
    })
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let workflow = try DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder())
    await #expect(throws: SQLiteLibraryError.invalidOriginal) { _ = try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting) }
    #expect(try await repository.summaries().items.isEmpty)
}


@Test
func sqliteDICOMLowCapacityFailsBeforeOwningAnyOriginal() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let workflow = try DICOMImportWorkflow(rootURL: fixture.store.rootURL, vault: repository, decoder: SQLiteDICOMDecoder(),
        metrics: nil, scannerControl: nil, availableCapacityProvider: { _ in 0 })
    await #expect(throws: DICOMImportError.insufficientCapacity) { _ = try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting) }
    #expect(try await repository.summaries().items.isEmpty)
    #expect(try fixture.store.state().generation == 0)
    #expect(try fixture.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals") } == 0)
    #expect(try DICOMImportJournal(rootURL: fixture.store.rootURL).pendingOperationCount() == 0)
    #expect(fixture.store.activeDICOMImports.isEmpty)
}

@Test
func sqliteDICOMStrictStudyRejectsGappedSeriesOrdinals() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    try fixture.store.write { db in
        try db.execute(sql: "UPDATE dicom_series SET ordinal=2")
        try sqliteDICOMRehash("dicom_series", SQLiteDICOMRows.seriesColumns, db)
        let hashes = try Data.fetchAll(db, sql: "SELECT content_hash FROM dicom_series ORDER BY ordinal")
        try db.execute(sql: "UPDATE dicom_studies SET series_hash=?", arguments: [SQLiteDICOMRows.collectionHash("dicom-study-series", hashes)])
        try sqliteDICOMRehash("dicom_studies", SQLiteDICOMRows.studyColumns, db)
    }
    #expect(throws: DICOMSliceServiceError.integrityFailure) { _ = try fixture.store.read { try SQLiteDICOMRows.strictStudy(imported.studyID, $0) } }
}

@Test
func sqliteDICOMNonfiniteTargetMetadataRemainsALocalFailure() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let details = try await repository.details(imported.studyID)
    let service = DICOMSliceService(repository: repository, decoder: SQLiteDICOMDecoder())
    let session = try await service.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
    try fixture.store.write { try $0.execute(sql: "UPDATE dicom_instances SET rescale_slope=?", arguments: [Double.infinity]) }
    await #expect(throws: DICOMSliceServiceError.integrityFailure) { _ = try await service.render(session: session, instanceID: session.instances[0].id) }
    #expect(try await repository.summaries().items.count == 1)
    #expect(try fixture.store.state().generation == 1)
    await service.close()
}

@Test
func sqliteDICOMCachedHardlinkDamageRemainsLocalAndGoodTargetStillRenders() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let workflow = try DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder())
    let damaged = try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    try GeneratedDICOMFixture.explicitVRLittleEndianMR(studyInstanceUID: "2.25.8871", seriesInstanceUID: "2.25.8872", sopInstanceUID: "2.25.8873").write(to: fixture.source.appendingPathComponent("synthetic.dcm"))
    let good = try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let service = DICOMSliceService(repository: repository, decoder: SQLiteDICOMDecoder())
    let details = try await repository.details(damaged.studyID)
    let session = try await service.openSeries(studyID: damaged.studyID, seriesID: details.series[0].id)
    _ = try await service.render(session: session, instanceID: session.instances[0].id)
    let path = fixture.store.originalsURL.appendingPathComponent(fixture.store.originalFilename(session.instances[0].attachmentID))
    try FileManager.default.linkItem(at: path, to: fixture.base.appendingPathComponent("synthetic-hardlink"))
    await #expect(throws: DICOMSliceServiceError.integrityFailure) {
        _ = try await service.render(session: session, instanceID: session.instances[0].id)
    }
    let goodDetails = try await repository.details(good.studyID)
    let goodSession = try await service.openSeries(studyID: good.studyID, seriesID: goodDetails.series[0].id)
    let image = try await service.render(session: goodSession, instanceID: goodSession.instances[0].id)
    #expect(try image.withGrayscaleBytes { $0.count } == 4)
    #expect(try await repository.summaries().items.count == 2)
    await service.close()
}

@Test(arguments: [false, true])
func sqliteDICOMTerminalCleanupPreservesUnrelatedStagedReport(abort: Bool) async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let reportOperation = UUID()
    let report = try sqliteStage(Data("synthetic report awaiting publication".utf8), in: fixture.store, operationID: reportOperation)
    let staging = try DICOMStudyStaging(rootURL: fixture.store.rootURL)
    let session = try await repository.beginImport(operationID: UUID(), staging: staging)
    let scan = try await DICOMFolderScanner().scan(directoryURL: fixture.source, operationID: session.ownership.operationID,
        securityScope: .notRequiredForTesting, staging: staging, ownership: session.ownership)
    let proposal = try await DICOMStudyIndexer(decoder: SQLiteDICOMDecoder()).index(stagedObjects: scan.stagedObjects, vaultID: session.libraryID, staging: staging)
    if abort {
        for object in proposal.objects { try fixture.store.adoptDICOMOriginal(object, session: session, staging: staging) }
        try await repository.abortImport(session)
    } else { _ = try await repository.commitImport(proposal, session: session, staging: staging, metrics: nil) }
    #expect(try fixture.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals") } == (abort ? 1 : proposal.objects.count + 1))
    try fixture.store.publishOriginal(report, operationID: reportOperation)
    let pin = try fixture.store.pinOriginal(report)
    try pin.withVerifiedDescriptor { _ in () }
    pin.release()
    #expect(try DICOMImportJournal(rootURL: fixture.store.rootURL).pendingOperationCount() == 0)
    #expect(fixture.store.activeDICOMImports.isEmpty)
}

@Test
func sqliteMixedTimelineUsesOneDateKindIDBoundaryIncludingCollisionsAndDamagedRows() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let reports = SQLiteReportRepository(store: fixture.store)
    let studies = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: studies, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let member = try FamilyMember(displayName: "Synthetic mixed timeline")
    try await reports.saveMember(member, replacing: nil)
    let date = Date(timeIntervalSince1970: 100)
    _ = try await studies.confirm(imported.studyID, expectedRevision: 0, memberID: member.id, effectiveDate: date)
    func report(id: UUID, date: Date?) async throws -> HealthRecord {
        let bytes = Data(id.uuidString.utf8)
        let file = try ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes))
        guard case .created(let draftID) = try await reports.stage(file) else { throw LibraryReportError.invalidDocument }
        let lease = try await reports.beginProcessing(draftID: draftID, attemptID: UUID())
        try await reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
        let draft = try await reports.draft(draftID)
        let candidates = try date.map { [ReportDateCandidate(date: $0, kind: .report, source: try SourceField.manualEntry("Synthetic date"))] } ?? []
        let record = try HealthRecord(id: id, memberID: member.id, sources: draft.sources, ocrDocumentObjectID: draft.documentObjectID,
            importState: .confirmed, dateCandidates: candidates, timelineDateCandidateID: candidates.first?.id)
        try await reports.confirm(draftID: draftID, expectedRevision: draft.revision, record: record)
        return record
    }
    let collision = try await report(id: imported.studyID, date: date)
    let other = try await report(id: UUID(), date: date)
    let unknown = try await report(id: UUID(), date: nil)
    let expectedReports = [collision.id, other.id].sorted { $0.uuidString < $1.uuidString }
    var cursor: LibraryQueryCursor?, items: [LibraryTimelineItem] = []
    repeat {
        let page = try await reports.timelinePage(memberID: nil, limit: 1, cursor: cursor)
        items += page.items; cursor = page.nextCursor
    } while cursor != nil
    #expect(items.map(\.id) == expectedReports + [imported.studyID, unknown.id])
    #expect(items.map(\.kind) == [0, 0, 1, 0])
    try fixture.store.write { db in try db.execute(sql: "UPDATE reports SET content_hash=zeroblob(32) WHERE record_id=?", arguments: [expectedReports[0].sqliteBytes]) }
    let damaged = try await reports.timelinePage(memberID: nil, limit: 1, cursor: nil)
    #expect(damaged.items.isEmpty && damaged.damagedIDs == [expectedReports[0]])
    let next: LibraryQueryCursor = try #require(damaged.nextCursor)
    cursor = next; items = []
    repeat {
        let page = try await reports.timelinePage(memberID: nil, limit: 1, cursor: cursor)
        items += page.items; cursor = page.nextCursor
    } while cursor != nil
    #expect(items.map(\.id) == [expectedReports[1], imported.studyID, unknown.id])
}

@Test
func sqliteDICOMDirectPublicationEmitsOneHintAfterTheWholeGraphIsReadable() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    var events = fixture.store.changes().makeAsyncIterator()
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let event = try #require(await events.next())
    let state = try fixture.store.state()
    #expect(event.generation == 1 && event.commitID == state.commitID)
    #expect(try await repository.details(imported.studyID).series.count == 1)
    try fixture.store.close()
    #expect(await events.next() == nil)
}

@Test
func sqliteDICOMKnownDamageRejectsAlreadyCachedPixelsAndPreservesStudy() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let imported = try await DICOMImportWorkflow(repository: repository, decoder: SQLiteDICOMDecoder()).importDirectory(fixture.source, securityScope: .notRequiredForTesting)
    let details = try await repository.details(imported.studyID)
    let service = DICOMSliceService(repository: repository, decoder: SQLiteDICOMDecoder())
    let session = try await service.openSeries(studyID: imported.studyID, seriesID: details.series[0].id)
    _ = try await service.render(session: session, instanceID: session.instances[0].id)
    #expect(try fixture.store.rememberIntegrityFailure(SQLiteIntegrityTarget(kind: .study, key: imported.studyID.sqliteBytes), state: fixture.store.state(), epoch: repository.epoch))
    await #expect(throws: SQLiteLibraryError.damaged) { try await service.render(session: session, instanceID: session.instances[0].id) }
    let listing = try await repository.summaries()
    #expect(listing.items.isEmpty && listing.damagedIDs == [imported.studyID])
    await #expect(throws: SQLiteLibraryError.damaged) { try await repository.delete(imported.studyID, expectedRevision: details.study.contentRevision) }
    #expect(try fixture.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM dicom_studies") } == 1)
    await service.close()
}

@Test
func sqliteDICOMCancellingAQueuedMultiHundredFileImportStopsWithinOneSecond() async throws {
    let fixture = try SQLiteDICOMFixture()
    defer { fixture.cleanup() }
    try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("synthetic.dcm"))
    for ordinal in 0..<220 {
        try GeneratedDICOMFixture.explicitVRLittleEndianMR(sopInstanceUID: "2.25.\(300_000 + ordinal)")
            .write(to: fixture.source.appendingPathComponent("synthetic-\(ordinal).dcm"))
    }
    let control = SQLiteBlockingWorkerControl()
    let repository = try SQLiteDICOMRepository(store: fixture.store)
    let workflow = try DICOMImportWorkflow(rootURL: fixture.store.rootURL, vault: repository, decoder: SQLiteDICOMDecoder(),
        metrics: DICOMImportMetricsRecorder(), scannerControl: control)
    let task = Task { try await workflow.importDirectory(fixture.source, securityScope: .notRequiredForTesting) }
    while !(await control.hasStarted) { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await workflow.state == .staging)

    let clock = ContinuousClock()
    let start = clock.now
    #expect(try await workflow.cancelCurrentImport() == nil)
    await #expect(throws: DICOMImportError.cancelled) { _ = try await task.value }

    #expect(start.duration(to: clock.now) < .seconds(1))
    #expect(await workflow.state == .cancelled)
    #expect(try await repository.summaries().items.isEmpty)
    #expect(try fixture.store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM originals") } == 0)
    #expect(fixture.store.activeDICOMImports.isEmpty)
}

/// Holds the first scanner worker so that the rest of the folder stays queued.
private actor SQLiteBlockingWorkerControl: DICOMFolderScannerControl {
    private(set) var hasStarted = false
    func sourceAdmitted(ordinal: Int) async throws {}
    func workerStarted() async throws {
        hasStarted = true
        try await Task.sleep(for: .seconds(30))
    }
}
