import AppKit
import KinloguePlatform
import SwiftUI
import UniformTypeIdentifiers

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
                    .buttonStyle(.kinlogueSecondary)
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(28)
        .frame(width: 540)
        .kinlogueSheetCanvas()
        .interactiveDismissDisabled(model.isDismissDisabled)
        .accessibilityIdentifier("restore-backup-sheet")
        .fileImporter(
            isPresented: $model.isFileImporterPresented,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let archiveURL = urls.first else {
                    model.importerCancelled()
                    return
                }
                Task { await model.prepare(archiveURL) }
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
        case .choosing:
            Text(AppLocalization.string("选择一个续页备份压缩包（.zip）。续页会先完整验证，确认之前不会修改当前资料库。"))
                .foregroundStyle(KinlogueTheme.onVariant)
                .fixedSize(horizontal: false, vertical: true)
            Text(AppLocalization.string("备份在网盘里时，请先确认它已完整下载到这台 Mac。"))
                .font(.caption)
                .foregroundStyle(KinlogueTheme.onVariant)
            Button(AppLocalization.string("选择备份文件…")) {
                model.chooseBackup()
            }
            .buttonStyle(.kinloguePrimary)
            .accessibilityIdentifier("restore-choose-backup")
        case .verifying:
            ProgressView(AppLocalization.string("正在验证备份…"))
            Text(AppLocalization.string("此阶段可以取消；当前资料库不会被替换。"))
                .font(.caption)
                .foregroundStyle(KinlogueTheme.onVariant)
        case .awaitingReplaceConfirmation(let summary):
            restoreSummary(summary)
            KinlogueWarningNotice(
                AppLocalization.string("这会替换而不是合并当前资料库。备份文件夹设置会保留，但自动备份会关闭，需要时请重新打开。")
            )
            Button(AppLocalization.string("确认替换本机资料库"), role: .destructive) {
                Task { await model.confirmReplacement() }
            }
            .buttonStyle(.kinlogueDestructive)
            .accessibilityIdentifier("restore-confirm-replacement")
        case .activating:
            ProgressView(AppLocalization.string("正在替换本机资料库…"))
            Text(AppLocalization.string("请勿退出续页。操作完成后必须重新启动。"))
                .foregroundStyle(KinlogueTheme.onVariant)
        case .restartRequired(let summary):
            restoreSummary(summary)
            KinlogueStatusLabel(
                AppLocalization.string("恢复已完成。请退出并重新打开续页。"),
                tone: .success
            )
            Button(AppLocalization.string("退出续页")) {
                RestartRequiredQuit.perform()
            }
            .buttonStyle(.kinloguePrimary)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("restore-quit")
        case .failed(.activation):
            KinlogueStatusLabel(
                model.failureText ?? AppLocalization.string("资料库替换未完成，请重新启动续页以安全收敛。"),
                tone: .danger
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(AppLocalization.string("资料库替换已进入收敛阶段。请退出并重新打开续页；在重新启动前不要继续使用当前窗口。"))
                .foregroundStyle(KinlogueTheme.onVariant)
            Button(AppLocalization.string("退出续页")) {
                RestartRequiredQuit.perform()
            }
            .buttonStyle(.kinloguePrimary)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("restore-failure-quit")
        case .failed:
            KinlogueStatusLabel(
                model.failureText ?? AppLocalization.string("恢复未完成。"),
                tone: .danger
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(AppLocalization.string("当前资料库不会因验证失败而被替换。你可以取消后重新选择备份。"))
                .foregroundStyle(KinlogueTheme.onVariant)
        }
    }

    private func restoreSummary(_ summary: BackupRestoreSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.string("已验证的备份概要"))
                .font(.headline)
            summaryRow(
                AppLocalization.string("备份时间"),
                value: summary.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                    .locale(AppLocalization.locale(for: AppLocalization.selectedLanguage())))
            )
            if !summary.creatorVersion.isEmpty {
                summaryRow(AppLocalization.string("写入它的续页版本"), value: summary.creatorVersion)
            }
            summaryRow(AppLocalization.string("家庭成员"), value: String(summary.memberCount))
            summaryRow(AppLocalization.string("健康记录"), value: String(summary.recordCount))
            summaryRow(AppLocalization.string("手机上传项目"), value: String(summary.inboxItemCount))
            summaryRow(AppLocalization.string("原始文件"), value: String(summary.originalCount))
            summaryRow(
                AppLocalization.string("资料大小"),
                value: ByteCountFormatter.string(fromByteCount: Int64(clamping: summary.plaintextByteCount), countStyle: .file)
            )
        }
        .padding(14)
        .kinloguePanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("不包含健康内容的备份概要"))
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
