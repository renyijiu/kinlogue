import Foundation
import Testing

struct KinlogueThemeSourceTests {
    @Test
    func warmSanctuaryPaletteHasOneSwiftSourceOfTruth() throws {
        let theme = try read("Sources/KinlogueApp/Views/KinlogueTheme.swift")
        let shell = try read("Sources/KinlogueApp/Views/AppShellView.swift")

        for token in [
            "primary = Color(hex: 0x1E6254)",
            "primaryHover = Color(hex: 0x15453B)",
            "primaryPressed = Color(hex: 0x0F322B)",
            "surface = Color(hex: 0xFFF8F5)",
            "container = Color(hex: 0xF5ECE7)",
            "accent = Color(hex: 0xDF8A4A)",
            "onSurface = Color(hex: 0x1E1B18)",
            "onVariant = Color(hex: 0x3F4946)",
            "outline = Color(hex: 0xBFC9C4)",
            "chip = Color(hex: 0xE9E1DC)",
            "selection = container",
            "selectionForeground = primary",
            "selectionHover = primary.opacity(0.08)",
            "cardHover = Color(hex: 0xFBF2ED)",
        ] {
            #expect(theme.contains(token), "missing palette contract: \(token)")
        }

        #expect(!shell.contains("enum KinlogueTheme"))
        #expect(shell.contains(".preferredColorScheme(.light)"))
    }

    @Test
    func customInteractionsRespectPointerAndMotionPreferences() throws {
        let theme = try read("Sources/KinlogueApp/Views/KinlogueTheme.swift")

        #expect(theme.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(theme.contains("@Environment(\\.colorSchemeContrast)"))
        #expect(theme.contains(".onHover"))
        #expect(theme.contains("configuration.isPressed"))
        #expect(theme.contains("scaleEffect"))
    }

