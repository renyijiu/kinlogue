import SwiftUI

struct DeleteVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: VaultDeletionModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(AppLocalization.string("永久删除本机资料库")) {
                    Label(AppLocalization.string("此操作不可撤销"), systemImage: "exclamationmark.octagon.fill")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Text(AppLocalization.string("将删除续页当前资料库中的家庭成员、健康记录和本地原件。"))
                    Text(AppLocalization.string("Time Machine 备份、APFS 快照以及其他外部副本不会受影响，也不会被此操作删除。"))
                        .foregroundStyle(.secondary)

                    Text(AppLocalization.string("如需继续，请准确输入："))
                        .fontWeight(.medium)
                    Text(VaultDeletionModel.confirmationPhrase)
                        .font(.system(.body, design: .monospaced))
                    TextField(AppLocalization.string("确认短语"), text: $model.confirmationInput)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.phase == .deleting)

                    if model.phase == .deleting {
                        ProgressView(AppLocalization.string("正在删除本机资料库…"))
                    } else if model.phase == .deleted {
                        Label(AppLocalization.string("本机资料库已删除"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(AppLocalization.string("请退出续页。系统快照与外部副本仍需在各自位置单独管理。"))
                            .foregroundStyle(.secondary)
                    } else {
                        Button(AppLocalization.string("永久删除本机资料库"), role: .destructive) {
                            Task { await model.deleteCurrentVault() }
                        }
                        .disabled(!model.canDeleteVault)
                    }

                    if let errorMessage = model.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(AppLocalization.string("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.phase == .deleting)
                    .accessibilityIdentifier("vault-delete-cancel")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 360)
        .navigationTitle(AppLocalization.string("删除资料库"))
        .interactiveDismissDisabled(model.phase == .deleting)
        .onDisappear { model.confirmationInput = "" }
    }
}
