import Foundation
import GRDB
import NIOCore
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite(.serialized)
struct SQLiteIntegrityAppTests {
    @Test
    @MainActor
    func originalDamageDoesNotBlockMetadataReadyAndInspectionIsPerItem() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic integrity member")
        try await fixture.reports.saveMember(member, replacing: nil)
        let bad = try await fixture.confirmed(member: member, seed: "damaged original")
        let good = try await fixture.confirmed(member: member, seed: "healthy original")
        let model = AppModel(service: fixture.service())
        await model.start()
        await model.selectRecord(bad.id)
        model.editingRecord = bad
        model.viewingOriginal = OriginalViewerPresentation(id: bad.id)
        model.comparisonModel.startSelection()
        model.comparisonModel.toggle(LibraryReportSummary(record: bad))
        model.comparisonModel.toggle(LibraryReportSummary(record: good))
        await model.comparisonModel.openComparison()
        #expect(model.originalDocument != nil && model.comparisonModel.leftOriginal != nil)
        let original = bad.sources.first.attachmentID
        let url = fixture.store.originalsURL.appendingPathComponent(original.uuidString.lowercased() + ".data")
        try Data(repeating: 0, count: "damaged original".utf8.count).write(to: url)
        let service = fixture.service()
        #expect(try await service.bootstrap().reportCount == 2)
        #expect(try await service.loadRecords(ids: [good.id]).records == [good])
        let report = try await SQLiteLibraryIntegrityScrubber(store: fixture.store).run()
        #expect(report.completed)
        #expect(report.damagedTargets.contains { $0.kind == .original && $0.id == original })
        await model.refresh()
        #expect(model.phase == .ready)
        #expect(model.selectedRecord == nil && model.originalDocument == nil)
        #expect(model.editingRecord == nil && model.viewingOriginal == nil)
        #expect(!model.comparisonModel.isPresented && model.comparisonModel.comparison == nil)
        #expect(model.comparisonModel.leftOriginal == nil && model.comparisonModel.rightOriginal == nil)
        #expect(model.comparisonModel.errorMessage != nil)
        model.presentationDidEnd()
        #expect(model.banner?.state == .recordUnavailable)
        await model.selectRecord(good.id)
        #expect(model.selectedRecord == good && model.originalDocument != nil)
        await model.beginDestructiveVaultLifecycle()
        await #expect(throws: SQLiteLibraryError.damaged) { try await service.loadRecords(ids: [bad.id]) }
        #expect(try await service.loadRecords(ids: [good.id]).records == [good])
    }

    @Test
    @MainActor
    func inspectionClosesAnOpenDamagedDraftAndReleasesItsOriginal() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let bytes = Data("synthetic open draft".utf8)
        let file = try ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes))
        guard case .created(let id) = try await fixture.reports.stage(file) else { throw LibraryReportError.invalidDocument }
        let lease = try await fixture.reports.beginProcessing(draftID: id, attemptID: UUID())
        try await fixture.reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
        let draft = try await fixture.reports.draft(id)
        let model = AppModel(service: fixture.service())
        await model.start()
        await model.presentReviewDraft(id)
        let review = model.makeReviewModel(draftID: id)
        #expect(model.makeReviewModel(draftID: id) === review)
        await review.load()
        #expect(review.originalDocument != nil && model.reviewDraftID == id)
        let original = draft.sources.first.attachmentID
        try Data(repeating: 0, count: bytes.count).write(to: fixture.store.originalsURL.appendingPathComponent(original.uuidString.lowercased() + ".data"))
        #expect(try await SQLiteLibraryIntegrityScrubber(store: fixture.store).run().completed)
        await model.refresh()
        #expect(model.phase == .ready && model.reviewDraftID == nil)
        #expect(!review.isPresented && review.originalDocument == nil)
        #expect(model.banner?.state == .originalUnavailable)
        await model.beginDestructiveVaultLifecycle()
    }

    @Test(arguments: IntegrityFailureTrigger.allCases)
    @MainActor
    func composedDatabaseFailureStopsReceptionAndDrainsViewerBeforeRestart(trigger: IntegrityFailureTrigger) async throws {
        let fixture = try SQLStartupFixture()
        defer { fixture.remove() }
        let context = try await SQLiteStartupContext.make(identity: fixture.identity)
        try await context.reconcile()
        let database = try await context.open()
        defer { try? database.close() }
        let reports = SQLiteReportRepository(store: database)
        let member = try FamilyMember(displayName: "Synthetic failure member")
        try await reports.saveMember(member, replacing: nil)
        let bytes = Data("synthetic failure original".utf8)
        guard case .created(let id) = try await reports.stage(ValidatedImportedFile(data: bytes, kind: .image,
            contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes))) else { throw LibraryReportError.invalidDocument }
        let lease = try await reports.beginProcessing(draftID: id, attemptID: UUID())
        try await reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
        let draft = try await reports.draft(id)
        let record = try HealthRecord(id: id, memberID: member.id, sources: draft.sources,
            ocrDocumentObjectID: draft.documentObjectID, importState: .confirmed)
        try await reports.confirm(draftID: id, expectedRevision: draft.revision, record: record)
        let live = try await LiveAppServiceEnvironment.makeOpened(identity: fixture.identity, store: database, lifecycle: context.lifecycle)
        let lan = try LiveLANInboxService(store: database, lifecycle: context.lifecycle, dependencies: .init(receiverStart: { receiver, address in
            try await receiver.start(at: address, port: 0, allowLoopbackForTesting: true,
                pipelineInstaller: { channel, _, _, _ in channel.eventLoop.makeSucceededFuture(()) })
        }))
        let closeGate = AsyncOperationGate()
        let services = LiveAppServiceEnvironment(dataService: live.dataService, originalExportService: live.originalExportService,
            destroyService: live.destroyService, lanInboxService: lan, dicomSliceServiceFactory: { IntegrityGatedSlices(closeGate: closeGate) },
            dicomImportMetrics: nil, vault: nil, lifecycle: context.lifecycle, commitChanges: live.commitChanges)
        let composition = AppComposition.makeOpened(identity: fixture.identity, services: services, context: context, database: database)
        #expect(await composition.startupCoordinator.start())
        let model = composition.appModel
        await model.selectRecord(id)
        #expect(model.originalDocument != nil)
        let inspector = try #require(composition.integrityCoordinator)
        for _ in 0..<100 {
            if case .completed = inspector.status { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .completed = inspector.status else { Issue.record("Expected completed inspection before failure"); await context.lifecycle.revoke(); return }
        await composition.libraryObserver?.reconcile()
        let viewer = model.makeDICOMStudyViewerModel(studyID: UUID())
        var dismissed = false
        viewer.activateWindow { dismissed = true }
        _ = try await lan.startReceiving(at: LANNetworkAddress(interfaceName: "lo0", host: "127.0.0.1", networkPrefixLength: 8))
        #expect(await lan.isReceiving())
        if case .comparison = trigger {
            model.comparisonModel.startSelection()
            model.comparisonModel.toggle(LibraryReportSummary(record: record))
            #expect(model.comparisonModel.selectedRecordIDs == [id])
        }
        try database.write { try $0.execute(sql: "DROP TABLE report_details") }
        #expect(try await reports.header().reportCount == 1)
        let failure = Task {
            switch trigger {
            case .detail: await model.selectRecord(id)
            case .observer: await composition.libraryObserver?.reconcile()
            case .comparison: await model.comparisonModel.reconcileSelection()
            case .inspection: await inspector.libraryChanged()
            }
        }
        let closing = await closeGate.waitUntilStarted()
        #expect(closing)
        if closing {
            #expect(model.phase != .restartRequired)
            #expect(model.originalDocument == nil && model.selectedRecord == nil && model.members.isEmpty)
            #expect(viewer.phase == .closed)
            await #expect(throws: LibraryLifecycleCoordinatorError.revoked) { try await context.lifecycle.requireActive() }
            for _ in 0..<100 {
                if !(await lan.isReceiving()) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!(await lan.isReceiving()))
        }
        await closeGate.open()
        await failure.value
        for _ in 0..<100 where model.phase != .restartRequired { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .restartRequired && model.restartRequiredForIntegrity)
        #expect(dismissed)
        #expect(inspector.status == .unavailable)
        #expect(!(await lan.isReceiving()))
        await #expect(throws: LibraryLifecycleCoordinatorError.revoked) { try await lan.refresh() }
        await context.lifecycle.revoke()
    }

    @Test
    @MainActor
    func inspectionWaitsForIdleAndDoesNotRestartAfterAnUnchangedRead() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let lifecycle = LibraryLifecycleCoordinator()
        let inspector = AppIntegrityCoordinator(store: fixture.store, lifecycle: lifecycle, onCompleted: {}, onUnsafe: {})
        #expect(inspector.status == .notInspected)
        await inspector.start()
        let gate = AsyncOperationGate()
        let operation = Task { try await lifecycle.withActiveOperation { await gate.wait() } }
        #expect(await gate.waitUntilStarted())
        try await Task.sleep(for: .milliseconds(2100))
        #expect(inspector.status == .incomplete)
        await gate.open()
        try await operation.value
        for _ in 0..<60 {
            if case .completed = inspector.status { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .completed = inspector.status else { Issue.record("Expected idle inspection"); await inspector.stop(); return }
        let completed = inspector.status
        try await lifecycle.withActiveOperation { _ = try fixture.store.state() }
        #expect(inspector.status == completed)
        await lifecycle.revoke()
    }

    @Test
    @MainActor
    func concurrentForegroundOperationsBothDrainTheSameInspection() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let lifecycle = LibraryLifecycleCoordinator()
        let scanning = AsyncOperationGate()
        let firstBody = AsyncOperationGate()
        let secondBody = AsyncOperationGate()
        let inspector = AppIntegrityCoordinator(store: fixture.store, lifecycle: lifecycle, onCompleted: {}, onUnsafe: {}, inspect: { progress in
            await scanning.wait()
            return try await SQLiteLibraryIntegrityScrubber(store: fixture.store).run(progress: progress)
        })
        await inspector.start()
        #expect(await scanning.waitUntilStarted())
        let first = Task { try await lifecycle.withActiveOperation { await firstBody.wait() } }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { try await lifecycle.withActiveOperation { await secondBody.wait() } }
        #expect(!(await firstBody.waitUntilStarted(timeout: .milliseconds(100))))
        #expect(!(await secondBody.waitUntilStarted(timeout: .milliseconds(100))))
        await scanning.open()
        #expect(await firstBody.waitUntilStarted())
        #expect(await secondBody.waitUntilStarted())
        await firstBody.open(); await secondBody.open()
        try await first.value; try await second.value
        await lifecycle.revoke()
    }

    @Test
    @MainActor
    func inspectionDoesNotStartWhenAnOperationPredatesRegistration() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let lifecycle = LibraryLifecycleCoordinator()
        let active = AsyncOperationGate()
        let operation = Task { try await lifecycle.withActiveOperation { await active.wait() } }
        #expect(await active.waitUntilStarted())
        let inspector = AppIntegrityCoordinator(store: fixture.store, lifecycle: lifecycle, onCompleted: {}, onUnsafe: {})
        await inspector.start()
        try await Task.sleep(for: .milliseconds(2100))
        if case .completed = inspector.status { Issue.record("Inspection ran during an operation accepted before registration") }
        await inspector.stop()
        await active.open()
        try await operation.value
        await lifecycle.revoke()
    }

    @Test(arguments: [false, true])
    func missingOrReplacedOriginalIsQuarantinedAtPinAdmission(replaced: Bool) async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic missing original")
        try await fixture.reports.saveMember(member, replacing: nil)
        let record = try await fixture.confirmed(member: member, seed: "missing original")
        let id = record.sources.first.attachmentID
        let url = fixture.store.originalsURL.appendingPathComponent(id.uuidString.lowercased() + ".data")
        try FileManager.default.moveItem(at: url, to: fixture.base.appendingPathComponent("owned-original-evidence"))
        if replaced { try Data("missing original".utf8).write(to: url) }
        await #expect(throws: SQLiteLibraryError.invalidOriginal) {
            try await fixture.reports.original(recordID: record.id, expectedRevision: record.revision, sourceID: record.sources.first.id)
        }
        await #expect(throws: SQLiteLibraryError.damaged) { try await fixture.reports.record(record.id) }
        await #expect(throws: SQLiteLibraryError.damaged) { try await fixture.reports.updateRecord(record, expectedRevision: record.revision) }
    }

    @Test
    func previewFailureQuarantinesItsReportButConsumerFailureDoesNot() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic preview member")
        try await fixture.reports.saveMember(member, replacing: nil)
        let record = try await fixture.confirmed(member: member, seed: "preview original")
        let original = record.sources.first.attachmentID
        let pin = try fixture.store.pinOriginal(original)
        #expect(throws: CancellationError.self) { try pin.withVerifiedDescriptor { _ in throw CancellationError() } }
        pin.release()
        #expect(try await fixture.reports.record(record.id) == record)
        let url = fixture.store.originalsURL.appendingPathComponent(original.uuidString.lowercased() + ".data")
        try Data(repeating: 0, count: "preview original".utf8.count).write(to: url)
        await #expect(throws: SQLiteLibraryError.invalidOriginal) {
            try await fixture.reports.original(recordID: record.id, expectedRevision: record.revision, sourceID: record.sources.first.id)
        }
        await #expect(throws: SQLiteLibraryError.damaged) { try await fixture.reports.record(record.id) }
    }

    @Test(arguments: [false, true])
    func originalExportFailuresQuarantineOnlyTheRelatedReport(missing: Bool) async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic export integrity")
        try await fixture.reports.saveMember(member, replacing: nil)
        let bad = try await fixture.confirmed(member: member, seed: "export integrity")
        let good = try await fixture.confirmed(member: member, seed: "healthy export")
        let url = fixture.store.originalsURL.appendingPathComponent(bad.sources.first.attachmentID.uuidString.lowercased() + ".data")
        if missing { try FileManager.default.moveItem(at: url, to: fixture.base.appendingPathComponent("owned-export-evidence")) }
        else { try Data(repeating: 0, count: "export integrity".utf8.count).write(to: url) }
        let service = LiveOriginalExportService(store: fixture.store, lifecycle: LibraryLifecycleCoordinator())
        await #expect(throws: (any Error).self) {
            try await service.export(to: fixture.base.appendingPathComponent("export.zip"), undatedToken: "undated", progress: { _ in })
        }
        await #expect(throws: SQLiteLibraryError.damaged) { try await fixture.reports.record(bad.id) }
        #expect(try await fixture.reports.record(good.id) == good)
    }

    @Test
    func oversizedMemberAndOrphanedDocumentAreLocalInspectionDamage() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let bad = try FamilyMember(displayName: "Synthetic oversized member")
        let good = try FamilyMember(displayName: "Synthetic healthy member")
        try await fixture.reports.saveMember(bad, replacing: nil)
        try await fixture.reports.saveMember(good, replacing: nil)
        let record = try await fixture.confirmed(member: good, seed: "orphan document")
        try fixture.store.write { db in
            try db.execute(sql: "UPDATE members SET display_name=CAST(zeroblob(16777217) AS TEXT) WHERE id=?", arguments: [bad.id.sqliteBytes])
            try db.execute(sql: "UPDATE reports SET document_id=NULL, document_hash=NULL WHERE record_id=?", arguments: [record.id.sqliteBytes])
        }
        let result = try await SQLiteLibraryIntegrityScrubber(store: fixture.store).run()
        #expect(result.completed)
        #expect(result.damagedTargets.contains { $0.kind == .member && $0.id == bad.id })
        #expect(result.damagedTargets.contains { $0.kind == .document && $0.id == record.ocrDocumentObjectID })
        #expect(try await fixture.reports.member(good.id) == good)
        #expect(try await fixture.reports.header().damagedMemberIDs.contains(bad.id))
        let next = try FamilyMember(id: good.id, displayName: "Synthetic healthy update")
        try await fixture.reports.saveMember(next, replacing: good)
    }

    @Test
    func inspectionPinDefersDamageUntilItsRevisionFenceAndOldEpochEvidenceIsIgnored() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic inspection fence")
        try await fixture.reports.saveMember(member, replacing: nil)
        let record = try await fixture.confirmed(member: member, seed: "inspection fence")
        let id = record.sources.first.attachmentID
        let initial = try fixture.store.state()
        let epoch = fixture.store.openEpoch
        let original = try fixture.store.read { try SQLiteOriginal.read(id, from: $0) }
        let pin = try fixture.store.pinOriginalForInspection(id)
        let url = fixture.store.originalsURL.appendingPathComponent(id.uuidString.lowercased() + ".data")
        try Data(repeating: 0, count: "inspection fence".utf8.count).write(to: url)
        #expect(throws: SQLiteLibraryError.invalidOriginal) { try pin.withVerifiedDescriptor { _ in () } }
        pin.release()
        #expect(try await fixture.reports.record(record.id) == record)
        try await fixture.reports.saveMember(FamilyMember(displayName: "Synthetic unrelated write"), replacing: nil)
        #expect(!(try fixture.store.rememberIntegrityFailure(SQLiteIntegrityTarget(kind: .original, key: id.sqliteBytes), state: initial, epoch: epoch)))
        #expect(try await fixture.reports.record(record.id) == record)
        try fixture.store.closeDatabaseForReplacement()
        try fixture.store.reopenAfterReplacement()
        fixture.store.noteOriginalIntegrityFailure(original, epoch: epoch)
        #expect(try await fixture.reports.record(record.id) == record)
    }

    @Test
    func concurrentRevisionChangeNeverClaimsCompleteInspection() async throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let member = try FamilyMember(displayName: "Synthetic revision member")
        try await fixture.reports.saveMember(member, replacing: nil)
        let update = IntegrityMutationOnce()
        let report = try await SQLiteLibraryIntegrityScrubber(store: fixture.store).run { _ in
            if await update.claim() {
                let next = try FamilyMember(id: member.id, displayName: "Synthetic updated member")
                try await fixture.reports.saveMember(next, replacing: member)
            }
        }
        #expect(!report.completed)
        #expect(report.damagedTargets.isEmpty)
    }

    @Test
    func cancellationGuardIsRemovedBeforeTheNextOrdinaryReadAndWrite() throws {
        let fixture = try SQLiteAppQueryFixture()
        defer { fixture.destroy() }
        let cancellation = SQLiteLogicalCancellation()
        #expect(throws: CancellationError.self) {
            try fixture.store.read { db in
                try SQLiteReadProgress.withGuard(db, check: cancellation.check) {
                    cancellation.cancel()
                    _ = try Int.fetchOne(db, sql: "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT sum(x) FROM n")
                }
            }
        }
        #expect(try fixture.store.state().generation >= 0)
        _ = try fixture.store.write { db in try SQLiteLibraryState.advance(in: db) }
    }
}
private actor IntegrityMutationOnce {
    private var claimed = false
    func claim() -> Bool { if claimed { return false }; claimed = true; return true }
}

enum IntegrityFailureTrigger: CaseIterable, Sendable { case detail, observer, comparison, inspection }
private struct IntegrityGatedSlices: DICOMSliceViewing {
    let closeGate: AsyncOperationGate
    func openSeries(studyID: UUID, seriesID: UUID) async throws -> DICOMSliceSeriesSession { throw DICOMSliceServiceError.closed }
    func render(session: DICOMSliceSeriesSession, instanceID: UUID, windowCenter: Double?, windowWidth: Double?) async throws -> DICOMSliceImage { throw DICOMSliceServiceError.closed }
    func prefetch(session: DICOMSliceSeriesSession, instanceID: UUID) async -> Bool { false }
    func handleMemoryPressure() async {}
    func close() async { await closeGate.wait() }
}
