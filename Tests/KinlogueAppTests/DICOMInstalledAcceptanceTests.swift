import Foundation
import Testing
@testable import KinlogueApp

struct DICOMInstalledAcceptanceTests {
    @Test
    func smokeEntryAcceptsOnlyTheThreeDICOMPhases() throws {
        let runID = "0123456789abcdef01234567"
        let support = URL(fileURLWithPath: "/tmp/KinlogueAcceptanceSupport")
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.kinlogue.mac.acceptance.\(runID)",
            "KinlogueAcceptanceEnabled": true,
            "KinlogueAcceptanceRunID": runID,
        ]

        for phase in [
            AcceptanceSmokePhase.dicomImport,
            .dicomRestart,
            .dicomDelete,
        ] {
            let entry = AcceptanceSmokeEntry.resolve(
                bundleInfo: info,
                arguments: ["Kinlogue", "--synthetic-smoke", phase.argument],
                trustedApplicationSupportDirectory: support
            )
            #expect(entry.request?.phase == phase)
        }
    }

    @Test
    func inputDirectoryIsBoundToTheAcceptanceRunRoot() throws {
        let runID = "0123456789abcdef01234567"
        let sourceVault = RuntimeVaultIdentity(rootURL: URL(
            fileURLWithPath: "/tmp/Support/Kinlogue/Acceptance/\(runID)/SourceVault"
        ))
        let context = try DICOMInstalledAcceptanceContext(
            runID: runID,
            sourceVault: sourceVault
        )

        #expect(context.inputDirectory.path ==
            "/tmp/Support/Kinlogue/Acceptance/\(runID)/DICOMInput")
    }

    @Test
    func failureEventExposesOnlyABoundedDiagnosticStep() throws {
        let event = DICOMInstalledAcceptanceEvent.failed(
            step: .viewerLimits,
            metrics: DICOMInstalledAcceptanceFailureMetrics(
                cachedWindowP95Milliseconds: 4,
                foregroundP95Milliseconds: 151,
                importMetrics: nil,
                renderedSliceCount: 648,
                rssCloseWithinLimit: true,
                rssPeakDeltaBytes: 1_024
            )
        )
        let data = try JSONEncoder().encode(event)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["code"] as? String == "KLA_DICOM_FAILED")
        #expect(object["failureStep"] as? String == "viewer-limits")
        #expect(object["foregroundP95Milliseconds"] as? Int == 151)
        #expect(object["cachedWindowP95Milliseconds"] as? Int == 4)
        #expect(object["rssPeakDeltaBytes"] as? Int == 1_024)
        #expect(object["ok"] as? Bool == false)
    }
}
