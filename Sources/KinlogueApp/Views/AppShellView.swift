import AppKit
import KinlogueCore
import SwiftUI
import UniformTypeIdentifiers

struct AppShellView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var model: AppModel
    @ObservedObject private var deletionModel: VaultDeletionModel
    @ObservedObject private var lanInboxModel: LANInboxModel
    @ObservedObject private var backupModel: BackupModel
    @ObservedObject private var restoreModel: RestoreModel
    private let startupCoordinator: AppStartupCoordinator
    @State private var selectedSidebarSection = AppSidebarSection.records
    @State private var hasCompletedStartup = false
    @Binding private var selectedLanguage: AppLanguage
    @AppStorage("hasAcknowledgedPlaintextStorageDisclosure")
    private var hasAcknowledgedStorageDisclosure = false
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isSettingsExportFocused: Bool

    init(
        model: AppModel,
        deletionModel: VaultDeletionModel,
        lanInboxModel: LANInboxModel,
        backupModel: BackupModel,
        restoreModel: RestoreModel,
        startupCoordinator: AppStartupCoordinator,
        selectedLanguage: Binding<AppLanguage>
    ) {
        self.model = model
        self.deletionModel = deletionModel
        self.lanInboxModel = lanInboxModel
        self.backupModel = backupModel
        self.restoreModel = restoreModel
        self.startupCoordinator = startupCoordinator
        _selectedLanguage = selectedLanguage
    }

    var body: some View {
        Group {
            if hasAcknowledgedStorageDisclosure {
                appContent
            } else {
                storageDisclosure
            }
        }
        .background(KinlogueTheme.surface)
        .toolbarBackground(KinlogueTheme.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .tint(KinlogueTheme.primary)
        .preferredColorScheme(.light)
        .background(PrimaryWindowReader { window in
            lanInboxModel.configurePrimaryWindow(window)
        })
        .task(id: hasAcknowledgedStorageDisclosure) {
            guard hasAcknowledgedStorageDisclosure else { return }
            hasCompletedStartup = await startupCoordinator.start()
        }
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: [.pdf, .jpeg, .png, .heic, .tiff],
            allowsMultipleSelection: true
        ) { result in
            Task { await model.handleImporterResult(result) }
        }
        .fileImporter(
            isPresented: $model.isDICOMFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            Task { await model.handleDICOMImporterResult(result) }
        }
        .sheet(isPresented: Binding(
            get: {
                backupModel.phase == .enrollmentPending
                    && backupModel.recoveryCode != nil
            },
            set: { presented in
                if !presented { backupModel.cancelSetup() }
            }
        )) {
            BackupSetupView(model: backupModel)
        }
        .sheet(isPresented: Binding(
            get: { backupModel.isPendingEnrollmentRecoveryPresented },
            set: { presented in
                if !presented { backupModel.cancelPendingEnrollmentRecovery() }
            }
        )) {
            PendingBackupEnrollmentView(model: backupModel)
        }
        .sheet(isPresented: Binding(
            get: { restoreModel.isPresented },
            set: { presented in
                if !presented { Task { await restoreModel.cancel() } }
            }
        )) {
            RestoreBackupView(model: restoreModel)
        }
        .sheet(isPresented: $model.isDICOMImportPresented, onDismiss: {
            model.dicomImportPresentationDidEnd()
        }) {
            DICOMImportSheet(
                model: model.dicomImportModel,
                onChooseFolder: { model.retryDICOMImportSelection() },
                onComplete: {
                    let destination = await model.finishDICOMImport()
                    if destination?.destination == .library {
                        selectedSidebarSection = .imaging
                    }
                },
                onClose: {
                    model.isDICOMImportPresented = false
                    model.dicomImportModel.clear()
                }
            )
        }
        .sheet(item: $model.reviewingDraft, onDismiss: {
            model.presentationDidEnd()
            Task { await model.refresh() }
        }) { presentation in
            ImportReviewContainer(model: model.makeReviewModel(draftID: presentation.id))
        }
        .sheet(item: $model.reviewingDICOMStudy, onDismiss: {
            model.dicomReviewPresentationDidEnd()
            Task { await model.refresh() }
        }) { presentation in
            DICOMStudyReviewContainer(
                model: model.makeDICOMStudyReviewModel(studyID: presentation.id),
                onOpenViewer: openDICOMViewer
            )
        }
        .sheet(isPresented: $model.isMemberEditorPresented, onDismiss: {
            model.presentationDidEnd()
        }) {
            MemberEditorView(existing: nil) { name, label in
                await model.saveMember(existing: nil, displayName: name, disambiguationLabel: label)
            }
        }
        .sheet(item: $model.editingMember, onDismiss: {
            model.presentationDidEnd()
        }) { member in
            MemberEditorView(existing: member) { name, label in
                await model.saveMember(existing: member, displayName: name, disambiguationLabel: label)
            }
        }
        .sheet(item: $model.editingRecord, onDismiss: {
            model.presentationDidEnd()
            Task { await model.refresh() }
        }) { record in
            RecordEditView(
                record: record,
                members: model.members,
                original: model.originalDocument,
                isOriginalLoading: model.isOriginalLoading,
                selectedOriginalSourceID: model.selectedOriginalSourceID,
                onSelectOriginalSource: { sourceID in
                    Task { await model.selectOriginalSource(sourceID) }
                }
            ) { command in
                await model.updateRecord(command)
            }
        }
        .sheet(item: $model.viewingOriginal, onDismiss: {
            model.presentationDidEnd()
        }) { _ in
            if let sources = model.originalSources {
                OrderedOriginalDocumentViewer(
                    sources: sources,
                    selectedSourceID: model.selectedOriginalSourceID,
                    payload: model.originalDocument,
                    isLoading: model.isOriginalLoading,
                    onSelectSource: { sourceID in
                        Task { await model.selectOriginalSource(sourceID) }
                    }
                )
            }
        }
        .sheet(isPresented: $model.isOriginalExportPresented, onDismiss: {
            model.originalExportModel.clear()
            model.presentationDidEnd()
            isSettingsExportFocused = true
        }) {
            OriginalExportView(
                model: model.originalExportModel,
                onChooseDestination: chooseOriginalExportDestination,
                onClose: closeOriginalExport,
                onShowInFinder: { destinationURL in
                    NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
                }
            )
        }
        .sheet(isPresented: $model.isVaultDeletionPresented, onDismiss: {
            model.presentationDidEnd()
        }) {
            DeleteVaultView(model: deletionModel)
        }
        .sheet(isPresented: $lanInboxModel.isReceiverSheetPresented) {
            LANReceiverSheet(model: lanInboxModel)
        }
        .modifier(ComparisonSheetModifier(
            model: model.comparisonModel,
            memberLabels: RecordQuery.selectionLabels(for: model.members),
            onDismiss: { model.presentationDidEnd() }
        ))
        .alert(item: Binding(
            get: { model.banner },
            set: { if $0 == nil { model.dismissBanner() } }
        )) { banner in
            Alert(title: Text(banner.message), dismissButton: .default(Text(AppLocalization.string("好"))))
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinloguePresentImporter)) { _ in
            presentImporterIfAvailable()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinlogueFocusSearch)) { _ in
            model.requestSearchFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinlogueToggleComparison)) { _ in
            guard model.phase == .ready else { return }
            if model.comparisonModel.isPresented {
                model.comparisonModel.closeComparison()
            } else {
                model.toggleComparisonSelection()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard hasCompletedStartup else { return }
            Task { await backupModel.handleAppEvent(.activation) }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            guard hasCompletedStartup else { return }
            Task { await backupModel.handleAppEvent(.wake) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            backupModel.cancelForApplicationTermination()
        }
        .onChange(of: model.searchFocusRequestID) { isSearchFocused = true }
        .onChange(of: deletionModel.phase) { _, phase in
            switch phase {
            case .deleted:
                model.isVaultDeletionPresented = false
            default:
                break
            }
        }
        .onExitCommand {
            if model.reviewingDICOMStudy != nil {
                model.dismissDICOMReviewIfAllowed()
            } else if model.isDICOMImportPresented {
                model.isDICOMImportPresented = false
                model.dicomImportModel.clear()
            } else if model.viewingOriginal != nil {
                model.viewingOriginal = nil
            } else if model.comparisonModel.isPresented {
                model.comparisonModel.closeComparison()
            } else if model.comparisonModel.isSelecting {
                model.comparisonModel.cancelSelection()
            }
        }
    }

    @ViewBuilder
    private var appContent: some View {
        switch model.phase {
        case .loading:
            ProgressView(AppLocalization.string("正在打开本机资料库…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .locked:
            lockedState
        case .failed:
            failedState
        case .ready:
            appNavigation
        case .changingVault:
            ProgressView(AppLocalization.string("正在更新本机资料库…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .restartRequired:
            restartRequiredState
        case .vaultDeleted:
            vaultDeletedState
        }
    }

    private var storageDisclosure: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(AppLocalization.string("本机资料存储说明"), systemImage: "externaldrive")
                .font(.title2.bold())
            Text(AppLocalization.string("续页只在这台 Mac 上处理资料。默认保存在本机；只有在你明确启用数据备份后，续页才会将加密恢复点写入你选择的目录。该目录是否被网盘客户端上传由对应客户端决定。只有在你主动开启“手机上传”时，才会临时接收同一局域网内浏览器发送的资料。活动资料库不提供应用层加密：报告和医学影像原件、成员资料及 OCR 结果以可读取的本地文件保存。能够访问此 Mac 用户资料的人员或软件，以及包含资料库的 Time Machine 备份、APFS 快照或其他副本，可能读取这些内容。"))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(AppLocalization.string("退出")) {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.kinlogueSecondary)
                Spacer()
                Button(AppLocalization.string("我了解，继续")) {
                    hasAcknowledgedStorageDisclosure = true
                }
                .buttonStyle(.kinloguePrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 620)
    }

    private var appNavigation: some View {
        Group {
            if selectedSidebarSection == .settings {
                settingsNavigation
            } else {
                recordsNavigation
            }
        }
        .confirmationDialog(
            AppLocalization.string("放弃这份失败的导入？"),
            isPresented: Binding(
                get: { model.pendingDiscardDraftID != nil },
                set: {
                    if !$0 {
                        model.pendingDiscardDraftID = nil
                        model.presentationDidEnd()
                    }
                }
            )
        ) {
            if let id = model.pendingDiscardDraftID {
                Button(AppLocalization.string("放弃并删除本机草稿"), role: .destructive) {
                    Task { await model.confirmDiscardDraft(id: id) }
                }
            }
            Button(AppLocalization.string("保留"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("源文件不会被删除；续页中的失败草稿会被移除。"))
        }
        .confirmationDialog(
            AppLocalization.string("删除这条记录？"),
            isPresented: Binding(
                get: { model.pendingDeleteRecordID != nil },
                set: {
                    if !$0 {
                        model.pendingDeleteRecordID = nil
                        model.presentationDidEnd()
                    }
                }
            )
        ) {
            if let id = model.pendingDeleteRecordID {
                Button(AppLocalization.string("从续页删除"), role: .destructive) {
                    Task { await model.confirmDeleteRecord(id: id) }
                }
            }
            Button(AppLocalization.string("保留"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("记录及其不再共享的原件将无法在续页中查看；最初选择的源文件不会被删除。"))
        }
        .confirmationDialog(
            AppLocalization.string("删除家庭成员？"),
            isPresented: Binding(
                get: { model.pendingDeleteMemberID != nil },
                set: {
                    if !$0 {
                        model.pendingDeleteMemberID = nil
                        model.presentationDidEnd()
                    }
                }
            )
        ) {
            if let id = model.pendingDeleteMemberID {
                Button(AppLocalization.string("删除家庭成员"), role: .destructive) {
                    Task { await model.confirmDeleteMember(id: id) }
                }
            }
            Button(AppLocalization.string("保留"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("只有没有关联记录或草稿时才能删除；否则请先重分配或逐条删除关联内容。"))
        }
    }

    private var settingsNavigation: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            SettingsView(
                selectedLanguage: $selectedLanguage,
                backupModel: backupModel,
                exportButtonFocus: $isSettingsExportFocused,
                onChooseBackupDirectory: chooseBackupDirectory,
                onRestoreBackup: restoreModel.present,
                onExportOriginals: model.presentOriginalExport,
                onDeleteVault: model.presentVaultDeletion
            )
        }
    }

    private func chooseOriginalExportDestination() {
        Task { @MainActor in
            let undatedToken = AppLocalization.string("未注明日期")
            guard await model.originalExportModel.prepareForDestination(
                undatedToken: undatedToken
            ) else { return }

            let panel = NSSavePanel()
            panel.allowedContentTypes = [.zip]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = AppLocalization.string("续页原始文件.zip")
            panel.title = AppLocalization.string("导出全部原始文件")
            panel.prompt = AppLocalization.string("导出")
            guard panel.runModal() == .OK, let destinationURL = panel.url else {
                model.originalExportModel.destinationSelectionCancelled()
                return
            }
            await model.originalExportModel.export(
                to: destinationURL,
                undatedToken: undatedToken
            )
        }
    }

    private func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = AppLocalization.string("选择数据备份目录")
        panel.prompt = AppLocalization.string("选择")
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        Task { await backupModel.beginSetup(selectedParent: selectedURL) }
    }

    private func closeOriginalExport() {
        model.isOriginalExportPresented = false
    }

    private var recordsNavigation: some View {
        NavigationSplitView {
            sidebar
        } content: {
            Group {
                if selectedSidebarSection == .lanInbox {
                    LANInboxView(
                        model: lanInboxModel,
                        members: model.members,
                        onOpenDuplicate: openDuplicateDestination
                    )
                } else if selectedSidebarSection == .imaging {
                    DICOMLibraryView(
                        model: model.dicomLibraryModel,
                        selectedMemberID: model.selectedMemberID
                    )
                } else {
                    VStack(spacing: 0) {
                        SearchFieldView(text: $model.searchText, isFocused: $isSearchFocused)
                        ComparisonSelectionBar(
                            model: model.comparisonModel,
                            onCompare: { Task { await model.openComparison() } }
                        )
                        Divider()
                        TimelineView(
                            comparisonModel: model.comparisonModel,
                            sections: model.timelineSections,
                            searchResults: model.searchResults,
                            isSearching: !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            selectedRecordID: model.selectedRecordID,
                            memberLabel: model.memberLabel(for:),
                            dicomMemberLabel: model.dicomLibraryModel.memberLabel(for:),
                            onSelect: { id in Task { await model.selectRecord(id) } },
                            onSelectDICOM: { id in
                                model.dicomLibraryModel.select(id)
                                selectedSidebarSection = .imaging
                            },
                            onImport: { presentImporterIfAvailable() }
                        )
                    }
                    .background(KinlogueTheme.surface)
                    .navigationTitle(model.selectedMemberID.flatMap { id in
                        RecordQuery.selectionLabels(for: model.members)[id]
                    } ?? AppLocalization.string("家庭时间线"))
                }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 520)
        } detail: {
            if selectedSidebarSection == .lanInbox {
                LANPendingSelectionDetailView(model: lanInboxModel)
            } else if selectedSidebarSection == .imaging {
                DICOMLibraryDetailContainer(
                    model: model.dicomLibraryModel,
                    onReview: { model.presentDICOMReview($0) },
                    onViewImages: openDICOMViewer
                )
            } else {
                RecordDetailView(
                    record: model.selectedRecord,
                    memberLabel: model.selectedRecord.map(model.memberLabel(for:)),
                    original: model.originalDocument,
                    isOriginalLoading: model.isOriginalLoading,
                    originalSources: model.originalSources,
                    selectedOriginalSourceID: model.selectedOriginalSourceID,
                    onSelectOriginalSource: { sourceID in
                        Task { await model.selectOriginalSource(sourceID) }
                    },
                    onOpenOriginal: { model.presentOriginalViewer() },
                    onEdit: { model.presentRecordEditor() },
                    onDelete: {
                        if let record = model.selectedRecord {
                            model.requestDeleteRecord(record)
                        }
                    }
                )
                .background(KinlogueTheme.surface)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.requestSearchFocus()
                } label: {
                    Label(AppLocalization.string("搜索"), systemImage: "magnifyingglass")
                }
                .help(AppLocalization.string("搜索已确认的记录"))
                Button {
                    presentImporterIfAvailable()
                } label: {
                    Label(AppLocalization.string("导入报告"), systemImage: "square.and.arrow.down")
                }
                .help(AppLocalization.string("导入报告"))
                Button {
                    model.presentDICOMImport()
                } label: {
                    Label(AppLocalization.string("导入医学影像"), systemImage: "waveform.path.ecg.rectangle")
                }
                .help(AppLocalization.string("导入医学影像"))
                ComparisonToolbarItem(
                    model: model.comparisonModel,
                    onToggle: { model.toggleComparisonSelection() }
                )
                Button {
                    if lanInboxModel.receiverPhase == .active {
                        lanInboxModel.isReceiverSheetPresented = true
                    } else {
                        Task { await lanInboxModel.prepareReceiving() }
                    }
                } label: {
                    Label(
                        lanInboxModel.receiverPhase == .active ? AppLocalization.string("手机接收中") : AppLocalization.string("手机上传"),
                        systemImage: lanInboxModel.receiverPhase == .active
                            ? "dot.radiowaves.left.and.right"
                            : "iphone.and.arrow.forward.inward"
                    )
                }
                .help(
                    lanInboxModel.receiverPhase == .active
                        ? AppLocalization.string("查看手机接收状态")
                        : AppLocalization.string("从手机接收资料")
                )
            }
        }
    }

    private var sidebar: some View {
        MemberSidebarView(
            members: model.members,
            selectedMemberID: $model.selectedMemberID,
            selectedSection: $selectedSidebarSection,
            lanInboxItemCount: lanInboxModel.items.count,
            isLANReceiverActive: lanInboxModel.receiverPhase == .active,
            dicomReviewStudies: model.dicomLibraryModel.reviewStudies,
            reviewQueue: model.reviewQueue,
            backgroundDrafts: model.backgroundDrafts,
            busyDraftIDs: model.busyDraftIDs,
            onAdd: { presentNewMemberEditorIfAvailable() },
            onOpenDraft: { presentReviewIfAvailable($0) },
            onRetryDraft: { id in Task { await model.retryDraft(id) } },
            onDiscardDraft: { model.requestDiscardDraft($0) },
            onOpenDICOMStudy: { model.presentDICOMReview($0) },
            onEdit: { presentMemberEditorIfAvailable($0) },
            onDelete: { model.requestDeleteMember($0) }
        )
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
    }

    private var hasBlockingPresentation: Bool {
        model.hasBlockingPresentation
    }

    private func presentImporterIfAvailable() {
        model.presentImporter()
    }

    private func presentReviewIfAvailable(_ id: ImportDraft.ID) {
        model.presentReviewDraft(id)
    }

    private func presentNewMemberEditorIfAvailable() {
        model.presentNewMemberEditor()
    }

    private func presentMemberEditorIfAvailable(_ member: FamilyMember) {
        model.presentMemberEditor(member)
    }

    private func openDICOMViewer(_ studyID: DICOMStudy.ID) {
        guard let studyID = model.dicomViewerStudyID(for: studyID) else { return }
        openWindow(id: DICOMViewerWindowScene.id, value: studyID)
    }

    private func openDuplicateDestination(_ destination: LANReportDuplicateDestination) {
        switch destination.kind {
        case .importDraft:
            selectedSidebarSection = .records
            model.presentReviewDraft(destination.id)
        case .healthRecord:
            selectedSidebarSection = .records
            Task { await model.selectRecord(destination.id) }
        }
    }

    private var lockedState: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("无法读取本机资料库"), systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(AppLocalization.string("续页不会覆盖无法识别的内容。若这里是旧版加密资料库，当前简化版不会自动迁移；请保留原目录，等待后续迁移工具。"))
        } actions: {
            Button(AppLocalization.string("从数据备份恢复…")) {
                restoreModel.present()
            }
        }
    }

    private var failedState: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("无法打开资料库"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(AppLocalization.string("本次操作未继续。请重新启动或稍后重试，应用会恢复到完整状态。"))
        } actions: {
            Button(AppLocalization.string("重试")) {
                Task { hasCompletedStartup = await startupCoordinator.start() }
            }
            Button(AppLocalization.string("从数据备份恢复…")) {
                restoreModel.present()
            }
        }
    }

    private var restartRequiredState: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("需要重新启动续页"), systemImage: "arrow.clockwise.circle")
        } description: {
            Text(AppLocalization.string("资料库删除结果尚未确认。请退出并重新打开续页后检查；原资料可能仍保留在磁盘上。"))
        }
    }

    private var vaultDeletedState: some View {
        ContentUnavailableView {
            Label(AppLocalization.string("本机资料库已删除"), systemImage: "checkmark.circle")
        } description: {
            Text(AppLocalization.string("请退出续页。Time Machine、APFS 快照和外部副本不会被此操作删除。"))
        }
    }
}

private struct PrimaryWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowReportingView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowReportingView)?.onWindow = onWindow
    }

    private final class WindowReportingView: NSView {
        var onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}

private struct ComparisonSheetModifier: ViewModifier {
    @ObservedObject var model: ComparisonModel
    let memberLabels: [FamilyMember.ID: String]
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { model.isPresented },
            set: { if !$0 { model.closeComparison() } }
        ), onDismiss: onDismiss) {
            ComparisonView(model: model, memberLabels: memberLabels)
        }
    }
}
