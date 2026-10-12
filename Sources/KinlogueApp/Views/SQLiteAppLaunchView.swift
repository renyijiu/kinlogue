import AppKit
import SwiftUI

/// Candidate launch surface; production selects this only after the cutover gates pass.
struct SQLiteAppLaunchView: View {
    @ObservedObject var startup: AppStartupCoordinator
    @Binding var selectedLanguage: AppLanguage
    @AppStorage("hasAcknowledgedPlaintextStorageDisclosure") private var acknowledged = false

    var body: some View {
        Group {
            if !acknowledged {
                StorageDisclosureView { acknowledged = true }
            } else if startup.isOpening {
                ProgressView(AppLocalization.string("正在打开资料库…"))
            } else if let failure = startup.candidateFailure {
                failureView(failure)
            } else if let composition = startup.composition {
                AppShellView(model: composition.appModel, deletionModel: composition.deletionModel,
                    lanInboxModel: composition.lanInboxModel, backupModel: composition.backupModel,
                    restoreModel: composition.restoreModel, startupCoordinator: composition.startupCoordinator,
                    selectedLanguage: $selectedLanguage, integrityCoordinator: composition.integrityCoordinator)
            } else {
                ProgressView(AppLocalization.string("正在打开资料库…"))
            }
        }
        .task(id: acknowledged) {
            guard acknowledged else { return }
            startup.acknowledgeStorageDisclosure()
            _ = await startup.start()
        }
    }

    @ViewBuilder private func failureView(_ failure: SQLiteStartupFailure) -> some View {
        if let composition = startup.composition {
            SQLiteStartupFailureView(failure: failure, restore: composition.restoreModel,
                canRestore: startup.seedRestoreService != nil || startup.hasOpenedComposition,
                retry: { _ = await startup.start() })
        }
    }
}

private struct SQLiteStartupFailureView: View {
    let failure: SQLiteStartupFailure
    @ObservedObject var restore: RestoreModel
    let canRestore: Bool
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("无法打开资料库"), systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(failure.message)
        } actions: {
            if failure.canRetry { Button(AppLocalization.string("重试")) { Task { await retry() } } }
            if canRestore && failure != .restartRequired {
                Button(AppLocalization.string("从数据备份恢复…")) { restore.present() }
            }
            Button(AppLocalization.string("退出")) { NSApplication.shared.terminate(nil) }
        }
        .sheet(isPresented: Binding(get: { restore.isPresented }, set: { if !$0 { Task { await restore.cancel() } } })) {
            RestoreBackupView(model: restore)
        }
    }
}
