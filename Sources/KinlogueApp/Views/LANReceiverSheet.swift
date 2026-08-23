import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import KinloguePlatform
import SwiftUI

struct LANReceiverSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: LANInboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(AppLocalization.string("从手机接收资料"), systemImage: "iphone.and.arrow.forward.inward")
                    .font(.title2.bold())
                Spacer()
                if model.receiverPhase == .active {
                    Label(AppLocalization.string("正在接收"), systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(KinlogueTheme.primary)
                        .accessibilityLabel(AppLocalization.string("局域网接收已开启"))
                }
            }

            if let details = model.receiverDetails, model.receiverPhase == .active {
                activeContent(details)
            } else {
                startContent
            }

            if let error = model.userErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityLabel(AppLocalization.string("错误：\(error)"))
            }

            Divider()
            HStack {
                Button(AppLocalization.string("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.receiverPhase == .active {
                    Button(AppLocalization.string("停止接收"), role: .destructive) {
                        Task { await model.stopReceiving() }
                    }
                    .accessibilityHint(AppLocalization.string("立即使地址和验证码失效，已完成上传的待确认项会保留"))
                } else {
                    Button(AppLocalization.string("开始接收")) {
                        Task { await model.startReceiving() }
                    }
                    .buttonStyle(.kinloguePrimary)
                    .disabled(
                        model.selectedAddress == nil
                            || !model.hasAcknowledgedPrivateNetwork
                            || model.receiverPhase != .inactive
                    )
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(26)
        .frame(width: 620)
        .background(KinlogueTheme.card)
        .interactiveDismissDisabled(model.receiverPhase == .starting || model.receiverPhase == .stopping)
        .accessibilityIdentifier("lan-receiver-sheet")
    }

    private var startContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                AppLocalization.string("只在可信任的私人 Wi-Fi 或有线局域网中使用"),
                systemImage: "lock.trianglebadge.exclamationmark"
            )
                .font(.headline)
            Text(AppLocalization.string("手机与这台 Mac 之间使用普通局域网 HTTP 连接，不能保证传输加密。请勿在公共、访客或不信任的网络中开启。"))
                .fixedSize(horizontal: false, vertical: true)

            if model.availableAddresses.count > 1 {
                Picker(AppLocalization.string("这台 Mac 的地址"), selection: $model.selectedAddress) {
                    Text(AppLocalization.string("请选择…")).tag(nil as LANNetworkAddress?)
                    ForEach(model.availableAddresses, id: \.self) { address in
                        Text("\(address.host) · \(address.interfaceName)")
                            .tag(Optional(address))
                    }
                }
            } else if let address = model.availableAddresses.first {
                LabeledContent(AppLocalization.string("这台 Mac 的地址")) {
                    Text("\(address.host) · \(address.interfaceName)")
                        .textSelection(.enabled)
                }
            }

            Toggle(
                AppLocalization.string("我确认当前是可信任的私人局域网"),
                isOn: $model.hasAcknowledgedPrivateNetwork
            )
            .disabled(model.selectedAddress == nil)
        }
        .padding(16)
        .background(KinlogueTheme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(KinlogueTheme.outline, lineWidth: 1)
        }
    }

    private func activeContent(_ details: LANReceiverDetails) -> some View {
        HStack(alignment: .top, spacing: 22) {
            QRCodeView(value: details.url.absoluteString)
                .frame(width: 190, height: 190)
                .accessibilityLabel(AppLocalization.string("局域网上传地址二维码，不包含验证码"))

            VStack(alignment: .leading, spacing: 14) {
                Text(AppLocalization.string("在同一局域网内，用手机浏览器打开："))
                    .foregroundStyle(.secondary)
                Text(details.url.absoluteString)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Button(AppLocalization.string("复制地址")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(details.url.absoluteString, forType: .string)
                }
                .buttonStyle(.kinlogueSecondary)
                .accessibilityHint(AppLocalization.string("只复制地址，不复制验证码"))

                Divider()
                Text(AppLocalization.string("验证码"))
                    .foregroundStyle(.secondary)
                Text(details.pairingCode)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .accessibilityLabel(AppLocalization.string("验证码 \(details.pairingCode.map(String.init).joined(separator: " "))"))
                Text(AppLocalization.string("验证码约 \(details.pairingExpiresInSeconds / 60) 分钟内有效，首次验证成功后即失效。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(AppLocalization.string("若手机无法打开，请确认两台设备没有使用访客网络隔离，并检查 macOS 防火墙是否允许续页接收入站连接。"))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct QRCodeView: View {
    let value: String

    var body: some View {
        if let image = Self.image(for: value) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            ContentUnavailableView(AppLocalization.string("二维码不可用"), systemImage: "qrcode")
        }
    }

    private static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let cgImage = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(
                output,
                from: output.extent
              ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
