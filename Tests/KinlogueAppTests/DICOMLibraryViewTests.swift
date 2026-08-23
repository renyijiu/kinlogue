import AppKit
import KinlogueCore
import SwiftUI
import Testing
@testable import KinlogueApp

@MainActor
struct DICOMLibraryViewTests {
    @Test
    func detailRefreshesWhenTheLibrarySelectionChanges() throws {
        let member = try FamilyMember(displayName: "Synthetic imaging member")
        let study = dicomSummary(
            state: .confirmed,
            memberID: member.id,
            effectiveDate: Date(timeIntervalSinceReferenceDate: 100)
        )
        let model = DICOMLibraryModel()
        model.update(studies: [study], members: [member])
        let hostingView = NSHostingView(rootView: DICOMLibraryDetailContainer(
            model: model,
            onReview: { _ in },
            onViewImages: { _ in }
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 620, height: 480)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        refresh(hostingView)
        let emptyPixels = try renderedPixels(of: hostingView)

        model.select(study.id)
        refresh(hostingView)
        let selectedPixels = try renderedPixels(of: hostingView)

        let expectedView = NSHostingView(rootView: DICOMLibraryDetailView(
            study: study,
            memberLabel: model.memberLabel(for: study),
            onReview: { _ in },
            onViewImages: { _ in }
        ))
        expectedView.frame = hostingView.frame
        let expectedWindow = NSWindow(
            contentRect: expectedView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        expectedWindow.contentView = expectedView
        expectedWindow.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        expectedWindow.orderBack(nil)
        defer {
            expectedWindow.orderOut(nil)
            expectedWindow.contentView = nil
        }
        refresh(expectedView)

        #expect(selectedPixels != emptyPixels)
        #expect(selectedPixels == (try renderedPixels(of: expectedView)))
    }

    @Test
    func appShellKeepsTheImagingDetailSubscribedToLibrarySelection() throws {
        let source = try String(
            contentsOf: repositoryURL
                .appendingPathComponent("Sources/KinlogueApp/Views/AppShellView.swift"),
            encoding: .utf8
        )

        #expect(source.contains(
            "DICOMLibraryDetailContainer(\n"
                + "                    model: model.dicomLibraryModel"
        ))
        #expect(!source.contains("study: model.dicomLibraryModel.selectedStudy"))
    }

    private func refresh(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        view.layoutSubtreeIfNeeded()
    }

    private func renderedPixels(of view: NSView) throws -> Data {
        let representation = try #require(
            view.bitmapImageRepForCachingDisplay(in: view.bounds)
        )
        view.cacheDisplay(in: view.bounds, to: representation)
        let bitmapData = try #require(representation.bitmapData)
        return Data(
            bytes: bitmapData,
            count: representation.bytesPerRow * representation.pixelsHigh
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
