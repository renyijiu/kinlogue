import SwiftUI

struct BackupExportView: View {
    @ObservedObject var model: BackupExportModel
    let onChooseDestination: () -> Void
    let onClose: () -> Void
    let onShowInFinder: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(AppLocalization.string("导出备份"), systemImage: "archivebox")
                .font(.title2.weight(.semibold))

            ScrollView {
                Group {
                    switch model.phase {
                    case .warning:
                        warningContent
                    case .choosing:
                        centeredProgress(AppLocalization.string("正在等待选择保存位置…"))
                    case .exporting:
                        exportProgress
                    case .cancelling:
                        centeredProgress(AppLocalization.string("正在取消并清理未完成的导出…"))
                    case .cancelled:
                        ContentUnavailableView(
                            AppLocalization.string("导出已取消"),
                            systemImage: "xmark.circle",
                            description: Text(AppLocalization.string("未发布不完整的压缩包。"))
                        )
                    case .failed:
                        ContentUnavailableView(
                            AppLocalization.string("导出未完成"),
                            systemImage: "exclamationmark.triangle",
                            description: Text(
                                model.errorMessage
                                    ?? AppLocalization.string("导出未完成，可以稍后重试。")
                            )
                        )
                    case .succeeded:
                        successContent
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            }

            Divider()
            actionBar
        }
        .padding(28)
        .frame(minWidth: 480, idealWidth: 600, minHeight: 480)
        .kinlogueSheetCanvas()
        .interactiveDismissDisabled(isDismissDisabled)
        .accessibilityIdentifier("backup-export-sheet")
    }

    private var warningContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                AppLocalization.string("备份文件不加密，包含全部健康资料"),
                systemImage: "exclamationmark.shield"
            )
            .font(.headline)
            .foregroundStyle(KinlogueTheme.warning)

            Text(AppLocalization.string("压缩包包含资料库的全部内容：家庭成员、报告、识别文字、草稿、手机上传和原始文件，可以用“从备份恢复…”整库恢复。"))
            VStack(alignment: .leading, spacing: 10) {
                warningRow(AppLocalization.string("原始文件按家庭成员和日期排列，解压后可以直接打开或打印。"))
                warningRow(AppLocalization.string("整份备份含有全家所有人的资料，不要直接交给医生；可以只发送某位成员的文件夹。"))
                warningRow(AppLocalization.string("导出后的文件由你保管，续页不会再管理或删除它。"))
            }
            .foregroundStyle(KinlogueTheme.onVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var exportProgress: some View {
        VStack(spacing: 18) {
            ProgressView(value: model.progressFraction)
                .progressViewStyle(.linear)
                .accessibilityLabel(AppLocalization.string("导出进度"))
                .accessibilityValue(
                    AppLocalization.string("已完成 \(Int(model.progressFraction * 100))%")
                )
            Text(progressTitle)
                .font(.headline)
            if let progress = model.progress {
                Text(AppLocalization.string(
                    "\(formattedByteCount(progress.completedByteCount)) / \(formattedByteCount(progress.totalByteCount))"
                ))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(KinlogueTheme.onVariant)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var successContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(KinlogueTheme.success)
                .accessibilityHidden(true)
            Text(AppLocalization.string("备份已导出"))
                .font(.title3.weight(.semibold))
            if let result = model.result {
                Text(result.url.lastPathComponent)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(AppLocalization.string("包含 \(result.originalCount) 个原件，压缩包 \(formattedByteCount(result.byteCount))"))
                .foregroundStyle(KinlogueTheme.onVariant)
            }
            Text(AppLocalization.string("压缩包位于续页资料库之外，请妥善保管。"))
                .font(.caption)
                .foregroundStyle(KinlogueTheme.onVariant)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack {
            switch model.phase {
            case .warning:
                Button(AppLocalization.string("取消"), action: onClose)
                    .buttonStyle(.kinlogueSecondary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("backup-export-close")
                Spacer()
                Button(AppLocalization.string("继续并选择位置…"), action: onChooseDestination)
                    .buttonStyle(.kinloguePrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("backup-export-continue")
            case .choosing:
                Spacer()
            case .exporting:
                if model.canCancel {
                    cancelButton
                }
                Spacer()
            case .cancelling:
                Spacer()
            case .cancelled:
                Button(AppLocalization.string("关闭"), action: onClose)
                    .buttonStyle(.kinlogueSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            case .failed:
                Button(AppLocalization.string("关闭"), action: onClose)
                    .buttonStyle(.kinlogueSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(AppLocalization.string("重试…")) {
                    model.begin()
                    onChooseDestination()
                }
                .buttonStyle(.kinloguePrimary)
                .accessibilityIdentifier("backup-export-retry")
            case .succeeded:
                if let destinationURL = model.result?.url {
                    Button(AppLocalization.string("在访达中显示")) {
                        onShowInFinder(destinationURL)
                    }
                    .buttonStyle(.kinlogueSecondary)
                    .accessibilityIdentifier("backup-export-show-in-finder")
                }
                Spacer()
                Button(AppLocalization.string("完成"), action: onClose)
                    .buttonStyle(.kinloguePrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("backup-export-done")
            }
        }
    }

    private var cancelButton: some View {
        Button(AppLocalization.string("取消")) {
            Task { await model.cancel() }
        }
        .buttonStyle(.kinlogueSecondary)
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("backup-export-cancel")
    }

    private var isDismissDisabled: Bool {
        switch model.phase {
        case .choosing, .exporting, .cancelling: true
        case .warning, .cancelled, .failed, .succeeded: false
        }
    }

    private var progressTitle: String {
        switch model.progress?.phase {
        case .preparing, nil: AppLocalization.string("正在准备导出…")
        case .writing: AppLocalization.string("正在写入备份…")
        case .verifying: AppLocalization.string("正在验证压缩包…")
        case .committing: AppLocalization.string("正在保存压缩包，请勿关闭续页…")
        }
    }

    private func centeredProgress(_ title: String) -> some View {
        ProgressView(title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func warningRow(_ title: String) -> some View {
        Label(title, systemImage: "checkmark.circle")
            .accessibilityElement(children: .combine)
    }

    private func formattedByteCount(_ byteCount: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: byteCount), countStyle: .file)
    }
}
