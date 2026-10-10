import SwiftUI

/// Shows that a report import or retry is still recognizing text. Nothing else
/// in the window changes while recognition runs, so without it a slow first
/// recognition looks as if the import never started.
struct ReportRecognitionStatusView: View {
    let activity: ReportRecognitionActivity
    let isSlow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(KinlogueTheme.onVariant)
            }
            if isSlow {
                SlowRecognitionNotice()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("report-recognition-status")
    }

    private var title: String {
        activity.total > 1
            ? AppLocalization.string("正在识别报告（第 \(activity.position)/\(activity.total) 个）…")
            : AppLocalization.string("正在识别报告…")
    }
}

struct SlowRecognitionNotice: View {
    var body: some View {
        Text(AppLocalization.string("识别仍在进行。系统首次识别需要准备识别模型，可能要等半分钟左右，之后会快很多；页数多的文件也需要更久。"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
