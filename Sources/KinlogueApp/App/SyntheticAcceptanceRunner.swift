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
    let memberName: String
    let reportDate: Date
    let organization: String
    let originalDigest: Data

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

/// The library one acceptance run seeds and later verifies. Only its text and original bytes
/// are fixed in advance: the library assigns record, source and original identifiers when an
/// original is staged, so a report is recognised by the digest of its original.
struct SyntheticAcceptanceScenario: Sendable {
    static let expectedMemberCount = 4
    static let recordsPerMember = 24
    static let expectedRecordCount = expectedMemberCount * recordsPerMember
    static let targetOrdinal = recordsPerMember * 2 + 11

    struct Report: Sendable {
        let ordinal: Int
        let memberIndex: Int
        let original: Data
        let originalDigest: Data
        let title: String
        let organization: String
        let reportType: String
        let reportDate: Date
        let dateSource: String
        let dateCandidateID: UUID
        let conclusion: String

        /// The confirmed record for this report, built on the draft the library made for its original.
        func record(confirming draft: ImportDraft, memberID: FamilyMember.ID) throws -> HealthRecord {
            guard let source = draft.sources.soleSource else { throw SyntheticAcceptanceError.invariantFailed }
            let reference = try SourceReference(sourceID: source.id, attachmentID: source.attachmentID, filePageNumber: 1)
            func field(_ text: String) throws -> SourceField {
                try SourceField(originalTranscription: text, references: [reference])
            }
            return try HealthRecord(
                id: draft.id,
                memberID: memberID,
                sources: draft.sources,
                ocrDocumentObjectID: draft.documentObjectID,
                importState: .confirmed,
                title: try field(title),
                organization: try field(organization),
                reportType: try field(reportType),
                dateCandidates: [ReportDateCandidate(id: dateCandidateID, date: reportDate, kind: .report, source: try field(dateSource))],
                timelineDateCandidateID: dateCandidateID,
                conclusion: try field(conclusion)
            )
        }

        func matches(_ record: HealthRecord, memberID: FamilyMember.ID) -> Bool {
            record.importState == .confirmed && record.memberID == memberID
                && record.title?.transcription == title
                && record.organization?.transcription == organization
                && record.reportType?.transcription == reportType
                && record.timelineDate == reportDate
                && record.dateCandidates.map(\.source.transcription) == [dateSource]
                && record.conclusion?.transcription == conclusion
        }
    }

    let memberNames: [String]
    let reports: [Report]
    let canary: String
    let originalMagic: String
    let scanTokens: [String]
    let conclusions: [String]
    let searchTerm: String
    let memberSearchTerm: String
    let organizationSearchTerm: String
    let dateSearchTerm: String
    let target: SyntheticAcceptanceTarget
    let tokenSetSHA256: String

    static func make(runID: String) throws -> Self {
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

        let memberNames = (0..<expectedMemberCount).map { nameStem + String($0 + 1) + " " + memberToken }
        var reports: [Report] = []
        let dateFormatter = ISO8601DateFormatter()
        for memberIndex in 0..<expectedMemberCount {
            for recordIndex in 0..<recordsPerMember {
                let ordinal = memberIndex * recordsPerMember + recordIndex
                let reportDate = Date(
                    timeIntervalSince1970: 1_700_000_000
                        + TimeInterval(
                            (recordIndex * 32 + memberIndex) * 86_400
                        )
                )
                let original = makePDF(
                    text: originalMagic + " " + canary + " " + String(ordinal)
                )
                reports.append(Report(
                    ordinal: ordinal,
                    memberIndex: memberIndex,
                    original: original,
                    originalDigest: ContentDigest.sha256(original),
                    title: titleStem + " " + String(ordinal + 1) + " " + titleToken,
                    organization: organizationSearchTerm + " " + String((ordinal % 3) + 1),
                    reportType: titleStem + " " + titleToken,
                    reportDate: reportDate,
                    dateSource: dateFormatter.string(from: reportDate) + " " + dateSourceToken,
                    dateCandidateID: AcceptanceFixtureIdentity.deterministicUUID(domain: "date", runID: runID, ordinal: ordinal),
                    conclusion: conclusionStem + " " + String(memberIndex + 1) + "-" + String(recordIndex + 1)
                        + " " + conclusionToken
                ))
            }
        }
        let targetReport = reports[targetOrdinal]
        return Self(
            memberNames: memberNames,
            reports: reports,
            canary: canary,
            originalMagic: originalMagic,
            scanTokens: scanTokens,
            conclusions: reports.map(\.conclusion),
            searchTerm: conclusionToken,
            memberSearchTerm: memberNames[0],
            organizationSearchTerm: organizationSearchTerm,
            dateSearchTerm: dateFormatter.string(from: reports[0].reportDate),
            target: SyntheticAcceptanceTarget(
                memberName: memberNames[targetReport.memberIndex],
                reportDate: targetReport.reportDate,
                organization: targetReport.organization,
                originalDigest: targetReport.originalDigest
            ),
            tokenSetSHA256: tokenSetDigest(tokens: scanTokens)
        )
    }

