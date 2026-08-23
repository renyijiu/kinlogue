import Foundation
import Testing

struct DICOMViewSafetyTests {
    @Test
    func importStartsFromTheRootFolderPickerAndShowsOnlyAggregateContentFreeProgress() throws {
        let appShellSource = try String(contentsOf: appShellURL, encoding: .utf8)
        let importSource = try String(contentsOf: importViewURL, encoding: .utf8)

        #expect(appShellSource.contains("isPresented: $model.isDICOMFolderPickerPresented"))
        #expect(appShellSource.contains("allowedContentTypes: [.folder]"))
        #expect(appShellSource.contains("allowsMultipleSelection: false"))
        #expect(!importSource.contains(".fileImporter("))
        #expect(!importSource.contains("选择 DICOM 文件夹"))
        #expect(importSource.contains("model.result?.viewableInstanceCount"))
        #expect(importSource.contains("model.result?.inertObjectCount"))
        #expect(!importSource.contains("lastPathComponent"))
        #expect(!importSource.contains("path(percentEncoded:"))
    }

    @Test
    func reviewRequiresAnExplicitSaveOrDeleteActionAndDoesNotExposeIdentifiers() throws {
        let source = try String(contentsOf: reviewViewURL, encoding: .utf8)
        let shell = try String(contentsOf: appShellURL, encoding: .utf8)

        #expect(source.contains(".interactiveDismissDisabled"))
        #expect(source.contains("!model.allowsDismissal"))
        #expect(shell.contains("model.dismissDICOMReviewIfAllowed()"))
        #expect(!shell.contains("model.reviewingDICOMStudy = nil"))
        #expect(source.contains("\"dicom-review-save\""))
        #expect(source.contains("\"dicom-review-delete\""))
        #expect(!source.contains("studyInstanceUID"))
        #expect(!source.contains("seriesInstanceUID"))
        #expect(!source.contains("sopInstanceUID"))
    }

    @Test
    func appShellKeepsReportAndImagingImportsAsSeparateActions() throws {
        let source = try String(contentsOf: appShellURL, encoding: .utf8)

        #expect(source.contains("AppLocalization.string(\"导入报告\")"))
        #expect(source.contains("AppLocalization.string(\"导入医学影像\")"))
        #expect(source.contains(".sheet(isPresented: $model.isDICOMImportPresented"))
        #expect(source.contains(".sheet(item: $model.reviewingDICOMStudy"))
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var importViewURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/DICOMImportSheet.swift")
    }

    private var reviewViewURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/DICOMStudyReviewView.swift")
    }

    private var appShellURL: URL {
        repositoryURL.appendingPathComponent("Sources/KinlogueApp/Views/AppShellView.swift")
    }
}
