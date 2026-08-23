import Foundation
import Testing

struct LANInboxViewSafetyTests {
    @Test
    func receiverQRCodeContainsOnlyTheAddressAndEverySheetHasExplicitExitControls() throws {
        let source = try read("Sources/KinlogueApp/Views/LANReceiverSheet.swift")

        #expect(source.contains("QRCodeView(value: details.url.absoluteString)"))
        #expect(!source.contains("QRCodeView(value: details.pairingCode"))
        #expect(source.contains(#"Button(AppLocalization.string("关闭"))"#))
        #expect(source.contains(
            #"Button(AppLocalization.string("停止接收"), role: .destructive)"#
        ))
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
        #expect(source.contains("普通局域网 HTTP 连接"))
    }

    @Test
    func unsupportedRowsCannotReachAnyRendererOrSystemPreviewSurface() throws {
        let row = try read("Sources/KinlogueApp/Views/LANInboxItemRow.swift")
        let workflow = try read("Sources/KinloguePlatform/LAN/LANPendingQueueWorkflow.swift")

        #expect(row.contains("if item.isReviewable"))
        #expect(workflow.contains("item.isReviewable else"))
        for forbidden in ["QuickLook", "QLPreview", "WKWebView", "NSWorkspace.shared.open"] {
            #expect(!row.contains(forbidden))
            #expect(!workflow.contains(forbidden))
        }
    }

    @Test
    func pendingItemActionsExposeLabelsAndDestructiveConfirmation() throws {
        let row = try read("Sources/KinlogueApp/Views/LANInboxItemRow.swift")
        let inbox = try read("Sources/KinlogueApp/Views/LANInboxView.swift")

        #expect(row.components(separatedBy: ".accessibilityLabel(").count >= 4)
        #expect(inbox.contains(".confirmationDialog("))
        #expect(inbox.contains(
            #"Button(AppLocalization.string("取消"), role: .cancel)"#
        ))
        #expect(inbox.contains(
            "if let command = model.pendingDeleteCommand"
        ))
        #expect(inbox.contains(
            "model.confirmDeleteItems(command)"
        ))
        #expect(inbox.contains("作为 1 份报告加入待确认"))
        #expect(inbox.contains("没有待确认项"))
        #expect(inbox.contains("处理完后队列会恢复为空"))
    }

    @Test
    func queueActionsAdaptBeforeLabelsOrButtonsAreCompressed() throws {
        let inbox = try read("Sources/KinlogueApp/Views/LANInboxView.swift")
        let shell = try read("Sources/KinlogueApp/Views/AppShellView.swift")

        #expect(inbox.contains("ViewThatFits(in: .horizontal)"))
        #expect(inbox.contains(".fixedSize(horizontal: true, vertical: false)"))
        #expect(shell.contains(
            ".navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 520)"
        ))
    }

    @Test
    func macOwnsSelectionReportOrderMemberAndDate() throws {
        let inbox = try read("Sources/KinlogueApp/Views/LANInboxView.swift")
        let detail = try read(
            "Sources/KinlogueApp/Views/LANPendingSelectionDetailView.swift"
        )

        #expect(inbox.contains("List(model.items, selection: $model.selectedItemIDs)"))
        #expect(inbox.contains("selectionDisabled(!item.isReviewable)"))
        #expect(inbox.contains("selection: $model.selectedMemberID"))
        #expect(inbox.contains("selection: $model.canonicalReportDate"))
        #expect(detail.contains("model.moveArchiveItem"))
        #expect(detail.contains("arrow.up"))
        #expect(detail.contains("arrow.down"))
        #expect(detail.contains("报告页序"))
        for obsolete in ["LANInbox" + "Batch", "批" + "次", "ba" + "tch"] {
            #expect(!inbox.localizedCaseInsensitiveContains(obsolete))
            #expect(!detail.localizedCaseInsensitiveContains(obsolete))
        }
    }

    @Test
    func reportOrderDetailProvidesAnInlinePreviewForTheSelectedSource() throws {
        let detail = try read(
            "Sources/KinlogueApp/Views/LANPendingSelectionDetailView.swift"
        )
        let model = try read("Sources/KinlogueApp/ViewModels/LANInboxModel.swift")

        #expect(detail.contains("private var previewItem: LANInboxItem?"))
        #expect(detail.contains("OriginalDocumentFitPreview("))
        #expect(detail.contains(".task(id: previewItem?.id)"))
        #expect(detail.contains(".id(item.id)"))
        #expect(detail.contains("previewItemID == item.id"))
        #expect(model.contains("func loadPreviewPayload(itemID: LANInboxItem.ID)"))
        #expect(model.contains("func presentPreview("))
        #expect(detail.contains("payload: loadedPreview.payload"))
    }

    private func read(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