    /// Identifies the seeded library across process restarts: its identity and the originals
    /// of its confirmed reports. Later commits that leave both alone do not change it.
    func summarySHA256(libraryID: UUID) -> String {
        var input = Data("kinlogue.acceptance.summary.v2".utf8)
        var libraryUUID = libraryID.uuid
        Swift.withUnsafeBytes(of: &libraryUUID) { input.append(contentsOf: $0) }
        for report in reports { input.append(report.originalDigest) }
        return ContentDigest.sha256(input).hexadecimalString
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

    private static func tokenSetDigest(tokens: [String]) -> String {
        var input = Data()
        for (index, token) in tokens.enumerated() {
            if index > 0 { input.append(0) }
            input.append(contentsOf: token.utf8)
        }
        return ContentDigest.sha256(input).hexadecimalString
    }
}

/// The SQLite library of one acceptance run, opened through the launch path the app uses.
@MainActor
struct AcceptanceLibrary {
    let launch: LibraryLaunchCoordinator
    let services: LiveAppServiceEnvironment
    let store: SQLiteLibraryStore

    static func open(identity: AppRuntimeIdentity) async throws -> Self {
        let launch = LibraryLaunchCoordinator(identity: identity)
        launch.acknowledgeStorageDisclosure()
        do {
            let services = try await launch.openEnvironment()
            guard let store = launch.database else { throw SyntheticAcceptanceError.invariantFailed }
            _ = try await services.dataService.bootstrap()
            // Reaching a usable library must not have read any original.
            guard store.originalReadMetrics.verifiedReadByteCount == 0 else { throw SyntheticAcceptanceError.invariantFailed }
            return Self(launch: launch, services: services, store: store)
        } catch {
            await launch.shutdown()
            throw error
        }
    }

    /// Releases the owner and closes the database; a phase that returns leaves nothing open.
    func close() async { await launch.shutdown() }

    /// Runs `body` on the opened library and closes it whether or not `body` succeeds.
    static func with<Result: Sendable>(
        identity: AppRuntimeIdentity,
        _ body: @MainActor (AcceptanceLibrary) async throws -> Result
    ) async throws -> Result {
        let library = try await open(identity: identity)
        do {
            let result = try await body(library)
            await library.close()
            return result
        } catch {
            await library.close()
            throw error
        }
    }
}

/// Opens at most one library for an acceptance phase and closes it when the phase ends.
@MainActor
final class AcceptanceLibrarySession {
    private var opened: AcceptanceLibrary?

    func library(identity: AppRuntimeIdentity) async throws -> AcceptanceLibrary {
        if let opened { return opened }
        let library = try await AcceptanceLibrary.open(identity: identity)
        opened = library
        return library
    }