    @Test
    func cardOutlineStaysInsideAdjacentTimelineRows() throws {
        let theme = try read("Sources/KinlogueApp/Views/KinlogueTheme.swift")
        let timeline = try read("Sources/KinlogueApp/Views/TimelineView.swift")

        #expect(timeline.contains("LazyVStack(alignment: .leading, spacing: 0)"))
        #expect(theme.contains(
            "RoundedRectangle(cornerRadius: 16)\n"
                + "                    .strokeBorder("
        ))
    }

    @Test
    func navigationSurfacesUseTheWarmPaletteWithoutCoolMaterialFallbacks() throws {
        let sidebar = try read("Sources/KinlogueApp/Views/MemberSidebarView.swift")
        let inbox = try read("Sources/KinlogueApp/Views/LANInboxView.swift")

        #expect(sidebar.contains(".scrollContentBackground(.hidden)"))
        #expect(sidebar.contains(".background(KinlogueTheme.surface)"))
        #expect(inbox.contains(".scrollContentBackground(.hidden)"))
        #expect(inbox.contains(".listRowBackground("))
        #expect(inbox.contains("? KinlogueTheme.container"))
        #expect(inbox.contains(": KinlogueTheme.surface"))
        #expect(inbox.contains(
            ".padding(12)\n"
                + "        .background(KinlogueTheme.container)\n"
                + "        .overlay(alignment: .top) { Divider() }"
        ))
        #expect(!inbox.contains(".background(.regularMaterial)"))
    }

    @Test
    func sidebarSelectionUsesWarmSelectionAndVisibleKeyboardFocusLayers() throws {
        let sidebar = try read("Sources/KinlogueApp/Views/MemberSidebarView.swift")

        #expect(sidebar.contains("List {"))
        #expect(!sidebar.contains("List(selection: sidebarSelection)"))
        #expect(!sidebar.contains(".tint(KinlogueTheme.primary)"))
        #expect(!sidebar.contains(".listItemTint(.fixed(KinlogueTheme.primary))"))
        #expect(sidebar.contains(".foregroundStyle(sidebarRowForeground(for: .allRecords))"))
        #expect(sidebar.contains(".foregroundStyle(sidebarRowForeground(for: .imaging))"))
        #expect(sidebar.contains(".foregroundStyle(sidebarRowForeground(for: .lanInbox))"))
        #expect(sidebar.contains(".foregroundStyle(sidebarRowForeground(for: selection))"))
        #expect(sidebar.contains(".foregroundStyle(sidebarRowForeground(for: .settings))"))
        #expect(sidebar.contains(".background(sidebarRowBackground(for: .allRecords))"))
        #expect(sidebar.contains(".listRowBackground(Color.clear)"))
        #expect(sidebar.contains(".background(sidebarRowBackground(for: .settings))"))
        #expect(sidebar.contains("KinlogueTheme.selectionHover"))
        #expect(sidebar.components(separatedBy: ".focusEffectDisabled()").count - 1 >= 4)
        #expect(sidebar.contains("@FocusState private var focusedSidebarSelection"))
        #expect(sidebar.components(separatedBy: ".overlay(sidebarRowFocusOverlay(for:").count - 1 >= 5)
        #expect(sidebar.components(separatedBy: ".onMoveCommand").count - 1 >= 5)
        #expect(sidebar.contains("minHeight: 44"))
        #expect(sidebar.components(separatedBy: ".sidebarRowHitTarget()").count - 1 == 6)
    }

    @Test
    func dicomLibrarySelectionUsesTheWarmPaletteWithoutSystemBlue() throws {
        let library = try read("Sources/KinlogueApp/Views/DICOMLibraryView.swift")

        #expect(library.contains("List {"))
        #expect(!library.contains("List(selection:"))
        #expect(!library.contains("List(studies, selection:"))
        #expect(library.contains(".buttonStyle(.plain)"))
        #expect(library.contains(".background(studyRowBackground(for: study.id))"))
        #expect(library.contains(".overlay(studyRowFocusOverlay(for: study.id))"))
        #expect(library.contains(".listRowBackground(Color.clear)"))
        #expect(library.contains("minHeight: 64"))
        #expect(library.contains("model.selectedStudyID == studyID"))
        #expect(library.contains(
            "? KinlogueTheme.selection\n"
                + "                    : hoveredStudyID == studyID"
        ))
        #expect(library.contains(
            "isSelected\n"
                + "                                            ? KinlogueTheme.selectionForeground"
        ))
        #expect(library.contains(
            "hoveredStudyID == studyID\n"
                + "                        ? KinlogueTheme.selectionHover"
        ))
        #expect(library.contains("focusedStudyID == studyID"))
        #expect(library.contains(
            "? KinlogueTheme.primary\n"
                + "                    : .clear,\n"
                + "                lineWidth: 2"
        ))
        #expect(library.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        #expect(library.contains(".focusEffectDisabled()"))
        #expect(library.contains(".onMoveCommand"))
        #expect(library.contains("DICOMLibrarySelectionNavigation.destination"))
    }

    @Test
    func selectedInboxRowsKeepSemanticForegroundsOnWarmBackgrounds() throws {
        let inbox = try read("Sources/KinlogueApp/Views/LANInboxView.swift")
        let row = try read("Sources/KinlogueApp/Views/LANInboxItemRow.swift")

        #expect(inbox.contains("model.selectedItemIDs.contains(item.id)"))
        #expect(inbox.contains("? KinlogueTheme.container"))
        #expect(inbox.contains(": KinlogueTheme.surface"))
        #expect(row.contains(".foregroundStyle(KinlogueTheme.onSurface)"))
        #expect(row.contains(".foregroundStyle(KinlogueTheme.onVariant)"))
        #expect(row.components(separatedBy: ".foregroundStyle(KinlogueTheme.primary)").count - 1 >= 2)
        #expect(row.contains(".foregroundStyle(.red)"))
    }

    @Test
    func windowToolbarUsesTheWarmSurfaceWithNativeControls() throws {
        let shell = try read("Sources/KinlogueApp/Views/AppShellView.swift")

        #expect(shell.contains(
            ".toolbarBackground(KinlogueTheme.surface, for: .windowToolbar)"
        ))
        #expect(shell.contains(
            ".toolbarBackground(.visible, for: .windowToolbar)"
        ))
    }

    @Test
    func iconOnlyToolbarActionsProvideLocalizedHoverHelp() throws {
        let shell = try read("Sources/KinlogueApp/Views/AppShellView.swift")
        let comparison = try read("Sources/KinlogueApp/Views/ComparisonView.swift")

        for help in [
            ".help(AppLocalization.string(\"搜索已确认的记录\"))",
            ".help(AppLocalization.string(\"导入报告\"))",
            ".help(AppLocalization.string(\"导入医学影像\"))",
            "? AppLocalization.string(\"查看手机接收状态\")",
            ": AppLocalization.string(\"从手机接收资料\")",
        ] {
            #expect(shell.contains(help), "missing toolbar help: \(help)")
        }

        #expect(comparison.contains(
            ".help(model.isSelecting ? AppLocalization.string(\"退出比较选择\")"
        ))
    }

    @Test
    func receiverSheetUsesAWhiteCanvasAndOutlinedDisclosureCard() throws {
        let receiver = try read("Sources/KinlogueApp/Views/LANReceiverSheet.swift")

        #expect(receiver.contains(".background(KinlogueTheme.card)"))
        #expect(receiver.contains(
            ".background(KinlogueTheme.card, in: RoundedRectangle(cornerRadius: 12))"
        ))
        #expect(receiver.contains(".stroke(KinlogueTheme.outline, lineWidth: 1)"))
        #expect(!receiver.contains(
            ".background(KinlogueTheme.container, in: RoundedRectangle(cornerRadius: 12))"
        ))
    }

    @Test
    func primaryActionsUseTheSharedInteractionStyle() throws {
        let primaryActionPaths = [
            "Sources/KinlogueApp/Views/AppShellView.swift",
            "Sources/KinlogueApp/Views/ComparisonView.swift",
            "Sources/KinlogueApp/Views/ImportReviewView.swift",
            "Sources/KinlogueApp/Views/LANInboxView.swift",
            "Sources/KinlogueApp/Views/LANReceiverSheet.swift",
            "Sources/KinlogueApp/Views/MemberSidebarView.swift",
            "Sources/KinlogueApp/Views/RecordEditView.swift",
            "Sources/KinlogueApp/Views/TimelineView.swift",
        ]
        let secondaryActionPaths = [
            "Sources/KinlogueApp/Views/AppShellView.swift",
            "Sources/KinlogueApp/Views/ImportReviewView.swift",
            "Sources/KinlogueApp/Views/LANReceiverSheet.swift",
        ]

        for path in primaryActionPaths {
            #expect(try read(path).contains(".buttonStyle(.kinloguePrimary)"), "missing: \(path)")
        }
        for path in secondaryActionPaths {
            #expect(try read(path).contains(".buttonStyle(.kinlogueSecondary)"), "missing: \(path)")
        }

        let sources = try primaryActionPaths.map(read).joined(separator: "\n")
        #expect(!sources.contains(".buttonStyle(.borderedProminent)"))
        #expect(!sources.contains(".tint(KinlogueTheme.sage)"))
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
