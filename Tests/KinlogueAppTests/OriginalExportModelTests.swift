import Foundation
import Testing
@testable import KinlogueApp
@testable import KinlogueCore

@MainActor
struct OriginalExportModelTests {
    @Test
    func warningPrecedesDestinationChoiceAndSuccessfulExportReportsProgress() async {
        let destination = URL(fileURLWithPath: "/synthetic/doctor-handoff.zip")
        let service = OriginalExportServiceSpy()
        await service.setProgress([
            AppOriginalExportProgress(
                phase: .writing,
                completedByteCount: 5,
                totalByteCount: 10,
                completedEntryCount: 1,
                totalEntryCount: 2,
                isCancellable: true
            ),
            AppOriginalExportProgress(
                phase: .committing,
                completedByteCount: 10,
                totalByteCount: 10,
                completedEntryCount: 2,
                totalEntryCount: 2,
                isCancellable: false
            ),
        ])
        await service.setResult(OriginalExportResult(
            destinationURL: destination,
            entryCount: 2,
            totalByteCount: 10
        ))
        let model = OriginalExportModel(service: service)

        #expect(model.phase == .warning)
        #expect(await model.prepareForDestination(undatedToken: "Undated"))
        #expect(model.phase == .choosing)

        await model.export(to: destination, undatedToken: "Undated")

        #expect(model.phase == .succeeded)
        #expect(model.result?.destinationURL == destination)
        #expect(model.progress?.phase == .committing)
        #expect(model.progressFraction == 1)
        #expect(await service.preparedTokens == ["Undated"])
        #expect(await service.exportedDestinations == [destination])
    }

    @Test
    func emptyArchiveIsASemanticStateAndNeverOpensTheDestinationChooser() async {
        let service = OriginalExportServiceSpy()
        await service.setError(.emptyArchive)
        let model = OriginalExportModel(service: service)

        #expect(!(await model.prepareForDestination(undatedToken: "未注明日期")))

        #expect(model.phase == .empty)
        #expect(model.userErrorMessage == nil)
        #expect(await service.exportedDestinations.isEmpty)
    }

    @Test
    func checkingCanBeCancelledBeforeOpeningTheDestinationChooser() async {
        let service = DelayedPreparationOriginalExportService()
        let model = OriginalExportModel(service: service)
        let preparation = Task {
            await model.prepareForDestination(undatedToken: "Undated")
        }
        await service.waitUntilStarted()

        await model.cancel()
        #expect(model.phase == .cancelling)
        await service.finish()

        #expect(!(await preparation.value))
        #expect(model.phase == .cancelled)
        #expect(await service.cancelCallCount == 1)
    }

