import AppKit
import Foundation
import SwiftUI
import Testing
@testable import KinlogueApp

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
            "chipHover = primary.opacity(0.10)",
            "chipPressed = primary.opacity(0.20)",
            "selection = primary.opacity(0.13)",
            "selectionForeground = primary",
            "selectionHover = primary.opacity(0.05)",
            "selectionPressed = primary.opacity(0.18)",
            "cardHover = Color(hex: 0xFBF2ED)",
            "success = primary",
            "warning = Color(hex: 0x8A4712)",
            "warningContainer = Color(hex: 0xFFF4E9)",
            "danger = Color(hex: 0x8A302D)",
            "dangerContainer = Color(hex: 0xF4E2DF)",
            "dangerContainerHover = Color(hex: 0xEDD3CF)",
            "dangerContainerPressed = Color(hex: 0xE6C4BF)",
            "static let control: CGFloat = 8",
            "static let card: CGFloat = 12",
            "static let interactiveCard: CGFloat = 16",
        ] {
            #expect(theme.contains(token), "missing palette contract: \(token)")
        }

        #expect(!shell.contains("enum KinlogueTheme"))
        #expect(theme.contains(".preferredColorScheme(.light)"))
        #expect(theme.contains("tint(KinlogueTheme.primary)"))
        #expect(shell.contains(".kinlogueAppearance()"))
    }

    @Test
    func nativeAccentColorAssetMatchesThePrimaryTokenAndIsPackagedExactly() throws {
        // AppKit draws focus rings, text selection and the date picker's
        // selected day in the app accent color, which SwiftUI tint cannot reach.
        let colorSet = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: repositoryURL.appendingPathComponent(
                "packaging/Assets.xcassets/AccentColor.colorset/Contents.json"
            ))
        ) as? [String: Any])
        let colors = try #require(colorSet["colors"] as? [[String: Any]])
        #expect(colors.count == 1)
        let color = try #require(colors.first?["color"] as? [String: Any])
        let components = try #require(color["components"] as? [String: String])
        #expect(color["color-space"] as? String == "srgb")
        #expect(components["alpha"] == "1.000")

        let primary = sRGBComponents(of: KinlogueTheme.primary)
        for (channel, value) in [
            ("red", primary.red),
            ("green", primary.green),
            ("blue", primary.blue),
        ] {
            let hex = try #require(components[channel])
            #expect(hex.hasPrefix("0x"))
            #expect(Int(hex.dropFirst(2), radix: 16) == Int((value * 255).rounded()))
        }

        let info = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: repositoryURL.appendingPathComponent("packaging/Info.plist")),
            format: nil
        ) as? [String: Any])
        #expect(info["NSAccentColorName"] as? String == "AccentColor")

        let builder = try read("scripts/build-app.sh")
        #expect(builder.contains("ASSET_CATALOG=\"$REPO_DIR/packaging/Assets.xcassets\""))
        #expect(builder.contains("\"$XCRUN_EXECUTABLE\" actool \"$ASSET_CATALOG\""))
        #expect(builder.contains("--accent-color \"$ACCENT_COLOR_NAME\""))
        #expect(builder.contains("/bin/cp -- \"$ASSET_COMPILED_ARCHIVE\" \"$APP_ASSET_ARCHIVE\""))
        // The archive must be in place before the bundle is signed.
        let archiveCopy = try #require(builder.range(of: "\"$APP_ASSET_ARCHIVE\"\n"))
        let bundleSignature = try #require(builder.range(
            of: "--entitlements \"$REPO_DIR/packaging/Kinlogue.entitlements\""
        ))
        #expect(archiveCopy.lowerBound < bundleSignature.lowerBound)

        let verifier = try read("scripts/verify-app.sh")
        let expectedRGB = [primary.red, primary.green, primary.blue]
            .map { String(Int(($0 * 255).rounded())) }
            .joined(separator: " ")
        #expect(verifier.contains("EXPECTED_ACCENT_COLOR_RGB=\"\(expectedRGB)\""))
        #expect(verifier.contains("EXPECTED_RESOURCE_FILES=\"./$EXPECTED_ASSET_ARCHIVE_FILE\n"))
        #expect(verifier.contains("\"$(plist_string NSAccentColorName)\" == \"$EXPECTED_ACCENT_COLOR_NAME\""))
        #expect(verifier.contains("assetutil --info \"$ASSET_ARCHIVE_FILE\""))
        #expect(verifier.contains("the asset archive must contain only the Warm Sanctuary accent color"))
    }

    @Test
    func everyWindowSheetAndPopoverOptsIntoTheLightWarmAppearance() throws {
        // Tint and color scheme set inside one presentation are not
        // guaranteed to reach another, so each root opts in by itself.
        for (path, expectedRoots) in [
            ("Sources/KinlogueApp/Views/AssistantConsentSheet.swift", 1),
            ("Sources/KinlogueApp/Views/BackupAndRestoreView.swift", 3),
            ("Sources/KinlogueApp/Views/ComparisonView.swift", 1),
            ("Sources/KinlogueApp/Views/DICOMImportSheet.swift", 1),
            ("Sources/KinlogueApp/Views/DICOMStudyReviewView.swift", 1),
            ("Sources/KinlogueApp/Views/DeleteVaultView.swift", 1),
            ("Sources/KinlogueApp/Views/ImportReviewView.swift", 1),
            ("Sources/KinlogueApp/Views/LANReceiverSheet.swift", 1),
            ("Sources/KinlogueApp/Views/MemberSidebarView.swift", 1),
            ("Sources/KinlogueApp/Views/OriginalDocumentView.swift", 2),
            ("Sources/KinlogueApp/Views/OriginalExportView.swift", 1),
            ("Sources/KinlogueApp/Views/RecordEditView.swift", 1),
            ("Sources/KinlogueApp/Views/RecordRuleUpdateView.swift", 1),
        ] {
            let roots = try read(path).components(separatedBy: ".kinlogueSheetCanvas()").count - 1
            #expect(roots == expectedRoots, "sheet canvas count changed: \(path)")
        }

        let presenters = try [
            "Sources/KinlogueApp/Views/AppShellView.swift",
            "Sources/KinlogueApp/Views/LANInboxView.swift",
        ].map(read).joined(separator: "\n")
        let presentedSheets = presenters.components(separatedBy: ".sheet(").count - 1
        // The two member editor sheets share one view and the two original
        // viewers each back one sheet, so 16 presentations map to 15 roots.
        #expect(presentedSheets == 16)

        for path in [
            "Sources/KinlogueApp/Views/AppShellView.swift",
            "Sources/KinlogueApp/Views/DICOMStudyViewer.swift",
            "Sources/KinlogueApp/Views/LocalizedDatePicker.swift",
            "Sources/KinlogueApp/Views/SQLiteAppLaunchView.swift",
        ] {
            #expect(try read(path).contains(".kinlogueAppearance()"), "missing: \(path)")
        }
    }

    @Test
    func pagesUseSemanticTokensInsteadOfSystemGraysStatusColorsOrCoolBackgrounds() throws {
        let viewsURL = repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views")
        let pageURLs = try FileManager.default.contentsOfDirectory(
            at: viewsURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.pathExtension == "swift" && $0.lastPathComponent != "KinlogueTheme.swift"
        }
        #expect(pageURLs.count >= 27)

        let literalRadius = try NSRegularExpression(pattern: #"cornerRadius: \d"#)
        var violations: [String] = []
        for pageURL in pageURLs {
            let source = try String(contentsOf: pageURL, encoding: .utf8)
            for forbidden in [
                ".foregroundStyle(.secondary)",
                ".foregroundStyle(.tertiary)",
                ".foregroundStyle(.red)",
                ".foregroundStyle(.orange)",
                ".foregroundStyle(.green)",
                ".tint(.red)",
                ".buttonStyle(.borderless)",
                ".buttonStyle(.bordered",
                "Color(nsColor:",
                ".regularMaterial",
                "Color(hex:",
            ] where source.contains(forbidden) {
                violations.append("\(pageURL.lastPathComponent): \(forbidden)")
            }
            let range = NSRange(source.startIndex..., in: source)
            if literalRadius.firstMatch(in: source, range: range) != nil {
                violations.append("\(pageURL.lastPathComponent): literal corner radius")
            }
        }
        #expect(violations.isEmpty, "use KinlogueTheme tokens: \(violations.joined(separator: ", "))")
    }

    @Test
    func rowInteractionLayersOrderPressedThenSelectedThenHover() {
        #expect(
            KinlogueTheme.rowFill(isSelected: true, isHovering: true, isPressed: true)
                == KinlogueTheme.selectionPressed
        )
        #expect(
            KinlogueTheme.rowFill(isSelected: true, isHovering: true, isPressed: false)
                == KinlogueTheme.selection
        )
        #expect(
            KinlogueTheme.rowFill(isSelected: false, isHovering: true, isPressed: false)
                == KinlogueTheme.selectionHover
        )
        #expect(
            KinlogueTheme.rowFill(isSelected: false, isHovering: false, isPressed: false)
                == Color.clear
        )

        var interaction = KinlogueRowInteraction<Int>()
        interaction.setHovering(true, for: 1)
        interaction.setPressed(true, for: 2)
        #expect(interaction.fill(for: 1, isSelected: false) == KinlogueTheme.selectionHover)
        #expect(interaction.fill(for: 2, isSelected: false) == KinlogueTheme.selectionPressed)
        // A late exit from another row must not clear the row now under the pointer.
        interaction.setHovering(false, for: 3)
        interaction.setPressed(false, for: 3)
        #expect(interaction.hoveredID == 1)
        #expect(interaction.pressedID == 2)
        interaction.setHovering(false, for: 1)
        interaction.setPressed(false, for: 2)
        #expect(interaction.fill(for: 1, isSelected: false) == Color.clear)
        #expect(interaction.fill(for: 2, isSelected: true) == KinlogueTheme.selection)

        // Selected must read heavier than hover on every canvas it is drawn on.
        for canvas in [KinlogueTheme.surface, KinlogueTheme.card, KinlogueTheme.container] {
            let canvasLuminance = luminance(of: canvas)
            let hover = luminance(of: KinlogueTheme.selectionHover, over: canvas)
            let selected = luminance(of: KinlogueTheme.selection, over: canvas)
            let pressed = luminance(of: KinlogueTheme.selectionPressed, over: canvas)
            #expect(canvasLuminance > hover)
            #expect(hover > selected)
            #expect(selected > pressed)
            #expect(contrast(canvasLuminance, selected) >= 1.2)
        }
    }

    @Test
    func textAndStatusForegroundsStayReadableOnEveryCanvas() {
        let canvases = [
            KinlogueTheme.surface,
            KinlogueTheme.card,
            KinlogueTheme.container,
            KinlogueTheme.warningContainer,
        ]
        for foreground in [
            KinlogueTheme.onSurface,
            KinlogueTheme.onVariant,
            KinlogueTheme.primary,
            KinlogueTheme.success,
            KinlogueTheme.warning,
            KinlogueTheme.danger,
        ] {
            for canvas in canvases {
                #expect(contrast(luminance(of: foreground), luminance(of: canvas)) >= 4.5)
            }
        }
        for dangerFill in [
            KinlogueTheme.dangerContainer,
            KinlogueTheme.dangerContainerHover,
            KinlogueTheme.dangerContainerPressed,
        ] {
            #expect(
                contrast(luminance(of: KinlogueTheme.danger), luminance(of: dangerFill)) >= 4.5
            )
        }
        // Row text keeps its contrast on top of the heaviest interaction layer.
        for foreground in [KinlogueTheme.onVariant, KinlogueTheme.selectionForeground] {
            let pressed = luminance(of: KinlogueTheme.selectionPressed, over: KinlogueTheme.container)
            #expect(contrast(luminance(of: foreground), pressed) >= 4.5)
        }
        #expect(KinlogueStatusTone.warning.systemImage != KinlogueStatusTone.danger.systemImage)
        #expect(KinlogueStatusTone.success.systemImage != KinlogueStatusTone.warning.systemImage)
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
            "RoundedRectangle(cornerRadius: KinlogueTheme.Radius.interactiveCard)\n"
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
        #expect(inbox.contains("KinlogueTheme.surface.overlay("))
        #expect(inbox.contains("? KinlogueTheme.selection"))
        #expect(inbox.contains(
            ".padding(12)\n"
                + "        .background(KinlogueTheme.container)\n"
                + "        .overlay(alignment: .top) { Divider() }"
        ))
        #expect(!inbox.contains(".background(.regularMaterial)"))

        let original = try read("Sources/KinlogueApp/Views/OriginalDocumentView.swift")
        // The ordered wrapper and the single-document content each paint one
        // fill, covering loading, failed and loaded states alike.
        #expect(original.components(separatedBy: ".background(KinlogueTheme.container)").count - 1 == 2)
        #expect(!original.contains("windowBackgroundColor"))
        #expect(!original.contains("Material"))
    }

    @Test
    func sidebarSelectionUsesWarmSelectionAndVisibleKeyboardFocusLayers() throws {
        let sidebar = try read("Sources/KinlogueApp/Views/MemberSidebarView.swift")

        #expect(sidebar.contains("List {"))
        #expect(!sidebar.contains("List(selection: sidebarSelection)"))
        #expect(!sidebar.contains(".tint(KinlogueTheme.primary)"))
        #expect(!sidebar.contains(".listItemTint(.fixed(KinlogueTheme.primary))"))
        #expect(sidebar.contains(".foregroundStyle(sidebarRowForeground(for: .allRecords))"))
        #expect(sidebar.contains(".foregroundStyle(sidebarRowForeground(for: .lanInbox))"))
        #expect(sidebar.contains(".foregroundStyle(sidebarRowForeground(for: selection))"))
        #expect(sidebar.contains(".foregroundStyle(sidebarRowForeground(for: .settings))"))
        #expect(sidebar.contains(".background(sidebarRowBackground(for: .allRecords))"))
        #expect(sidebar.contains(".listRowBackground(Color.clear)"))
        #expect(sidebar.contains(".background(sidebarRowBackground(for: .settings))"))
        #expect(sidebar.contains("KinlogueRowInteraction<MemberSidebarSelection>()"))
        #expect(sidebar.contains(
            "rowInteraction.fill(\n"
                + "                for: selection,\n"
                + "                isSelected: currentSidebarSelection == selection"
        ))
        #expect(sidebar.components(separatedBy: ".buttonStyle(.kinlogueRow {").count - 1 == 5)
        #expect(sidebar.components(separatedBy: "rowInteraction.setHovering(isHovering, for:").count - 1 == 4)
        #expect(!sidebar.contains(".buttonStyle(.plain)"))
        // A bare Label icon follows the accent tint and the window's active
        // state in a sidebar list, so every row styles its symbol explicitly.
        #expect(sidebar.contains("private struct SidebarRowLabel: View"))
        #expect(!sidebar.contains(" Label("))
        #expect(sidebar.components(separatedBy: "SidebarRowLabel(").count - 1 == 8)
        #expect(sidebar.components(separatedBy: "color: sidebarRowForeground(for:").count - 1 == 3)
        #expect(sidebar.components(separatedBy: ".focusEffectDisabled()").count - 1 >= 4)
        #expect(sidebar.contains("@FocusState private var focusedSidebarSelection"))
        #expect(sidebar.components(separatedBy: ".overlay(sidebarRowFocusOverlay(for:").count - 1 >= 4)
        #expect(sidebar.components(separatedBy: ".onMoveCommand").count - 1 >= 4)
        #expect(sidebar.contains("minHeight: 44"))
        #expect(sidebar.components(separatedBy: ".sidebarRowHitTarget()").count - 1 == 5)
    }

    @Test
    func timelineImagingSelectionAndFilterUseTheWarmPaletteWithoutSystemControls() throws {
        let timeline = try read("Sources/KinlogueApp/Views/TimelineView.swift")

        #expect(!timeline.contains("List(selection:"))
        #expect(!timeline.contains(".pickerStyle(.segmented)"))
        #expect(timeline.contains(".buttonStyle(.kinlogueCard(isHighlighted: isSelected))"))
        #expect(timeline.contains("isSelected: study.id == dicomLibraryModel.selectedStudyID"))
        #expect(timeline.contains(".disabled(isSelectingComparison)"))
        #expect(timeline.contains(".buttonStyle(.kinlogueChip(isSelected: isSelected))"))
        #expect(!timeline.contains(".buttonStyle(.plain)"))
        #expect(timeline.contains("Image(systemName: \"checkmark\")"))
        #expect(
            timeline.components(
                separatedBy: ".accessibilityAddTraits(isSelected ? .isSelected : [])"
            ).count - 1 == 2
        )
    }

    @Test
    func selectableChipsGrowHeavierFromHoverToPressedAndKeepTheirTextReadable() {
        // A neutral chip layers its interaction state over the Chip fill.
        let resting = luminance(of: KinlogueTheme.chip)
        let hover = luminance(of: KinlogueTheme.chipHover, over: KinlogueTheme.chip)
        let pressed = luminance(of: KinlogueTheme.chipPressed, over: KinlogueTheme.chip)
        #expect(resting > hover)
        #expect(hover > pressed)
        #expect(contrast(luminance(of: KinlogueTheme.onVariant), pressed) >= 4.5)

        #expect(
            KinlogueTheme.chipFill(isSelected: false, isHovering: true, isPressed: true)
                == KinlogueTheme.chip
        )
        #expect(
            KinlogueTheme.chipLayer(isSelected: false, isHovering: true, isPressed: true)
                == KinlogueTheme.chipPressed
        )
        #expect(
            KinlogueTheme.chipLayer(isSelected: false, isHovering: true, isPressed: false)
                == KinlogueTheme.chipHover
        )
        #expect(
            KinlogueTheme.chipLayer(isSelected: false, isHovering: false, isPressed: false)
                == Color.clear
        )

        // A selected chip follows the primary button and never takes the layer.
        #expect(
            KinlogueTheme.chipFill(isSelected: true, isHovering: true, isPressed: true)
                == KinlogueTheme.primaryPressed
        )
        #expect(
            KinlogueTheme.chipFill(isSelected: true, isHovering: true, isPressed: false)
                == KinlogueTheme.primaryHover
        )
        #expect(
            KinlogueTheme.chipFill(isSelected: true, isHovering: false, isPressed: false)
                == KinlogueTheme.primary
        )
        #expect(
            KinlogueTheme.chipLayer(isSelected: true, isHovering: true, isPressed: true)
                == Color.clear
        )
        for fill in [
            KinlogueTheme.primary,
            KinlogueTheme.primaryHover,
            KinlogueTheme.primaryPressed,
        ] {
            #expect(contrast(luminance(of: .white), luminance(of: fill)) >= 4.5)
        }
    }

    @Test
    func selectedInboxRowsKeepSemanticForegroundsOnWarmBackgrounds() throws {
        let inbox = try read("Sources/KinlogueApp/Views/LANInboxView.swift")
        let row = try read("Sources/KinlogueApp/Views/LANInboxItemRow.swift")

        #expect(inbox.contains("model.selectedItemIDs.contains(item.id)"))
        // The row fill is composited over Surface so it stays opaque.
        #expect(inbox.contains("KinlogueTheme.surface.overlay("))
        #expect(inbox.contains("? KinlogueTheme.selection"))
        #expect(row.contains(".foregroundStyle(KinlogueTheme.onSurface)"))
        #expect(row.contains(".foregroundStyle(KinlogueTheme.onVariant)"))
        // Ghost buttons set their own foreground, so list selection cannot recolor them.
        #expect(row.components(separatedBy: ".buttonStyle(.kinlogueGhost)").count - 1 == 2)
        #expect(row.contains(".buttonStyle(.kinlogueGhost(.danger))"))
        #expect(row.contains("case .failed, .integrityFailed: KinlogueTheme.danger"))
        #expect(row.contains("case .unsupported: KinlogueTheme.warning"))
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
    func receiverSheetUsesTheSharedCanvasAndOutlinedWhiteCards() throws {
        let receiver = try read("Sources/KinlogueApp/Views/LANReceiverSheet.swift")
        let theme = try read("Sources/KinlogueApp/Views/KinlogueTheme.swift")

        #expect(receiver.contains(".kinlogueSheetCanvas()"))
        #expect(!receiver.contains(".background(KinlogueTheme.card)"))
        // The disclosure card and the QR code both sit on white so they
        // stand apart from the Surface canvas.
        #expect(receiver.components(separatedBy: ".kinloguePanel(.card)").count - 1 == 2)
        #expect(!receiver.contains(".kinloguePanel()"))
        #expect(theme.contains("case .container, .card: KinlogueTheme.outline"))
        #expect(theme.contains(".strokeBorder(stroke, lineWidth: contrast == .increased ? 2 : 1)"))
    }

    @Test
    func primaryActionsUseTheSharedInteractionStyle() throws {
        let primaryActionPaths = [
            "Sources/KinlogueApp/Views/StorageDisclosureView.swift",
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
            "Sources/KinlogueApp/Views/BackupAndRestoreView.swift",
            "Sources/KinlogueApp/Views/ComparisonView.swift",
            "Sources/KinlogueApp/Views/DICOMImportSheet.swift",
            "Sources/KinlogueApp/Views/DICOMStudyReviewView.swift",
            "Sources/KinlogueApp/Views/DeleteVaultView.swift",
            "Sources/KinlogueApp/Views/ImportReviewView.swift",
            "Sources/KinlogueApp/Views/LANReceiverSheet.swift",
            "Sources/KinlogueApp/Views/MemberSidebarView.swift",
            "Sources/KinlogueApp/Views/OriginalDocumentView.swift",
            "Sources/KinlogueApp/Views/OriginalExportView.swift",
            "Sources/KinlogueApp/Views/RecordDetailView.swift",
            "Sources/KinlogueApp/Views/RecordEditView.swift",
            "Sources/KinlogueApp/Views/SettingsView.swift",
            "Sources/KinlogueApp/Views/StorageDisclosureView.swift",
        ]
        // Every in-content destructive action shares one look; system
        // confirmation dialogs keep their native destructive role.
        let destructiveActionPaths = [
            "Sources/KinlogueApp/Views/BackupAndRestoreView.swift",
            "Sources/KinlogueApp/Views/DICOMStudyReviewView.swift",
            "Sources/KinlogueApp/Views/DeleteVaultView.swift",
            "Sources/KinlogueApp/Views/ImportReviewView.swift",
            "Sources/KinlogueApp/Views/LANInboxView.swift",
            "Sources/KinlogueApp/Views/LANReceiverSheet.swift",
            "Sources/KinlogueApp/Views/RecordDetailView.swift",
            "Sources/KinlogueApp/Views/SettingsView.swift",
        ]

        for path in primaryActionPaths {
            #expect(try read(path).contains(".buttonStyle(.kinloguePrimary)"), "missing: \(path)")
        }
        for path in secondaryActionPaths {
            #expect(try read(path).contains(".buttonStyle(.kinlogueSecondary)"), "missing: \(path)")
        }
        for path in destructiveActionPaths {
            #expect(try read(path).contains(".buttonStyle(.kinlogueDestructive)"), "missing: \(path)")
        }

        let launchPaths = [
            "Sources/KinlogueApp/Views/AppShellView.swift",
            "Sources/KinlogueApp/Views/SQLiteAppLaunchView.swift",
        ]
        for path in launchPaths {
            #expect(try read(path).contains("StorageDisclosureView {"), "missing disclosure: \(path)")
        }
        let sources = try (primaryActionPaths + launchPaths).map(read).joined(separator: "\n")
        #expect(!sources.contains(".buttonStyle(.borderedProminent)"))
        #expect(!sources.contains(".tint(KinlogueTheme.sage)"))
    }

    private func luminance(of color: Color, over canvas: Color? = nil) -> Double {
        var components = sRGBComponents(of: color)
        if let canvas {
            let backdrop = sRGBComponents(of: canvas)
            let alpha = components.alpha
            components.red = components.red * alpha + backdrop.red * (1 - alpha)
            components.green = components.green * alpha + backdrop.green * (1 - alpha)
            components.blue = components.blue * alpha + backdrop.blue * (1 - alpha)
        }
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(components.red)
            + 0.7152 * linear(components.green)
            + 0.0722 * linear(components.blue)
    }

    private func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func sRGBComponents(
        of color: Color
    ) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return (
            Double(resolved.redComponent),
            Double(resolved.greenComponent),
            Double(resolved.blueComponent),
            Double(resolved.alphaComponent)
        )
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
