import AppKit
import KinloguePlatform
import SwiftUI
import UniformTypeIdentifiers

struct BackupSetupView: View {
    @ObservedObject var model: BackupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppLocalization.string("保存数据备份恢复码"))
                .font(.title2.bold())
            Text(AppLocalization.string("恢复码是读取加密恢复点所必需的。请把它完整保存在密码管理器或其他独立位置；续页无法替你找回。"))
                .foregroundStyle(KinlogueTheme.onVariant)
                .fixedSize(horizontal: false, vertical: true)

            if let recoveryCode = model.recoveryCode {
                Text(recoveryCode)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(KinlogueTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(AppLocalization.string("恢复码显示在屏幕上。为避免旁人通过辅助功能听到，续页不会朗读这段敏感内容。"))
                    .font(.caption)
                    .foregroundStyle(KinlogueTheme.onVariant)
            } else {
                ProgressView(AppLocalization.string("正在准备加密备份…"))
            }

            Toggle(
                AppLocalization.string("我已将恢复码完整保存在独立位置"),
                isOn: $model.hasConfirmedIndependentSave
            )
            .accessibilityIdentifier("backup-recovery-code-saved")

            SecureField(
                AppLocalization.string("完整回输恢复码"),
                text: $model.recoveryCodeReentry
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("backup-recovery-code-reentry")

            if let failure = model.failureText {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("backup-setup-error")
            }

            HStack {
                Button(AppLocalization.string("取消"), role: .cancel) {
                    model.cancelSetup()
                }
                Spacer()
                Button(AppLocalization.string("验证并启用备份")) {
                    Task { await model.completeSetup() }
                }
                .buttonStyle(.kinloguePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(model.recoveryCode == nil)
                .accessibilityIdentifier("backup-enable")
            }
        }
        .padding(28)
        .frame(width: 540)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("backup-setup-sheet")
    }
}

struct PendingBackupEnrollmentView: View {
    @ObservedObject var model: BackupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppLocalization.string("继续未完成的备份设置"))
                .font(.title2.bold())
            Text(AppLocalization.string("输入你在首次设置时独立保存的完整恢复码。续页会继续使用原有备份身份，不会生成新的恢复码。"))
                .foregroundStyle(KinlogueTheme.onVariant)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(
                AppLocalization.string("恢复码"),
                text: $model.pendingEnrollmentRecoveryCode
            )
            .textFieldStyle(.roundedBorder)
            .disabled(model.isPendingEnrollmentOperation)
            .accessibilityIdentifier("backup-pending-recovery-code")

            if let failure = model.failureText {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("backup-pending-error")
            }

            HStack {
                Button(AppLocalization.string("取消"), role: .cancel) {
                    model.cancelPendingEnrollmentRecovery()
                }
                .disabled(model.isPendingEnrollmentOperation)
                Spacer()
                Button {
                    Task { await model.resumePendingEnrollment() }
                } label: {
                    if model.isPendingEnrollmentOperation {
                        ProgressView(AppLocalization.string("正在验证恢复码…"))
                    } else {
                        Text(AppLocalization.string("验证并完成设置"))
                    }
                }
                .buttonStyle(.kinloguePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    model.isPendingEnrollmentOperation
                        || model.pendingEnrollmentRecoveryCode
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                )
                .accessibilityIdentifier("backup-pending-resume")
            }
        }
        .padding(28)
        .frame(width: 540)
        .interactiveDismissDisabled(model.isPendingEnrollmentOperation)
        .accessibilityIdentifier("backup-pending-enrollment-sheet")
    }
}

