import SwiftUI

struct DeleteVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: VaultDeletionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(AppLocalization.string("永久删除本机资料库"))
                .font(.title2.bold())
            KinlogueStatusLabel(AppLocalization.string("此操作不可撤销"), tone: .danger)
                .font(.headline)

            Text(AppLocalization.string("将删除续页当前资料库中的家庭成员、健康记录和本地原件。"))
                .fixedSize(horizontal: false, vertical: true)
            Text(AppLocalization.string("Time Machine 备份、APFS 快照以及其他外部副本不会受影响，也不会被此操作删除。"))
                .foregroundStyle(KinlogueTheme.onVariant)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.string("如需继续，请准确输入："))
                    .fontWeight(.medium)
                Text(VaultDeletionModel.confirmationPhrase)
                    .font(.system(.body, design: .monospaced))
                TextField(AppLocalization.string("确认短语"), text: $model.confirmationInput)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.phase == .deleting)
            }

            if model.phase == .deleting {
                ProgressView(AppLocalization.string("正在删除本机资料库…"))
            } else if model.phase == .deleted {
                KinlogueStatusLabel(AppLocalization.string("本机资料库已删除"), tone: .success)
                Text(AppLocalization.string("请退出续页。系统快照与外部副本仍需在各自位置单独管理。"))
                    .foregroundStyle(KinlogueTheme.onVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = model.errorMessage {
                KinlogueStatusLabel(errorMessage, tone: .danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
            Divider()

            HStack {
                Button(AppLocalization.string("取消")) { dismiss() }
                    .buttonStyle(.kinlogueSecondary)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.phase == .deleting)
                    .accessibilityIdentifier("vault-delete-cancel")
                Spacer()
                if model.phase != .deleting, model.phase != .deleted {
                    Button(AppLocalization.string("永久删除本机资料库"), role: .destructive) {
                        Task { await model.deleteCurrentVault() }
                    }
                    .buttonStyle(.kinlogueDestructive)
                    .disabled(!model.canDeleteVault)
                }
            }
        }
        .padding(28)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 360)
        .kinlogueSheetCanvas()
        .navigationTitle(AppLocalization.string("删除资料库"))
        .interactiveDismissDisabled(model.phase == .deleting)
        .onDisappear { model.confirmationInput = "" }
    }
}
