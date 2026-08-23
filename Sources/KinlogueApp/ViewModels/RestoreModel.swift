import Foundation
import KinlogueCore
import KinloguePlatform

enum RestoreModelPhase: Equatable {
    case idle
    case enteringRecoveryCode
    case authenticating
    case awaitingReplaceConfirmation(BackupRestoreSummary)
    case activating
    case restartRequired(BackupRestoreSummary)
    case failed(RestoreModelFailure)
}

enum RestoreModelFailure: Equatable {
    case fileAccess
    case authentication
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
    func startAccessing(_ url: URL) async -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) async {
        url.stopAccessingSecurityScopedResource()
    }
}

@MainActor
final class RestoreModel: ObservableObject {
    private let service: any BackupRestoreServicing
    private let securityScope: any RestoreFileSecurityScope
    private var operationGeneration: UInt64 = 0

    @Published private(set) var phase: RestoreModelPhase = .idle
    @Published var recoveryCode = ""
    @Published var isFileImporterPresented = false

    init(
        service: any BackupRestoreServicing,
        securityScope: any RestoreFileSecurityScope = SystemRestoreFileSecurityScope()
    ) {
        self.service = service
        self.securityScope = securityScope
    }

    var isPresented: Bool { phase != .idle }

    var isDismissDisabled: Bool {
        switch phase {
        case .activating, .restartRequired, .failed(.activation):
            true
        default:
            false
        }
    }

    var failureText: String? {
        guard case .failed(let failure) = phase else { return nil }
        return switch failure {
        case .fileAccess:
            AppLocalization.string("无法读取所选恢复点，请确认文件已下载到本机后重试。")
        case .authentication:
            AppLocalization.string("恢复码错误，或恢复点未通过身份验证。")
        case .unsupportedFormat:
            AppLocalization.string("此恢复点需要更新版本的续页。")
        case .capacity:
            AppLocalization.string("本机没有足够空间安全恢复这份资料库。")
        case .invalidBackup:
            AppLocalization.string("恢复点不完整或已损坏，当前资料库没有变化。")
        case .activation:
            AppLocalization.string("资料库替换未完成，请重新启动续页以安全收敛。")
        }
    }

    func present() {
        _ = beginOperation()
        recoveryCode = ""
        phase = .enteringRecoveryCode
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

    func chooseCheckpoint() {
        guard !recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .failed(.authentication)
            return
        }
        isFileImporterPresented = true
    }

    func prepare(_ checkpointURL: URL) async {
        isFileImporterPresented = false
        let generation = beginOperation()
        phase = .authenticating
        guard await securityScope.startAccessing(checkpointURL) else {
            guard generation == operationGeneration else { return }
            phase = .failed(.fileAccess)
            return
        }
        do {
            let summary = try await service.prepare(
                checkpointURL: checkpointURL,
                recoveryCode: recoveryCode
            )
            await securityScope.stopAccessing(checkpointURL)
            guard generation == operationGeneration else {
                try? await service.cancelPreparedRestore()
                return
            }
            phase = .awaitingReplaceConfirmation(summary)
        } catch {
            await securityScope.stopAccessing(checkpointURL)
            guard generation == operationGeneration else { return }
            phase = .failed(Self.map(error, activation: false))
        }
    }

    func confirmReplacement() async {
        guard case .awaitingReplaceConfirmation = phase else { return }
        let generation = beginOperation()
        phase = .activating
        do {
            let result = try await service.activatePreparedRestore()
            guard generation == operationGeneration else { return }
            recoveryCode = ""
            phase = .restartRequired(result.summary)
        } catch {
            guard generation == operationGeneration else { return }
            recoveryCode = ""
            phase = .failed(Self.map(error, activation: true))
        }
    }

    func cancel() async {
        guard !isDismissDisabled else { return }
        _ = beginOperation()
        try? await service.cancelPreparedRestore()
        recoveryCode = ""
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
        case .authenticationFailed:
            return .authentication
        case .unsupportedFormat:
            return .unsupportedFormat
        case .capacityInsufficient:
            return .capacity
        case .invalidSource, .sourceChanged:
            return .fileAccess
        case .graphInvalid, .stagingConflict, .receiptInvalid,
             .activationConflict, .ioFailure, .injectedFailure:
            return .invalidBackup
        }
    }
}
