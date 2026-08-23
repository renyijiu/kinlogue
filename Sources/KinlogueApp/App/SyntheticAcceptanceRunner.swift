import Darwin
import Foundation
import KinlogueCore
import KinloguePlatform

enum AcceptanceSmokeEventCode: String, Codable, Sendable {
    case claimComplete = "KLA_CLAIM_COMPLETE"
    case seedComplete = "KLA_SEED_COMPLETE"
    case restartComplete = "KLA_RESTART_COMPLETE"
    case forcedReady = "KLA_FORCED_READY"
    case afterForceComplete = "KLA_AFTER_FORCE_COMPLETE"
    case cleanupComplete = "KLA_CLEANUP_COMPLETE"
    case failed = "KLA_FAILED"
}

struct AcceptanceSmokeEvent: Codable, Equatable, Sendable {
    let code: AcceptanceSmokeEventCode
    let ok: Bool
    let memberCount: Int
    let recordCount: Int
    let attachmentCount: Int
    let summarySHA256: String
    let targetedRetrievalUnderThirtySeconds: Bool
    let tokenSetSHA256: String

    func encodedLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    func emit() {
        guard let line = try? encodedLine(),
              let bytes = (line + "\n").data(using: .utf8) else { return }
        FileHandle.standardOutput.write(bytes)
    }
}

struct SyntheticAcceptanceTarget: Equatable, Sendable {
    let memberID: FamilyMember.ID
    let memberName: String
    let recordID: HealthRecord.ID
    let attachmentID: Attachment.ID
    let reportDate: Date
    let organization: String

    func matches(
        _ record: HealthRecord,
        resolvedMemberID: FamilyMember.ID
    ) -> Bool {
        record.memberID == resolvedMemberID
            && record.timelineDate == reportDate
            && record.organization?.transcription == organization
    }
}

enum AcceptanceSmokeRunDisposition: Equatable, Sendable {
    case exit(Int32)
    case holdForForcedTermination
}

enum SyntheticAcceptanceError: Error, Equatable, Sendable {
    case invariantFailed
    case unsafeCleanupTarget
}

struct SyntheticAcceptanceScenario: Sendable {
    static let expectedMemberCount = 4
    static let recordsPerMember = 24
    static let expectedRecordCount = expectedMemberCount * recordsPerMember
    static let targetOrdinal = recordsPerMember * 2 + 11

    let catalog: VaultCatalog
    let originals: [Attachment.ID: Data]
    let canary: String
    let originalMagic: String
    let scanTokens: [String]
    let memberNames: [String]
    let conclusions: [String]
    let searchTerm: String
    let memberSearchTerm: String
    let organizationSearchTerm: String
    let dateSearchTerm: String
    let target: SyntheticAcceptanceTarget
    let summarySHA256: String
    let tokenSetSHA256: String