struct RestoreBackupView: View {
    @ObservedObject var model: RestoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppLocalization.string("从数据备份恢复"))
                .font(.title2.bold())

            phaseContent

            if !model.isDismissDisabled {
                HStack {
                    Spacer()
                    Button(AppLocalization.string("取消"), role: .cancel) {
                        Task { await model.cancel() }
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(28)
        .frame(width: 540)
        .interactiveDismissDisabled(model.isDismissDisabled)
        .accessibilityIdentifier("restore-backup-sheet")
        .fileImporter(
            isPresented: $model.isFileImporterPresented,
            allowedContentTypes: [UTType(filenameExtension: "kinloguebackup") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let checkpointURL = urls.first else {
                    model.importerCancelled()
                    return
                }
                Task { await model.prepare(checkpointURL) }
            case .failure:
                model.importerCancelled()
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .enteringRecoveryCode:
            Text(AppLocalization.string("选择一个已下载到本机的 .kinloguebackup 恢复点。恢复会先完整验证，不会在确认前修改当前资料库。"))
                .foregroundStyle(KinlogueTheme.onVariant)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(AppLocalization.string("恢复码"), text: $model.recoveryCode)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("restore-recovery-code")
            Button(AppLocalization.string("选择恢复点…")) {
                model.chooseCheckpoint()
            }
            .buttonStyle(.kinloguePrimary)
            .accessibilityIdentifier("restore-choose-checkpoint")
        case .authenticating:
            ProgressView(AppLocalization.string("正在验证恢复点…"))
            Text(AppLocalization.string("此阶段可以取消；当前资料库不会被替换。"))
                .font(.caption)
                .foregroundStyle(KinlogueTheme.onVariant)
        case .awaitingReplaceConfirmation(let summary):
            restoreSummary(summary)
            Label(
                AppLocalization.string("这会替换而不是合并当前资料库，并移除本机备份设置。外部恢复点会保留。"),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            Button(AppLocalization.string("确认替换本机资料库"), role: .destructive) {
                Task { await model.confirmReplacement() }
            }
            .accessibilityIdentifier("restore-confirm-replacement")
        case .activating:
            ProgressView(AppLocalization.string("正在替换本机资料库…"))
            Text(AppLocalization.string("请勿退出续页。操作完成后必须重新启动。"))
                .foregroundStyle(KinlogueTheme.onVariant)
        case .restartRequired(let summary):
            restoreSummary(summary)
            Label(AppLocalization.string("恢复已完成。请退出并重新打开续页。"), systemImage: "checkmark.circle")
                .foregroundStyle(.green)
            Button(AppLocalization.string("退出续页")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.kinloguePrimary)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("restore-quit")
        case .failed(.activation):
            Label(
                model.failureText ?? AppLocalization.string("资料库替换未完成，请重新启动续页以安全收敛。"),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            Text(AppLocalization.string("资料库替换已进入收敛阶段。请退出并重新打开续页；在重新启动前不要继续使用当前窗口。"))
                .foregroundStyle(KinlogueTheme.onVariant)
            Button(AppLocalization.string("退出续页")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.kinloguePrimary)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("restore-failure-quit")
        case .failed:
            Label(
                model.failureText ?? AppLocalization.string("恢复未完成。"),
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            Text(AppLocalization.string("当前资料库不会因验证失败而被替换。你可以取消后重新选择恢复点。"))
                .foregroundStyle(KinlogueTheme.onVariant)
        }
    }

    private func restoreSummary(_ summary: BackupRestoreSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string("已验证的恢复点概要"))
                .font(.headline)
            summaryRow(
                AppLocalization.string("家庭成员"),
                value: String(summary.memberCount)
            )
            summaryRow(
                AppLocalization.string("健康记录"),
                value: String(summary.recordCount)
            )
            summaryRow(
                AppLocalization.string("手机上传项目"),
                value: String(summary.inboxItemCount)
            )
            summaryRow(
                AppLocalization.string("解密后大小"),
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: summary.plaintextByteCount),
                    countStyle: .file
                )
            )
        }
        .padding(14)
        .background(KinlogueTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("不包含健康内容的恢复点概要"))
    }

    private func summaryRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(KinlogueTheme.onVariant)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }
}