    func close() async {
        await opened?.close()
        opened = nil
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
                try await holdOpenLibraryForForcedTermination()
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

    /// Seeds through the services the app uses: members by the data service, and each report by
    /// staging its original, recording a recognised document and confirming the draft.
    private func seed() async throws {
        let runID = try acceptanceRunID()
        _ = try loadRunOwnership(runID: runID)
        guard !FileManager.default.fileExists(atPath: request.identity.sourceVault.rootURL.path) else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let scenario = try SyntheticAcceptanceScenario.make(runID: runID)
        let verified = try await AcceptanceLibrary.with(identity: request.identity) { library in
            let service = library.services.dataService
            guard try await service.refresh().members.isEmpty else { throw SyntheticAcceptanceError.invariantFailed }
            var memberIDs: [UUID] = []
            for name in scenario.memberNames {
                let header = try await service.createMember(displayName: name, disambiguationLabel: nil)
                guard let member = header.members.first(where: { $0.displayName == name }) else {
                    throw SyntheticAcceptanceError.invariantFailed
                }
                memberIDs.append(member.id)
            }
            let reports = SQLiteReportRepository(store: library.store)
            for report in scenario.reports {
                let file = try ValidatedImportedFile(data: report.original, kind: .pdf, contentTypeIdentifier: "com.adobe.pdf",
                                                     sha256Digest: report.originalDigest, pageCount: 1)
                guard case .created(let draftID) = try await reports.stage(file) else {
                    throw SyntheticAcceptanceError.invariantFailed
                }
                let lease = try await reports.beginProcessing(draftID: draftID, attemptID: UUID())
                try await reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
                let draft = try await reports.draft(draftID)
                try await reports.confirm(draftID: draftID, expectedRevision: draft.revision,
                                          record: report.record(confirming: draft, memberID: memberIDs[report.memberIndex]))
            }
            return try await verify(library, runID: runID)
        }
        verified.event(code: .seedComplete).emit()
    }

    private func verifyAfterRestart(code: AcceptanceSmokeEventCode) async throws {
        let runID = try acceptanceRunID()
        _ = try loadRunOwnership(runID: runID)
        let verified = try await AcceptanceLibrary.with(identity: request.identity) { try await verify($0, runID: runID) }
        verified.event(code: code).emit()
    }

    /// Verifies the library and then keeps it open, with the owner lock held, so the forced
    /// termination that follows interrupts a process that still owns the database.
    private func holdOpenLibraryForForcedTermination() async throws {
        let runID = try acceptanceRunID()
        _ = try loadRunOwnership(runID: runID)
        let library = try await AcceptanceLibrary.open(identity: request.identity)
        do {
            let verified = try await verify(library, runID: runID)
            await ForcedTerminationHold.shared.keep(library)
            verified.event(code: .forcedReady).emit()
        } catch {
            await library.close()
            throw error
        }
    }

    private func runLANReceiverProbe() async throws {
        let runID = try acceptanceRunID()
        _ = try loadRunOwnership(runID: runID)
        guard let executableURL = Bundle.main.executableURL else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        try await InstalledLANAcceptanceProbe(
            identity: request.identity,
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
            identity: request.identity,
            runID: runID,
            executableURL: executableURL
        ).verifyAfterProcessRestart().emit()
    }

    private func cleanup() async throws {
        let runID = try acceptanceRunID()
        let ownership = try loadRunOwnership(runID: runID)
        let root = request.identity.sourceVault.rootURL
        if FileManager.default.fileExists(atPath: root.path) {
            try await AcceptanceLibrary.with(identity: request.identity) { library in
                try await library.services.destroyService.destroyCurrentVault()
            }
        }
        guard !FileManager.default.fileExists(atPath: root.path) else {
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

    /// Reads the library back through the data service: the targeted lookup a user would do
    /// first, then every report, its original bytes, search, timelines and a comparison.
    @MainActor
    private func verify(_ library: AcceptanceLibrary, runID: String) async throws -> VerificationSummary {
        let service = library.services.dataService
        let expected = try SyntheticAcceptanceScenario.make(runID: runID)
        let targetedClock = ContinuousClock()
        let targetedStart = targetedClock.now
        let header = try await service.refresh()
        let targetedMembers = header.members.filter { $0.displayName == expected.target.memberName }
        guard targetedMembers.count == 1, let targetedMember = targetedMembers.first else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let targetedSummaries = try await reports(service, query: expected.organizationSearchTerm, memberID: targetedMember.id)
            .filter { $0.timelineDate == expected.target.reportDate }
        guard targetedSummaries.count == 1, let targetedSummary = targetedSummaries.first else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let targetedSelection = try await service.loadRecords(ids: [targetedSummary.id])
        guard let targetedRecord = targetedSelection.records.first,
              expected.target.matches(targetedRecord, resolvedMemberID: targetedMember.id),
              let targetedSource = targetedRecord.sources.soleSource else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let targetedOriginal = try await service.loadOriginal(
            recordID: targetedRecord.id, sourceID: targetedSource.id,
            expectedRevision: targetedRecord.revision, expectedLibrary: targetedSelection.revision
        )
        guard targetedOriginal.data == expected.reports[SyntheticAcceptanceScenario.targetOrdinal].original,
              ContentDigest.sha256(targetedOriginal.data) == expected.target.originalDigest else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let targetedRetrievalUnderThirtySeconds = targetedStart.duration(
            to: targetedClock.now
        ) <= .seconds(30)
        guard targetedRetrievalUnderThirtySeconds else {
            throw SyntheticAcceptanceError.invariantFailed
        }

        var memberIDsByName: [String: UUID] = [:]
        for member in header.members { memberIDsByName[member.displayName] = member.id }
        guard header.members.count == SyntheticAcceptanceScenario.expectedMemberCount,
              Set(memberIDsByName.keys) == Set(expected.memberNames),
              header.reportCount == SyntheticAcceptanceScenario.expectedRecordCount else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        var reportsByDigest: [Data: SyntheticAcceptanceScenario.Report] = [:]
        for report in expected.reports { reportsByDigest[report.originalDigest] = report }
        let summaries = try await reports(service, query: "", memberID: nil)
        guard summaries.count == SyntheticAcceptanceScenario.expectedRecordCount else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        var verifiedOrdinals: Set<Int> = []
        var records: [HealthRecord] = []
        // The detail read serves an open record or a comparison, so it takes one record at a time here.
        for summary in summaries {
            let selection = try await service.loadRecords(ids: [summary.id])
            guard let record = selection.records.first, selection.records.count == 1,
                  let source = record.sources.soleSource else { throw SyntheticAcceptanceError.invariantFailed }
            let original = try await service.loadOriginal(
                recordID: record.id, sourceID: source.id,
                expectedRevision: record.revision, expectedLibrary: selection.revision
            )
            guard let report = reportsByDigest[ContentDigest.sha256(original.data)],
                  original.data == report.original,
                  let memberID = memberIDsByName[expected.memberNames[report.memberIndex]],
                  report.matches(record, memberID: memberID),
                  verifiedOrdinals.insert(report.ordinal).inserted else {
                throw SyntheticAcceptanceError.invariantFailed
            }
            records.append(record)
        }
        guard verifiedOrdinals.count == SyntheticAcceptanceScenario.expectedRecordCount else {
            throw SyntheticAcceptanceError.invariantFailed
        }

        guard try await reports(service, query: expected.searchTerm, memberID: nil).count
                == SyntheticAcceptanceScenario.expectedRecordCount else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        let memberSearch = try await reports(service, query: expected.memberSearchTerm, memberID: nil)
        guard memberSearch.count == SyntheticAcceptanceScenario.recordsPerMember,
              memberSearch.allSatisfy({ $0.memberID == memberIDsByName[expected.memberNames[0]] }) else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        guard try await reports(service, query: expected.organizationSearchTerm, memberID: nil).count
                == SyntheticAcceptanceScenario.expectedRecordCount else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        guard try await reports(service, query: expected.dateSearchTerm, memberID: nil).count == 1 else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        for member in header.members {
            var dates: [Date] = []
            var cursor: LibraryQueryCursor?
            repeat {
                let page = try await service.timelinePage(memberID: member.id, cursor: cursor)
                guard page.damagedIDs.isEmpty else { throw SyntheticAcceptanceError.invariantFailed }
                for item in page.items {
                    guard case .report(let report) = item, let date = report.timelineDate else {
                        throw SyntheticAcceptanceError.invariantFailed
                    }
                    dates.append(date)
                }
                cursor = page.nextCursor
            } while cursor != nil
            guard dates.count == SyntheticAcceptanceScenario.recordsPerMember,
                  Set(dates).count == dates.count else {
                throw SyntheticAcceptanceError.invariantFailed
            }
        }
        let comparison = try RecordComparison(records: Array(records.prefix(2)))
        guard comparison.left.conclusion != .notProvided,
              comparison.right.conclusion != .notProvided else {
            throw SyntheticAcceptanceError.invariantFailed
        }
        return VerificationSummary(
            memberCount: header.members.count,
            recordCount: header.reportCount,
            attachmentCount: verifiedOrdinals.count,
            summarySHA256: expected.summarySHA256(libraryID: header.revision.libraryID),
            targetedRetrievalUnderThirtySeconds: targetedRetrievalUnderThirtySeconds,
            tokenSetSHA256: expected.tokenSetSHA256
        )
    }

    /// Every confirmed report a query returns, in the pages the app would read.
    private func reports(_ service: LiveAppService, query: String, memberID: UUID?) async throws -> [LibraryReportSummary] {
        var items: [LibraryReportSummary] = []
        var cursor: LibraryQueryCursor?
        repeat {
            let page = try await service.reportPage(query: query, memberID: memberID, cursor: cursor)
            guard page.damagedIDs.isEmpty, page.damagedMemberIDs.isEmpty else { throw SyntheticAcceptanceError.invariantFailed }
            items += page.items
            cursor = page.nextCursor
        } while cursor != nil
        return items
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

/// Keeps the library of a forced-termination phase open until the process is killed.
@MainActor
private final class ForcedTerminationHold {
    static let shared = ForcedTerminationHold()
    private var library: AcceptanceLibrary?
    func keep(_ library: AcceptanceLibrary) { self.library = library }
    func release() async {
        await library?.close()
        library = nil
    }
}

#if DEBUG
extension SyntheticAcceptanceRunner {
    /// Stands in for the kill an installed run delivers after a forced-termination phase.
    static func releaseForcedTerminationHoldForTesting() async { await ForcedTerminationHold.shared.release() }
}
#endif