    static func make(
        runID: String,
        vaultID: UUID,
        generation: UInt64
    ) throws -> Self {
        let canary = derivedToken(
            prefixScalars: [0x4B, 0x4C, 0x41, 0x2D],
            domain: "kinlogue.acceptance.canary.v1",
            runID: runID
        )
        let originalMagic = derivedToken(
            prefixScalars: [0x4B, 0x4C, 0x4F, 0x2D],
            domain: "kinlogue.acceptance.original.v1",
            runID: runID
        )
        let memberToken = derivedToken(
            prefixScalars: [0x4B, 0x4C, 0x4D, 0x2D],
            domain: "kinlogue.acceptance.member.v1",
            runID: runID
        )
        let titleToken = derivedToken(
            prefixScalars: [0x4B, 0x4C, 0x54, 0x2D],
            domain: "kinlogue.acceptance.title.v1",
            runID: runID
        )
        let organizationToken = derivedToken(
            prefixScalars: [0x4B, 0x4C, 0x48, 0x2D],
            domain: "kinlogue.acceptance.organization.v1",
            runID: runID
        )
        let dateSourceToken = derivedToken(
            prefixScalars: [0x4B, 0x4C, 0x44, 0x2D],
            domain: "kinlogue.acceptance.date-source.v1",
            runID: runID
        )
        let conclusionToken = derivedToken(
            prefixScalars: [0x4B, 0x4C, 0x43, 0x2D],
            domain: "kinlogue.acceptance.conclusion.v1",
            runID: runID
        )
        let scanTokens = [
            canary,
            originalMagic,
            memberToken,
            titleToken,
            organizationToken,
            dateSourceToken,
            conclusionToken,
        ]
        let nameStem = unicodeString([0x7EED, 0x9875, 0x9A8C, 0x6536, 0x6210, 0x5458])
        let conclusionStem = unicodeString([0x5408, 0x6210, 0x62A5, 0x544A, 0x7ED3, 0x8BBA])
        let titleStem = unicodeString([0x672C, 0x673A, 0x9A8C, 0x6536, 0x62A5, 0x544A])
        let organizationStem = unicodeString([0x5408, 0x6210, 0x673A, 0x6784])
        let organizationSearchTerm = organizationStem + " " + organizationToken

        var members: [FamilyMember] = []
        var memberNames: [String] = []
        for memberIndex in 0..<expectedMemberCount {
            let memberID = AcceptanceFixtureIdentity.deterministicUUID(
                domain: "member",
                runID: runID,
                ordinal: memberIndex
            )
            let name = nameStem + String(memberIndex + 1) + " " + memberToken
            members.append(try FamilyMember(id: memberID, displayName: name))
            memberNames.append(name)
        }

        var records: [HealthRecord] = []
        var attachments: [Attachment] = []
        var originals: [Attachment.ID: Data] = [:]
        var conclusions: [String] = []
        let dateFormatter = ISO8601DateFormatter()
        for memberIndex in 0..<expectedMemberCount {
            for recordIndex in 0..<recordsPerMember {
                let ordinal = memberIndex * recordsPerMember + recordIndex
                let attachmentID = AcceptanceFixtureIdentity.deterministicUUID(
                    domain: "attachment",
                    runID: runID,
                    ordinal: ordinal
                )
                let recordID = AcceptanceFixtureIdentity.deterministicUUID(
                    domain: "record",
                    runID: runID,
                    ordinal: ordinal
                )
                let dateID = AcceptanceFixtureIdentity.deterministicUUID(
                    domain: "date",
                    runID: runID,
                    ordinal: ordinal
                )
                let reportDate = Date(
                    timeIntervalSince1970: 1_700_000_000
                        + TimeInterval(
                            (recordIndex * 32 + memberIndex) * 86_400
                        )
                )
                let organization = organizationSearchTerm
                    + " " + String((ordinal % 3) + 1)
                let conclusion = conclusionStem
                    + " " + String(memberIndex + 1)
                    + "-" + String(recordIndex + 1)
                    + " " + conclusionToken
                let original = makePDF(
                    text: originalMagic + " " + canary + " " + String(ordinal)
                )
                let attachment = try Attachment(
                    id: attachmentID,
                    contentTypeIdentifier: "com.adobe.pdf",
                    byteCount: original.count,
                    sha256Digest: ContentDigest.sha256(original)
                )
                let sourceReference = try SourceReference(pageNumber: 1)
                let dateCandidate = ReportDateCandidate(
                    id: dateID,
                    date: reportDate,
                    kind: .report,
                    source: try SourceField(
                        originalTranscription: dateFormatter.string(from: reportDate)
                            + " " + dateSourceToken,
                        references: [sourceReference]
                    )
                )
                let record = try HealthRecord(
                    id: recordID,
                    memberID: members[memberIndex].id,
                    attachmentID: attachmentID,
                    importState: .confirmed,
                    title: try SourceField(
                        originalTranscription: titleStem + " " + String(ordinal + 1)
                            + " " + titleToken,
                        references: [sourceReference]
                    ),
                    organization: try SourceField(
                        originalTranscription: organization,
                        references: [sourceReference]
                    ),
                    reportType: try SourceField(
                        originalTranscription: titleStem + " " + titleToken,
                        references: [sourceReference]
                    ),
                    dateCandidates: [dateCandidate],
                    timelineDateCandidateID: dateID,
                    conclusion: try SourceField(
                        originalTranscription: conclusion,
                        references: [sourceReference]
                    )
                )
                attachments.append(attachment)
                records.append(record)
                originals[attachmentID] = original
                conclusions.append(conclusion)
            }
        }

        let catalog = try VaultCatalog(
            vaultID: vaultID,
            generation: generation,
            members: members,
            records: records,
            attachments: attachments
        )
        let targetRecord = records[targetOrdinal]
        let targetMember = members[targetOrdinal / recordsPerMember]
        guard targetRecord.memberID == targetMember.id,
              let targetDate = targetRecord.timelineDate,
              let targetOrganization = targetRecord.organization?.transcription,
              let targetAttachmentID = targetRecord.soleAttachmentID else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        return Self(
            catalog: catalog,
            originals: originals,
            canary: canary,
            originalMagic: originalMagic,
            scanTokens: scanTokens,
            memberNames: memberNames,
            conclusions: conclusions,
            searchTerm: conclusionToken,
            memberSearchTerm: memberNames[0],
            organizationSearchTerm: organizationSearchTerm,
            dateSearchTerm: dateFormatter.string(
                from: records[0].timelineDate ?? .distantPast
            ),
            target: SyntheticAcceptanceTarget(
                memberID: targetRecord.memberID,
                memberName: targetMember.displayName,
                recordID: targetRecord.id,
                attachmentID: targetAttachmentID,
                reportDate: targetDate,
                organization: targetOrganization
            ),
            summarySHA256: summaryDigest(for: catalog),
            tokenSetSHA256: tokenSetDigest(tokens: scanTokens)
        )
    }

