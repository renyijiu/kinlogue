import KinlogueCore
import SwiftUI

struct LANInboxItemRow: View {
    let item: LANInboxItem
    let isBusy: Bool
    let onPreview: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let localizedStateLabel = stateLabel

        HStack(spacing: 12) {
            Image(systemName: stateIcon)
                .foregroundStyle(stateColor)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName.rawValue)
                    .lineLimit(2)
                    .foregroundStyle(KinlogueTheme.onSurface)
                HStack(spacing: 8) {
                    Text(localizedStateLabel)
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(item.contentIdentity.byteCount),
                        countStyle: .file
                    ))
                    Text(item.receivedAt, format: .dateTime.month().day().hour().minute())
                }
                .font(.caption)
                .foregroundStyle(KinlogueTheme.onVariant)
            }
            Spacer()
            if item.isReviewable {
                Button(action: onPreview) {
                    Image(systemName: "eye")
                        .foregroundStyle(KinlogueTheme.primary)
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .accessibilityLabel(AppLocalization.string("查看 \(item.displayName.rawValue) 原件"))
            }
            if canRetry {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(KinlogueTheme.primary)
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .accessibilityLabel(AppLocalization.string("重试处理 \(item.displayName.rawValue)"))
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .disabled(isBusy)
            .accessibilityLabel(AppLocalization.string("删除待确认项 \(item.displayName.rawValue)"))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("\(item.displayName.rawValue)，\(localizedStateLabel)"))
    }

    private var stateLabel: String {
        switch item.state {
        case .stored: AppLocalization.string("等待识别")
        case .preprocessing: AppLocalization.string("正在本机识别")
        case .reviewable: AppLocalization.string("可选择并归档")
        case .unsupported: AppLocalization.string("不支持预览，原件仍保留")
        case .failed: AppLocalization.string("处理失败，可重试")
        case .integrityFailed: AppLocalization.string("完整性校验失败")
        }
    }

    private var canRetry: Bool {
        switch item.state {
        case .stored, .failed, .unsupported: true
        case .preprocessing, .reviewable, .integrityFailed: false
        }
    }

    private var stateIcon: String {
        switch item.state {
        case .stored, .preprocessing: "text.viewfinder"
        case .reviewable: "checkmark.circle"
        case .unsupported: "nosign"
        case .failed, .integrityFailed: "exclamationmark.triangle"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .reviewable: KinlogueTheme.primary
        case .failed, .integrityFailed: .red
        case .unsupported: .orange
        default: .secondary
        }
    }
}
