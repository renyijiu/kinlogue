import KinlogueCore
import SwiftUI

struct DICOMStudyReviewContainer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject var model: DICOMStudyReviewModel
    let onOpenViewer: @MainActor (DICOMStudy.ID) -> Void

    var body: some View {
        DICOMStudyReviewView(
            model: model,
            onViewImages: {
                guard let studyID = model.content?.study.id else { return }
                onOpenViewer(studyID)
            },
            onDismiss: { dismiss() }
        )
        .task { await model.load() }
        .onDisappear { model.clear() }
        .interactiveDismissDisabled(!model.allowsDismissal)
    }
}

struct DICOMStudyReviewView: View {
    @ObservedObject var model: DICOMStudyReviewModel
    let onViewImages: () -> Void
    let onDismiss: () -> Void

    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalization.string("确认医学影像检查"))
                        .font(.title2.weight(.semibold))
                    Text(AppLocalization.string("只确认归属成员与检查日期；续页不会从影像推断诊断或结论。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            Divider()

            Group {
                switch model.phase {
                case .idle, .loading:
                    ProgressView(AppLocalization.string("正在读取本机影像索引…"))
                case .failed where model.content == nil:
                    ContentUnavailableView(
                        AppLocalization.string("无法读取这项影像检查"),
                        systemImage: "exclamationmark.triangle"
                    )
                default:
                    reviewForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                if model.content == nil {
                    Spacer()
                    Button(AppLocalization.string("关闭"), action: onDismiss)
                        .disabled(isBusy || !model.allowsDismissal)
                } else {
                    if (model.content?.viewableInstanceCount ?? 0) > 0 {
                        Button(AppLocalization.string("查看影像"), action: onViewImages)
                            .buttonStyle(.kinlogueSecondary)
                            .disabled(isBusy)
                            .accessibilityIdentifier("dicom-review-view-images")
                    }
                    Button(AppLocalization.string("删除这项影像检查…"), role: .destructive) {
                        isDeleteConfirmationPresented = true
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("dicom-review-delete")
                    Spacer()
                    if model.operationFailed {
                        Text(AppLocalization.string("操作未完成，可以稍后重试"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if model.content?.study.state == .confirmed {
                        Button(AppLocalization.string("取消"), action: onDismiss)
                            .disabled(isBusy)
                    }
                    Button(AppLocalization.string("确认并加入医学影像库")) {
                        Task {
                            if await model.save() { onDismiss() }
                        }
                    }
                    .buttonStyle(.kinloguePrimary)
                    .disabled(isBusy)
                    .accessibilityIdentifier("dicom-review-save")
                }
            }
            .padding(20)
        }
        .frame(width: 600, height: 540)
        .confirmationDialog(
            AppLocalization.string("删除这项医学影像检查？"),
            isPresented: $isDeleteConfirmationPresented
        ) {
            Button(AppLocalization.string("从续页删除影像检查"), role: .destructive) {
                Task {
                    if await model.deleteStudy() { onDismiss() }
                }
            }
            Button(AppLocalization.string("保留"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("检查索引和不再共享的本机 DICOM 原件会被删除；最初选择的源文件夹不会被修改。"))
        }
    }

    private var reviewForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let content = model.content {
                    let selectionLabels = RecordQuery.selectionLabels(
                        for: content.selectableMembers
                    )
                    GroupBox(AppLocalization.string("检查内容")) {
                        VStack(spacing: 10) {
                            DICOMReviewCountRow(
                                title: AppLocalization.string("可查看影像"),
                                value: content.viewableInstanceCount
                            )
                            DICOMReviewCountRow(
                                title: AppLocalization.string("影像序列"),
                                value: content.seriesCount
                            )
                            DICOMReviewCountRow(
                                title: AppLocalization.string("保留但暂不可查看的对象"),
                                value: content.inertObjectCount
                            )
                        }
                        .padding(.top, 6)
                    }

                    Picker(AppLocalization.string("家庭成员"), selection: $model.selectedMemberID) {
                        Text(AppLocalization.string("请选择")).tag(Optional<FamilyMember.ID>.none)
                        ForEach(content.selectableMembers) { member in
                            Text(selectionLabels[member.id] ?? member.displayName)
                                .tag(Optional(member.id))
                        }
                    }
                    .accessibilityHint(AppLocalization.string("必须由你明确选择，影像内容不会自动决定归属"))

                    LocalizedDatePicker(
                        AppLocalization.string("检查日期"),
                        selection: $model.effectiveDate
                    )
                    .accessibilityHint(AppLocalization.string("请选择报告或影像资料中可核实的检查日期"))

                    if model.hasValidationError {
                        Text(AppLocalization.string("请先选择有效的家庭成员和检查日期"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(24)
        }
    }

    private var isBusy: Bool {
        model.phase == .saving || model.phase == .deleting || model.phase == .loading
    }
}

private struct DICOMReviewCountRow: View {
    let title: String
    let value: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)").monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
