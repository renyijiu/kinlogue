import Foundation
import KinlogueCore
import KinloguePlatform
import Testing
@testable import KinlogueApp

@MainActor
struct BackupExportModelTests {
    @Test
    func warningPrecedesDestinationChoiceAndSuccessfulExportReportsProgress() async {
        let destination = URL(fileURLWithPath: "/synthetic/backup.zip")
        let service = BackupExportServiceSpy()
        await service.setProgress([
            AppBackupProgress(phase: .writing, completedByteCount: 5, totalByteCount: 10, isCancellable: true),
            AppBackupProgress(phase: .committing, completedByteCount: 10, totalByteCount: 10, isCancellable: false),
        ])
        let model = BackupExportModel(service: service)

        #expect(model.phase == .warning)
        #expect(model.beginChoosingDestination())
        #expect(model.phase == .choosing)
        await model.export(to: destination)

        #expect(model.phase == .succeeded)
        #expect(model.result?.url == destination)
        #expect(await service.exportedDestinations == [destination])
    }

    @Test
    func aCancelledDestinationChoiceReturnsToTheWarning() {
        let model = BackupExportModel(service: BackupExportServiceSpy())
        #expect(model.beginChoosingDestination())
        model.destinationSelectionCancelled()
        #expect(model.phase == .warning)
    }

    @Test
    func failuresKeepASemanticErrorThatFollowsTheLanguage() async {
        let service = BackupExportServiceSpy()
        await service.setError(.insufficientSpace)
        let model = BackupExportModel(service: service)
        await model.export(to: URL(fileURLWithPath: "/synthetic/full.zip"))
        #expect(model.phase == .failed)
        #expect(model.errorMessage == AppLocalization.string("所选位置没有足够空间完成导出。"))
    }

    @Test
    func cancelRequestsCleanupAndSettlesAsCancelledBeforeCommit() async {
        let destination = URL(fileURLWithPath: "/synthetic/late.zip")
        let service = DelayedBackupExportService(destination: destination, acceptsCancel: true)
        let model = BackupExportModel(service: service)
        let task = Task { await model.export(to: destination) }
        await service.waitUntilStarted()

        await model.cancel()
        #expect(model.phase == .cancelling)
        await service.finish()
        await task.value

        #expect(model.phase == .cancelled)
        #expect(model.result == nil)
        #expect(await service.cancelCallCount == 1)
    }

    @Test
    func cancellationRejectedAfterCommitIsReportedAsSuccess() async {
        let destination = URL(fileURLWithPath: "/synthetic/committed.zip")
        let service = DelayedBackupExportService(destination: destination, acceptsCancel: false)
        let model = BackupExportModel(service: service)
        let task = Task { await model.export(to: destination) }
        await service.waitUntilStarted()

        await model.cancel()
        await service.finish()
        await task.value

        #expect(model.phase == .succeeded)
        #expect(model.result?.url == destination)
        #expect(await service.cancelCallCount == 1)
    }

    @Test
    func lifecycleClearFencesALateResult() async {
        let destination = URL(fileURLWithPath: "/synthetic/late-commit.zip")
        let service = DelayedBackupExportService(destination: destination, acceptsCancel: false)
        let model = BackupExportModel(service: service)
        let task = Task { await model.export(to: destination) }
        await service.waitUntilStarted()

        model.clear()
        await service.finish()
        await task.value

        #expect(model.phase == .warning)
        #expect(model.result == nil)
    }

    @Test
    func exportSharesTheRootModalBoundaryAndVaultLifecycleClearsIt() async {
        let model = AppModel(service: AppServiceSpy(snapshot: .empty), backupExportService: BackupExportServiceSpy())
        await model.start()

        model.presentBackupExport()
        #expect(model.isBackupExportPresented)
        #expect(model.backupExportModel.phase == .warning)
        model.presentImporter()
        #expect(!model.isImporterPresented)

        await model.beginDestructiveVaultLifecycle()

        #expect(!model.isBackupExportPresented)
        #expect(model.backupExportModel.phase == .warning)
    }

    @Test
    func progressRelayCoalescesManyUpdatesToTheLatestPercentage() async {
        let relay = BackupProgressRelay()
        var delivered: [AppBackupProgress] = []
        for completed in 0...30_000 {
            relay.submit(AppBackupProgress(phase: .writing, completedByteCount: UInt64(completed),
                                           totalByteCount: 30_000, isCancellable: true)) { delivered.append($0) }
        }
        await Task.yield()
        #expect(delivered.count == 1)
        #expect(delivered.first?.completedByteCount == 30_000)
    }

