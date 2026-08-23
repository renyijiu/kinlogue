import Foundation
import Testing
@testable import KinlogueApp

struct DICOMViewerSourceSafetyTests {
    @Test
    func viewerUsesOnlyOpaqueModelStateAndProvidesAccessibleControls() throws {
        let viewer = try source("DICOMStudyViewer.swift")
        let canvas = try source("DICOMImageCanvas.swift")
        let controls = try source("DICOMViewerControls.swift")
        let combined = viewer + canvas + controls

        for forbidden in [
            "PlaintextVault", "DICOMDecoderAdapter", "FileHandle", "lastPathComponent",
            "studyInstanceUID", "seriesInstanceUID", "sopInstanceUID", "getAllTags",
            "ShareLink", "NSPasteboard", "draggable(",
        ] {
            #expect(!combined.contains(forbidden))
        }
        for required in [
            "dicom-viewer-canvas", "dicom-viewer-retry", "dicom-viewer-fit",
            "dicom-viewer-reset", "dicom-viewer-slice-slider",
            "dicom-viewer-playback", "accessibilityLabel", "keyboardShortcut", "Space",
        ] {
            #expect(combined.contains(required))
        }
    }

    @Test
    func seriesSelectionUsesOneMenuAtEveryWindowWidth() throws {
        let viewer = try source("DICOMStudyViewer.swift")
        let controls = try source("DICOMViewerControls.swift")

        for required in [
            "Picker(", ".pickerStyle(.menu)", "dicom-viewer-series-picker",
            "dicom-viewer-series-previous", "dicom-viewer-series-next",
        ] {
            #expect(controls.contains(required))
        }

        #expect(!viewer.contains("private var seriesList"))
        #expect(!viewer.contains("compactSeriesPicker"))
        #expect(!viewer.contains("List(model.series"))
    }

    @Test
    func viewerOpensInAResizableStandardWindowFromEveryEntryPoint() throws {
        let app = try appSource("App/KinlogueApp.swift")
        let shell = try source("AppShellView.swift")
        let review = try source("DICOMStudyReviewView.swift")

        for required in [
            "WindowGroup(", "DICOMViewerWindowScene.id", ".windowResizability(.contentMinSize)",
            ".defaultSize(width:", "openWindow(id: DICOMViewerWindowScene.id, value:",
        ] {
            #expect((app + shell).contains(required))
        }

        #expect(!shell.contains(".sheet(item: $model.viewingDICOMStudy"))
        #expect(!review.contains(".sheet(isPresented: $isViewerPresented"))
        #expect(review.contains("onOpenViewer(studyID)"))
    }

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: repositoryURL
                .appendingPathComponent("Sources/KinlogueApp/Views")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    private func appSource(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryURL
                .appendingPathComponent("Sources/KinlogueApp")
                .appendingPathComponent(path),
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
