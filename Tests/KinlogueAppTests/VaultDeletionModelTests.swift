import Foundation
import KinlogueCore
import Testing

@testable import KinlogueApp

@Suite(.serialized)
@MainActor
struct VaultDeletionModelTests {
    @Test
    func confirmationPhraseTracksTheSelectedLanguageAfterItsFirstRead() {
        withSelectedLanguage(.simplifiedChinese) {
            #expect(VaultDeletionModel.confirmationPhrase == "彻底删除")

            UserDefaults.standard.set(
                AppLanguage.english.rawValue,
                forKey: AppLocalization.languagePreferenceKey
            )
            #expect(VaultDeletionModel.confirmationPhrase == "Permanently Delete")
        }
    }

    @Test
    func deletionRequiresTheExactConfirmationPhrase() async {
        let destroy = VaultDeletionDestroySpy()
        let model = VaultDeletionModel(destroyService: destroy)
        model.confirmationInput = " \(VaultDeletionModel.confirmationPhrase) "

        await model.deleteCurrentVault()

        #expect(model.phase == .idle)
        #expect(model.errorMessage == AppLocalization.string("请输入完整确认短语"))
        #expect(await destroy.callCount == 0)
    }

    @Test
    func retainedErrorTracksTheSelectedLanguage() async {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.object(forKey: AppLocalization.languagePreferenceKey)
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: AppLocalization.languagePreferenceKey)
            } else {
                defaults.removeObject(forKey: AppLocalization.languagePreferenceKey)
            }
        }
        defaults.set(
            AppLanguage.simplifiedChinese.rawValue,
            forKey: AppLocalization.languagePreferenceKey
        )
        let model = VaultDeletionModel(destroyService: VaultDeletionDestroySpy())
        model.confirmationInput = "wrong"
        await model.deleteCurrentVault()
        #expect(model.errorMessage == "请输入完整确认短语")

        defaults.set(
            AppLanguage.english.rawValue,
            forKey: AppLocalization.languagePreferenceKey
        )
        #expect(model.errorMessage == "Enter the complete confirmation phrase")
    }

    @Test
    func englishConfirmationRejectsTheChinesePhrase() {
        withSelectedLanguage(.english) {
            let model = VaultDeletionModel(destroyService: VaultDeletionDestroySpy())
            model.confirmationInput = "彻底删除"

            #expect(!model.canDeleteVault)

            model.confirmationInput = "Permanently Delete"

            #expect(model.canDeleteVault)
        }
    }

    @Test
    func chineseConfirmationRejectsTheEnglishPhrase() {
        withSelectedLanguage(.simplifiedChinese) {
            let model = VaultDeletionModel(destroyService: VaultDeletionDestroySpy())
            model.confirmationInput = "Permanently Delete"

            #expect(!model.canDeleteVault)

            model.confirmationInput = "彻底删除"

            #expect(model.canDeleteVault)
        }
    }

    @Test
    func successfulDeletionPublishesOneTerminalOutcome() async {
        let events = VaultDeletionEventRecorder()
        let destroy = VaultDeletionDestroySpy(events: events)
        let model = VaultDeletionModel(
            destroyService: destroy,
            onDeletionBegan: { events.append("began") },
            onVaultDeleted: { events.append("deleted") },
            onDeletionFailed: { events.append("failed") }
        )
        model.confirmationInput = VaultDeletionModel.confirmationPhrase

        await model.deleteCurrentVault()

        #expect(model.phase == .deleted)
        #expect(model.confirmationInput.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(events.values == ["began", "destroy", "deleted"])
    }

    @Test
    func failedDeletionIsExplicitAndCanBeRetriedWithFreshConfirmation() async {
        let events = VaultDeletionEventRecorder()
        let destroy = VaultDeletionDestroySpy(shouldFail: true, events: events)
        let model = VaultDeletionModel(
            destroyService: destroy,
            onDeletionBegan: { events.append("began") },
            onVaultDeleted: { events.append("deleted") },
            onDeletionFailed: { events.append("failed") }
        )
        model.confirmationInput = VaultDeletionModel.confirmationPhrase

        await model.deleteCurrentVault()

        #expect(model.phase == .failed)
        #expect(!model.canDeleteVault)
        #expect(model.confirmationInput.isEmpty)
        #expect(
            model.errorMessage == AppLocalization.string(
                "未能删除本机资料库。请重新启动续页后检查；原资料可能仍保留在磁盘上。"
            )
        )
        #expect(events.values == ["began", "destroy", "failed"])
    }

    @Test
    func processLocalRevocationFinishesBeforeDurableDestroyBegins() async throws {
        let events = VaultDeletionEventRecorder()
        let lifecycle = LibraryLifecycleCoordinator()
        try await lifecycle.register(id: UUID()) {
            events.append("revoke")
        }
        let coordinated = LifecycleCoordinatedVaultDestroyService(
            lifecycle: lifecycle,
            underlying: VaultDeletionDestroySpy(events: events)
        )

        try await coordinated.destroyCurrentVault()

        #expect(events.values == ["revoke", "destroy"])
        do {
            try await lifecycle.requireActive()
            Issue.record("A destroyed runtime unexpectedly remained active")
        } catch LibraryLifecycleCoordinatorError.revoked {
            // Expected terminal state.
        } catch {
            Issue.record("Unexpected lifecycle error: \(error)")
        }
    }

    @Test
    func durableDestroyWaitsForAnAdmittedOperationToFinish() async throws {
        let lifecycle = LibraryLifecycleCoordinator()
        let revocationGate = try await installRevocationGate(on: lifecycle)
        let firstGate = AsyncOperationGate()
        let secondGate = AsyncOperationGate()
        let destroy = VaultDeletionDestroySpy()
        let coordinated = LifecycleCoordinatedVaultDestroyService(
            lifecycle: lifecycle,
            underlying: destroy
        )
        let firstOperation = Task {
            try await lifecycle.withActiveOperation {
                await firstGate.wait()
            }
        }
        let secondOperation = Task {
            try await lifecycle.withActiveOperation {
                await secondGate.wait()
            }
        }
        guard await firstGate.waitUntilStarted(),
            await secondGate.waitUntilStarted()
        else {
            firstOperation.cancel()
            secondOperation.cancel()
            await firstGate.open()
            await secondGate.open()
            _ = try? await firstOperation.value
            _ = try? await secondOperation.value
            Issue.record("Timed out waiting for active lifecycle operations")
            return
        }

        let deletion = Task {
            try await coordinated.destroyCurrentVault()
        }
        guard await revocationGate.waitUntilStarted() else {
            deletion.cancel()
            await revocationGate.open()
            await firstGate.open()
            await secondGate.open()
            _ = try? await firstOperation.value
            _ = try? await secondOperation.value
            _ = try? await deletion.value
            Issue.record("Timed out waiting for lifecycle revocation")
            return
        }
        await revocationGate.open()

        #expect(await destroy.callCount == 0)
        await firstGate.open()
        try await firstOperation.value
        #expect(await destroy.callCount == 0)
        await secondGate.open()
        try await secondOperation.value
        try await deletion.value
        #expect(await destroy.callCount == 1)
    }

    @Test
    func failedOperationReleasesItsLifecycleLease() async throws {
        let lifecycle = LibraryLifecycleCoordinator()

        do {
            try await lifecycle.withActiveOperation {
                throw VaultDeletionTestError.requestedFailure
            }
            Issue.record("The synthetic operation unexpectedly succeeded")
        } catch VaultDeletionTestError.requestedFailure {
            // Expected failure; the lease must still be released by defer.
        }

        let destroy = VaultDeletionDestroySpy()
        let coordinated = LifecycleCoordinatedVaultDestroyService(
            lifecycle: lifecycle,
            underlying: destroy
        )
        try await coordinated.destroyCurrentVault()
        #expect(await destroy.callCount == 1)
    }

    @Test
    func concurrentDurableDestroysShareOneInFlightDestroy() async throws {
        let gate = AsyncOperationGate()
        let destroy = GatedVaultDeletionDestroySpy(gate: gate)
        let coordinated = LifecycleCoordinatedVaultDestroyService(
            lifecycle: LibraryLifecycleCoordinator(),
            underlying: destroy
        )

        async let firstCaller: Void = coordinated.destroyCurrentVault()
        async let secondCaller: Void = coordinated.destroyCurrentVault()
        guard await gate.waitUntilStarted() else {
            await gate.open()
            _ = try? await (firstCaller, secondCaller)
            Issue.record("Timed out waiting for the destroy to enter the underlying service")
            return
        }

        #expect(await destroy.callCount == 1)
        #expect(await destroy.maximumConcurrentCalls == 1)
        await gate.open()
        _ = try await (firstCaller, secondCaller)
        #expect(await destroy.callCount == 1)
        #expect(await destroy.maximumConcurrentCalls == 1)

        try await coordinated.destroyCurrentVault()
        #expect(await destroy.callCount == 1)
    }

    @Test
    func failedDurableDestroyCanBeRetried() async throws {
        let destroy = FailOnceVaultDeletionDestroySpy()
        let coordinated = LifecycleCoordinatedVaultDestroyService(
            lifecycle: LibraryLifecycleCoordinator(),
            underlying: destroy
        )

        await #expect(throws: VaultDeletionTestError.requestedFailure) {
            try await coordinated.destroyCurrentVault()
        }
        try await coordinated.destroyCurrentVault()
        #expect(await destroy.callCount == 2)
    }

    private func withSelectedLanguage(
        _ language: AppLanguage,
        operation: @MainActor () -> Void
    ) {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: AppLocalization.languagePreferenceKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: AppLocalization.languagePreferenceKey)
            } else {
                defaults.removeObject(forKey: AppLocalization.languagePreferenceKey)
            }
        }

        defaults.set(language.rawValue, forKey: AppLocalization.languagePreferenceKey)
        operation()
    }
}