    @Test
    func resultCopyKeepsItsTypedValuesAndPluralInEnglish() {
        #expect(AppLocalization.string("包含 \(1) 个原件，压缩包 \("10 MB")", language: .english) == "1 original, ZIP 10 MB")
        #expect(AppLocalization.string("包含 \(2) 个原件，压缩包 \("10 MB")", language: .english) == "2 originals, ZIP 10 MB")
        #expect(AppLocalization.string("续页备份 \("2026-10-19 153012")", language: .english) == "Kinlogue Backup 2026-10-19 153012")
        #expect(AppLocalization.string("续页备份 \("2026-10-19 153012")", language: .simplifiedChinese) == "续页备份 2026-10-19 153012")
    }
}

struct LiveBackupExportLifecycleTests {
    @Test
    func wholeLibraryDeletionCancelsAndWaitsForAnAdmittedExport() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("KinlogueExportLifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let lifecycle = LibraryLifecycleCoordinator()
        let gate = AsyncOperationGate()
        let cancellationObserved = AsyncOperationGate()
        let destroy = BackupExportDestroySpy()
        let service = LiveBackupService(
            activeVaultURL: base.appendingPathComponent("Vault"),
            settingsStore: BackupSettingsStore(rootURL: base.appendingPathComponent("Backup")),
            lifecycle: lifecycle,
            requiresSelectedDirectoryScope: false,
            archive: { _, _, _ in
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    Task { await cancellationObserved.open() }
                }
                try Task.checkCancellation()
                throw BackupArchiveWriteError.injectedFailure
            },
            currentRevision: { try BackupLibraryRevision(libraryID: UUID(), generation: 0, commitID: UUID()) }
        )
        let coordinatedDestroy = LifecycleCoordinatedVaultDestroyService(lifecycle: lifecycle, underlying: destroy)
        let export = Task { try await service.export(to: base.appendingPathComponent("blocked.zip"), progress: { _ in }) }
        guard await gate.waitUntilStarted() else {
            export.cancel()
            await gate.open()
            Issue.record("Timed out waiting for export admission")
            return
        }

        let deletion = Task { try await coordinatedDestroy.destroyCurrentVault() }
        await cancellationObserved.wait()
        #expect(await destroy.callCount == 0)

        await gate.open()
        await #expect(throws: CancellationError.self) { try await export.value }
        try await deletion.value
        #expect(await destroy.callCount == 1)
    }
}

private actor BackupExportServiceSpy: BackupExportServicing {
    private(set) var exportedDestinations: [URL] = []
    private var error: BackupExportError?
    private var progressValues: [AppBackupProgress] = []

    func setError(_ error: BackupExportError?) { self.error = error }
    func setProgress(_ values: [AppBackupProgress]) { progressValues = values }

    func export(to url: URL, progress: @escaping @Sendable (AppBackupProgress) -> Void) async throws -> BackupExportResult {
        exportedDestinations.append(url)
        if let error { throw error }
        for value in progressValues { progress(value) }
        return BackupExportResult(url: url, originalCount: 2, byteCount: 10)
    }

    func cancelExport() -> Bool { true }
}

private actor DelayedBackupExportService: BackupExportServicing {
    let destination: URL
    let acceptsCancel: Bool
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCallCount = 0
    private var cancellationRequested = false

    init(destination: URL, acceptsCancel: Bool) {
        self.destination = destination
        self.acceptsCancel = acceptsCancel
    }

    func export(to url: URL, progress: @escaping @Sendable (AppBackupProgress) -> Void) async throws -> BackupExportResult {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { finishContinuation = $0 }
        if cancellationRequested { throw CancellationError() }
        return BackupExportResult(url: destination, originalCount: 1, byteCount: 1)
    }

    func cancelExport() -> Bool {
        cancelCallCount += 1
        if acceptsCancel { cancellationRequested = true }
        return acceptsCancel
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private actor BackupExportDestroySpy: VaultDestroyServicing {
    private(set) var callCount = 0
    func destroyCurrentVault() async throws { callCount += 1 }
}
