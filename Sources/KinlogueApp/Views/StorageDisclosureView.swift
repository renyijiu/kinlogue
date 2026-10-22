import AppKit
import SwiftUI

struct StorageDisclosureView: View {
    let onAcknowledge: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(AppLocalization.string("本机资料存储说明"), systemImage: "externaldrive")
                .font(.title2.bold())
            Text(AppLocalization.string("续页只在这台 Mac 上处理资料。默认保存在本机；只有在你选择备份文件夹或导出备份时，续页才会把未加密的备份压缩包写到你选择的位置，该位置是否被网盘客户端上传由对应客户端决定。只有在你主动开启“手机上传”时，才会临时接收同一局域网内浏览器发送的资料。资料库和备份都不提供应用层加密：报告和医学影像原件、成员资料及 OCR 结果以可读取的文件保存。能够访问此 Mac 用户资料或备份文件的人员或软件，以及包含资料库的 Time Machine 备份、APFS 快照或其他副本，可能读取这些内容。"))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(AppLocalization.string("退出")) {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.kinlogueSecondary)
                Spacer()
                Button(AppLocalization.string("我了解，继续")) {
                    onAcknowledge()
                }
                .buttonStyle(.kinloguePrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 620)
    }

}
