import Foundation
import KinlogueCore

@MainActor
final class DICOMViewerRegistry {
    private struct Entry {
        let studyID: DICOMStudy.ID
        let invalidate: @MainActor () -> Void
        let finishRevocation: @MainActor () async -> Void
    }

    private struct PendingRevocation {
        let studyID: DICOMStudy.ID
        let task: Task<Void, Never>
    }

    private var entries: [UUID: Entry] = [:]
    private var pendingRevocations: [UUID: PendingRevocation] = [:]
    private var wholeVaultRevocationDepth = 0
    private var studyRevocationDepth: [DICOMStudy.ID: Int] = [:]

    func register(
        studyID: DICOMStudy.ID,
        invalidate: @escaping @MainActor () -> Void,
        finishRevocation: @escaping @MainActor () async -> Void
    ) -> UUID? {
        if wholeVaultRevocationDepth > 0 || studyRevocationDepth[studyID, default: 0] > 0 {
            invalidate()
            scheduleRevocation(studyID: studyID, finishRevocation: finishRevocation)
            return nil
        }
        let registrationID = UUID()
        entries[registrationID] = Entry(
            studyID: studyID,
            invalidate: invalidate,
            finishRevocation: finishRevocation
        )
        return registrationID
    }

    func unregister(_ registrationID: UUID) {
        entries[registrationID] = nil
    }

    func revoke(studyID: DICOMStudy.ID) async {
        studyRevocationDepth[studyID, default: 0] += 1
        await revoke { $0.studyID == studyID }
        await drainPendingRevocations(
            { $0.studyID == studyID },
            onDrained: {
                let remaining = self.studyRevocationDepth[studyID, default: 1] - 1
                self.studyRevocationDepth[studyID] = remaining == 0 ? nil : remaining
            }
        )
    }

    func revokeAll() async {
        await withWholeVaultRevocation {}
    }

    /// Keeps whole-Vault revocation active across a catalog lifecycle step.
    /// Registrations attempted by delayed window presentation are invalidated
    /// immediately and joined before the fence is released.
    func withWholeVaultRevocation(
        _ operation: @escaping @MainActor () async -> Void
    ) async {
        wholeVaultRevocationDepth += 1
        await revoke { _ in true }
        await drainPendingRevocations { _ in true }
        await operation()
        await drainPendingRevocations(
            { _ in true },
            onDrained: { self.wholeVaultRevocationDepth -= 1 }
        )
    }

    private func revoke(_ isTarget: (Entry) -> Bool) async {
        let registrations = entries.filter { isTarget($0.value) }
        for (registrationID, _) in registrations {
            entries[registrationID] = nil
        }

        // Clear every target before awaiting service teardown so no other open
        // window can retain rendered medical pixels during a slow close.
        for (_, entry) in registrations {
            entry.invalidate()
        }
        for (_, entry) in registrations {
            scheduleRevocation(
                studyID: entry.studyID,
                finishRevocation: entry.finishRevocation
            )
        }
    }

    private func scheduleRevocation(
        studyID: DICOMStudy.ID,
        finishRevocation: @escaping @MainActor () async -> Void
    ) {
        let pendingID = UUID()
        pendingRevocations[pendingID] = PendingRevocation(
            studyID: studyID,
            task: Task { @MainActor in await finishRevocation() }
        )
    }

    private func drainPendingRevocations(
        _ isTarget: (PendingRevocation) -> Bool,
        onDrained: () -> Void = {}
    ) async {
        while true {
            let pending = pendingRevocations.filter { isTarget($0.value) }
            guard !pending.isEmpty else {
                onDrained()
                return
            }
            for (pendingID, revocation) in pending {
                await revocation.task.value
                pendingRevocations[pendingID] = nil
            }
        }
    }
}