    private static func derivedToken(
        prefixScalars: [UInt8],
        domain: String,
        runID: String
    ) -> String {
        var input = Data(domain.utf8)
        input.append(0)
        input.append(contentsOf: runID.utf8)
        return String(decoding: prefixScalars, as: UTF8.self)
            + ContentDigest.sha256(input).hexadecimalString
    }

    private static func unicodeString(_ scalars: [UInt32]) -> String {
        String(scalars.compactMap { UnicodeScalar($0) }.map(Character.init))
    }
}

enum AcceptanceFixtureIdentity {
    static func deterministicUUID(
        domain: String,
        runID: String,
        ordinal: Int
    ) -> UUID {
        var input = Data("kinlogue.acceptance.uuid.v1".utf8)
        input.append(0)
        input.append(contentsOf: domain.utf8)
        input.append(0)
        input.append(contentsOf: runID.utf8)
        input.append(0)
        input.append(contentsOf: String(ordinal).utf8)
        var bytes = Array(ContentDigest.sha256(input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private extension SyntheticAcceptanceScenario {
    private static func makePDF(text: String) -> Data {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        let stream = "BT\n/F1 12 Tf\n72 720 Td\n(" + escaped + ") Tj\nET\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                + "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length " + String(stream.utf8.count) + " >>\nstream\n"
                + stream + "endstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]

        var output = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A])
        output.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = [0]
        for (index, body) in objects.enumerated() {
            offsets.append(output.count)
            output.append(contentsOf: "\(index + 1) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let crossReferenceOffset = output.count
        output.append(contentsOf: "xref\n0 \(objects.count + 1)\n".utf8)
        output.append(contentsOf: "0000000000 65535 f \n".utf8)
        for offset in offsets.dropFirst() {
            output.append(contentsOf: String(format: "%010d 00000 n \n", offset).utf8)
        }
        output.append(contentsOf: (
            "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
                + "startxref\n\(crossReferenceOffset)\n%%EOF\n"
        ).utf8)
        return output
    }

    private static func summaryDigest(for catalog: VaultCatalog) -> String {
        var input = Data("kinlogue.acceptance.summary.v1".utf8)
        var vaultUUID = catalog.vaultID.uuid
        Swift.withUnsafeBytes(of: &vaultUUID) { input.append(contentsOf: $0) }
        input.append(contentsOf: String(catalog.generation).utf8)
        input.append(0)
        for attachment in catalog.attachments {
            var attachmentUUID = attachment.id.uuid
            Swift.withUnsafeBytes(of: &attachmentUUID) { input.append(contentsOf: $0) }
            input.append(attachment.sha256Digest)
        }
        return ContentDigest.sha256(input).hexadecimalString
    }

    private static func tokenSetDigest(tokens: [String]) -> String {
        var input = Data()
        for (index, token) in tokens.enumerated() {
            if index > 0 { input.append(0) }
            input.append(contentsOf: token.utf8)
        }
        return ContentDigest.sha256(input).hexadecimalString
    }
}

struct SyntheticAcceptanceRunner: Sendable {
    static let successExitCode: Int32 = 0
    static let failureExitCode: Int32 = 70

    let request: AcceptanceSmokeRequest

    func run() async -> AcceptanceSmokeRunDisposition {
        do {
            switch request.phase {
            case .claim:
                try claim()
            case .seed:
                try await seed()
            case .restart:
                try await verifyAfterRestart(code: .restartComplete)
            case .dicomImport, .dicomRestart, .dicomDelete:
                try await DICOMInstalledAcceptanceRunner(request: request).run()
            case .lanReceiver:
                try await runLANReceiverProbe()
            case .lanReceiverRestart:
                try await verifyLANReceiverAfterProcessRestart()
            case .forcedReady:
                try await verifyAfterRestart(code: .forcedReady)
                return .holdForForcedTermination
            case .afterForce:
                try await verifyAfterRestart(code: .afterForceComplete)
            case .cleanup:
                try await cleanup()
            }
            return .exit(Self.successExitCode)
        } catch let error as InstalledLANAcceptanceProbeError {
            try? InstalledLANAcceptanceFailureEvent(error: error).emit()
            return .exit(Self.failureExitCode)
        } catch let error as DICOMInstalledAcceptanceError {
            DICOMInstalledAcceptanceEvent.failed(
                step: error.step,
                metrics: error.failureMetrics
            ).emit()
            return .exit(Self.failureExitCode)
        } catch {
            AcceptanceSmokeEvent(
                code: .failed,
                ok: false,
                memberCount: 0,
                recordCount: 0,
                attachmentCount: 0,
                summarySHA256: String(repeating: "0", count: 64),
                targetedRetrievalUnderThirtySeconds: false,
                tokenSetSHA256: String(repeating: "0", count: 64)
            ).emit()
            return .exit(Self.failureExitCode)
        }
    }

    private func claim() throws {
        let runID = try acceptanceRunID()
        _ = try AcceptanceRunOwnership.claim(
            applicationSupportURL: try expectedApplicationSupportURL(runID: runID),
            runID: runID
        )
        AcceptanceSmokeEvent(
            code: .claimComplete,
            ok: true,
            memberCount: 0,
            recordCount: 0,
            attachmentCount: 0,
            summarySHA256: String(repeating: "0", count: 64),
            targetedRetrievalUnderThirtySeconds: false,
            tokenSetSHA256: String(repeating: "0", count: 64)
        ).emit()
    }

    private func seed() async throws {
        let runID = try acceptanceRunID()
        _ = try loadRunOwnership(runID: runID)
        let sourceVault = try makeVault(identity: request.identity.sourceVault)
        guard await sourceVault.inspect() == .absent else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let initial = try await sourceVault.initialize()
        let scenario = try SyntheticAcceptanceScenario.make(
            runID: runID,
            vaultID: initial.vaultID,
            generation: try VaultGeneration.successor(of: initial.generation)
        )
        let writes = try scenario.catalog.attachments.map { attachment in
            guard let original = scenario.originals[attachment.id] else {
                throw SyntheticAcceptanceError.invariantFailed
            }
            return VaultObjectWrite(
                reference: VaultObjectReference(id: attachment.id, kind: .attachment),
                plaintext: original
            )
        }
        _ = try await sourceVault.commit(VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: scenario.catalog,
            writes: writes
        ))
        let verified = try await verify(vault: sourceVault, runID: runID)

        verified.event(code: .seedComplete).emit()
    }

    private func verifyAfterRestart(code: AcceptanceSmokeEventCode) async throws {
        let runID = try acceptanceRunID()
        _ = try loadRunOwnership(runID: runID)
        let source = try makeVault(identity: request.identity.sourceVault)
        let verified = try await verify(vault: source, runID: runID)
        verified.event(code: code).emit()
    }

    private func runLANReceiverProbe() async throws {
        let runID = try acceptanceRunID()
        _ = try loadRunOwnership(runID: runID)
        guard let executableURL = Bundle.main.executableURL else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        try await InstalledLANAcceptanceProbe(
            rootURL: request.identity.sourceVault.rootURL,
            runID: runID,
            executableURL: executableURL
        ).run().emit()
    }

    private func verifyLANReceiverAfterProcessRestart() async throws {
        let runID = try acceptanceRunID()
        _ = try loadRunOwnership(runID: runID)
        guard let executableURL = Bundle.main.executableURL else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        try await InstalledLANAcceptanceProbe(
            rootURL: request.identity.sourceVault.rootURL,
            runID: runID,
            executableURL: executableURL
        ).verifyAfterProcessRestart().emit()
    }

    private func cleanup() async throws {
        let runID = try acceptanceRunID()
        let ownership = try loadRunOwnership(runID: runID)
        let source = try makeVault(identity: request.identity.sourceVault)
        switch await source.inspect() {
        case .ready:
            try await source.destroy()
        case .absent:
            break
        case .operationInProgress, .legacyEncrypted, .damaged, .unsupportedVersion:
            throw SyntheticAcceptanceError.invariantFailed
        }
        guard await source.inspect() == .absent else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        try ownership.releaseAfterVaultRemoval()
        AcceptanceSmokeEvent(
            code: .cleanupComplete,
            ok: true,
            memberCount: 0,
            recordCount: 0,
            attachmentCount: 0,
            summarySHA256: String(repeating: "0", count: 64),
            targetedRetrievalUnderThirtySeconds: false,
            tokenSetSHA256: String(repeating: "0", count: 64)
        ).emit()
    }

    private func verify(
        vault: PlaintextVault,
        runID: String
    ) async throws -> VerificationSummary {
        let targetedClock = ContinuousClock()
        let targetedStart = targetedClock.now
        let catalog = try await vault.loadCatalog()
        let expected = try SyntheticAcceptanceScenario.make(
            runID: runID,
            vaultID: catalog.vaultID,
            generation: catalog.generation
        )
        let targetedMembers = catalog.members.filter {
            $0.displayName == expected.target.memberName
        }
        guard targetedMembers.count == 1,
              let targetedMember = targetedMembers.first,
              targetedMember.id == expected.target.memberID else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let targetedRecords = catalog.records.filter {
            expected.target.matches(
                $0,
                resolvedMemberID: targetedMember.id
            )
        }
        let targetedAttachments = catalog.attachments.filter {
            $0.id == expected.target.attachmentID
        }
        guard targetedRecords.count == 1,
              let targetedRecord = targetedRecords.first,
              targetedRecord.id == expected.target.recordID,
              targetedRecord.soleAttachmentID == expected.target.attachmentID,
              targetedAttachments.count == 1,
              let targetedAttachment = targetedAttachments.first,
              targetedAttachment.id == targetedRecord.soleAttachmentID,
              let expectedTargetOriginal = expected.originals[targetedAttachment.id] else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let targetedOriginal = try await vault.readObject(
            VaultObjectReference(
                id: targetedAttachment.id,
                kind: .attachment
            )
        )
        let targetedDigest = ContentDigest.sha256(targetedOriginal)
        guard targetedOriginal == expectedTargetOriginal,
              targetedDigest == targetedAttachment.sha256Digest else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let targetedRetrievalUnderThirtySeconds = targetedStart.duration(
            to: targetedClock.now
        ) <= .seconds(30)
        guard targetedRetrievalUnderThirtySeconds else {
            throw SyntheticAcceptanceError.invariantFailed
        }

        guard catalog == expected.catalog else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let search = RecordQuery.search(
            expected.searchTerm,
            records: catalog.records,
            members: catalog.members
        )
        guard search.count == SyntheticAcceptanceScenario.expectedRecordCount else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let memberSearch = RecordQuery.search(
            expected.memberSearchTerm,
            records: catalog.records,
            members: catalog.members
        )
        guard memberSearch.count == SyntheticAcceptanceScenario.recordsPerMember,
              memberSearch.allSatisfy({
                  $0.memberID == expected.catalog.members[0].id
              }) else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let organizationSearch = RecordQuery.search(
            expected.organizationSearchTerm,
            records: catalog.records,
            members: catalog.members
        )
        guard organizationSearch.count
                == SyntheticAcceptanceScenario.expectedRecordCount else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let dateSearch = RecordQuery.search(
            expected.dateSearchTerm,
            records: catalog.records,
            members: catalog.members
        )
        guard dateSearch.count == 1 else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        for member in catalog.members {
            let timeline = RecordQuery.timeline(
                records: catalog.records,
                memberID: member.id
            )
            guard timeline.count == SyntheticAcceptanceScenario.recordsPerMember,
                  timeline.allSatisfy({ section in
                      if case .dated = section.group { return section.records.count == 1 }
                      return false
                  }) else {
                throw SyntheticAcceptanceError.invariantFailed
            }
        }
        let comparison = try RecordComparison(records: Array(catalog.records.prefix(2)))
        guard comparison.left.conclusion != .notProvided,
              comparison.right.conclusion != .notProvided else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        for attachment in catalog.attachments {
            guard let expectedOriginal = expected.originals[attachment.id] else {
                throw SyntheticAcceptanceError.invariantFailed
            }
            let original = try await vault.readObject(
                VaultObjectReference(id: attachment.id, kind: .attachment)
            )
            guard original == expectedOriginal,
                  ContentDigest.sha256(original) == attachment.sha256Digest else {
                throw SyntheticAcceptanceError.invariantFailed
            }
        }
        return VerificationSummary(
            memberCount: catalog.members.count,
            recordCount: catalog.records.count,
            attachmentCount: catalog.attachments.count,
            summarySHA256: expected.summarySHA256,
            targetedRetrievalUnderThirtySeconds: targetedRetrievalUnderThirtySeconds,
            tokenSetSHA256: expected.tokenSetSHA256
        )
    }

    private func makeVault(identity: RuntimeVaultIdentity) throws -> PlaintextVault {
        try PlaintextVault(rootURL: identity.rootURL)
    }

    private func acceptanceRunID() throws -> String {
        guard case let .acceptance(runID) = request.identity.mode else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        return runID
    }

    private func expectedRunRoot(runID: String) throws -> URL {
        let source = request.identity.sourceVault.rootURL.standardizedFileURL
        let runRoot = source.deletingLastPathComponent()
        let acceptanceRoot = runRoot.deletingLastPathComponent()
        let kinlogueRoot = acceptanceRoot.deletingLastPathComponent()
        guard source.lastPathComponent == "SourceVault",
              runRoot.lastPathComponent == runID,
              acceptanceRoot.lastPathComponent == "Acceptance",
              kinlogueRoot.lastPathComponent == "Kinlogue" else {
            throw SyntheticAcceptanceError.unsafeCleanupTarget
        }
        return runRoot
    }

    private func expectedApplicationSupportURL(runID: String) throws -> URL {
        try expectedRunRoot(runID: runID)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadRunOwnership(runID: String) throws -> AcceptanceRunOwnership {
        try AcceptanceRunOwnership.load(
            applicationSupportURL: expectedApplicationSupportURL(runID: runID),
            runID: runID
        )
    }
}

private struct VerificationSummary: Equatable, Sendable {
    let memberCount: Int
    let recordCount: Int
    let attachmentCount: Int
    let summarySHA256: String
    let targetedRetrievalUnderThirtySeconds: Bool
    let tokenSetSHA256: String

    func event(code: AcceptanceSmokeEventCode) -> AcceptanceSmokeEvent {
        AcceptanceSmokeEvent(
            code: code,
            ok: true,
            memberCount: memberCount,
            recordCount: recordCount,
            attachmentCount: attachmentCount,
            summarySHA256: summarySHA256,
            targetedRetrievalUnderThirtySeconds: targetedRetrievalUnderThirtySeconds,
            tokenSetSHA256: tokenSetSHA256
        )
    }
}

extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
