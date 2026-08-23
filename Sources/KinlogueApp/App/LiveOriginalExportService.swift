import Foundation
import KinloguePlatform

actor LiveOriginalExportService: OriginalExportServicing {
    typealias PrepareOperation = @Sendable (String) async throws -> Void
    typealias ExportOperation = @Sendable (
        URL,
        String,
        @escaping @Sendable (AppOriginalExportProgress) -> Void
    ) async throws -> OriginalExportResult

    private let lifecycle: LibraryLifecycleCoordinator
    private let prepareOperation: PrepareOperation
    private let exportOperation: ExportOperation
    private let lifecycleRegistrationID = UUID()
    private var lifecycleIsRegistered = false
    private var cancelActiveOperation: (@Sendable () -> Bool)?

    init(vault: PlaintextVault, lifecycle: LibraryLifecycleCoordinator) {
        let exporter = PlaintextOriginalArchiveExporter(vault: vault)
        self.lifecycle = lifecycle
        prepareOperation = { undatedToken in
            do {
                _ = try await exporter.prepare(undatedToken: undatedToken)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Self.appError(for: error)
            }
        }
        exportOperation = { destinationURL, undatedToken, progress in
            do {
                let preparation = try await exporter.prepare(undatedToken: undatedToken)
                let result = try await exporter.export(
                    preparation,
                    to: destinationURL
                ) { value in
                    progress(Self.appProgress(value))
                }
                return OriginalExportResult(
                    destinationURL: result.destinationURL,
                    entryCount: result.entryCount,
                    totalByteCount: result.totalByteCount
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Self.appError(for: error)
            }
        }
    }

    init(
        lifecycle: LibraryLifecycleCoordinator,
        prepareOperation: @escaping PrepareOperation,
        exportOperation: @escaping ExportOperation
    ) {
        self.lifecycle = lifecycle
        self.prepareOperation = prepareOperation
        self.exportOperation = exportOperation
    }

    func prepare(undatedToken: String) async throws {
        try await ensureLifecycleRegistration()
        try await lifecycle.withActiveOperation { [self] in
            try await runOperation {
                try await self.prepareOperation(undatedToken)
            }
        }
    }

    func export(
        to destinationURL: URL,
        undatedToken: String,
        progress: @escaping @Sendable (AppOriginalExportProgress) -> Void
    ) async throws -> OriginalExportResult {
        try await ensureLifecycleRegistration()
        let cancellationGate = OriginalExportCancellationGate()
        return try await lifecycle.withActiveOperation { [self] in
            try await runOperation(cancellationGate: cancellationGate) {
                try await self.exportOperation(destinationURL, undatedToken) { value in
                    cancellationGate.update(isCancellable: value.isCancellable)
                    progress(value)
                }
            }
        }
    }

    func cancel() -> Bool {
        cancelActiveOperation?() ?? false
    }

    private func ensureLifecycleRegistration() async throws {
        guard !lifecycleIsRegistered else { return }
        try await lifecycle.register(id: lifecycleRegistrationID) { [weak self] in
            _ = await self?.cancel()
        }
        lifecycleIsRegistered = true
    }

    private func runOperation<Result: Sendable>(
        cancellationGate: OriginalExportCancellationGate = OriginalExportCancellationGate(),
        _ operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        guard cancelActiveOperation == nil else {
            throw OriginalExportServiceError.unavailable
        }
        let task = Task {
            try await operation()
        }
        cancelActiveOperation = { cancellationGate.cancel(task) }
        defer {
            cancelActiveOperation = nil
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func appProgress(
        _ progress: OriginalArchiveExportProgress
    ) -> AppOriginalExportProgress {
        let phase: AppOriginalExportPhase
        switch progress.phase {
        case .preparing: phase = .preparing
        case .writing: phase = .writing
        case .verifying: phase = .verifying
        case .committing: phase = .committing
        }
        return AppOriginalExportProgress(
            phase: phase,
            completedByteCount: progress.completedByteCount,
            totalByteCount: progress.totalByteCount,
            completedEntryCount: progress.completedEntryCount,
            totalEntryCount: progress.totalEntryCount,
            isCancellable: progress.isCancellable
        )
    }

    nonisolated private static func appError(for error: Error) -> OriginalExportServiceError {
        guard let error = error as? PlaintextOriginalArchiveExportError else {
            return .unavailable
        }
        switch error {
        case .emptyArchive: return .emptyArchive
        case .invalidDestination: return .invalidDestination
        case .insufficientSpace: return .insufficientSpace
        case .destinationAccessDenied: return .destinationAccessDenied
        case .vaultChanged: return .vaultChanged
        case .sourceIntegrityFailure: return .sourceIntegrityFailure
        case .archiveIntegrityFailure: return .archiveIntegrityFailure
        case .publicationIndeterminate: return .publicationIndeterminate
        case .ioFailure, .injectedFailure: return .unavailable
        }
    }
}

// SAFETY: `lock` serializes every read and write of `isCancellable`; the
// referenced Task is supplied per call and is not retained by this gate.
private final class OriginalExportCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancellable = true

    func update(isCancellable: Bool) {
        lock.withLock { self.isCancellable = isCancellable }
    }

    func cancel<Success: Sendable>(_ task: Task<Success, Error>) -> Bool {
        let accepted = lock.withLock { isCancellable }
        guard accepted else { return false }
        task.cancel()
        return true
    }
}
