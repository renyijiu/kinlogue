import Foundation
import KinlogueCore

enum VaultDeletionPhase: Equatable {
    case idle
    case deleting
    case deleted
    case failed
}

private enum VaultDeletionError: Equatable {
    case confirmationRequired
    case deletionFailed

    var localizedText: String {
        switch self {
        case .confirmationRequired:
            AppLocalization.string("请输入完整确认短语")
        case .deletionFailed:
            AppLocalization.string("未能删除本机资料库。请重新启动续页后检查；原资料可能仍保留在磁盘上。")
        }
    }
}

@MainActor
final class VaultDeletionModel: ObservableObject {
    static var confirmationPhrase: String {
        AppLocalization.string("彻底删除")
    }

    private let destroyService: any VaultDestroyServicing
    private let onDeletionBegan: @MainActor () async -> Void
    private let onVaultDeleted: @MainActor () -> Void
    private let onDeletionFailed: @MainActor () -> Void

    @Published private(set) var phase: VaultDeletionPhase = .idle
    @Published var confirmationInput = ""
    @Published private var userError: VaultDeletionError?

    init(
        destroyService: any VaultDestroyServicing,
        onDeletionBegan: @escaping @MainActor () async -> Void = {},
        onVaultDeleted: @escaping @MainActor () -> Void = {},
        onDeletionFailed: @escaping @MainActor () -> Void = {}
    ) {
        self.destroyService = destroyService
        self.onDeletionBegan = onDeletionBegan
        self.onVaultDeleted = onVaultDeleted
        self.onDeletionFailed = onDeletionFailed
    }

    var canDeleteVault: Bool {
        (phase == .idle || phase == .failed)
            && confirmationInput == Self.confirmationPhrase
    }

    var errorMessage: String? { userError?.localizedText }

    func deleteCurrentVault() async {
        guard canDeleteVault else {
            userError = .confirmationRequired
            return
        }

        userError = nil
        confirmationInput = ""
        phase = .deleting
        await onDeletionBegan()

        do {
            try await destroyService.destroyCurrentVault()
            phase = .deleted
            onVaultDeleted()
        } catch {
            phase = .failed
            userError = .deletionFailed
            onDeletionFailed()
        }
    }
}
