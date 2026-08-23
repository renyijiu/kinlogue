import Foundation

enum OriginalExportModelPhase: Equatable {
    case warning
    case checking
    case choosing
    case exporting
    case cancelling
    case cancelled
    case empty
    case failed
    case succeeded
}

@MainActor
final class OriginalExportModel: ObservableObject {
    private let service: any OriginalExportServicing
    private var userError: OriginalExportServiceError?
    private var exportTask: Task<OriginalExportResult, Error>?
    private var cancellationRequested = false
    private var operationGeneration: UInt64 = 0

    @Published private(set) var phase: OriginalExportModelPhase = .warning
    @Published private(set) var progress: AppOriginalExportProgress?
    @Published private(set) var result: OriginalExportResult?

    init(service: any OriginalExportServicing) {
        self.service = service
    }

    var progressFraction: Double {
        guard let progress else { return 0 }
        if progress.phase == .committing { return 1 }
        if progress.totalByteCount > 0 {
            return min(1, max(0, Double(progress.completedByteCount) / Double(progress.totalByteCount)))
        }
        guard progress.totalEntryCount > 0 else { return 0 }
        return min(1, max(0, Double(progress.completedEntryCount) / Double(progress.totalEntryCount)))
    }

    var canCancel: Bool {
        phase == .exporting && (progress?.isCancellable ?? true)
    }

    var userErrorMessage: String? {
        switch userError {
        case nil: nil
        case .emptyArchive: nil
        case .invalidDestination:
            AppLocalization.string("无法使用所选导出位置，请选择其他位置。")
        case .insufficientSpace:
            AppLocalization.string("所选位置没有足够空间完成导出。")
        case .destinationAccessDenied:
            AppLocalization.string("续页没有权限写入所选位置，请重新选择。")
        case .vaultChanged:
            AppLocalization.string("导出期间资料库发生变化，未生成不完整的压缩包。请重试。")
        case .sourceIntegrityFailure:
            AppLocalization.string("部分原始文件已损坏或发生变化，导出未完成。")
        case .archiveIntegrityFailure:
            AppLocalization.string("压缩包验证失败，未发布不完整的导出。")
        case .publicationIndeterminate:
            AppLocalization.string("导出文件可能已经写入，但无法确认磁盘同步状态。请检查所选位置后再决定是否重试。")
        case .unavailable:
            AppLocalization.string("导出未完成，可以稍后重试。")
        }
    }

    func begin() {
        guard phase != .exporting, phase != .cancelling else { return }
        resetToWarning(cancelService: false)
    }

    func prepareForDestination(undatedToken: String) async -> Bool {
        guard phase == .warning || phase == .empty || phase == .failed || phase == .cancelled else {
            return false
        }
        operationGeneration &+= 1
        let generation = operationGeneration
        cancellationRequested = false
        userError = nil
        result = nil
        progress = nil
        phase = .checking
        do {
            try await service.prepare(undatedToken: undatedToken)
            guard generation == operationGeneration, !cancellationRequested else { return false }
            phase = .choosing
            return true
        } catch is CancellationError {
            guard generation == operationGeneration else { return false }
            phase = .cancelled
            return false
        } catch let error as OriginalExportServiceError {
            guard generation == operationGeneration else { return false }
            apply(error)
            return false
        } catch {
            guard generation == operationGeneration else { return false }
            userError = .unavailable
            phase = .failed
            return false
        }
    }

    func destinationSelectionCancelled() {
        guard phase == .choosing else { return }
        phase = .warning
    }

    func export(to destinationURL: URL, undatedToken: String) async {
        guard phase == .choosing || phase == .warning else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        cancellationRequested = false
        userError = nil
        result = nil
        progress = nil
        phase = .exporting
        let progressRelay = OriginalExportProgressRelay()
        let task = Task { [service] in
            try await service.export(
                to: destinationURL,
                undatedToken: undatedToken
            ) { [weak self] value in
                progressRelay.submit(value) { @MainActor [weak self] value in
                    self?.apply(value, generation: generation)
                }
            }
        }
        exportTask = task
        defer {
            if generation == operationGeneration { exportTask = nil }
        }
        do {
            let completed = try await task.value
            // A successful result is authoritative: cancellation can race the
            // Platform transition into its non-cancellable atomic commit.
            guard generation == operationGeneration else { return }
            progress = AppOriginalExportProgress(
                phase: .committing,
                completedByteCount: completed.totalByteCount,
                totalByteCount: completed.totalByteCount,
                completedEntryCount: completed.entryCount,
                totalEntryCount: completed.entryCount,
                isCancellable: false
            )
            result = completed
            phase = .succeeded
        } catch is CancellationError {
            guard generation == operationGeneration else { return }
            phase = .cancelled
        } catch let error as OriginalExportServiceError {
            guard generation == operationGeneration else { return }
            apply(error)
        } catch {
            guard generation == operationGeneration else { return }
            userError = .unavailable
            phase = .failed
        }
    }

    func cancel() async {
        guard canCancel || phase == .checking || phase == .choosing else { return }
        guard await service.cancel() else { return }
        cancellationRequested = true
        phase = .cancelling
        exportTask?.cancel()
    }

    func clear() {
        resetToWarning(cancelService: true)
    }

    private func resetToWarning(cancelService: Bool) {
        operationGeneration &+= 1
        cancellationRequested = true
        exportTask?.cancel()
        exportTask = nil
        progress = nil
        result = nil
        userError = nil
        phase = .warning
        if cancelService {
            Task { [service] in _ = await service.cancel() }
        }
    }

    private func apply(_ value: AppOriginalExportProgress, generation: UInt64) {
        guard generation == operationGeneration,
              !cancellationRequested,
              phase == .exporting else { return }
        progress = value
    }

    private func apply(_ error: OriginalExportServiceError) {
        if error == .emptyArchive {
            userError = nil
            phase = .empty
            return
        }
        userError = error
        phase = .failed
    }
}

// SAFETY: `lock` protects all coalescing state. The only work scheduled outside
// the lock is a Sendable delivery closure isolated to the MainActor.
final class OriginalExportProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPhase: AppOriginalExportPhase?
    private var lastPercent = -1
    private var lastCancellable = true
    private var latest: AppOriginalExportProgress?
    private var deliveryScheduled = false

    func submit(
        _ progress: AppOriginalExportProgress,
        delivery: @escaping @MainActor @Sendable (AppOriginalExportProgress) -> Void
    ) {
        let shouldSchedule = lock.withLock {
            let percent = Self.percent(for: progress)
            let shouldAccept = lastPhase != progress.phase
                || lastPercent != percent
                || lastCancellable != progress.isCancellable
            guard shouldAccept else { return false }
            lastPhase = progress.phase
            lastPercent = percent
            lastCancellable = progress.isCancellable
            latest = progress
            guard !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let value = self.lock.withLock({ () -> AppOriginalExportProgress? in
                      defer {
                          self.latest = nil
                          self.deliveryScheduled = false
                      }
                      return self.latest
                  }) else { return }
            delivery(value)
        }
    }

    private static func percent(for progress: AppOriginalExportProgress) -> Int {
        let rawPercent: Int
        if progress.totalByteCount > 0 {
            rawPercent = Int((Double(progress.completedByteCount) / Double(progress.totalByteCount)) * 100)
        } else if progress.totalEntryCount > 0 {
            rawPercent = Int((Double(progress.completedEntryCount) / Double(progress.totalEntryCount)) * 100)
        } else {
            rawPercent = 0
        }
        return min(max(rawPercent, 0), 100) / 10 * 10
    }
}
