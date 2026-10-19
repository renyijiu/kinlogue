import Foundation
import KinlogueCore
import KinloguePlatform

enum RestoreModelPhase: Equatable {
    case idle
    case choosing
    case verifying
    case awaitingReplaceConfirmation(BackupRestoreSummary)
    case activating
    case restartRequired(BackupRestoreSummary)
    case failed(RestoreModelFailure)
}

enum RestoreModelFailure: Equatable {
    case fileAccess
    case notABackup
    case unsupportedFormat
    case capacity
    case invalidBackup
    case activation
}

protocol RestoreFileSecurityScope: Sendable {
    func startAccessing(_ url: URL) async -> Bool
    func stopAccessing(_ url: URL) async
}

struct SystemRestoreFileSecurityScope: RestoreFileSecurityScope {
    func startAccessing(_ url: URL) async -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) async { url.stopAccessingSecurityScopedResource() }
}

@MainActor
final class RestoreModel: ObservableObject {
    private let service: any BackupRestoreServicing
    private let securityScope: any RestoreFileSecurityScope
    private let onReplacementBegan: @MainActor () async -> Void
    private let onReplacementEnded: @MainActor () -> Void
    private var operationGeneration: UInt64 = 0

    @Published private(set) var phase: RestoreModelPhase = .idle
    @Published var isFileImporterPresented = false

    init(
        service: any BackupRestoreServicing,
        securityScope: any RestoreFileSecurityScope = SystemRestoreFileSecurityScope(),
        onReplacementBegan: @escaping @MainActor () async -> Void = {},
        onReplacementEnded: @escaping @MainActor () -> Void = {}
    ) {
        self.service = service
        self.securityScope = securityScope
        self.onReplacementBegan = onReplacementBegan
        self.onReplacementEnded = onReplacementEnded
    }

    var isPresented: Bool { phase != .idle }

    var isDismissDisabled: Bool {
        switch phase {
        case .activating, .restartRequired, .failed(.activation): true
        default: false
        }
    }

    var failureText: String? {
        guard case .failed(let failure) = phase else { return nil }
        return switch failure {
        case .fileAccess:
            AppLocalization.string("无法读取所选文件，请确认它已完整下载到这台 Mac 后重试。")
        case .notABackup:
            AppLocalization.string("所选文件不是续页备份。")
        case .unsupportedFormat:
            AppLocalization.string("这份备份需要更新版本的续页。")
        case .capacity:
            AppLocalization.string("本机没有足够空间安全恢复这份资料库。")
        case .invalidBackup:
            AppLocalization.string("备份不完整或已损坏，当前资料库没有变化。")
        case .activation:
            AppLocalization.string("资料库替换未完成，请重新启动续页以安全收敛。")
        }
    }

    func present() {
        guard !isDismissDisabled else { return }
        _ = beginOperation()
        phase = .choosing
    }

    func reconcileBeforeStartingServices() async -> Bool {
        do {
            try await service.reconcileBeforeStartingServices()
            return true
        } catch {
            phase = .failed(.activation)
            return false
        }
    }

    func chooseBackup() {
        isFileImporterPresented = true
    }

    func prepare(_ archiveURL: URL) async {
        isFileImporterPresented = false
        let generation = beginOperation()
        phase = .verifying
        guard await securityScope.startAccessing(archiveURL) else {
            guard generation == operationGeneration else { return }
            phase = .failed(.fileAccess)
            return
        }
        guard generation == operationGeneration else {
            await securityScope.stopAccessing(archiveURL)
            return
        }
        do {
            let summary = try await service.prepare(archiveURL: archiveURL)
            await securityScope.stopAccessing(archiveURL)
            // The service cleans up a preparation that lost its generation; a cancel here
            // could revoke a newer one across the await.
            guard generation == operationGeneration else { return }
            phase = .awaitingReplaceConfirmation(summary)
        } catch {
            await securityScope.stopAccessing(archiveURL)
            guard generation == operationGeneration else { return }
            phase = .failed(Self.map(error, activation: false))
        }
    }

    func confirmReplacement() async {
        guard case .awaitingReplaceConfirmation = phase else { return }
        let generation = beginOperation()
        phase = .activating
        await onReplacementBegan()
        defer { onReplacementEnded() }
        do {
            let result = try await service.activatePreparedRestore()
            guard generation == operationGeneration else { return }
            phase = .restartRequired(result.summary)
        } catch {
            guard generation == operationGeneration else { return }
            phase = .failed(Self.map(error, activation: true))
        }
    }

    func cancel() async {
        guard !isDismissDisabled else { return }
        let generation = beginOperation()
        try? await service.cancelPreparedRestore()
        guard generation == operationGeneration else { return }
        isFileImporterPresented = false
        phase = .idle
    }

    func importerCancelled() {
        isFileImporterPresented = false
    }

    private func beginOperation() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }

    private static func map(_ error: Error, activation: Bool) -> RestoreModelFailure {
        guard !activation else { return .activation }
        guard let error = error as? BackupRestoreError else { return .invalidBackup }
        switch error {
        case .notABackup: return .notABackup
        case .unsupportedFormat: return .unsupportedFormat
        case .capacityInsufficient: return .capacity
        case .invalidSource, .sourceChanged: return .fileAccess
        case .graphInvalid, .stagingConflict, .receiptInvalid,
             .activationConflict, .ioFailure, .injectedFailure:
            return .invalidBackup
        }
    }
}
