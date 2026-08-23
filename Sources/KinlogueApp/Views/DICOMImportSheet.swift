import SwiftUI

struct DICOMImportSheet: View {
    @ObservedObject var model: DICOMImportModel
    let onChooseFolder: () -> Void
    let onComplete: () async -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(AppLocalization.string("导入医学影像"), systemImage: "waveform.path.ecg.rectangle")
                .font(.title2.weight(.semibold))

            Group {
                switch model.phase {
                case .idle, .selecting, .importing:
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(AppLocalization.string("正在本机扫描、复制并验证影像…"))
                        Text(AppLocalization.string("源文件不会被修改；取消时会清理未发布的本机暂存。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .cancelling:
                    ProgressView(AppLocalization.string("正在取消并清理暂存…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .cancelled:
                    ContentUnavailableView(
                        AppLocalization.string("影像导入已取消"),
                        systemImage: "xmark.circle"
                    )
                case .failed:
                    ContentUnavailableView {
                        Label(AppLocalization.string("影像导入未完成"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(model.userErrorMessage ?? AppLocalization.string("影像导入未完成，可以稍后重试"))
                    } actions: {
                        Button(AppLocalization.string("重新选择文件夹…"), action: onChooseFolder)
                    }
                case .succeeded:
                    importSummary
                }
            }
            .frame(minHeight: 220)

            Divider()
            HStack {
                if model.phase == .importing || model.phase == .selecting {
                    Button(AppLocalization.string("取消")) {
                        Task { await model.cancel() }
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("dicom-import-cancel")
                } else if model.phase != .cancelling {
                    Button(AppLocalization.string("关闭"), action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if model.phase == .succeeded {
                    Button(AppLocalization.string("继续")) {
                        Task { await onComplete() }
                    }
                    .buttonStyle(.kinloguePrimary)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dicom-import-continue")
                }
            }
        }
        .padding(28)
        .frame(width: 560, height: 430)
        .interactiveDismissDisabled(model.phase == .importing || model.phase == .cancelling)
    }

    private var importSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                model.result?.wasExisting == true
                    ? AppLocalization.string("这项检查已在医学影像库中")
                    : AppLocalization.string("影像已安全导入本机资料库"),
                systemImage: "checkmark.circle.fill"
            )
            .font(.headline)
            .foregroundStyle(KinlogueTheme.primary)

            DICOMImportCountRow(
                title: AppLocalization.string("可查看影像"),
                value: model.result?.viewableInstanceCount ?? 0
            )
            DICOMImportCountRow(
                title: AppLocalization.string("保留但暂不可查看的对象"),
                value: model.result?.inertObjectCount ?? 0
            )
            DICOMImportCountRow(
                title: AppLocalization.string("忽略的非 DICOM 文件"),
                value: model.result?.ignoredNonDICOMCount ?? 0
            )
            DICOMImportCountRow(
                title: AppLocalization.string("合并的重复对象"),
                value: model.result?.ignoredDuplicateCount ?? 0
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DICOMImportCountRow: View {
    let title: String
    let value: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .font(.body.monospacedDigit().weight(.medium))
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}
