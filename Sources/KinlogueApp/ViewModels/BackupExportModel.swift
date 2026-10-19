import Foundation

enum BackupExportModelPhase: Equatable {
    case warning
    case choosing
    case exporting
    case cancelling
    case cancelled
    case failed
    case succeeded
}

/// The "export a backup to…" sheet: a warning, the save panel, progress and the result.
@MainActor
final class BackupExportModel: ObservableObject {
    private let service: any BackupExportServicing
    private var error: BackupExportError?
    private var exportTask: Task<BackupExportResult, Error>?
    private var cancellationRequested = false
    private var operationGeneration: UInt64 = 0

    @Published private(set) var phase: BackupExportModelPhase = .warning
    @Published private(set) var progress: AppBackupProgress?
    @Published private(set) var result: BackupExportResult?

    init(service: any BackupExportServicing) {
        self.service = service
    }

    var progressFraction: Double {
        guard let progress else { return 0 }
        if progress.phase == .committing { return 1 }
        guard progress.totalByteCount > 0 else { return 0 }
        return min(1, max(0, Double(progress.completedByteCount) / Double(progress.totalByteCount)))
    }

    var canCancel: Bool {
        phase == .exporting && (progress?.isCancellable ?? true)
    }

    var errorMessage: String? {
        switch error {
        case nil: nil
        case .invalidDestination:
            AppLocalization.string("无法使用所选导出位置，请选择其他位置。")
        case .insufficientSpace:
            AppLocalization.string("所选位置没有足够空间完成导出。")
        case .destinationAccessDenied:
            AppLocalization.string("续页没有权限写入所选位置，请重新选择。")
        case .sourceChanged:
            AppLocalization.string("导出期间资料库发生了变化或有原件未通过校验，导出未完成。")
        case .libraryUnreadable:
            AppLocalization.string("资料库的部分内容无法读取，导出未完成。")
        case .archiveIntegrityFailure:
            AppLocalization.string("压缩包验证失败，未发布不完整的导出。")
        case .publicationIndeterminate:
            AppLocalization.string("导出文件可能已经写入，但无法确认磁盘同步状态。请检查所选位置后再决定是否重试。")
        case .busy:
            AppLocalization.string("另一项资料库操作正在进行，请稍后重试。")
        case .unavailable:
            AppLocalization.string("导出未完成，可以稍后重试。")
        }
    }

    func begin() {
        guard phase != .exporting, phase != .cancelling else { return }
        reset(cancelService: false)
    }

    /// The save panel is about to open.
    func beginChoosingDestination() -> Bool {
        guard phase == .warning || phase == .failed || phase == .cancelled else { return false }
        operationGeneration &+= 1
        error = nil
        result = nil
        progress = nil
        phase = .choosing
        return true
    }

    func destinationSelectionCancelled() {
        guard phase == .choosing else { return }
        phase = .warning
    }

    func export(to destinationURL: URL) async {
        guard phase == .choosing || phase == .warning else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        cancellationRequested = false
        error = nil
        result = nil
        progress = nil
        phase = .exporting
        let relay = BackupProgressRelay()
        let task = Task { [weak self, service] in
            try await service.export(to: destinationURL) { [weak self] value in
                relay.submit(value) { @MainActor [weak self] value in
                    self?.apply(value, generation: generation)
                }
            }
        }
        exportTask = task
        defer { if generation == operationGeneration { exportTask = nil } }
        do {
            let completed = try await task.value
            // A finished export is authoritative: a cancel can race its non-cancellable commit.
            guard generation == operationGeneration else { return }
            result = completed
            phase = .succeeded
        } catch is CancellationError {
            guard generation == operationGeneration else { return }
            phase = .cancelled
        } catch {
            guard generation == operationGeneration else { return }
            self.error = error as? BackupExportError ?? .unavailable
            phase = .failed
        }
    }

    func cancel() async {
        guard canCancel else { return }
        guard await service.cancelExport() else { return }
        cancellationRequested = true
        phase = .cancelling
        exportTask?.cancel()
    }

    func clear() {
        reset(cancelService: true)
    }

    private func reset(cancelService: Bool) {
        operationGeneration &+= 1
        cancellationRequested = true
        exportTask?.cancel()
        exportTask = nil
        progress = nil
        result = nil
        error = nil
        phase = .warning
        if cancelService {
            Task { [service] in _ = await service.cancelExport() }
        }
    }

    private func apply(_ value: AppBackupProgress, generation: UInt64) {
        guard generation == operationGeneration, !cancellationRequested, phase == .exporting else { return }
        progress = value
    }
}

// SAFETY: `lock` protects all coalescing state. The only work scheduled outside the lock is a
// Sendable delivery closure isolated to the MainActor.
final class BackupProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPhase: AppBackupPhase?
    private var lastPercent = -1
    private var lastCancellable = true
    private var latest: AppBackupProgress?
    private var deliveryScheduled = false

    func submit(_ progress: AppBackupProgress, delivery: @escaping @MainActor @Sendable (AppBackupProgress) -> Void) {
        let shouldSchedule = lock.withLock {
            let percent = Self.percent(for: progress)
            guard lastPhase != progress.phase || lastPercent != percent || lastCancellable != progress.isCancellable else {
                return false
            }
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
                  let value = self.lock.withLock({ () -> AppBackupProgress? in
                      defer { self.latest = nil; self.deliveryScheduled = false }
                      return self.latest
                  }) else { return }
            delivery(value)
        }
    }

    private static func percent(for progress: AppBackupProgress) -> Int {
        guard progress.totalByteCount > 0 else { return 0 }
        let raw = Int((Double(progress.completedByteCount) / Double(progress.totalByteCount)) * 100)
        return min(max(raw, 0), 100) / 10 * 10
    }
}
