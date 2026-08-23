import SwiftUI
import KinlogueCore

struct SettingsView: View {
    private static let controlColumnWidth: CGFloat = 220

    @Binding var selectedLanguage: AppLanguage
    @ObservedObject var backupModel: BackupModel
    let exportButtonFocus: FocusState<Bool>.Binding
    let onChooseBackupDirectory: () -> Void
    let onRestoreBackup: () -> Void
    let onExportOriginals: () -> Void
    let onDeleteVault: () -> Void
    @State private var isAbandonPendingBackupConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.string("设置"))
                        .font(.largeTitle.bold())
                        .foregroundStyle(KinlogueTheme.onSurface)
                    Text(AppLocalization.string("管理续页的显示语言和本机数据。"))
                        .font(.title3)
                        .foregroundStyle(KinlogueTheme.onVariant)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label(AppLocalization.string("通用"), systemImage: "slider.horizontal.3")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(KinlogueTheme.primary)

                    settingsCard {
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(AppLocalization.string("语言"))
                                    .font(.headline)
                                    .foregroundStyle(KinlogueTheme.onSurface)
                                Text(AppLocalization.string("选择界面语言"))
                                    .foregroundStyle(KinlogueTheme.onVariant)
                            }

                            Spacer(minLength: 24)

                            Picker(
                                AppLocalization.string("选择界面语言"),
                                selection: $selectedLanguage
                            ) {
                                ForEach(AppLanguage.allCases) { language in
                                    Text(displayName(for: language)).tag(language)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                            .frame(width: Self.controlColumnWidth, alignment: .trailing)
                            .accessibilityIdentifier("settings-language-picker")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label(AppLocalization.string("数据备份"), systemImage: "externaldrive.badge.timemachine")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(KinlogueTheme.primary)

                    backupCard
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label(AppLocalization.string("数据管理"), systemImage: "externaldrive")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(KinlogueTheme.primary)

                    settingsCard {
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(AppLocalization.string("导出全部原始文件"))
                                    .font(.headline)
                                    .foregroundStyle(KinlogueTheme.onSurface)
                                Text(AppLocalization.string("将已确认报告和医学影像的原始文件按家庭成员与日期整理为一个 ZIP 压缩包。"))
                                    .foregroundStyle(KinlogueTheme.onVariant)
                                Text(AppLocalization.string("导出内容为未加密副本，不包含 OCR、备注或草稿。"))
                                    .foregroundStyle(KinlogueTheme.onVariant)
                            }

                            Spacer(minLength: 24)

                            Button(AppLocalization.string("导出原始文件…")) {
                                onExportOriginals()
                            }
                            .focused(exportButtonFocus)
                            .fixedSize()
                            .frame(width: Self.controlColumnWidth, alignment: .trailing)
                            .accessibilityIdentifier("settings-export-originals")
                        }
                    }

                    settingsCard {
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(AppLocalization.string("删除本机数据"))
                                    .font(.headline)
                                    .foregroundStyle(KinlogueTheme.onSurface)
                                Text(AppLocalization.string("将删除续页当前资料库中的家庭成员、健康记录和本地原件。"))
                                    .foregroundStyle(KinlogueTheme.onVariant)
                                Text(AppLocalization.string("此操作不可撤销"))
                                    .foregroundStyle(KinlogueTheme.onVariant)
                            }

                            Spacer(minLength: 24)

                            Button(AppLocalization.string("删除本机数据…"), role: .destructive) {
                                onDeleteVault()
                            }
                            .tint(.red)
                            .foregroundStyle(.red)
                            .fixedSize()
                            .frame(width: Self.controlColumnWidth, alignment: .trailing)
                            .accessibilityIdentifier("settings-delete-local-data")
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(KinlogueTheme.surface)
        .navigationTitle(AppLocalization.string("设置"))
        .accessibilityIdentifier("settings-view")
        .alert(
            AppLocalization.string("放弃未完成的备份设置？"),
            isPresented: $isAbandonPendingBackupConfirmationPresented
        ) {
            Button(AppLocalization.string("取消"), role: .cancel) {}
            Button(AppLocalization.string("放弃并重新配置"), role: .destructive) {
                Task { await backupModel.abandonPendingEnrollment() }
            }
        } message: {
            Text(AppLocalization.string("这会移除本机保存的未完成备份身份。已有外部文件不会被删除；之后可以选择目录并生成新的恢复码。"))
        }
    }

    @ViewBuilder
    private var backupCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(AppLocalization.string("加密目录备份"))
                            .font(.headline)
                            .foregroundStyle(KinlogueTheme.onSurface)
                        Text(AppLocalization.string("续页会把加密恢复点写入你选择的具体目录。该目录可以由阿里云盘、百度网盘或其他桌面客户端同步。"))
                            .foregroundStyle(KinlogueTheme.onVariant)
                        Text(AppLocalization.string("续页只能验证所选目录里的本地恢复点，无法证明网盘客户端已经上传。"))
                            .foregroundStyle(KinlogueTheme.onVariant)
                    }
                    Spacer(minLength: 24)
                    if backupModel.status.enrollment == .notConfigured {
                        Button(AppLocalization.string("选择备份目录…"), action: onChooseBackupDirectory)
                            .fixedSize()
                            .frame(width: Self.controlColumnWidth, alignment: .trailing)
                            .accessibilityIdentifier("backup-choose-directory")
                    }
                }

                switch backupModel.status.enrollment {
                case .notConfigured:
                    Text(AppLocalization.string("自动备份默认关闭。设置时会生成一份必须独立保存的恢复码。"))
                        .foregroundStyle(KinlogueTheme.onVariant)
                case .pending:
                    Label(
                        AppLocalization.string("备份设置尚未完成。若你仍保存原恢复码，可以继续完成；续页不会生成新的恢复码。"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    HStack(spacing: 12) {
                        Button(AppLocalization.string("放弃未完成的设置…"), role: .destructive) {
                            isAbandonPendingBackupConfirmationPresented = true
                        }
                        .disabled(backupModel.isPendingEnrollmentOperation)
                        .accessibilityIdentifier("backup-abandon-pending-enrollment")
                        Spacer()
                        Button(AppLocalization.string("继续未完成的备份设置…")) {
                            backupModel.presentPendingEnrollmentRecovery()
                        }
                        .disabled(backupModel.isPendingEnrollmentOperation)
                        .accessibilityIdentifier("backup-resume-pending-enrollment")
                    }
                case .ready:
                    configuredBackupControls
                }

                Divider()
                Button(AppLocalization.string("从恢复点恢复…"), action: onRestoreBackup)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("backup-restore")

                if let failure = backupModel.failureText {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("backup-status-error")
                }
            }
        }
    }

    private var configuredBackupControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(AppLocalization.string("所选目录")) {
                Text(backupModel.status.destinationDisplayName ?? AppLocalization.string("目录当前不可用"))
            }
            LabeledContent(AppLocalization.string("本地恢复点")) {
                Text(backupModel.localCheckpointText)
            }
            LabeledContent(AppLocalization.string("网盘状态")) {
                Text(backupModel.cloudStatusText)
            }

            if let verifiedAt = backupModel.status.lastLocalVerificationAt {
                LabeledContent(AppLocalization.string("最近本地验证")) {
                    Text(verifiedAt, style: .relative)
                }
            }
            if let estimate = backupModel.status.estimate {
                LabeledContent(AppLocalization.string("单个恢复点估算")) {
                    Text(byteCount(estimate.singleCheckpointBytes))
                }
                LabeledContent(AppLocalization.string("保留空间估算")) {
                    Text(byteCount(estimate.retainedBytes))
                }
                LabeledContent(AppLocalization.string("临时空间估算")) {
                    Text(byteCount(estimate.temporaryBytes))
                }
            }

            Divider()

            Toggle(
                AppLocalization.string("自动备份"),
                isOn: Binding(
                    get: { backupModel.isAutomaticBackupEnabled },
                    set: { enabled in
                        Task { await backupModel.setAutomaticBackupEnabled(enabled) }
                    }
                )
            )
            .accessibilityIdentifier("backup-automatic-toggle")

            HStack {
                Text(AppLocalization.string("保留的恢复点数量"))
                Spacer()
                Picker(
                    AppLocalization.string("保留的恢复点数量"),
                    selection: Binding(
                        get: { backupModel.retentionCount },
                        set: { count in Task { await backupModel.setRetentionCount(count) } }
                    )
                ) {
                    ForEach(BackupRetentionCount.allowedRange, id: \.self) { count in
                        Text(String(count)).tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                .accessibilityIdentifier("backup-retention-picker")
            }

            HStack(spacing: 12) {
                Button {
                    Task { await backupModel.backUpNow() }
                } label: {
                    if backupModel.phase == .backingUp {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(AppLocalization.string("正在准备加密备份…"))
                        }
                    } else {
                        Text(AppLocalization.string("立即备份"))
                    }
                }
                .accessibilityLabel(AppLocalization.string("立即创建加密恢复点"))
                .accessibilityIdentifier("backup-now")

                Button(AppLocalization.string("在访达中显示")) {
                    Task { await backupModel.showBackupRepository() }
                }
                .accessibilityIdentifier("backup-show-in-finder")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(backupModel.phase == .backingUp)
        }
    }

    private func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(22)
            .background(KinlogueTheme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(KinlogueTheme.outline, lineWidth: 1)
            }
    }

    private func displayName(for language: AppLanguage) -> String {
        switch language {
        case .system:
            AppLocalization.string("跟随系统")
        case .simplifiedChinese:
            "简体中文"
        case .english:
            "English"
        }
    }
}