private enum VaultDeletionTestError: Error {
    case requestedFailure
}

private actor VaultDeletionDestroySpy: VaultDestroyServicing {
    private let shouldFail: Bool
    private let events: VaultDeletionEventRecorder?
    private(set) var callCount = 0

    init(
        shouldFail: Bool = false,
        events: VaultDeletionEventRecorder? = nil
    ) {
        self.shouldFail = shouldFail
        self.events = events
    }

    func destroyCurrentVault() async throws {
        callCount += 1
        events?.append("destroy")
        if shouldFail {
            throw VaultDeletionTestError.requestedFailure
        }
    }
}

private actor GatedVaultDeletionDestroySpy: VaultDestroyServicing {
    private let gate: AsyncOperationGate
    private(set) var callCount = 0
    private(set) var maximumConcurrentCalls = 0
    private var activeCalls = 0

    init(gate: AsyncOperationGate) {
        self.gate = gate
    }

    func destroyCurrentVault() async throws {
        callCount += 1
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        await gate.wait()
        activeCalls -= 1
    }
}

private actor FailOnceVaultDeletionDestroySpy: VaultDestroyServicing {
    private(set) var callCount = 0

    func destroyCurrentVault() async throws {
        callCount += 1
        if callCount == 1 {
            throw VaultDeletionTestError.requestedFailure
        }
    }
}

private final class VaultDeletionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] {
        lock.withLock { events }
    }

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }
}
