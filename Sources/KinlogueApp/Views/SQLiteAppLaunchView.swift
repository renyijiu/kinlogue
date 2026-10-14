import AppKit
import SwiftUI

/// The main window's root. Nothing touches the library before the storage disclosure is
/// accepted; after that it shows the opening state, a failure with its recovery actions, or
/// the app shell on the opened SQLite library.
struct SQLiteAppLaunchView: View {
    @ObservedObject var startup: LibraryLaunchCoordinator
    @Binding var selectedLanguage: AppLanguage
    @AppStorage("hasAcknowledgedPlaintextStorageDisclosure") private var acknowledged = false

    var body: some View {
        Group {
            if !acknowledged {
                StorageDisclosureView { acknowledged = true }
            } else if startup.isOpening {
                ProgressView(AppLocalization.string("正在打开资料库…"))
            } else if let failure = startup.failure {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KinlogueTheme.surface)
        .kinlogueAppearance()
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
            if failure.canRetry {
                Button(AppLocalization.string("重试")) { Task { await retry() } }
                    .buttonStyle(.kinloguePrimary)
            }
            if canRestore && failure != .restartRequired {
                Button(AppLocalization.string("从数据备份恢复…")) { restore.present() }
                    .buttonStyle(.kinlogueSecondary)
            }
            Button(AppLocalization.string("退出")) { NSApplication.shared.terminate(nil) }
                .buttonStyle(.kinlogueSecondary)
        }
        .sheet(isPresented: Binding(get: { restore.isPresented }, set: { if !$0 { Task { await restore.cancel() } } })) {
            RestoreBackupView(model: restore)
        }
    }
}
