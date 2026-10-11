import KinlogueCore
import SwiftUI

struct DICOMStudyDetailView: View {
    let study: DICOMStudySummary
    let memberLabel: String
    let onReview: (DICOMStudy.ID) -> Void
    let onViewImages: (DICOMStudy.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(AppLocalization.string("医学影像检查"), systemImage: "waveform.path.ecg.rectangle")
                .font(.title2.weight(.semibold))
            Text(memberLabel)
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
                    .accessibilityIdentifier("dicom-study-detail-view-images")
                Button(AppLocalization.string("编辑归属与日期")) { onReview(study.id) }
                    .buttonStyle(.kinlogueSecondary)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KinlogueTheme.surface)
    }
}