    @Test
    func cancelRequestsCleanupAndSettlesAsCancelledBeforeCommit() async {
        let destination = URL(fileURLWithPath: "/synthetic/late.zip")
        let service = DelayedOriginalExportService(destination: destination)
        let model = OriginalExportModel(service: service)
        let task = Task {
            await model.export(to: destination, undatedToken: "Undated")
        }
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
    func lifecycleClearFencesALateCommittedResult() async {
        let destination = URL(fileURLWithPath: "/synthetic/late-commit.zip")
        let service = CommittingOriginalExportService(destination: destination)
        let model = OriginalExportModel(service: service)
        let task = Task {
            await model.export(to: destination, undatedToken: "Undated")
        }
        await service.waitUntilCommitting()

        model.clear()
        await service.finish()
        await task.value

        #expect(model.phase == .warning)
        #expect(model.result == nil)
    }

    @Test
    func cancellationRejectedAfterCommitIsReportedAsSuccess() async {
        let destination = URL(fileURLWithPath: "/synthetic/committed.zip")
        let service = CommittingOriginalExportService(destination: destination)
        let model = OriginalExportModel(service: service)
        let task = Task {
            await model.export(to: destination, undatedToken: "Undated")
        }
        await service.waitUntilCommitting()

        await model.cancel()
        await service.finish()
        await task.value

        #expect(model.phase == .succeeded)
        #expect(model.result?.destinationURL == destination)
        #expect(await service.cancelCallCount == 1)
    }

    @Test
    func exportSharesTheRootModalBoundaryAndVaultLifecycleClearsIt() async {
        let model = AppModel(
            service: AppServiceSpy(snapshot: .empty),
            originalExportService: OriginalExportServiceSpy()
        )
        await model.start()

        model.presentOriginalExport()
        #expect(model.isOriginalExportPresented)
        #expect(model.originalExportModel.phase == .warning)
        model.presentImporter()
        #expect(!model.isImporterPresented)

        await model.beginDestructiveVaultLifecycle()

        #expect(!model.isOriginalExportPresented)
        #expect(model.originalExportModel.phase == .warning)
    }

    @Test
    func progressRelayCoalescesLargeEntryCountsToTheLatestPercentage() async {
        let relay = OriginalExportProgressRelay()
        var delivered: [AppOriginalExportProgress] = []

        for completed in 0...30_000 {
            relay.submit(AppOriginalExportProgress(
                phase: .writing,
                completedByteCount: completed,
                totalByteCount: 30_000,
                completedEntryCount: completed,
                totalEntryCount: 30_000,
                isCancellable: true
            )) { value in
                delivered.append(value)
            }
        }
        await Task.yield()

        #expect(delivered.count == 1)
        #expect(delivered.first?.completedEntryCount == 30_000)
    }
}

struct LiveOriginalExportServiceLifecycleTests {
    @Test
    func wholeLibraryDeletionCancelsAndWaitsForAnAdmittedExport() async throws {
        let lifecycle = LibraryLifecycleCoordinator()
        let gate = AsyncOperationGate()
        let cancellationObserved = AsyncOperationGate()
        let destroy = OriginalExportDestroySpy()
        let service = LiveOriginalExportService(
            lifecycle: lifecycle,
            prepareOperation: { _ in },
            exportOperation: { destination, _, _ in
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    Task { await cancellationObserved.open() }
                }
                try Task.checkCancellation()
                return OriginalExportResult(
                    destinationURL: destination,
                    entryCount: 1,
                    totalByteCount: 1
                )
            }
        )
        let coordinatedDestroy = LifecycleCoordinatedVaultDestroyService(
            lifecycle: lifecycle,
            underlying: destroy
        )
        let destination = URL(fileURLWithPath: "/synthetic/blocked.zip")
        let export = Task {
            try await service.export(
                to: destination,
                undatedToken: "Undated",
                progress: { _ in }
            )
        }
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

private actor OriginalExportServiceSpy: OriginalExportServicing {
    private(set) var preparedTokens: [String] = []
    private(set) var exportedDestinations: [URL] = []
    private(set) var cancelCallCount = 0
    private var error: OriginalExportServiceError?
    private var progressValues: [AppOriginalExportProgress] = []
    private var result = OriginalExportResult(
        destinationURL: URL(fileURLWithPath: "/synthetic/export.zip"),
        entryCount: 1,
        totalByteCount: 1
    )

    func setError(_ error: OriginalExportServiceError?) { self.error = error }
    func setProgress(_ values: [AppOriginalExportProgress]) { progressValues = values }
    func setResult(_ result: OriginalExportResult) { self.result = result }

    func prepare(undatedToken: String) async throws {
        preparedTokens.append(undatedToken)
        if let error { throw error }
    }

    func export(
        to destinationURL: URL,
        undatedToken: String,
        progress: @escaping @Sendable (AppOriginalExportProgress) -> Void
    ) async throws -> OriginalExportResult {
        exportedDestinations.append(destinationURL)
        if let error { throw error }
        for value in progressValues { progress(value) }
        return OriginalExportResult(
            destinationURL: destinationURL,
            entryCount: result.entryCount,
            totalByteCount: result.totalByteCount
        )
    }

    func cancel() -> Bool {
        cancelCallCount += 1
        return true
    }
}

private actor DelayedOriginalExportService: OriginalExportServicing {
    let destination: URL
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCallCount = 0
    private var cancellationRequested = false

    init(destination: URL) { self.destination = destination }

    func prepare(undatedToken: String) async throws {}

    func export(
        to destinationURL: URL,
        undatedToken: String,
        progress: @escaping @Sendable (AppOriginalExportProgress) -> Void
    ) async throws -> OriginalExportResult {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { finishContinuation = $0 }
        if cancellationRequested { throw CancellationError() }
        return OriginalExportResult(destinationURL: destination, entryCount: 1, totalByteCount: 1)
    }

    func cancel() -> Bool {
        cancelCallCount += 1
        cancellationRequested = true
        return true
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

private actor DelayedPreparationOriginalExportService: OriginalExportServicing {
    private var started = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCallCount = 0
    private var cancellationRequested = false

    func prepare(undatedToken: String) async throws {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { finishContinuation = $0 }
        if cancellationRequested { throw CancellationError() }
    }

    func export(
        to destinationURL: URL,
        undatedToken: String,
        progress: @escaping @Sendable (AppOriginalExportProgress) -> Void
    ) async throws -> OriginalExportResult {
        throw OriginalExportServiceError.unavailable
    }

    func cancel() -> Bool {
        cancelCallCount += 1
        cancellationRequested = true
        return true
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

private actor CommittingOriginalExportService: OriginalExportServicing {
    let destination: URL
    private var isCommitting = false
    private var committingContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelCallCount = 0

    init(destination: URL) { self.destination = destination }

    func prepare(undatedToken: String) async throws {}

    func export(
        to destinationURL: URL,
        undatedToken: String,
        progress: @escaping @Sendable (AppOriginalExportProgress) -> Void
    ) async throws -> OriginalExportResult {
        isCommitting = true
        committingContinuation?.resume()
        committingContinuation = nil
        await withCheckedContinuation { finishContinuation = $0 }
        return OriginalExportResult(destinationURL: destination, entryCount: 1, totalByteCount: 1)
    }

    func cancel() -> Bool {
        cancelCallCount += 1
        return false
    }

    func waitUntilCommitting() async {
        guard !isCommitting else { return }
        await withCheckedContinuation { committingContinuation = $0 }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

private actor OriginalExportDestroySpy: VaultDestroyServicing {
    private(set) var callCount = 0
    func destroyCurrentVault() async throws { callCount += 1 }
}
