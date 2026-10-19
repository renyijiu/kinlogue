import SwiftUI
import KinlogueCore

struct SettingsView: View {
    private static let controlColumnWidth: CGFloat = 220

    @Binding var selectedLanguage: AppLanguage
    @ObservedObject var backupModel: BackupModel
    let exportButtonFocus: FocusState<Bool>.Binding
    let onChooseBackupFolder: () -> Void
    let onRestoreBackup: () -> Void
    let onExportBackup: () -> Void
    let onDeleteVault: () -> Void
    var integrityCoordinator: AppIntegrityCoordinator? = nil

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
                    Label(AppLocalization.string("数据备份与导出"), systemImage: "externaldrive.badge.timemachine")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(KinlogueTheme.primary)

                    backupCard

                    settingsCard {
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(AppLocalization.string("导出备份"))
                                    .font(.headline)
                                    .foregroundStyle(KinlogueTheme.onSurface)
                                Text(AppLocalization.string("把同样的备份压缩包保存到任意位置。它不计入保留数量，续页之后也不会管理它。"))
                                    .foregroundStyle(KinlogueTheme.onVariant)
                            }

                            Spacer(minLength: 24)

                            Button(AppLocalization.string("导出备份到…")) {
                                onExportBackup()
                            }
                            .buttonStyle(.kinlogueSecondary)
                            .focused(exportButtonFocus)
                            .fixedSize()
                            .frame(width: Self.controlColumnWidth, alignment: .trailing)
                            .accessibilityIdentifier("settings-export-backup")
                        }
                    }

                    settingsCard {
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(AppLocalization.string("从备份恢复"))
                                    .font(.headline)
                                    .foregroundStyle(KinlogueTheme.onSurface)
                                Text(AppLocalization.string("选择一个续页备份压缩包，完整验证后替换当前资料库。"))
                                    .foregroundStyle(KinlogueTheme.onVariant)
                            }

                            Spacer(minLength: 24)

                            Button(AppLocalization.string("从备份恢复…"), action: onRestoreBackup)
                                .buttonStyle(.kinlogueSecondary)
                                .fixedSize()
                                .frame(width: Self.controlColumnWidth, alignment: .trailing)
                                .accessibilityIdentifier("backup-restore")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label(AppLocalization.string("数据管理"), systemImage: "externaldrive")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(KinlogueTheme.primary)

                    if let integrityCoordinator {
                        settingsCard { LibraryIntegrityStatusView(inspector: integrityCoordinator) }
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
                            .buttonStyle(.kinlogueDestructive)
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
    }

    @ViewBuilder
    private var backupCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(AppLocalization.string("备份到文件夹"))
                            .font(.headline)
                            .foregroundStyle(KinlogueTheme.onSurface)
                        Text(AppLocalization.string("续页把完整资料库写成 ZIP 压缩包，保存在你选择的文件夹里。文件夹可以在外置盘、NAS 上，也可以由阿里云盘、百度网盘等客户端同步。"))
                            .foregroundStyle(KinlogueTheme.onVariant)
                    }
                    Spacer(minLength: 24)
                    if !backupModel.status.isFolderConfigured {
                        Button(AppLocalization.string("选择备份文件夹…"), action: onChooseBackupFolder)
                            .buttonStyle(.kinloguePrimary)
                            .fixedSize()
                            .frame(width: Self.controlColumnWidth, alignment: .trailing)
                            .accessibilityIdentifier("backup-choose-folder")
                    }
                }

                KinlogueWarningNotice(
                    AppLocalization.string("备份文件不加密，包含全部健康资料。放在网盘同步文件夹里，网盘服务商和能登录该账号的人都能读取。")
                )

                if backupModel.status.isFolderConfigured {
                    configuredBackupControls
                } else {
                    Text(AppLocalization.string("自动备份默认关闭。选择文件夹后可以立即备份，或打开自动备份。"))
                        .foregroundStyle(KinlogueTheme.onVariant)
                }

                if let failure = backupModel.failureText {
                    KinlogueStatusLabel(failure, tone: .danger)
                        .accessibilityIdentifier("backup-status-error")
                }
            }
        }
    }

    private var configuredBackupControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(AppLocalization.string("备份文件夹")) {
                Text(backupModel.status.folderName ?? AppLocalization.string("文件夹当前不可用"))
            }
            if let lastBackupAt = backupModel.status.lastBackupAt {
                LabeledContent(AppLocalization.string("最近一次备份")) {
                    Text(lastBackupAt, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                }
            }
            LabeledContent(AppLocalization.string("本机写入并管理的备份")) {
                Text(String(backupModel.status.managedBackupCount))
                    .monospacedDigit()
            }
            HStack(spacing: 12) {
                Spacer()
                Button(AppLocalization.string("更改文件夹…"), action: onChooseBackupFolder)
                    .accessibilityIdentifier("backup-change-folder")
                Button(AppLocalization.string("在访达中显示")) {
                    Task { await backupModel.showFolder() }
                }
                .accessibilityIdentifier("backup-show-in-finder")
            }
            .buttonStyle(.kinlogueSecondary)

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
            Text(AppLocalization.string("续页运行时，资料变化后自动备份，每天最多一次。"))
                .font(.caption)
                .foregroundStyle(KinlogueTheme.onVariant)

            HStack {
                Text(AppLocalization.string("保留最近的备份份数"))
                Spacer()
                Picker(
                    AppLocalization.string("保留最近的备份份数"),
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
            Text(AppLocalization.string("超出份数时，续页只删除自己写入、之后没有被改名、移动或修改的备份；文件夹里的其他文件不会被删除。"))
                .font(.caption)
                .foregroundStyle(KinlogueTheme.onVariant)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await backupModel.backUpNow() }
            } label: {
                if backupModel.phase == .backingUp {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(AppLocalization.string("正在创建备份…"))
                    }
                } else {
                    Text(AppLocalization.string("立即备份"))
                }
            }
            .buttonStyle(.kinlogueSecondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(backupModel.phase == .backingUp)
            .accessibilityIdentifier("backup-now")

            if let completion = backupModel.completionText {
                KinlogueStatusLabel(completion, tone: .success)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityIdentifier("backup-status-complete")
            }
            if let deferred = backupModel.cleanupDeferredText {
                KinlogueStatusLabel(deferred, tone: .warning)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .disabled(backupModel.isManualBackupInFlight)
    }

    private func settingsCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(22)
            .kinloguePanel(.card)
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
