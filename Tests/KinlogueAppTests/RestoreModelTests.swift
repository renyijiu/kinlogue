import Foundation
import KinlogueCore
import KinloguePlatform
import Testing
@testable import KinlogueApp

@Suite("Restore model")
@MainActor
struct RestoreModelTests {
    @Test
    func selectedCheckpointIsScopedOnlyForPreparationAndSummaryNeedsConfirmation() async throws {
        let service = RestoreModelService()
        let scope = RestoreScope()
        let model = RestoreModel(service: service, securityScope: scope)
        model.present()
        model.recoveryCode = "synthetic-code"

        await model.prepare(URL(fileURLWithPath: "/selected.kinloguebackup"))

        guard case let .awaitingReplaceConfirmation(summary) = model.phase else {
            Issue.record("Expected replacement confirmation")
            return
        }
        #expect(summary.memberCount == 2)
        #expect(summary.recordCount == 3)
        #expect(await scope.events == ["start", "stop"])
        #expect(await service.prepareCodes == ["synthetic-code"])
        #expect(await service.activationCount == 0)
    }

    @Test
    func confirmationActivatesAndClearsSensitiveInput() async {
        let service = RestoreModelService()
        let model = RestoreModel(service: service, securityScope: RestoreScope())
        model.present()
        model.recoveryCode = "synthetic-code"
        await model.prepare(URL(fileURLWithPath: "/selected.kinloguebackup"))

        await model.confirmReplacement()

        guard case .restartRequired = model.phase else {
            Issue.record("Expected restart-required state")
            return
        }
        #expect(model.recoveryCode.isEmpty)
        #expect(await service.activationCount == 1)
        #expect(model.isDismissDisabled)
    }

    @Test
    func cancellationBeforeConfirmationDoesNotActivate() async {
        let service = RestoreModelService()
        let model = RestoreModel(service: service, securityScope: RestoreScope())
        model.present()
        model.recoveryCode = "synthetic-code"
        await model.prepare(URL(fileURLWithPath: "/selected.kinloguebackup"))

        await model.cancel()

        #expect(model.phase == .idle)
        #expect(model.recoveryCode.isEmpty)
        #expect(await service.cancelCount == 1)
        #expect(await service.activationCount == 0)
    }

    @Test
    func cancellationDuringPreparationCleansLatePreparedStaging() async {
        let service = RestoreModelService()
        await service.pausePreparation()
        let model = RestoreModel(service: service, securityScope: RestoreScope())
        model.present()
        model.recoveryCode = "synthetic-code"
        let preparation = Task {
            await model.prepare(URL(fileURLWithPath: "/selected.kinloguebackup"))
        }
        await service.waitUntilPreparationEntered()

        await model.cancel()
        await service.resumePreparation()
        await preparation.value

        #expect(model.phase == .idle)
        #expect(await service.hasPreparedRestore == false)
        #expect(await service.cancelCount >= 1)
    }

    @Test
    func activationFailureRequiresQuitAndCannotReturnToTheRestorePicker() async {
        let service = RestoreModelService(activationError: .activationConflict)
        let model = RestoreModel(service: service, securityScope: RestoreScope())
        model.present()
        model.recoveryCode = "synthetic-code"
        await model.prepare(URL(fileURLWithPath: "/selected.kinloguebackup"))

        await model.confirmReplacement()

        #expect(model.phase == .failed(.activation))
        #expect(model.isDismissDisabled)
        #expect(model.recoveryCode.isEmpty)
        await model.cancel()
        #expect(model.phase == .failed(.activation))
        #expect(await service.cancelCount == 0)
    }
}

private actor RestoreModelService: BackupRestoreServicing {
    private let activationError: BackupRestoreError?
    private(set) var prepareCodes: [String] = []
    private(set) var activationCount = 0
    private(set) var cancelCount = 0
    private(set) var hasPreparedRestore = false
    private var preparePaused = false
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    private var prepareEntered = false
    private var prepareWaiters: [CheckedContinuation<Void, Never>] = []

    init(activationError: BackupRestoreError? = nil) {
        self.activationError = activationError
    }

    func reconcileBeforeStartingServices() async throws {}

    func prepare(checkpointURL: URL, recoveryCode: String) async throws -> BackupRestoreSummary {
        _ = checkpointURL
        prepareCodes.append(recoveryCode)
        prepareEntered = true
        prepareWaiters.forEach { $0.resume() }
        prepareWaiters.removeAll()
        if preparePaused {
            await withCheckedContinuation { prepareContinuation = $0 }
        }
        hasPreparedRestore = true
        return restoreModelSummary()
    }

    func cancelPreparedRestore() async throws {
        cancelCount += 1
        hasPreparedRestore = false
    }

    func activatePreparedRestore() async throws -> BackupRestoreActivationResult {
        activationCount += 1
        if let activationError { throw activationError }
        return .init(summary: restoreModelSummary())
    }

    func pausePreparation() { preparePaused = true }
    func waitUntilPreparationEntered() async {
        if prepareEntered { return }
        await withCheckedContinuation { prepareWaiters.append($0) }
    }
    func resumePreparation() {
        prepareContinuation?.resume()
        prepareContinuation = nil
    }
}

private actor RestoreScope: RestoreFileSecurityScope {
    private(set) var events: [String] = []
    func startAccessing(_ url: URL) -> Bool {
        _ = url
        events.append("start")
        return true
    }
    func stopAccessing(_ url: URL) {
        _ = url
        events.append("stop")
    }
}

private func restoreModelSummary() -> BackupRestoreSummary {
    let vault = try! BackupRevision(
        generation: 1,
        commitID: UUID(),
        manifestDigest: Data(repeating: 1, count: 32)
    )
    let inbox = try! BackupRevision(
        generation: 1,
        commitID: UUID(),
        manifestDigest: Data(repeating: 2, count: 32)
    )
    return .init(
        checkpointID: try! BackupCheckpointID(bytes: Data(repeating: 3, count: 16)),
        revisionPair: try! BackupRevisionPair(vault: vault, lanInbox: inbox),
        sequence: 7,
        memberCount: 2,
        recordCount: 3,
        inboxItemCount: 4,
        plaintextByteCount: 5,
        formatVersion: .current
    )
}
