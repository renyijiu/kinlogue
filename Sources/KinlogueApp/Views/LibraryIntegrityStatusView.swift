import SwiftUI

struct LibraryIntegrityStatusView: View {
    @ObservedObject var inspector: AppIntegrityCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(AppLocalization.string("资料库完整性巡检")).font(.headline)
            switch inspector.status {
            case .notInspected:
                Text(AppLocalization.string("尚未巡检"))
            case .waiting:
                Text(AppLocalization.string("尚未巡检，等待空闲时开始"))
            case .inspecting(let count):
                Text(AppLocalization.string("正在巡检"))
                LabeledContent(AppLocalization.string("已检查项目"), value: count.formatted())
            case .incomplete:
                Text(AppLocalization.string("巡检未完成，将在空闲时继续"))
            case .completed(let date, let damaged):
                Text(AppLocalization.string("本次巡检已完成"))
                LabeledContent(AppLocalization.string("完成时间")) { Text(date, format: .dateTime) }
                LabeledContent(AppLocalization.string("已隔离的损坏项目"), value: damaged.formatted())
            case .unavailable:
                Text(AppLocalization.string("完整性检查未通过，资料库操作已停止"))
            }
        }
        .foregroundStyle(KinlogueTheme.onVariant)
        .accessibilityIdentifier("settings-library-integrity")
    }
}
