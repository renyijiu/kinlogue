import Foundation
import Testing

struct ImportReviewViewSafetyTests {
    @Test
    func reviewCannotDismissWithoutChoosingAPersistenceAction() throws {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains(".interactiveDismissDisabled(!model.loadFailed)"))
        #expect(source.contains("\"import-review-close\""))
        #expect(source.contains("\"import-review-defer\""))
        #expect(source.contains("\"import-review-confirm\""))
        #expect(source.contains("\"import-review-discard\""))
    }

    @Test
    func embeddedOriginalSurfacesUseInlinePresentationWhileViewersStayDedicated() throws {
        let importReview = try source(named: "ImportReviewView.swift")
        let comparison = try source(named: "ComparisonOriginalPane.swift")
        let recordDetail = try source(named: "RecordDetailView.swift")
        let lanSelection = try source(named: "LANPendingSelectionDetailView.swift")
        let originalDocument = try source(named: "OriginalDocumentView.swift")

        #expect(importReview.contains("presentation: .inline"))
        #expect(comparison.contains("presentation: .inline"))
        #expect(recordDetail.contains("presentation: .inline"))
        #expect(recordDetail.contains("OriginalDocumentFitPreview("))
        #expect(lanSelection.contains("OriginalDocumentFitPreview("))
        #expect(originalDocument.contains("enum OriginalDocumentPresentation"))
        #expect(originalDocument.contains("case inline"))
        #expect(originalDocument.contains("case viewer"))
        #expect(originalDocument.contains("presentation: .viewer"))
    }

    private func source(named filename: String) throws -> String {
        try String(
            contentsOf: repositoryURL
                .appendingPathComponent("Sources/KinlogueApp/Views")
                .appendingPathComponent(filename),
            encoding: .utf8
        )
    }

    private var sourceURL: URL {
        repositoryURL
            .appendingPathComponent("Sources/KinlogueApp/Views/ImportReviewView.swift")
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

struct DeleteVaultViewSafetyTests {
    @Test
    func destructiveSheetHasAnExplicitCancelPathThatLocksDuringDeletion() throws {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("Button(AppLocalization.string(\"取消\"))"))
        #expect(source.contains("\"vault-delete-cancel\""))
        #expect(source.contains(".interactiveDismissDisabled(model.phase == .deleting)"))
        #expect(source.contains(".disabled(model.phase == .deleting)"))
    }

    @Test
    func dataExportAndWholeLibraryDeletionAreSeparateSettingsActions() throws {
        let appShell = try String(contentsOf: appShellURL, encoding: .utf8)
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)

        #expect(!appShell.contains("删除本机资料库…"))
        #expect(!appShell.contains("删除本机数据…"))
        #expect(appShell.components(separatedBy: "model.presentVaultDeletion").count == 2)
        #expect(appShell.contains("onDeleteVault: model.presentVaultDeletion"))
        #expect(appShell.contains("onExportOriginals: model.presentOriginalExport"))
        #expect(appShell.contains("NSSavePanel()"))
        #expect(appShell.contains("panel.allowedContentTypes = [.zip]"))
        #expect(settings.contains("Button(AppLocalization.string(\"删除本机数据…\"), role: .destructive)"))
        #expect(settings.contains("Button(AppLocalization.string(\"导出原始文件…\"))"))
        #expect(settings.contains("onExportOriginals()"))
        #expect(settings.contains("onDeleteVault()"))
        let backupButtonStart = try #require(settings.range(
            of: "Button(AppLocalization.string(\"选择备份目录…\"), action: onChooseBackupDirectory)"
        ))
        let backupButtonEnd = try #require(settings.range(
            of: ".accessibilityIdentifier(\"backup-choose-directory\")",
            range: backupButtonStart.lowerBound..<settings.endIndex
        ))
        let backupButton = settings[backupButtonStart.lowerBound..<backupButtonEnd.upperBound]
        #expect(backupButton.contains(".fixedSize()"))
        #expect(backupButton.contains(
            ".frame(width: Self.controlColumnWidth, alignment: .trailing)"
        ))
        #expect(settings.components(
            separatedBy: ".frame(width: Self.controlColumnWidth, alignment: .trailing)"
        ).count == 5)
        let manualActionsStart = try #require(settings.range(of: "HStack(spacing: 12)"))
        let manualActionsEnd = try #require(settings.range(
            of: ".disabled(backupModel.phase == .backingUp)",
            range: manualActionsStart.lowerBound..<settings.endIndex
        ))
        let manualActions = settings[
            manualActionsStart.lowerBound..<manualActionsEnd.upperBound
        ]
        #expect(manualActions.contains(
            ".frame(maxWidth: .infinity, alignment: .trailing)"
        ))
        let restoreButtonStart = try #require(settings.range(
            of: "Button(AppLocalization.string(\"从恢复点恢复…\"), action: onRestoreBackup)"
        ))
        let restoreButtonEnd = try #require(settings.range(
            of: ".accessibilityIdentifier(\"backup-restore\")",
            range: restoreButtonStart.lowerBound..<settings.endIndex
        ))
        let restoreButton = settings[
            restoreButtonStart.lowerBound..<restoreButtonEnd.upperBound
        ]
        #expect(restoreButton.contains(
            ".frame(maxWidth: .infinity, alignment: .trailing)"
        ))
        #expect(settings.contains(".tint(.red)"))
        #expect(settings.contains(".foregroundStyle(.red)"))
        #expect(settings.contains("\"settings-export-originals\""))
        #expect(settings.contains(".focused(exportButtonFocus)"))
        #expect(settings.contains("\"settings-delete-local-data\""))
        #expect(settings.contains("\"backup-show-in-finder\""))
        #expect(settings.contains("AppLocalization.string(\"正在准备加密备份…\")"))
    }

    private var sourceURL: URL {
        repositoryURL
            .appendingPathComponent("Sources/KinlogueApp/Views/DeleteVaultView.swift")
    }

    private var appShellURL: URL {
        repositoryURL
            .appendingPathComponent("Sources/KinlogueApp/Views/AppShellView.swift")
    }

    private var settingsURL: URL {
        repositoryURL
            .appendingPathComponent("Sources/KinlogueApp/Views/SettingsView.swift")
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

struct OriginalExportViewSafetyTests {
    @Test
    func warningPrecedesSelectionAndActiveExportCannotBeDismissed() throws {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("case .warning:"))
        #expect(source.contains("导出的压缩包包含未加密的健康资料"))
        #expect(source.contains("不是资料库备份"))
        #expect(source.contains("删除续页资料库不会删除已导出的副本"))
        #expect(source.contains(".interactiveDismissDisabled(isDismissDisabled)"))
        #expect(source.contains("case .checking, .choosing, .exporting, .cancelling: true"))
        #expect(source.contains("case .checking:\n                cancelButton"))
        #expect(source.contains("\"original-export-cancel\""))
        #expect(source.contains("\"original-export-show-in-finder\""))

        let shell = try String(contentsOf: appShellSourceURL, encoding: .utf8)
        #expect(shell.contains("@FocusState private var isSettingsExportFocused"))
        #expect(shell.contains("isSettingsExportFocused = true"))
    }

    private var sourceURL: URL {
        repositoryURL
            .appendingPathComponent("Sources/KinlogueApp/Views/OriginalExportView.swift")
    }

    private var appShellSourceURL: URL {
        repositoryURL
            .appendingPathComponent("Sources/KinlogueApp/Views/AppShellView.swift")
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

struct AppShellPresentationSafetyTests {
    @Test
    func appShellReceivesItsModelsWithoutBuildingProductionServices() throws {
        let appShell = try String(contentsOf: appShellURL, encoding: .utf8)

        #expect(!appShell.contains("AppComposition.makeDefault()"))
        #expect(appShell.contains("@ObservedObject private var model: AppModel"))
        #expect(appShell.contains("init(\n        model: AppModel,"))
    }

    @Test
    func modalWorkflowsUseStablePresentationOwners() throws {
        let source = try String(contentsOf: appShellURL, encoding: .utf8)
        let backupAndRestore = try String(contentsOf: backupAndRestoreURL, encoding: .utf8)

        #expect(source.contains(".sheet(item: $model.reviewingDraft"))
        #expect(source.contains(".sheet(item: $model.editingRecord"))
        #expect(!source.contains(".sheet(isPresented: $model.isRecordEditorPresented"))
        #expect(!source.contains("if let draftID = model.reviewDraftID"))
        #expect(!source.contains("isPresented: $restoreModel.isFileImporterPresented"))
        let restoreViewStart = try #require(backupAndRestore.range(
            of: "struct RestoreBackupView: View {"
        ))
        let restoreView = backupAndRestore[restoreViewStart.lowerBound...]
        let setupView = backupAndRestore[..<restoreViewStart.lowerBound]
        #expect(restoreView.contains("isPresented: $model.isFileImporterPresented"))
        #expect(restoreView.contains("UTType(filenameExtension: \"kinloguebackup\")"))
        #expect(restoreView.contains("Task { await model.prepare(checkpointURL) }"))
        #expect(!setupView.contains("isPresented: $model.isFileImporterPresented"))
    }

    @Test
    func pendingBackupEnrollmentOffersResumeAndConfirmedAbandonment() throws {
        let appShell = try String(contentsOf: appShellURL, encoding: .utf8)
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)
        let backupAndRestore = try String(contentsOf: backupAndRestoreURL, encoding: .utf8)

        #expect(appShell.contains("PendingBackupEnrollmentView(model: backupModel)"))
        #expect(settings.contains("backup-resume-pending-enrollment"))
        #expect(settings.contains("backup-abandon-pending-enrollment"))
        #expect(settings.contains("Button(AppLocalization.string(\"放弃并重新配置\"), role: .destructive)"))
        #expect(settings.contains("await backupModel.abandonPendingEnrollment()"))
        #expect(!settings.contains("try? await"))
        #expect(backupAndRestore.contains("SecureField("))
        #expect(backupAndRestore.contains("backup-pending-recovery-code"))
        #expect(backupAndRestore.contains("backup-pending-resume"))
        #expect(backupAndRestore.contains("model.cancelPendingEnrollmentRecovery()"))
    }

    @Test
    func restoreActivationFailureOffersOnlyTheTerminalQuitAction() throws {
        let source = try String(contentsOf: backupAndRestoreURL, encoding: .utf8)
        let failureStart = try #require(source.range(of: "case .failed(.activation):"))
        let genericFailureStart = try #require(source.range(
            of: "case .failed:",
            range: failureStart.upperBound..<source.endIndex
        ))
        let terminalFailure = source[failureStart.lowerBound..<genericFailureStart.lowerBound]

        #expect(terminalFailure.contains("restore-failure-quit"))
        #expect(terminalFailure.contains("NSApplication.shared.terminate(nil)"))
        #expect(!terminalFailure.contains("当前资料库不会因验证失败而被替换"))
    }

    @Test
    func comparisonSheetUsesTheRootViewInsteadOfAZeroSizedPresentationHost() throws {
        let appShell = try String(contentsOf: appShellURL, encoding: .utf8)
        let comparison = try String(contentsOf: comparisonURL, encoding: .utf8)

        #expect(appShell.contains("private struct ComparisonSheetModifier: ViewModifier"))
        #expect(appShell.contains("@ObservedObject var model: ComparisonModel"))
        #expect(appShell.contains("model: model.comparisonModel"))
        #expect(!appShell.contains("_comparisonModel ="))
        #expect(!appShell.contains("ComparisonPresentationHost"))
        #expect(!comparison.contains("ComparisonPresentationHost"))
        #expect(!comparison.contains(".frame(width: 0, height: 0)"))
    }

    private var appShellURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/AppShellView.swift")
    }

    private var backupAndRestoreURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/BackupAndRestoreView.swift")
    }

    private var settingsURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/SettingsView.swift")
    }

    private var comparisonURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/ComparisonView.swift")
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

struct EditorFailurePresentationSafetyTests {
    @Test
    func saveFailuresRenderInsideTheirExistingSheets() throws {
        let memberEditor = try String(contentsOf: memberSidebarURL, encoding: .utf8)
        let recordEditor = try String(contentsOf: recordEditURL, encoding: .utf8)

        #expect(memberEditor.contains("无法添加家庭成员，请稍后再试。"))
        #expect(memberEditor.contains("无法保存家庭成员，请稍后再试。"))
        #expect(recordEditor.contains("无法保存这条记录，请稍后再试。"))
        #expect(memberEditor.contains("accessibilityLabel(AppLocalization.string(\"错误：\\(errorMessage)\"))"))
        #expect(recordEditor.contains("accessibilityLabel(AppLocalization.string(\"错误：\\(errorMessage)\"))"))
    }

    private var memberSidebarURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/MemberSidebarView.swift")
    }

    private var recordEditURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/RecordEditView.swift")
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
