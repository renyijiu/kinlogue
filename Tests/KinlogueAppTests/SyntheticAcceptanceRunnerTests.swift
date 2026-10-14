import CryptoKit
import Foundation
import PDFKit
import Testing
@testable import KinlogueApp
import KinlogueCore
import KinloguePlatform

@Suite(.serialized)
struct SyntheticAcceptanceRunnerTests {
    private let supportDirectory = URL(
        fileURLWithPath: "/Users/acceptance/Library/Application Support",
        isDirectory: true
    )
    private let runID = "0123456789abcdef01234567"

    @Test
    func productionSyntheticSmokeIsRejectedBeforeAnyRunnerCanStart() {
        let untouchedSupportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let decision = AcceptanceSmokeEntry.resolve(
            bundleInfo: [
                "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
            ],
            arguments: [
                "Kinlogue",
                AppRuntimeIdentity.syntheticSmokeArgument,
                AcceptanceSmokePhase.seed.argument,
            ],
            trustedApplicationSupportDirectory: untouchedSupportDirectory
        )

        #expect(decision == .reject)
        #expect(!FileManager.default.fileExists(atPath: untouchedSupportDirectory.path))
        print("KINLOGUE_PRODUCTION_REJECTION_UNIT_PASSED")
    }

    @Test
    func acceptanceSmokeRequiresOneKnownPhaseAndSignedRunIdentity() throws {
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.kinlogue.mac.acceptance.\(runID)",
            AppRuntimeIdentity.acceptanceEnabledInfoKey: true,
            AppRuntimeIdentity.acceptanceRunIDInfoKey: runID,
        ]
        let decision = AcceptanceSmokeEntry.resolve(
            bundleInfo: info,
            arguments: [
                "Kinlogue",
                AppRuntimeIdentity.syntheticSmokeArgument,
                AcceptanceSmokePhase.seed.argument,
            ],
            trustedApplicationSupportDirectory: supportDirectory
        )
        let request = try #require(decision.request)

        #expect(request.phase == .seed)
        #expect(request.identity.mode == .acceptance(runID: runID))
        #expect(request.identity.syntheticSmokeRequested)

