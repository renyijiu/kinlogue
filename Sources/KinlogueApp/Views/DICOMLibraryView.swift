import KinlogueCore
import SwiftUI

enum DICOMLibraryNavigationStep {
    case previous
    case next
}

enum DICOMLibrarySelectionNavigation {
    static func destination(
        from studyID: DICOMStudy.ID,
        step: DICOMLibraryNavigationStep,
        studyIDs: [DICOMStudy.ID]
    ) -> DICOMStudy.ID? {
        guard let currentIndex = studyIDs.firstIndex(of: studyID) else {
            return nil
        }
        let destinationIndex = switch step {
        case .previous: currentIndex - 1
        case .next: currentIndex + 1
        }
        guard studyIDs.indices.contains(destinationIndex) else { return nil }
        return studyIDs[destinationIndex]
    }
}

struct DICOMLibraryView: View {
    @ObservedObject var model: DICOMLibraryModel
    let selectedMemberID: FamilyMember.ID?
    @State private var hoveredStudyID: DICOMStudy.ID?
    @FocusState private var focusedStudyID: DICOMStudy.ID?

    var body: some View {
        let studies = model.confirmedStudies(memberID: selectedMemberID)
        Group {
            if studies.isEmpty {
                ContentUnavailableView {
                    Label(AppLocalization.string("还没有已确认的医学影像"), systemImage: "waveform.path.ecg.rectangle")
                } description: {
                    Text(AppLocalization.string("导入 DICOM 文件夹并确认家庭成员与检查日期后，会显示在这里。"))
                }
            } else {
                List {
                    ForEach(studies) { study in
                        let isSelected = model.selectedStudyID == study.id
                        Button {
                            if !isSelected {
                                model.select(study.id)
                            }
                            focusedStudyID = study.id
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.memberLabel(for: study))
                                    .font(.headline)
                                    .foregroundStyle(
                                        isSelected
                                            ? KinlogueTheme.selectionForeground
                                            : KinlogueTheme.onSurface
                                    )
                                HStack(spacing: 8) {
                                    if let date = study.effectiveDate {
                                        Text(ReportDateSemantics.formatted(
                                            date,
                                            style: .medium
                                        ))
                                    }
                                    Text(AppLocalization.string("保留 \(study.retainedObjectCount) 个对象"))
                                }
                                .font(.caption)
                                .foregroundStyle(
                                    isSelected
                                        ? KinlogueTheme.selectionForeground
                                        : KinlogueTheme.onVariant
                                )
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($focusedStudyID, equals: study.id)
                        .focusEffectDisabled()
                        .background(studyRowBackground(for: study.id))
                        .overlay(studyRowFocusOverlay(for: study.id))
                        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityHint(AppLocalization.string("选择后可查看检查摘要"))
                        .onHover { isHovering in
                            updateHoveredStudy(study.id, isHovering: isHovering)
                        }
                        .onMoveCommand { direction in
                            moveStudySelection(
                                from: study.id,
                                in: studies,
                                direction: direction
                            )
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(KinlogueTheme.surface)
        .navigationTitle(AppLocalization.string("医学影像"))
    }

    private func studyRowBackground(for studyID: DICOMStudy.ID) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(
                model.selectedStudyID == studyID
                    ? KinlogueTheme.selection
                    : hoveredStudyID == studyID
                        ? KinlogueTheme.selectionHover
                        : .clear
            )
    }

    private func studyRowFocusOverlay(for studyID: DICOMStudy.ID) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(
                focusedStudyID == studyID
                    ? KinlogueTheme.primary
                    : .clear,
                lineWidth: 2
            )
    }

    private func updateHoveredStudy(
        _ studyID: DICOMStudy.ID,
        isHovering: Bool
    ) {
        if isHovering {
            hoveredStudyID = studyID
        } else if hoveredStudyID == studyID {
            hoveredStudyID = nil
        }
    }

    private func moveStudySelection(
        from studyID: DICOMStudy.ID,
        in studies: [DICOMStudySummary],
        direction: MoveCommandDirection
    ) {
        let step: DICOMLibraryNavigationStep
        switch direction {
        case .up: step = .previous
        case .down: step = .next
        default: return
        }
        guard let nextStudyID = DICOMLibrarySelectionNavigation.destination(
            from: studyID,
            step: step,
            studyIDs: studies.map(\.id)
        ) else { return }
        model.select(nextStudyID)
        focusedStudyID = nextStudyID
    }
}

struct DICOMLibraryDetailContainer: View {
    @ObservedObject var model: DICOMLibraryModel
    let onReview: (DICOMStudy.ID) -> Void
    let onViewImages: (DICOMStudy.ID) -> Void

    var body: some View {
        let selectedStudy = model.selectedStudy
        DICOMLibraryDetailView(
            study: selectedStudy,
            memberLabel: selectedStudy.map { model.memberLabel(for: $0) },
            onReview: onReview,
            onViewImages: onViewImages
        )
    }
}

struct DICOMLibraryDetailView: View {
    let study: DICOMStudySummary?
    let memberLabel: String?
    let onReview: (DICOMStudy.ID) -> Void
    let onViewImages: (DICOMStudy.ID) -> Void

    var body: some View {
        Group {
            if let study {
                VStack(alignment: .leading, spacing: 18) {
                    Label(AppLocalization.string("医学影像检查"), systemImage: "waveform.path.ecg.rectangle")
                        .font(.title2.weight(.semibold))
                    Text(memberLabel ?? AppLocalization.string("家庭成员"))
                        .font(.headline)
                    if let date = study.effectiveDate {
                        Text(ReportDateSemantics.formatted(
                            date,
                            style: .long
                        ))
                    }
                    Text(AppLocalization.string("只显示受支持的本机二维 MR 切片；影像不会进入 OCR、搜索或比较。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(AppLocalization.string("查看影像")) { onViewImages(study.id) }
                            .buttonStyle(.kinloguePrimary)
                            .accessibilityIdentifier("dicom-library-view-images")
                        Button(AppLocalization.string("编辑归属与日期")) { onReview(study.id) }
                            .buttonStyle(.kinlogueSecondary)
                    }
                    Spacer()
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(
                    AppLocalization.string("选择一项医学影像检查"),
                    systemImage: "waveform.path.ecg.rectangle"
                )
            }
        }
        .background(KinlogueTheme.surface)
    }
}
