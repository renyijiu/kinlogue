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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinlogue-installed-lan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        _ = try await PlaintextVault(rootURL: root).initialize()
        let executable = try #require(Bundle.main.executableURL)
        let probe = InstalledLANAcceptanceProbe(
            rootURL: root,
            runID: runID,
            executableURL: executable
        )

        let receiver = try await probe.run()
        let restarted = try await probe.verifyAfterProcessRestart()

        #expect(receiver.ok)
        #expect(receiver.uniqueFilesStored)
        #expect(receiver.interruptedUploadCleanupVerified)
        #expect(restarted.completedFilesAfterProcessRestart)
        #expect(restarted.listenerAbsentAfterRestartStop)
    }

    @Test
    func generatedScenarioHasFourMembersAndTwentyFourConfirmedOriginalsEach() throws {
        let vaultID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        let scenario = try SyntheticAcceptanceScenario.make(
            runID: runID,
            vaultID: vaultID,
            generation: 2
        )

        #expect(scenario.catalog.members.count == 4)
        #expect(scenario.catalog.records.count == 96)
        #expect(scenario.catalog.attachments.count == 96)
        #expect(Set(scenario.catalog.records.map(\.memberID)).count == 4)
        let recordsByMember = Dictionary(
            grouping: scenario.catalog.records,
            by: \.memberID
        )
        #expect(recordsByMember.count == 4)
        #expect(recordsByMember.values.allSatisfy { $0.count == 24 })
        #expect(scenario.catalog.records.allSatisfy { $0.importState == .confirmed })
        #expect(scenario.originals.count == 96)
        #expect(scenario.scanTokens.count == 7)
        #expect(Set(scenario.scanTokens).count == scenario.scanTokens.count)
        #expect(
            scenario.tokenSetSHA256
                == "42197b855f8339ba1c0eedf7a8ddfa64a76e16730264022785faa3fcf628adc7"
        )
        #expect(scenario.originals.values.allSatisfy {
            $0.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D])
        })
        let firstOriginal = try #require(scenario.originals.values.first)
        #expect(PDFDocument(data: firstOriginal)?.pageCount == 1)

        let reportDates = scenario.catalog.records.compactMap(\.timelineDate)
        let earliestDate = try #require(reportDates.min())
        let latestDate = try #require(reportDates.max())
        let twoYearSpan = earliestDate.distance(to: latestDate)
        #expect(twoYearSpan >= 700 * 86_400)
        #expect(twoYearSpan <= 800 * 86_400)
        for member in scenario.catalog.members {
            let memberDates = scenario.catalog.records
                .filter { $0.memberID == member.id }
                .compactMap(\.timelineDate)
            let first = try #require(memberDates.min())
            let last = try #require(memberDates.max())
            #expect(first.distance(to: last) == 23 * 32 * 86_400)
        }

        let targetedMembers = scenario.catalog.members.filter {
            $0.displayName == scenario.target.memberName
        }
        let targetedMember = try #require(targetedMembers.first)
        #expect(targetedMembers.count == 1)
        #expect(targetedMember.id == scenario.target.memberID)
        let targetedRecords = scenario.catalog.records.filter {
            scenario.target.matches(
                $0,
                resolvedMemberID: targetedMember.id
            )
        }
        let targetedRecord = try #require(targetedRecords.first)
        #expect(targetedRecords.count == 1)
        #expect(targetedRecord.id == scenario.target.recordID)
        #expect(targetedRecord.memberID == scenario.target.memberID)
        #expect(targetedMember.displayName == scenario.target.memberName)
        #expect(targetedRecord.soleAttachmentID == scenario.target.attachmentID)
        #expect(targetedRecord.timelineDate == scenario.target.reportDate)
        #expect(
            targetedRecord.organization?.transcription
                == scenario.target.organization
        )
        let targetedAttachments = scenario.catalog.attachments.filter {
            $0.id == scenario.target.attachmentID
        }
        let targetedAttachment = try #require(targetedAttachments.first)
        #expect(targetedAttachments.count == 1)
        let targetedOriginal = try #require(
            scenario.originals[scenario.target.attachmentID]
        )
        #expect(
            Data(SHA256.hash(data: targetedOriginal))
                == targetedAttachment.sha256Digest
        )

        let search = RecordQuery.search(
            scenario.searchTerm,
            records: scenario.catalog.records,
            members: scenario.catalog.members
        )
        #expect(search.count == 96)

        let memberSearch = RecordQuery.search(
            scenario.memberSearchTerm,
            records: scenario.catalog.records,
            members: scenario.catalog.members
        )
        #expect(memberSearch.count == 24)
        #expect(memberSearch.allSatisfy {
            $0.memberID == scenario.catalog.members[0].id
        })
        #expect(RecordQuery.search(
            scenario.organizationSearchTerm,
            records: scenario.catalog.records,
            members: scenario.catalog.members
        ).count == 96)
        #expect(RecordQuery.search(
            scenario.dateSearchTerm,
            records: scenario.catalog.records,
            members: scenario.catalog.members
        ).count == 1)
        #expect(scenario.catalog.members.allSatisfy { member in
            RecordQuery.timeline(
                records: scenario.catalog.records,
                memberID: member.id
            ).count == 24
        })

        #expect(scenario.memberNames.allSatisfy { value in
            scenario.scanTokens.contains { value.contains($0) }
        })
        #expect(scenario.conclusions.allSatisfy { value in
            scenario.scanTokens.contains { value.contains($0) }
        })
        #expect(scenario.catalog.records.allSatisfy { record in
            let values = [
                record.title?.transcription,
                record.organization?.transcription,
                record.reportType?.transcription,
                record.dateCandidates.first?.source.transcription,
                record.conclusion?.transcription,
            ].compactMap { $0 }
            return values.allSatisfy { value in
                scenario.scanTokens.contains { value.contains($0) }
            }
        })

        let comparison = try RecordComparison(
            records: Array(scenario.catalog.records.prefix(2))
        )
        #expect(comparison.left.sources != comparison.right.sources)
        #expect(comparison.left.conclusion != .notProvided)
        #expect(comparison.right.conclusion != .notProvided)
    }

    @Test
    func plaintextRunnerPersistsAcrossRestartsAndRemovesItsOwnedRun() async throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("kinlogue-plaintext-runner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
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
            } else {
                #expect(disposition == .exit(SyntheticAcceptanceRunner.successExitCode))
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
        let scenario = try SyntheticAcceptanceScenario.make(
            runID: runID,
            vaultID: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!,
            generation: 2
        )
        let event = AcceptanceSmokeEvent(
            code: .seedComplete,
            ok: true,
            memberCount: scenario.catalog.members.count,
            recordCount: scenario.catalog.records.count,
            attachmentCount: scenario.catalog.attachments.count,
            summarySHA256: scenario.summarySHA256,
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
