import Foundation
import KinlogueCore
import KinloguePlatform

struct SQLiteCandidateAcceptanceMeasurement: Encodable, Sendable {
    let code = "KLA_SQLITE_CANDIDATE_COMPLETE"
    let reportCount: Int
    let readyMilliseconds: Double
    let originalBytesBeforeReady: UInt64
    let firstReportPageMilliseconds: Double
    let searchPageMilliseconds: Double
    let lanFirstPageMilliseconds: Double
    let exportedOriginalCount: Int

    func emit() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(self)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }
}

/// The signed acceptance identity and its existing inode receipt are mandatory.
/// This one-record probe exercises the real App startup/services, not a scale gate.
@MainActor
struct SQLiteCandidateAcceptanceProbe {
    static func run(request: AcceptanceSmokeRequest) async throws -> SQLiteCandidateAcceptanceMeasurement {
        guard request.phase == .sqliteCandidate, case .acceptance(let runID) = request.identity.mode,
              request.identity.syntheticSmokeRequested else { throw SyntheticAcceptanceError.invariantFailed }
        let root = request.identity.sourceVault.rootURL
        let support = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ownership = try AcceptanceRunOwnership.load(applicationSupportURL: support, runID: runID)
        guard ownership.runRoot == root.deletingLastPathComponent(),
              !FileManager.default.fileExists(atPath: root.path) else { throw SyntheticAcceptanceError.unsafeCleanupTarget }
        try await seed(identity: request.identity)
        let startup = AppStartupCoordinator(identity: request.identity)
        do {
            let measurement = try await measure(startup: startup, exportURL: ownership.runRoot.appendingPathComponent("sqlite-candidate-originals.zip"))
            guard let services = startup.environment else { throw SyntheticAcceptanceError.invariantFailed }
            try await services.destroyService.destroyCurrentVault()
            await startup.shutdown()
            try ownership.releaseAfterVaultRemoval()
            return measurement
        } catch {
            await startup.shutdown()
            throw error
        }
    }

    private static func seed(identity: AppRuntimeIdentity) async throws {
        let startup = AppStartupCoordinator(identity: identity)
        startup.acknowledgeStorageDisclosure()
        do {
            let services = try await startup.openEnvironment()
            _ = try await services.dataService.bootstrap()
            let header = try await services.dataService.createMember(displayName: "Synthetic candidate member", disambiguationLabel: nil)
            guard let member = header.members.first, let store = startup.database else { throw SyntheticAcceptanceError.invariantFailed }
            let reports = SQLiteReportRepository(store: store)
            let bytes = Data("synthetic candidate original".utf8)
            let file = try ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png", sha256Digest: ContentDigest.sha256(bytes))
            guard case .created(let id) = try await reports.stage(file) else { throw SyntheticAcceptanceError.invariantFailed }
            let lease = try await reports.beginProcessing(draftID: id, attemptID: UUID())
            try await reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
            let draft = try await reports.draft(id)
            let record = try HealthRecord(id: id, memberID: member.id, sources: draft.sources, ocrDocumentObjectID: draft.documentObjectID,
                importState: .confirmed, conclusion: SourceField.manualEntry("Synthetic candidate source"))
            try await reports.confirm(draftID: id, expectedRevision: draft.revision, record: record)
            await startup.shutdown()
        } catch { await startup.shutdown(); throw error }
    }

    static func measure(startup: AppStartupCoordinator, exportURL: URL) async throws -> SQLiteCandidateAcceptanceMeasurement {
        let clock = ContinuousClock()
        startup.acknowledgeStorageDisclosure()
        let start = clock.now
        guard await startup.start(), startup.composition?.appModel.phase == .ready,
              let services = startup.environment, let store = startup.database else { throw SyntheticAcceptanceError.invariantFailed }
        let ready = milliseconds(start.duration(to: clock.now))
        let bytes = store.originalReadMetrics.verifiedReadByteCount
        guard bytes == 0 else { throw SyntheticAcceptanceError.invariantFailed }
        await startup.composition?.integrityCoordinator?.pause()
        let pageStart = clock.now
        let page = try await services.dataService.reportPage(query: "", memberID: nil, cursor: nil)
        let pageTime = milliseconds(pageStart.duration(to: clock.now))
        let searchStart = clock.now
        _ = try await services.dataService.reportPage(query: "synthetic", memberID: nil, cursor: nil)
        let searchTime = milliseconds(searchStart.duration(to: clock.now))
        let lanStart = clock.now
        _ = try await services.lanInboxService.refresh()
        let lanTime = milliseconds(lanStart.duration(to: clock.now))
        let count = try await services.dataService.refresh().reportCount
        guard count == 1, page.items.count == 1 else { throw SyntheticAcceptanceError.invariantFailed }
        let exported = try await services.originalExportService.export(to: exportURL, undatedToken: "undated", progress: { _ in })
        guard exported.entryCount == 1, exported.destinationURL == exportURL else { throw SyntheticAcceptanceError.invariantFailed }
        // Only this exact, newly published artifact is removed; failed probes retain their evidence.
        try FileManager.default.removeItem(at: exportURL)
        return SQLiteCandidateAcceptanceMeasurement(reportCount: count, readyMilliseconds: ready, originalBytesBeforeReady: bytes,
            firstReportPageMilliseconds: pageTime, searchPageMilliseconds: searchTime,
            lanFirstPageMilliseconds: lanTime, exportedOriginalCount: exported.entryCount)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