        #expect(AcceptanceSmokeEntry.resolve(
            bundleInfo: info,
            arguments: [
                "Kinlogue",
                AppRuntimeIdentity.syntheticSmokeArgument,
                "--acceptance-phase=unknown",
            ],
            trustedApplicationSupportDirectory: supportDirectory
        ) == .reject)
        #expect(AcceptanceSmokeEntry.resolve(
            bundleInfo: info,
            arguments: [
                "Kinlogue",
                AppRuntimeIdentity.syntheticSmokeArgument,
                AcceptanceSmokePhase.seed.argument,
                "--extra",
            ],
            trustedApplicationSupportDirectory: supportDirectory
        ) == .reject)
    }

    @Test
    func installedLANEvidenceCannotEncodeAFailedRequiredField() throws {
        let hash = String(repeating: "a", count: 64)
        let valid = try InstalledLANAcceptanceEvent(
            executableSHA256: hash,
            listenerAbsentBeforeStart: true,
            listenerActiveAfterStart: true,
            channelClosedAfterStop: true,
            listenerAbsentAfterStop: true,
            oldSessionRejected: true,
            pairingRejected: true,
            authenticationRejected: true,
            hostRejected: true,
            originRejected: true,
            framingRejected: true,
            uniqueFilesStored: true,
            streamingUploadVerified: true,
            interruptedUploadCleanupVerified: true
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
                as? [String: Any]
        )

        #expect(object["code"] as? String == "KLA_LAN_RECEIVER_COMPLETE")
        #expect(object["ok"] as? Bool == true)
        #expect(object["executableSHA256"] as? String == hash)
        #expect(Set(object.keys).count == 16)
        #expect(throws: InstalledLANAcceptanceProbeError.requiredEvidence(
            "listenerAbsentBeforeStart"
        )) {
            try InstalledLANAcceptanceEvent(
                executableSHA256: hash,
                listenerAbsentBeforeStart: false,
                listenerActiveAfterStart: true,
                channelClosedAfterStop: true,
                listenerAbsentAfterStop: true,
                oldSessionRejected: true,
                pairingRejected: true,
                authenticationRejected: true,
                hostRejected: true,
                originRejected: true,
                framingRejected: true,
                uniqueFilesStored: true,
                streamingUploadVerified: true,
                interruptedUploadCleanupVerified: true
            )
        }
    }

    @Test
    func installedLANFailureEvidenceContainsOnlyAFixedReason() throws {
        let event = InstalledLANAcceptanceFailureEvent(
            error: .requiredEvidence("listenerAbsentBeforeStart")
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
                as? [String: Any]
        )

        #expect(Set(object.keys) == ["code", "ok", "reason"])
        #expect(object["code"] as? String == "KLA_LAN_RECEIVER_FAILED")
        #expect(object["ok"] as? Bool == false)
        #expect(object["reason"] as? String == "required-listenerAbsentBeforeStart")
    }

    @Test
    func installedLANProbeUsesProductionHTTPAndPersistsAcrossProcessPhases()
        async throws
    {
        let support = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("kinlogue-installed-lan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let identity = try acceptanceIdentity(support: support, phase: .lanReceiver)
        _ = try AcceptanceRunOwnership.claim(applicationSupportURL: support, runID: runID)
        let executable = try #require(Bundle.main.executableURL)
        let probe = InstalledLANAcceptanceProbe(
            identity: identity,
            runID: runID,
            executableURL: executable
        )

        // Each phase opens the SQLite library and closes it again, as a separate process would.
        let receiver = try await probe.run()
        let restarted = try await probe.verifyAfterProcessRestart()

        #expect(receiver.ok)
        #expect(receiver.uniqueFilesStored)
        #expect(receiver.interruptedUploadCleanupVerified)
        #expect(restarted.completedFilesAfterProcessRestart)
        #expect(restarted.listenerAbsentAfterRestartStop)
        #expect(FileManager.default.fileExists(
            atPath: identity.sourceVault.rootURL.appendingPathComponent(SQLiteLibraryStore.databaseFilename).path))
    }

    private func acceptanceIdentity(support: URL, phase: AcceptanceSmokePhase) throws -> AppRuntimeIdentity {
        try AppRuntimeIdentity.resolve(bundleInfo: [
            "CFBundleIdentifier": "com.kinlogue.mac.acceptance.\(runID)",
            AppRuntimeIdentity.acceptanceEnabledInfoKey: true,
            AppRuntimeIdentity.acceptanceRunIDInfoKey: runID,
        ], arguments: ["Kinlogue", AppRuntimeIdentity.syntheticSmokeArgument, phase.argument],
            trustedApplicationSupportDirectory: support)
    }

    @Test
    func generatedScenarioHasFourMembersAndTwentyFourConfirmedOriginalsEach() throws {
        let scenario = try SyntheticAcceptanceScenario.make(runID: runID)

        #expect(scenario.memberNames.count == 4)
        #expect(Set(scenario.memberNames).count == 4)
        #expect(scenario.reports.count == 96)
        #expect(scenario.reports.map(\.ordinal) == Array(0..<96))
        #expect(Set(scenario.reports.map(\.originalDigest)).count == 96)
        let reportsByMember = Dictionary(grouping: scenario.reports, by: \.memberIndex)
        #expect(reportsByMember.count == 4)
        #expect(reportsByMember.values.allSatisfy { $0.count == 24 })
        #expect(scenario.scanTokens.count == 7)
        #expect(Set(scenario.scanTokens).count == scenario.scanTokens.count)
        #expect(
            scenario.tokenSetSHA256
                == "42197b855f8339ba1c0eedf7a8ddfa64a76e16730264022785faa3fcf628adc7"
        )
        #expect(scenario.reports.allSatisfy {
            $0.original.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D])
                && ContentDigest.sha256($0.original) == $0.originalDigest
        })
        #expect(PDFDocument(data: scenario.reports[0].original)?.pageCount == 1)

        let reportDates = scenario.reports.map(\.reportDate)
        let earliestDate = try #require(reportDates.min())
        let latestDate = try #require(reportDates.max())
        let twoYearSpan = earliestDate.distance(to: latestDate)
        #expect(twoYearSpan >= 700 * 86_400)
        #expect(twoYearSpan <= 800 * 86_400)
        for reports in reportsByMember.values {
            let first = try #require(reports.map(\.reportDate).min())
            let last = try #require(reports.map(\.reportDate).max())
            #expect(first.distance(to: last) == 23 * 32 * 86_400)
        }

        let targetReport = scenario.reports[SyntheticAcceptanceScenario.targetOrdinal]
        #expect(scenario.target.memberName == scenario.memberNames[targetReport.memberIndex])
        #expect(scenario.target.reportDate == targetReport.reportDate)
        #expect(scenario.target.organization == targetReport.organization)
        #expect(scenario.target.originalDigest == targetReport.originalDigest)

        // The library assigns identifiers when an original is staged, so records are built on
        // the draft it returns. Here a draft stands in for each staged original.
        let members = try scenario.memberNames.map { try FamilyMember(displayName: $0) }
        let records = try scenario.reports.map { report in
            let draft = try ImportDraft(sources: ReportSources([ReportSource(attachmentID: UUID(), pageCount: 1)]))
            let record = try report.record(confirming: draft, memberID: members[report.memberIndex].id)
            #expect(record.id == draft.id && record.sources == draft.sources)
            #expect(report.matches(record, memberID: members[report.memberIndex].id))
            return record
        }
        #expect(records.allSatisfy { $0.importState == .confirmed })
        #expect(!scenario.reports[1].matches(records[0], memberID: members[0].id))
        #expect(!scenario.reports[0].matches(records[0], memberID: members[1].id))
        #expect(records.filter {
            scenario.target.matches($0, resolvedMemberID: members[targetReport.memberIndex].id)
        } == [records[SyntheticAcceptanceScenario.targetOrdinal]])
        #expect(records.allSatisfy { record in
            [record.title, record.organization, record.reportType, record.conclusion].allSatisfy { field in
                field?.references.allSatisfy { $0.sourceID == record.sources.first.id } == true
            }
        })

        #expect(RecordQuery.search(scenario.searchTerm, records: records, members: members).count == 96)
        let memberSearch = RecordQuery.search(scenario.memberSearchTerm, records: records, members: members)
        #expect(memberSearch.count == 24)
        #expect(memberSearch.allSatisfy { $0.memberID == members[0].id })
        #expect(RecordQuery.search(scenario.organizationSearchTerm, records: records, members: members).count == 96)
        #expect(RecordQuery.search(scenario.dateSearchTerm, records: records, members: members).count == 1)
        let comparison = try RecordComparison(records: Array(records.prefix(2)))
        #expect(comparison.left.conclusion != .notProvided)
        #expect(comparison.right.conclusion != .notProvided)

        let libraryID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        #expect(scenario.summarySHA256(libraryID: libraryID) == scenario.summarySHA256(libraryID: libraryID))
        #expect(scenario.summarySHA256(libraryID: libraryID) != scenario.summarySHA256(libraryID: UUID()))
    }

    @Test
    func runnerSeedsTheSQLiteLibraryPersistsAcrossRestartsAndRemovesItsOwnedRun() async throws {
        let support = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("kinlogue-acceptance-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.kinlogue.mac.acceptance.\(runID)",
            AppRuntimeIdentity.acceptanceEnabledInfoKey: true,
            AppRuntimeIdentity.acceptanceRunIDInfoKey: runID,
        ]

        let reportPhases: [AcceptanceSmokePhase] = [
            .claim,
            .seed,
            .restart,
            .lanReceiver,
            .lanReceiverRestart,
            .forcedReady,
            .afterForce,
            .cleanup,
        ]
        for phase in reportPhases {
            let entry = AcceptanceSmokeEntry.resolve(
                bundleInfo: info,
                arguments: [
                    "Kinlogue",
                    AppRuntimeIdentity.syntheticSmokeArgument,
                    phase.argument,
                ],
                trustedApplicationSupportDirectory: support
            )
            let request = try #require(entry.request)
            let disposition = await SyntheticAcceptanceRunner(request: request).run()
            if phase == .forcedReady {
                #expect(disposition == .holdForForcedTermination)
                // The phase leaves the library open for the kill that follows. A second owner is
                // refused until this process lets go, which the installed run does by dying.
                let second = await SyntheticAcceptanceRunner(request: request).run()
                #expect(second == .exit(SyntheticAcceptanceRunner.failureExitCode))
                await SyntheticAcceptanceRunner.releaseForcedTerminationHoldForTesting()
            } else {
                #expect(disposition == .exit(SyntheticAcceptanceRunner.successExitCode))
            }
            if phase == .seed {
                let root = try #require(entry.request).identity.sourceVault.rootURL
                #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(SQLiteLibraryStore.databaseFilename).path))
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("originals").path).count == 96)
            }
        }

        let runRoot = support
            .appendingPathComponent("Kinlogue", isDirectory: true)
            .appendingPathComponent("Acceptance", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: runRoot.path))
    }

    @Test
    func eventEncodingNeverIncludesRuntimeSecretsOrPaths() throws {
        let scenario = try SyntheticAcceptanceScenario.make(runID: runID)
        let event = AcceptanceSmokeEvent(
            code: .seedComplete,
            ok: true,
            memberCount: scenario.memberNames.count,
            recordCount: scenario.reports.count,
            attachmentCount: scenario.reports.count,
            summarySHA256: scenario.summarySHA256(libraryID: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!),
            targetedRetrievalUnderThirtySeconds: true,
            tokenSetSHA256: scenario.tokenSetSHA256
        )
        let encoded = try event.encodedLine()

        #expect(scenario.scanTokens.allSatisfy { !encoded.contains($0) })
        #expect(!encoded.contains(scenario.memberNames[0]))
        #expect(!encoded.contains(scenario.conclusions[0]))
        #expect(!encoded.contains("/Users/"))
        #expect(!encoded.contains(runID))

        let object = try JSONSerialization.jsonObject(
            with: Data(encoded.utf8)
        ) as? [String: Any]
        #expect(object?["targetedRetrievalUnderThirtySeconds"] as? Bool == true)
        #expect(Set(object?.keys.map { $0 } ?? []) == [
            "attachmentCount",
            "code",
            "memberCount",
            "ok",
            "recordCount",
            "summarySHA256",
            "targetedRetrievalUnderThirtySeconds",
            "tokenSetSHA256",
        ])
    }
}
