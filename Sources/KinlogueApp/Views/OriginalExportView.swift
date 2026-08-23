import SwiftUI

struct OriginalExportView: View {
    @ObservedObject var model: OriginalExportModel
    let onChooseDestination: () -> Void
    let onClose: () -> Void
    let onShowInFinder: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(AppLocalization.string("导出全部原始文件"), systemImage: "archivebox")
                .font(.title2.weight(.semibold))

            ScrollView {
                Group {
                    switch model.phase {
                    case .warning:
                        warningContent
                    case .checking:
                        centeredProgress(AppLocalization.string("正在检查可导出的原始文件…"))
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
                    case .empty:
                        ContentUnavailableView(
                            AppLocalization.string("没有可导出的原始文件"),
                            systemImage: "archivebox",
                            description: Text(AppLocalization.string("确认后的报告和医学影像原件会出现在这里。"))
                        )
                    case .failed:
                        ContentUnavailableView(
                            AppLocalization.string("导出未完成"),
                            systemImage: "exclamationmark.triangle",
                            description: Text(
                                model.userErrorMessage
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
        .interactiveDismissDisabled(isDismissDisabled)
        .accessibilityIdentifier("original-export-sheet")
    }

    private var warningContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                AppLocalization.string("导出的压缩包包含未加密的健康资料"),
                systemImage: "exclamationmark.shield"
            )
            .font(.headline)
            .foregroundStyle(.orange)

            Text(AppLocalization.string("只会导出已确认报告和医学影像的原始文件，并按家庭成员和日期排列。"))
            VStack(alignment: .leading, spacing: 10) {
                warningRow(AppLocalization.string("不包含 OCR、转录、备注、目录或草稿。"))
                warningRow(AppLocalization.string("这是提供给医生查看的副本，不是资料库备份，不能用于恢复续页。"))
                warningRow(AppLocalization.string("导出后文件由您保管；删除续页资料库不会删除已导出的副本。"))
            }
            .foregroundStyle(.secondary)
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
                let totalFiles = AppLocalization.string("\(progress.totalEntryCount) 个文件")
                Text(AppLocalization.string("已处理 \(progress.completedEntryCount) / \(totalFiles)"))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                Text(AppLocalization.string(
                    "\(formattedByteCount(progress.completedByteCount)) / \(formattedByteCount(progress.totalByteCount))"
                ))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var successContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(KinlogueTheme.primary)
                .accessibilityHidden(true)
            Text(AppLocalization.string("原始文件已导出"))
                .font(.title3.weight(.semibold))
            if let result = model.result {
                Text(result.destinationURL.lastPathComponent)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(AppLocalization.string("共 \(result.entryCount) 个文件，\(formattedByteCount(result.totalByteCount))"))
                .foregroundStyle(.secondary)
            }
            Text(AppLocalization.string("压缩包位于续页资料库之外，请妥善保管。"))
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("original-export-close")
                Spacer()
                Button(AppLocalization.string("继续并选择位置…"), action: onChooseDestination)
                    .buttonStyle(.kinloguePrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("original-export-continue")
            case .checking:
                cancelButton
                Spacer()
            case .choosing:
                Spacer()
            case .exporting:
                if model.canCancel {
                    cancelButton
                }
                Spacer()
            case .cancelling:
                Spacer()
            case .cancelled, .empty:
                Button(AppLocalization.string("关闭"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
            case .failed:
                Button(AppLocalization.string("关闭"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(AppLocalization.string("重试…")) {
                    model.begin()
                    onChooseDestination()
                }
                .buttonStyle(.kinloguePrimary)
                .accessibilityIdentifier("original-export-retry")
            case .succeeded:
                if let destinationURL = model.result?.destinationURL {
                    Button(AppLocalization.string("在访达中显示")) {
                        onShowInFinder(destinationURL)
                    }
                    .accessibilityIdentifier("original-export-show-in-finder")
                }
                Spacer()
                Button(AppLocalization.string("完成"), action: onClose)
                    .buttonStyle(.kinloguePrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("original-export-done")
            }
        }
    }

    private var cancelButton: some View {
        Button(AppLocalization.string("取消")) {
            Task { await model.cancel() }
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("original-export-cancel")
    }

    private var isDismissDisabled: Bool {
        switch model.phase {
        case .checking, .choosing, .exporting, .cancelling: true
        case .warning, .cancelled, .empty, .failed, .succeeded: false
        }
    }

    private var progressTitle: String {
        switch model.progress?.phase {
        case .preparing, nil: AppLocalization.string("正在准备导出…")
        case .writing: AppLocalization.string("正在复制原始文件…")
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

    private func formattedByteCount(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}
