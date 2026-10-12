import Darwin
import Foundation
import KinlogueCore
import KinloguePlatform

/// Characterizes the current plaintext Vault and LAN inbox at synthetic scale.
///
/// Every byte is generated at run time inside an owned temporary work
/// directory. The probe drives the production stores through their public
/// API; it does not reimplement manifest, commit, or backup algorithms, and it
/// never opens the App's Application Support Vault.
enum StorageScaleProbe {
    private static let workDirectoryPrefix = "kinlogue-storage-scale-probe."
    private static let reserveByteCount: Int64 = 16 * 1_024 * 1_024 * 1_024
    private static let memberCount = 6
    private static let ocrBlockCount = 60
    private static let reportBatchByteCount = 256 * 1_024 * 1_024
    private static let reportBatchCount = 250
    private static let seriesInstanceCount = 250

    static func run(arguments: [String]) async -> Int32 {
        do {
            let configuration = try Configuration(arguments: arguments)
            var report = ProbeReport()
            report.set("probe", "KLG-STORAGE-SCALE-PROBE-1")
            report.set("command", configuration.command.rawValue)
            if [.logicalStartup, .logicalOperations, .logicalBackup].contains(configuration.command) {
                _ = try fileByteCount(configuration.rootURL.appendingPathComponent("library.sqlite"))
            }
            switch configuration.command {
            case .generate: try await generate(configuration, into: &report)
            case .startup: try await startup(configuration, into: &report)
            case .operations: try await operations(configuration, into: &report)
            case .inbox: try await inbox(configuration, into: &report)
            case .capacityInbox: try await capacityInbox(configuration, into: &report)
            case .backup: try await backup(configuration, into: &report)
            case .logicalGenerate: try await logicalGenerate(configuration, into: &report)
            case .logicalCapture: try await logicalCapture(configuration, into: &report)
            case .logicalQueries: try await logicalQueries(configuration, into: &report)
            case .logicalInbox: try await logicalInbox(configuration, into: &report)
            case .logicalStartup: try await logicalStartup(configuration, into: &report)
            case .logicalOperations: try await logicalOperations(configuration, into: &report)
            case .logicalBackup: try await backup(configuration, into: &report)
            case .logicalCapacity: try await logicalCapacity(configuration, into: &report)
            }
            print(report.json)
            return EXIT_SUCCESS
        } catch let error as ProbeError {
            FileHandle.standardError.write(Data("storage scale probe failed: \(error.rawValue)\n".utf8))
            return error == .insufficientDiskSpace ? 75 : EXIT_FAILURE
        } catch {
            FileHandle.standardError.write(
                Data("storage scale probe failed: \(String(describing: type(of: error)))\n".utf8)
            )
            return EXIT_FAILURE
        }
    }

    // MARK: - Configuration

    private enum ProbeError: String, Error {
        case invalidArguments
        case invalidWorkDirectory
        case insufficientDiskSpace
        case unexpectedState
    }

    private enum Command: String {
        case generate, startup, operations, inbox, backup
        case capacityInbox = "capacity-inbox"
        case logicalGenerate = "logical-generate"
        case logicalCapture = "logical-capture"
        case logicalQueries = "logical-queries"
        case logicalInbox = "logical-inbox"
        case logicalStartup = "logical-startup"
        case logicalOperations = "logical-operations"
        case logicalBackup = "logical-backup"
        case logicalCapacity = "logical-capacity"
    }

    private struct Configuration {
        let command: Command
        let workDirectory: URL
        var reportCount = 0
        var attachmentByteCount = 64 * 1_024
        var largeAttachmentCount = 0
        var largeAttachmentByteCount = 100 * 1_024 * 1_024
        var dicomStudyCount = 0
        var dicomObjectsPerStudy = 0
        var dicomObjectByteCount = 0
        var inboxCheckpoints: [Int] = []
        var inboxItemByteCount = 32 * 1_024
        var iterations = 7

        var rootURL: URL { workDirectory.appendingPathComponent("Vault", isDirectory: true) }

        init(arguments: [String]) throws {
            guard let first = arguments.first, let command = Command(rawValue: first) else {
                throw ProbeError.invalidArguments
            }
            self.command = command
            if command == .logicalOperations { iterations = 20 }
            if command == .logicalCapacity { reportCount = 20_000 }
            var workDirectory: URL?
            var index = 1
            func integer(_ range: ClosedRange<Int>) throws -> Int {
                guard index + 1 < arguments.count,
                      let value = Int(arguments[index + 1]),
                      range.contains(value) else { throw ProbeError.invalidArguments }
                return value
            }
            while index < arguments.count {
                switch arguments[index] {
                case "--work-directory":
                    guard index + 1 < arguments.count else { throw ProbeError.invalidArguments }
                    workDirectory = try Self.validatedWorkDirectory(arguments[index + 1])
                case "--reports": reportCount = try integer(0...(command == .logicalCapacity ? 20_000 : 10_000))
                case "--attachment-bytes": attachmentByteCount = try integer(1_024...8 * 1_024 * 1_024)
                case "--large-attachments": largeAttachmentCount = try integer(0...64)
                case "--large-attachment-bytes":
                    largeAttachmentByteCount = try integer(1_024 * 1_024...100 * 1_024 * 1_024)
                case "--dicom-studies": dicomStudyCount = try integer(0...5)
                case "--dicom-objects-per-study": dicomObjectsPerStudy = try integer(0...2_000)
                case "--dicom-object-bytes": dicomObjectByteCount = try integer(0...4 * 1_024 * 1_024)
                case "--inbox-item-bytes": inboxItemByteCount = try integer(1_024...4 * 1_024 * 1_024)
                case "--iterations": iterations = try integer(3...25)
                case "--inbox-checkpoints":
                    guard index + 1 < arguments.count else { throw ProbeError.invalidArguments }
                    inboxCheckpoints = try arguments[index + 1].split(separator: ",").map {
                        guard let value = Int($0), (0...4_990).contains(value) else {
                            throw ProbeError.invalidArguments
                        }
                        return value
                    }.sorted()
                default: throw ProbeError.invalidArguments
                }
                index += 2
            }
            guard let workDirectory else { throw ProbeError.invalidArguments }
            self.workDirectory = workDirectory
        }

        /// Only a private directory created by the wrapper script is accepted,
        /// so a typo can never point the probe at a real library.
        private static func validatedWorkDirectory(_ rawPath: String) throws -> URL {
            guard rawPath.hasPrefix("/"), !rawPath.contains("\n"), !rawPath.contains("\r"),
                  !rawPath.contains("/Library/Application Support/"),
                  !rawPath.contains("/Library/Containers/") else {
                throw ProbeError.invalidWorkDirectory
            }
            let url = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            guard url.lastPathComponent.hasPrefix(StorageScaleProbe.workDirectoryPrefix),
                  url.resolvingSymlinksInPath().standardizedFileURL.path == url.path else {
                throw ProbeError.invalidWorkDirectory
            }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & 0o077 == 0 else {
                throw ProbeError.invalidWorkDirectory
            }
            return url
        }
    }

    // MARK: - Generate

    private static func generate(
        _ configuration: Configuration,
        into report: inout ProbeReport
    ) async throws {
        let plannedByteCount = Int64(configuration.reportCount)
            * Int64(configuration.attachmentByteCount + 48 * 1_024)
            + Int64(configuration.largeAttachmentCount) * Int64(configuration.largeAttachmentByteCount)
            + Int64(configuration.dicomStudyCount) * Int64(configuration.dicomObjectsPerStudy)
            * Int64(configuration.dicomObjectByteCount)
        // Source, encrypted checkpoint and restored library coexist during verification.
        try requireAvailableCapacity(
            at: configuration.workDirectory,
            byteCount: plannedByteCount * 3 + reserveByteCount
        )

        let started = now()
        let vault = try PlaintextVault(rootURL: configuration.rootURL)
        var catalog = try await vault.initialize()
        _ = try await PlaintextLANInboxStore(rootURL: configuration.rootURL).initialize()

        let members = try (0..<memberCount).map {
            try FamilyMember(displayName: "合成成员 \($0 + 1)")
        }
        catalog = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: try catalog.replacing(members: members),
            writes: []
        ))

        let bytes = SyntheticBytes()
        let draftCount = min(configuration.reportCount, max(16, configuration.reportCount / 50))
        var batch = ReportBatch()
        var ordinal = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            catalog = try await vault.commit(try VaultCommitRequest(
                expectedGeneration: catalog.generation,
                catalog: try catalog.replacing(
                    records: catalog.records + batch.records,
                    attachments: catalog.attachments + batch.attachments,
                    importDrafts: catalog.importDrafts + batch.drafts
                ),
                writes: batch.writes
            ))
            batch = ReportBatch()
        }
        func append(byteCount: Int, contentType: String) async throws {
            try batch.append(makeReport(
                ordinal: ordinal,
                member: members[ordinal % members.count],
                attachmentBytes: bytes.make(byteCount: byteCount, domain: 1, ordinal: ordinal),
                contentType: contentType,
                isDraft: ordinal < draftCount
            ))
            ordinal += 1
            if batch.byteCount >= reportBatchByteCount || batch.count >= reportBatchCount {
                try await flush()
            }
        }
        for _ in 0..<configuration.reportCount {
            try await append(byteCount: configuration.attachmentByteCount, contentType: "public.jpeg")
        }
        for _ in 0..<configuration.largeAttachmentCount {
            try await append(
                byteCount: configuration.largeAttachmentByteCount,
                contentType: "com.adobe.pdf"
            )
        }
        try await flush()

        for studyOrdinal in 0..<configuration.dicomStudyCount {
            catalog = try await appendDICOMStudy(
                ordinal: studyOrdinal,
                objectCount: configuration.dicomObjectsPerStudy,
                objectByteCount: configuration.dicomObjectByteCount,
                member: members[studyOrdinal % members.count],
                bytes: bytes,
                catalog: catalog,
                vault: vault
            )
        }

        report.set("generate_ms", milliseconds(since: started))
        try describe(catalog, rootURL: configuration.rootURL, into: &report)
    }

    /// Same synthetic shape as `generate`, committed through real SQLite repositories.
    private static func logicalGenerate(_ configuration: Configuration, into report: inout ProbeReport) async throws {
        guard configuration.largeAttachmentCount == 0, configuration.dicomStudyCount == 0 else { throw ProbeError.invalidArguments }
        try requireAvailableCapacity(at: configuration.workDirectory,
            byteCount: Int64(configuration.reportCount) * Int64(configuration.attachmentByteCount + 96 * 1_024) * 3 + reserveByteCount)
        let started = now()
        let store = try SQLiteLibraryStore(rootURL: configuration.rootURL)
        defer { try? store.close() }
        let repository = SQLiteReportRepository(store: store)
        let members = try (0..<memberCount).map { try FamilyMember(displayName: "合成成员 \($0 + 1)") }
        for member in members { try await repository.saveMember(member, replacing: nil) }
        let bytes = SyntheticBytes()
        let draftCount = min(configuration.reportCount, max(16, configuration.reportCount / 50))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        for ordinal in 0..<configuration.reportCount {
            let data = bytes.make(byteCount: configuration.attachmentByteCount, domain: 1, ordinal: ordinal)
            let file = try ValidatedImportedFile(data: data, kind: .image, contentTypeIdentifier: "public.jpeg", sha256Digest: ContentDigest.sha256(data))
            guard case let .created(id) = try await repository.stage(file) else { throw ProbeError.unexpectedState }
            let initial = try await repository.draft(id)
            let member = members[ordinal % members.count]
            let generated = try makeReport(ordinal: ordinal, member: member, attachmentBytes: data,
                contentType: "public.jpeg", isDraft: ordinal < draftCount, suppliedSource: initial.sources.elements[0])
            let document = try decoder.decode(ImportDraftDocument.self, from: generated.writes[1].plaintext)
            let lease = try await repository.beginProcessing(draftID: id, attemptID: UUID())
            try await repository.completeProcessing(lease: lease, document: document)
            if ordinal >= draftCount {
                let draft = try await repository.draft(id)
                let record = try confirmedRecord(member: member, sources: draft.sources, documentID: draft.documentObjectID,
                    candidates: document.candidates, note: ordinal % 4 == 0 ? "合成备注 \(ordinal)" : nil)
                try await repository.confirm(draftID: id, expectedRevision: draft.revision, record: record)
            }
        }
        report.set("generate_ms", milliseconds(since: started))
        report.set("record_count", configuration.reportCount - draftCount)
        report.set("draft_count", draftCount)
        report.set("ocr_blocks_per_report", ocrBlockCount)
        report.set("database_bytes", try fileByteCount(configuration.rootURL.appendingPathComponent("library.sqlite")))
        report.set("footprint_peak_bytes", Memory.current().peakFootprint)
    }

    /// Fresh-process storage identity/quick_check/FK admission and the first bounded page.
    private static func logicalStartup(_ configuration: Configuration, into report: inout ProbeReport) async throws {
        let before = Memory.current()
        let started = now()
        let store = try SQLiteLibraryStore(rootURL: configuration.rootURL)
        defer { try? store.close() }
        let opened = milliseconds(since: started)
        let page = try await SQLiteReportRepository(store: store).reportPage()
        let elapsed = milliseconds(since: started)
        let originalBytes = store.originalReadMetrics.verifiedReadByteCount
        guard page.items.count <= 100, Set(page.items.map(\.id)).count == page.items.count,
              page.damagedIDs.isEmpty, page.damagedMemberIDs.isEmpty, originalBytes == 0 else {
            throw ProbeError.unexpectedState
        }
        if configuration.reportCount > 0 {
            let draftCount = min(configuration.reportCount, max(16, configuration.reportCount / 50))
            guard page.items.count == min(100, configuration.reportCount - draftCount) else { throw ProbeError.unexpectedState }
        }
        report.set("storage_open_ms", opened)
        report.set("storage_and_first100_ms", elapsed)
        report.set("first_page_count", page.items.count)
        report.set("original_read_bytes", originalBytes)
        report.set("sqlite_version", Int(try store.engineConfiguration().sqliteVersion))
        report.set("footprint_before_bytes", before.footprint)
        report.set("footprint_peak_bytes", Memory.current().peakFootprint)
        report.set("measurement", "Platform fresh process; OS cold cache uncontrolled; not App Ready")
    }

    private static func logicalOperations(_ configuration: Configuration, into report: inout ProbeReport) async throws {
        let store = try SQLiteLibraryStore(rootURL: configuration.rootURL)
        defer { try? store.close() }
        let repository = SQLiteReportRepository(store: store)
        let inbox = try SQLiteLANInboxStore(store: store)
        try await inbox.prepare()
        guard let member = try await repository.members().first else { throw ProbeError.unexpectedState }
        let bytes = SyntheticBytes()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let beforeInboxCount = try await inbox.queueScreen().storage.itemCount
        var stage = Samples(), read = Samples(), save = Samples(), confirm = Samples(), edit = Samples(), publish = Samples()
        for iteration in 0...configuration.iterations {
            let data = bytes.make(byteCount: 64 * 1_024, domain: 31, ordinal: iteration)
            var started = now()
            let file = try ValidatedImportedFile(data: data, kind: .image, contentTypeIdentifier: "public.jpeg", sha256Digest: ContentDigest.sha256(data))
            guard case let .created(id) = try await repository.stage(file) else { throw ProbeError.unexpectedState }
            let initial = try await repository.draft(id)
            let stageElapsed = milliseconds(since: started)
            guard initial.state == .staging, initial.sources.elements.count == 1,
                  try await repository.loadSource(draftID: id).data == file.data else { throw ProbeError.unexpectedState }
            let generated = try makeReport(ordinal: iteration, member: member, attachmentBytes: data,
                contentType: "public.jpeg", isDraft: true, suppliedSource: initial.sources.first)
            let document = try decoder.decode(ImportDraftDocument.self, from: generated.writes[1].plaintext)
            let lease = try await repository.beginProcessing(draftID: id, attemptID: UUID())
            try await repository.completeProcessing(lease: lease, document: document)
            started = now()
            let snapshot = try await repository.loadReviewSnapshot(draftID: id)
            let readElapsed = milliseconds(since: started)
            guard snapshot.document == document, snapshot.originalData == data,
                  snapshot.draft.sources == initial.sources, snapshot.draft.state == .needsReview else { throw ProbeError.unexpectedState }
            let reviewed = ImportDraftDocument(blocks: document.blocks, candidates: document.candidates,
                candidateExtractionVersion: document.candidateExtractionVersion,
                reviewState: ImportDraftReviewState(timelineDateSelection: .unknown,
                    title: document.candidates.title?.transcription ?? "", organization: "合成复核机构",
                    department: "", reportType: "", reportedResults: "合成用户修订", conclusion: "",
                    abnormalItems: [], userNote: "合成复核备注"))
            started = now()
            try await repository.saveReview(draftID: id, expectedRevision: snapshot.draft.revision, memberID: member.id, document: reviewed)
            let saved = try await repository.loadReviewSnapshot(draftID: id)
            let saveElapsed = milliseconds(since: started)
            guard saved.document == reviewed, saved.draft.revision == snapshot.draft.revision + 1,
                  saved.draft.memberID == member.id, saved.draft.sources == initial.sources else { throw ProbeError.unexpectedState }
            let record = try confirmedRecord(member: member, sources: saved.draft.sources,
                documentID: saved.draft.documentObjectID, candidates: document.candidates, note: "合成复核备注")
            started = now()
            try await repository.confirm(draftID: id, expectedRevision: saved.draft.revision, record: record)
            let confirmed = try await repository.record(record.id)
            let page = try await repository.reportPage()
            let confirmElapsed = milliseconds(since: started)
            guard confirmed == record, page.damagedIDs.isEmpty else { throw ProbeError.unexpectedState }
            let edited = try HealthRecord(id: record.id, memberID: record.memberID, sources: record.sources,
                ocrDocumentObjectID: record.ocrDocumentObjectID, importState: .confirmed, revision: record.revision + 1,
                title: record.title, organization: record.organization, department: record.department,
                reportType: record.reportType, dateCandidates: record.dateCandidates,
                timelineDateCandidateID: record.timelineDateCandidateID, reportedResults: record.reportedResults,
                conclusion: record.conclusion, abnormalItems: record.abnormalItems,
                notes: [try UserNote(text: "合成编辑备注 \(iteration)")])
            started = now()
            try await repository.updateRecord(edited, expectedRevision: record.revision)
            let reread = try await repository.record(record.id)
            let refreshed = try await repository.reportPage()
            let editElapsed = milliseconds(since: started)
            guard reread == edited, reread.sources == initial.sources, refreshed.damagedIDs.isEmpty else { throw ProbeError.unexpectedState }
            // Only IDs created by this iteration are removed, outside every timed operation.
            try await repository.deleteRecord(edited.id, expectedRevision: edited.revision)
            let lanData = bytes.make(byteCount: 32 * 1_024, domain: 32, ordinal: iteration)
            let session = UUID()
            started = now()
            let item = try await logicalUpload(lanData, inbox: inbox, session: session)
            let publishElapsed = milliseconds(since: started)
            let screen = try await inbox.queueScreen()
            guard item.contentIdentity.byteCount == lanData.count, item.contentIdentity.sha256Digest == ContentDigest.sha256(lanData),
                  screen.storage.itemCount == beforeInboxCount + 1, screen.page.damagedItemIDs.isEmpty else { throw ProbeError.unexpectedState }
            try await inbox.removeItem(itemID: item.id, expectedRevision: item.revision, activeSessionID: session)
            try await inbox.endItemSession(sessionID: session)
            guard try await inbox.queueScreen().storage.itemCount == beforeInboxCount else { throw ProbeError.unexpectedState }
            if iteration > 0 {
                stage.append(stageElapsed); read.append(readElapsed); save.append(saveElapsed)
                confirm.append(confirmElapsed); edit.append(editElapsed); publish.append(publishElapsed)
            }
        }
        report.set("warmup_count", 1)
        for (key, samples) in [("stage64k", stage), ("review_read", read), ("save_review", save),
                               ("confirm", confirm), ("edit", edit), ("lan_publish32k", publish)] {
            report.set(key, samples.logicalReport)
        }
        report.set("invariants", "source,OCR,review,user-edit,revision,durable-readback,owned-cleanup verified")
        report.set("footprint_peak_bytes", Memory.current().peakFootprint)
        report.set("measurement", "Platform durable commands plus bounded refresh; excludes OCR execution and HTTP")
    }

    private static func logicalUpload(_ data: Data, inbox: SQLiteLANInboxStore, session: UUID) async throws -> LANInboxItem {
        let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "synthetic-scale.jpg"),
            declaredByteCount: data.count, mediaType: "image/jpeg")
        guard case let .sink(sink) = try await inbox.startItemUpload(
            transport: LANInboxTransportIdentity(sessionID: session, remoteFileID: UUID()), metadata: metadata,
            attemptRevision: 1, admissionGeneration: inbox.itemAdmissionGeneration()) else { throw ProbeError.unexpectedState }
        try await sink.write(data).value
        let completed = try await sink.finish()
        guard completed.byteCount == data.count, completed.sha256Digest == ContentDigest.sha256(data),
              let item = try await inbox.queueScreen().page.items.first(where: { $0.originatingSessionID == session }) else {
            throw ProbeError.unexpectedState
        }
        return item
    }

    private static func logicalCapacity(_ configuration: Configuration, into report: inout ProbeReport) async throws {
        guard configuration.reportCount > 0, !FileManager.default.fileExists(atPath: configuration.rootURL.path) else {
            throw ProbeError.invalidArguments
        }
        try requireAvailableCapacity(at: configuration.workDirectory, byteCount: reserveByteCount + Int64(configuration.reportCount) * 32_768)
        let started = now()
        do {
            let store = try SQLiteLibraryStore(rootURL: configuration.rootURL)
            defer { try? store.close() }
            let repository = SQLiteReportRepository(store: store)
            let bytes = SyntheticBytes()
            for ordinal in 0..<configuration.reportCount {
                let data = bytes.make(byteCount: 1_024, domain: 33, ordinal: ordinal)
                let file = try ValidatedImportedFile(data: data, kind: .image, contentTypeIdentifier: "public.jpeg", sha256Digest: ContentDigest.sha256(data))
                guard case .created = try await repository.stage(file) else { throw ProbeError.unexpectedState }
            }
            let inbox = try SQLiteLANInboxStore(store: store)
            let item = try await logicalUpload(bytes.make(byteCount: 1_024, domain: 34, ordinal: 0), inbox: inbox, session: UUID())
            let source = try ReportSource(attachmentID: item.blobID, displayName: item.displayName.rawValue, pageCount: 1)
            let document = try LANPreprocessedSourceDocument(source: source, contentTypeIdentifier: "public.jpeg", blocks: [])
            _ = try await inbox.savePreprocessedDocument(itemID: item.id, expectedRevision: item.revision, document: document)
        }
        report.set("capacity_seed_ms", milliseconds(since: started))
        report.set("capacity_draft_count", configuration.reportCount)
        report.set("capacity_original_bytes", (configuration.reportCount + 1) * 1_024)
        try await backup(configuration, into: &report)
    }

    private static func logicalQueries(_ configuration: Configuration, into report: inout ProbeReport) async throws {
        let store = try SQLiteLibraryStore(rootURL: configuration.rootURL)
        defer { try? store.close() }
        let repository = SQLiteReportRepository(store: store)
        for (key, query) in [("first_page", ""), ("no_match", "synthetic-absent-query"), ("rare", "项目9876"), ("date", "2026-01"), ("chinese", "合成"), ("member", "成员")] {
            // The uncached Core predicate runs outside measured samples, with the same bounded scanner.
            let expected = try await repository.measureReportSearch(query, prefilter: false)
            let checked = try await repository.measureReportSearch(query)
            guard expected.ids == checked.ids, expected.damagedIDs == checked.damagedIDs else { throw ProbeError.unexpectedState }
            var result = ProbeReport()
            result.set("match_count", checked.ids.count)
            result.set("oracle_ids_equal", "true")
            result.set("peak_batch_bytes", checked.peakBatchBytes)
            result.set("maximum_lanes", checked.maximumLanes)
            result.set("candidate_count", checked.candidateCount)
            var pageValues: [Double] = [], fullValues: [Double] = [], sqlValues: [Double] = []
            _ = try await repository.reportPage(query: query)
            for iteration in 0..<configuration.iterations {
                var started = now()
                _ = try await repository.reportPage(query: query)
                let pageElapsed = milliseconds(since: started)
                pageValues.append(pageElapsed); result.set("first_page_sample_\(iteration)", pageElapsed)
                started = now()
                let full = try await repository.measureReportSearch(query)
                let fullElapsed = milliseconds(since: started)
                guard full.ids == expected.ids else { throw ProbeError.unexpectedState }
                fullValues.append(fullElapsed); sqlValues.append(full.sqlReadMilliseconds)
                result.set("full_match_sample_\(iteration)", fullElapsed)
                result.set("sql_read_sample_\(iteration)", full.sqlReadMilliseconds)
            }
            for (prefix, values) in [("first_page", pageValues), ("full_match", fullValues), ("sql_read", sqlValues)] {
                let sorted = values.sorted()
                result.set(prefix + "_p50_ms", sorted[(sorted.count - 1) / 2])
                result.set(prefix + "_empirical_p95_ms", sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)])
                result.set(prefix + "_max_ms", sorted.last!)
            }
            report.set(key, result)
        }
        report.set("footprint_peak_bytes", Memory.current().peakFootprint)
    }

    private static func logicalInbox(_ configuration: Configuration, into report: inout ProbeReport) async throws {
        guard let count = configuration.inboxCheckpoints.last else { throw ProbeError.invalidArguments }
        let kernel = try SQLiteLibraryStore(rootURL: configuration.rootURL)
        defer { try? kernel.close() }
        let store = try SQLiteLANInboxStore(store: kernel)
        try await store.prepare()
        var uploaded = try await store.queueScreen().storage.itemCount
        let bytes = SyntheticBytes()
        var session = UUID()
        let fillStart = now()
        while uploaded < count {
            if uploaded > 0, uploaded % 200 == 0 {
                session = UUID()
            }
            let data = bytes.make(byteCount: configuration.inboxItemByteCount, domain: 4, ordinal: uploaded)
            let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "synthetic-\(uploaded).jpg"),
                declaredByteCount: data.count, mediaType: "image/jpeg")
            guard case .sink(let sink) = try await store.startItemUpload(
                transport: LANInboxTransportIdentity(sessionID: session, remoteFileID: UUID()), metadata: metadata,
                attemptRevision: 1, admissionGeneration: store.itemAdmissionGeneration()) else { throw ProbeError.unexpectedState }
            try await sink.write(data).value
            _ = try await sink.finish()
            uploaded += 1
        }
        report.set("fill_ms", milliseconds(since: fillStart))
        report.set("item_count", uploaded)
        report.set("item_bytes", configuration.inboxItemByteCount)
        report.set("receipt_count", try await store.loadSnapshot().transportReceipts.count)
        report.set("measurement", "Platform queueScreen first100, whole-inbox metadata aggregates; App service boundary covered separately")
        _ = try await store.queueScreen()
        report.set("warmup_count", 1)
        var samples: [Double] = []
        for index in 0..<configuration.iterations {
            let started = now()
            let screen = try await store.queueScreen()
            let elapsed = milliseconds(since: started)
            guard screen.page.items.count == min(100, uploaded), screen.storage.itemCount == uploaded,
                  screen.page.damagedItemIDs.isEmpty, screen.damagedUploadIDs.isEmpty,
                  (screen.page.nextCursor != nil) == (uploaded > 100) else { throw ProbeError.unexpectedState }
            samples.append(elapsed)
            report.set("first100_sample_\(index)", elapsed)
        }
        let sorted = samples.sorted()
        report.set("first100_p50_ms", sorted[(sorted.count - 1) / 2])
        report.set("first100_empirical_p95_ms", sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1])
        report.set("first100_max_ms", sorted.last!)
        report.set("footprint_peak_bytes", Memory.current().peakFootprint)
    }

    private static func logicalCapture(_ configuration: Configuration, into report: inout ProbeReport) async throws {
        let store = try SQLiteLibraryStore(rootURL: configuration.rootURL)
        defer { try? store.close() }
        let phases = LogicalCapturePhases()
        let source = SQLiteLogicalBackupSource(store: store, captureObservation: phases.record)
        func descriptors() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap(Int32.init)
                .filter { fcntl($0, F_GETFD) != -1 }.count
        }
        report.set("fd_before_capture", try descriptors())
        report.set("footprint_before_bytes", Memory.current().footprint)
        report.set("peak_before_capture_bytes", Memory.current().peakFootprint)
        let fdPeak = LogicalCaptureFDPeak()
        let sampler = Task.detached {
            while !Task.isCancelled {
                fdPeak.sample()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let started = now()
        do {
            let snapshot = try await source.prepare()
            defer { snapshot.release() }
            report.set("prepare_ms", milliseconds(since: started))
            report.set("admission_capture_ms", snapshot.captureDuration * 1_000)
            report.set("logical_bytes", snapshot.logicalByteCount)
            report.set("plaintext_bytes", snapshot.totalPlaintextByteCount)
            report.set("entry_count", snapshot.entryCount)
            report.set("fd_with_snapshot", try descriptors())
            report.set("footprint_with_snapshot_bytes", Memory.current().footprint)
            report.set("capture_outcome", "capturedAndValidated")
        } catch SQLiteLogicalBackupError.captureTimedOut {
            report.set("prepare_ms", milliseconds(since: started))
            report.set("capture_outcome", "captureTimedOut")
        }
        sampler.cancel(); await sampler.value
        report.set("fd_peak_sampled", fdPeak.value)
        report.set("capture_footprint_peak_sampled_bytes", fdPeak.footprint)
        report.set("fd_after_release", try descriptors())
        report.set("footprint_after_release_bytes", Memory.current().footprint)
        for (kind, count, duration, footprint, peak) in phases.values {
            report.set("phase_\(kind)_emitted_count", count)
            report.set("phase_\(kind)_ms", duration * 1_000)
            report.set("phase_\(kind)_footprint_bytes", footprint)
            report.set("phase_\(kind)_peak_bytes", peak)
        }
        report.set("footprint_peak_bytes", Memory.current().peakFootprint)
    }

    private struct GeneratedReport {
        let attachment: Attachment
        let record: HealthRecord?
        let draft: ImportDraft?
        let writes: [VaultObjectWrite]
    }

    private struct ReportBatch {
        var records: [HealthRecord] = []
        var drafts: [ImportDraft] = []
        var attachments: [Attachment] = []
        var writes: [VaultObjectWrite] = []
        var byteCount = 0
        var count: Int { attachments.count }
        var isEmpty: Bool { attachments.isEmpty }

        mutating func append(_ report: GeneratedReport) {
            attachments.append(report.attachment)
            if let record = report.record { records.append(record) }
            if let draft = report.draft { drafts.append(draft) }
            writes.append(contentsOf: report.writes)
            byteCount += report.writes.reduce(0) { $0 + $1.plaintext.count }
        }
    }

    /// One single-page report shaped like a reviewed lab report: 60 OCR
    /// blocks, nine sourced fields, two date candidates and three abnormal
    /// items. Text is obviously synthetic and carries no real identity.
    private static func makeReport(
        ordinal: Int,
        member: FamilyMember,
        attachmentBytes: Data,
        contentType: String,
        isDraft: Bool,
        suppliedSource: ReportSource? = nil
    ) throws -> GeneratedReport {
        let attachment = try Attachment(
            id: suppliedSource?.attachmentID ?? UUID(),
            contentTypeIdentifier: contentType,
            byteCount: attachmentBytes.count,
            sha256Digest: ContentDigest.sha256(attachmentBytes)
        )
        let source = try suppliedSource ?? ReportSource(
            attachmentID: attachment.id,
            displayName: "synthetic-report-\(ordinal).jpg",
            pageCount: 1
        )
        let sources = try ReportSources([source])
        let blocks = try (0..<ocrBlockCount).map { blockIndex in
            try OCRBlock(
                sourceID: source.id,
                attachmentID: attachment.id,
                filePageNumber: 1,
                text: syntheticText(seed: ordinal &* 131 &+ blockIndex, characterCount: 18),
                boundingBox: try NormalizedRect(
                    x: 0.05,
                    y: Double(blockIndex) / Double(ocrBlockCount + 1),
                    width: 0.9,
                    height: 0.012
                ),
                confidence: 0.92,
                method: .vision,
                engineVersion: "synthetic-scale-probe"
            )
        }
        func field(_ text: String, block: Int) throws -> SourceField {
            try SourceField(
                originalTranscription: text,
                references: [try SourceReference(
                    sourceID: source.id,
                    attachmentID: attachment.id,
                    filePageNumber: 1,
                    boundingBox: blocks[block].boundingBox,
                    blockID: blocks[block].id
                )]
            )
        }
        // Ten years of UTC-noon dates keep the timeline grouped like real use.
        let day = TimeInterval(1_577_880_000 + (ordinal % 3_650) * 86_400)
        let dates = [
            ReportDateCandidate(
                date: Date(timeIntervalSince1970: day),
                kind: .report,
                source: try field("合成报告日期 \(ordinal % 3_650)", block: 3)
            ),
            ReportDateCandidate(
                date: Date(timeIntervalSince1970: day - 86_400),
                kind: .collection,
                source: try field("合成采样日期 \(ordinal % 3_650)", block: 4)
            ),
        ]
        let candidates = ReportCandidates(
            memberName: try field(member.displayName, block: 0),
            organization: try field("合成机构 \(ordinal % 40)", block: 1),
            department: try field("合成科室 \(ordinal % 12)", block: 2),
            reportType: try field("合成检验类型 \(ordinal % 25)", block: 5),
            title: try field("合成报告 项目\(ordinal)", block: 6),
            dateCandidates: dates,
            reportedResults: try field(
                syntheticText(seed: ordinal &* 977, characterCount: 600),
                block: 7
            ),
            conclusion: try field(
                syntheticText(seed: ordinal &* 613, characterCount: 120),
                block: 8
            ),
            abnormalItems: try (0..<3).map {
                try field(syntheticText(seed: ordinal &* 37 &+ $0, characterCount: 24), block: 9 + $0)
            }
        )
        let documentID = UUID()
        let document = try ImportDraftDocument(blocks: blocks, candidates: candidates)
            .attributedAndValidated(for: sources)
        let writes = [
            VaultObjectWrite(
                reference: VaultObjectReference(id: attachment.id, kind: .attachment),
                plaintext: attachmentBytes
            ),
            VaultObjectWrite(
                reference: VaultObjectReference(id: documentID, kind: .ocr),
                plaintext: try canonicalJSON(document)
            ),
        ]
        if isDraft {
            return GeneratedReport(
                attachment: attachment,
                record: nil,
                draft: ImportDraft(
                    sources: sources,
                    state: .needsReview,
                    revision: 2,
                    documentObjectID: documentID
                ),
                writes: writes
            )
        }
        return GeneratedReport(
            attachment: attachment,
            record: try confirmedRecord(
                member: member,
                sources: sources,
                documentID: documentID,
                candidates: candidates,
                note: ordinal % 4 == 0 ? "合成备注 \(ordinal)" : nil
            ),
            draft: nil,
            writes: writes
        )
    }

    private static func confirmedRecord(
        member: FamilyMember,
        sources: ReportSources,
        documentID: UUID?,
        candidates: ReportCandidates,
        note: String?
    ) throws -> HealthRecord {
        try HealthRecord(
            memberID: member.id,
            sources: sources,
            ocrDocumentObjectID: documentID,
            importState: .confirmed,
            title: candidates.title,
            organization: candidates.organization,
            department: candidates.department,
            reportType: candidates.reportType,
            dateCandidates: candidates.dateCandidates,
            timelineDateCandidateID: candidates.dateCandidates.first?.id,
            reportedResults: candidates.reportedResults,
            conclusion: candidates.conclusion,
            abnormalItems: candidates.abnormalItems,
            notes: try note.map { [try UserNote(text: $0)] } ?? []
        )
    }

    /// Opaque synthetic bytes stand in for DICOM originals. The Vault only
    /// hashes them; the separately stored index is a real, geometry-ordered
    /// `DICOMStudyIndex`, so reopen validation does its production work.
    private static func appendDICOMStudy(
        ordinal: Int,
        objectCount: Int,
        objectByteCount: Int,
        member: FamilyMember,
        bytes: SyntheticBytes,
        catalog initial: VaultCatalog,
        vault: PlaintextVault
    ) async throws -> VaultCatalog {
        guard objectCount > 0, objectByteCount >= 1_024 else { throw ProbeError.invalidArguments }
        var catalog = initial
        var owned: [Attachment] = []
        owned.reserveCapacity(objectCount)
        var pending: [Attachment] = []
        var writes: [VaultObjectWrite] = []
        var pendingByteCount = 0
        func flush() async throws {
            guard !pending.isEmpty else { return }
            catalog = try await vault.commit(try VaultCommitRequest(
                expectedGeneration: catalog.generation,
                catalog: try catalog.replacing(attachments: catalog.attachments + pending),
                writes: writes
            ))
            pending = []
            writes = []
            pendingByteCount = 0
        }
        for objectOrdinal in 0..<objectCount {
            let data = bytes.make(
                byteCount: objectByteCount,
                domain: 2,
                ordinal: ordinal * 10_000 + objectOrdinal
            )
            let attachment = try Attachment(
                contentTypeIdentifier: "org.nema.dicom",
                byteCount: data.count,
                sha256Digest: ContentDigest.sha256(data)
            )
            owned.append(attachment)
            pending.append(attachment)
            writes.append(VaultObjectWrite(
                reference: VaultObjectReference(id: attachment.id, kind: .attachment),
                plaintext: data
            ))
            pendingByteCount += data.count
            if pendingByteCount >= reportBatchByteCount { try await flush() }
        }
        try await flush()

        let studyID = UUID()
        var instances: [DICOMStudyIndex.Instance] = []
        var series: [DICOMStudyIndex.Series] = []
        let row = try DICOMStudyIndex.Vector3(x: 1, y: 0, z: 0)
        let column = try DICOMStudyIndex.Vector3(x: 0, y: 1, z: 0)
        for (seriesOrdinal, slice) in stride(from: 0, to: owned.count, by: seriesInstanceCount)
            .enumerated() {
            let seriesID = UUID()
            let members = owned[slice..<min(owned.count, slice + seriesInstanceCount)]
            let seriesInstances = try members.enumerated().map { order, attachment in
                try DICOMStudyIndex.Instance(
                    id: UUID(),
                    attachmentID: attachment.id,
                    seriesID: seriesID,
                    sopInstanceUIDDigest: try .init(
                        scope: .sopInstance,
                        digest: digest("sop-\(ordinal)-\(seriesOrdinal)-\(order)")
                    ),
                    canonicalOrder: order,
                    sopClass: .mrImageStorage,
                    transferSyntax: .explicitVRLittleEndian,
                    modality: .mr,
                    attributes: try .init(
                        rows: 512,
                        columns: 512,
                        samplesPerPixel: 1,
                        bitsAllocated: 16,
                        bitsStored: 12,
                        highBit: 11,
                        pixelRepresentation: .unsigned,
                        photometricInterpretation: .monochrome2,
                        imagePositionPatient: try .init(x: 0, y: 0, z: Double(order) * 3),
                        imageOrientationPatientRow: row,
                        imageOrientationPatientColumn: column,
                        rescaleSlope: 1,
                        rescaleIntercept: 0,
                        windowCenter: 400,
                        windowWidth: 800
                    )
                )
            }
            series.append(try DICOMStudyIndex.Series(
                id: seriesID,
                ordinal: seriesOrdinal + 1,
                instanceIDs: seriesInstances.map(\.id),
                seriesUIDDigest: try .init(
                    scope: .series,
                    digest: digest("series-\(ordinal)-\(seriesOrdinal)")
                ),
                orderingProvenance: .geometryProjection
            ))
            instances.append(contentsOf: seriesInstances)
        }
        let index = try DICOMStudyIndex(
            studyID: studyID,
            studyUIDDigest: try .init(scope: .study, digest: digest("study-\(ordinal)")),
            retainedObjects: owned.map { .init(attachmentID: $0.id, kind: .viewableImage) },
            instances: instances,
            series: series
        )
        let indexID = UUID()
        let study = try DICOMStudy(
            id: studyID,
            state: .confirmed,
            fingerprint: try DICOMStudyFingerprint(objects: owned.map {
                try .init(sha256Digest: $0.sha256Digest, byteCount: $0.byteCount)
            }),
            indexObjectID: indexID,
            attachmentIDs: owned.map(\.id),
            confirmedMemberID: member.id,
            effectiveDate: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + ordinal * 86_400))
        )
        return try await vault.commit(try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: try catalog.replacing(dicomStudies: catalog.dicomStudies + [study]),
            writes: [VaultObjectWrite(
                reference: VaultObjectReference(id: indexID, kind: .record),
                plaintext: try canonicalJSON(index)
            )]
        ))
    }

    // MARK: - Startup

    /// Meant to run in a fresh process so the peak footprint belongs to the
    /// validated open alone.
    private static func startup(
        _ configuration: Configuration,
        into report: inout ProbeReport
    ) async throws {
        let before = Memory.current()
        let vault = try PlaintextVault(rootURL: configuration.rootURL)
        let started = now()
        let catalog = try await vault.loadValidatedCatalog()
        report.set("load_validated_catalog_ms", milliseconds(since: started))
        let after = Memory.current()
        report.set("footprint_before_bytes", before.footprint)
        report.set("footprint_peak_bytes", after.peakFootprint)
        report.set("max_rss_bytes", after.maximumResidentSize)
        report.set("record_count", catalog.records.count)
        report.set("attachment_count", catalog.attachments.count)
    }

    // MARK: - Operations

    private static func operations(
        _ configuration: Configuration,
        into report: inout ProbeReport
    ) async throws {
        let iterations = configuration.iterations
        let vault = try PlaintextVault(rootURL: configuration.rootURL)
        let store = VaultImportDraftStore(vault: vault)
        var catalog = try await vault.loadCatalog()
        guard let member = catalog.members.first else { throw ProbeError.unexpectedState }
        try describe(catalog, rootURL: configuration.rootURL, into: &report)

        // `LiveAppService.refresh` is `loadCatalog` plus this confirmed filter.
        var refresh = Samples()
        var confirmed: [HealthRecord] = []
        for _ in 0..<iterations {
            let started = now()
            let loaded = try await vault.loadCatalog()
            confirmed = loaded.records.filter { $0.importState == .confirmed }
            refresh.append(milliseconds(since: started))
        }
        report.set("app_refresh_load_catalog", refresh)

        // `AppModel.rebuildSearch` runs this on every search-field edit.
        for (name, term) in [
            ("search_common_term", "合成"),
            ("search_rare_term", "项目\(max(0, catalog.records.count - 1))"),
            ("search_no_match", "zzqx"),
            ("search_date_term", "2020-01"),
        ] {
            var samples = Samples()
            var matchCount = 0
            for _ in 0..<iterations {
                let started = now()
                matchCount = RecordQuery.search(
                    term,
                    records: confirmed,
                    members: catalog.members
                ).count
                samples.append(milliseconds(since: started))
            }
            report.set(name, samples)
            report.set("\(name)_matches", matchCount)
        }
        var timeline = Samples()
        for _ in 0..<iterations {
            let started = now()
            _ = RecordQuery.timeline(records: confirmed, memberID: member.id)
            timeline.append(milliseconds(since: started))
        }
        report.set("timeline_one_member", timeline)

        let drafts = catalog.importDrafts.filter { $0.state == .needsReview }
        guard drafts.count >= iterations else { throw ProbeError.unexpectedState }

        var reviewSnapshot = Samples()
        for draft in drafts.prefix(iterations) {
            let started = now()
            _ = try await store.loadReviewSnapshot(draftID: draft.id)
            reviewSnapshot.append(milliseconds(since: started))
        }
        report.set("read_snapshot_review", reviewSnapshot)

        var saveReview = Samples()
        var confirm = Samples()
        for draft in drafts.prefix(iterations) {
            let document = try await store.loadDocument(draftID: draft.id)
            let reviewed = ImportDraftDocument(
                blocks: document.blocks,
                candidates: document.candidates,
                candidateExtractionVersion: document.candidateExtractionVersion,
                reviewState: ImportDraftReviewState(
                    timelineDateSelection: .unknown,
                    title: document.candidates.title?.transcription ?? "",
                    organization: document.candidates.organization?.transcription ?? "",
                    department: document.candidates.department?.transcription ?? "",
                    reportType: document.candidates.reportType?.transcription ?? "",
                    reportedResults: document.candidates.reportedResults?.transcription ?? "",
                    conclusion: document.candidates.conclusion?.transcription ?? "",
                    abnormalItems: document.candidates.abnormalItems.map(\.transcription),
                    userNote: "合成复核备注"
                )
            )
            var started = now()
            try await store.saveReview(
                draftID: draft.id,
                expectedRevision: draft.revision,
                memberID: member.id,
                document: reviewed
            )
            saveReview.append(milliseconds(since: started))

            catalog = try await vault.loadCatalog()
            guard let saved = catalog.importDrafts.first(where: { $0.id == draft.id }) else {
                throw ProbeError.unexpectedState
            }
            let record = try confirmedRecord(
                member: member,
                sources: saved.sources,
                documentID: saved.documentObjectID,
                candidates: document.candidates,
                note: "合成复核备注"
            )
            started = now()
            try await store.confirm(
                draftID: saved.id,
                expectedRevision: saved.revision,
                record: record
            )
            confirm.append(milliseconds(since: started))
            catalog = try await vault.loadCatalog()
        }
        report.set("commit_save_review", saveReview)
        report.set("commit_confirm", confirm)

        // Mirrors `LiveAppService.mutateCatalog`: load, transform, commit.
        var edit = Samples()
        for iteration in 0..<iterations {
            let started = now()
            let current = try await vault.loadCatalog()
            guard let index = current.records.firstIndex(where: {
                $0.importState == .confirmed
            }) else { throw ProbeError.unexpectedState }
            let record = current.records[index]
            var records = current.records
            records[index] = try HealthRecord(
                id: record.id,
                memberID: record.memberID,
                sources: record.sources,
                ocrDocumentObjectID: record.ocrDocumentObjectID,
                importState: .confirmed,
                revision: record.revision + 1,
                title: record.title,
                organization: record.organization,
                department: record.department,
                reportType: record.reportType,
                dateCandidates: record.dateCandidates,
                timelineDateCandidateID: record.timelineDateCandidateID,
                reportedResults: record.reportedResults,
                conclusion: record.conclusion,
                abnormalItems: record.abnormalItems,
                notes: [try UserNote(text: "合成编辑备注 \(iteration)")]
            )
            catalog = try await vault.commit(try VaultCommitRequest(
                expectedGeneration: current.generation,
                catalog: try current.replacing(records: records),
                writes: []
            ))
            edit.append(milliseconds(since: started))
        }
        report.set("commit_edit_confirmed_record", edit)

        // Isolates the lookup cost from JSON loading, hashing, and committing.
        let unmatched = try ReportFingerprint(sources: [
            .init(sha256Digest: Data(repeating: 0xA7, count: 32), byteCount: 1)
        ])
        var duplicateLookup = Samples()
        for _ in 0..<iterations {
            let started = now()
            let duplicate = DuplicateDetector.find(
                fingerprint: unmatched,
                attachments: catalog.attachments,
                records: catalog.records,
                drafts: catalog.importDrafts
            )
            duplicateLookup.append(milliseconds(since: started))
            guard duplicate == nil else { throw ProbeError.unexpectedState }
        }
        report.set("duplicate_detector_no_match", duplicateLookup)

        var stage = Samples()
        let bytes = SyntheticBytes()
        for iteration in 0..<iterations {
            let data = bytes.make(
                byteCount: configuration.attachmentByteCount,
                domain: 3,
                ordinal: iteration
            )
            let file = try ValidatedImportedFile(
                data: data,
                kind: .image,
                contentTypeIdentifier: "public.jpeg",
                sha256Digest: ContentDigest.sha256(data)
            )
            let started = now()
            guard case .created = try await store.stage(file) else {
                throw ProbeError.unexpectedState
            }
            stage.append(milliseconds(since: started))
        }
        report.set("commit_stage_new_original", stage)

        try componentEstimates(rootURL: configuration.rootURL, iterations: iterations, into: &report)
        report.set("footprint_peak_bytes", Memory.current().peakFootprint)
    }

    /// Splits one manifest resolution into its parts with mirror types. These
    /// are estimates taken outside the Vault actor, not instrumented
    /// production timings.
    private static func componentEstimates(
        rootURL: URL,
        iterations: Int,
        into report: inout ProbeReport
    ) throws {
        struct ObjectMirror: Decodable {
            let reference: VaultObjectReference
            let byteCount: Int
            let sha256Digest: Data
        }
        struct ManifestMirror: Decodable {
            let catalog: VaultCatalog
            let objects: [ObjectMirror]
        }
        let manifestURL = rootURL.appendingPathComponent("library.json", isDirectory: false)
        var decode = Samples()
        var encode = Samples()
        var digestSamples = Samples()
        var stat = Samples()
        var manifest: ManifestMirror?
        for _ in 0..<iterations {
            let data = try Data(contentsOf: manifestURL)
            var started = now()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            manifest = try decoder.decode(ManifestMirror.self, from: data)
            decode.append(milliseconds(since: started))
            guard let manifest else { throw ProbeError.unexpectedState }
            started = now()
            let encoded = try canonicalJSON(manifest.catalog)
            encode.append(milliseconds(since: started))
            started = now()
            _ = ContentDigest.sha256(encoded)
            digestSamples.append(milliseconds(since: started))
        }
        guard let manifest else { throw ProbeError.unexpectedState }
        let objectsURL = rootURL.appendingPathComponent("objects", isDirectory: true)
        for _ in 0..<iterations {
            let started = now()
            var metadata = Darwin.stat()
            var count = 0
            for directory in try FileManager.default.contentsOfDirectory(atPath: objectsURL.path) {
                let directoryURL = objectsURL.appendingPathComponent(directory, isDirectory: true)
                for name in try FileManager.default.contentsOfDirectory(atPath: directoryURL.path) {
                    if lstat(directoryURL.appendingPathComponent(name).path, &metadata) == 0 {
                        count += 1
                    }
                }
            }
            stat.append(milliseconds(since: started))
            guard count >= manifest.objects.count else { throw ProbeError.unexpectedState }
        }
        report.set("estimate_manifest_json_decode", decode)
        report.set("estimate_catalog_json_encode", encode)
        report.set("estimate_catalog_sha256", digestSamples)
        report.set("estimate_object_list_and_lstat", stat)
    }

    // MARK: - LAN inbox

    private static func inbox(
        _ configuration: Configuration,
        into report: inout ProbeReport
    ) async throws {
        guard !configuration.inboxCheckpoints.isEmpty else { throw ProbeError.invalidArguments }
        let vault = try PlaintextVault(rootURL: configuration.rootURL)
        if await vault.inspect() == .absent { _ = try await vault.initialize() }
        let catalog = try await vault.loadCatalog()
        let store = try PlaintextLANInboxStore(rootURL: configuration.rootURL)
        if await store.inspect() == .absent { _ = try await store.initialize() }
        try requireAvailableCapacity(
            at: configuration.workDirectory,
            byteCount: Int64(configuration.inboxCheckpoints.last ?? 0)
                * Int64(configuration.inboxItemByteCount) + reserveByteCount
        )
        report.set("vault_object_count", catalog.reachableObjectReferences.count)
        report.set("inbox_item_bytes", configuration.inboxItemByteCount)

        let bytes = SyntheticBytes()
        let manifestURL = configuration.rootURL
            .appendingPathComponent("lan-inbox", isDirectory: true)
            .appendingPathComponent("inbox.json", isDirectory: false)
        var uploaded = try await store.loadSnapshot().items.count
        var sessionID = UUID()
        var sessionUploadCount = 0
        func upload() async throws -> Double {
            if sessionUploadCount == 200 {
                try await store.endItemSession(sessionID: sessionID)
                sessionID = UUID()
                sessionUploadCount = 0
            }
            let data = bytes.make(
                byteCount: configuration.inboxItemByteCount,
                domain: 4,
                ordinal: uploaded
            )
            let metadata = try LANInboxTransportMetadata(
                displayName: try LANInboxDisplayName(rawValue: "synthetic-\(uploaded).jpg"),
                declaredByteCount: data.count,
                mediaType: "image/jpeg"
            )
            let started = now()
            let admission = try await store.itemAdmissionGeneration()
            guard case let .sink(sink) = try await store.startItemUpload(
                transport: LANInboxTransportIdentity(sessionID: sessionID, remoteFileID: UUID()),
                metadata: metadata,
                attemptRevision: 1,
                admissionGeneration: admission
            ) else { throw ProbeError.unexpectedState }
            try await sink.write(data).value
            _ = try await sink.finish()
            let elapsed = milliseconds(since: started)
            uploaded += 1
            sessionUploadCount += 1
            return elapsed
        }

        let fillStarted = now()
        for checkpoint in configuration.inboxCheckpoints {
            guard checkpoint >= uploaded else { throw ProbeError.invalidArguments }
            while uploaded < checkpoint { _ = try await upload() }
            var entry = ProbeReport()
            entry.set("pending_items_before", uploaded)
            entry.set("inbox_manifest_bytes", try fileByteCount(manifestURL))
            var refresh = Samples()
            for _ in 0..<configuration.iterations {
                let started = now()
                _ = try await store.snapshotAndStorageSummary()
                refresh.append(milliseconds(since: started))
            }
            entry.set("screen_refresh", refresh)
            var publish = Samples()
            for _ in 0..<configuration.iterations { publish.append(try await upload()) }
            entry.set("publish_one_item", publish)
            report.set("checkpoint_\(checkpoint)", entry)
        }
        report.set("fill_and_measure_ms", milliseconds(since: fillStarted))
        report.set("footprint_peak_bytes", Memory.current().peakFootprint)
    }

    /// Adds a durable blob and a valid derived document above a full Vault's object cap.
    private static func capacityInbox(
        _ configuration: Configuration,
        into report: inout ProbeReport
    ) async throws {
        let vault = try PlaintextVault(rootURL: configuration.rootURL)
        guard try await vault.loadCatalog().reachableObjectReferences.count == 20_000 else {
            throw ProbeError.unexpectedState
        }
        var uploadConfiguration = configuration
        uploadConfiguration.inboxCheckpoints = [0]
        uploadConfiguration.iterations = 1
        try await inbox(uploadConfiguration, into: &report)
        let store = try PlaintextLANInboxStore(rootURL: configuration.rootURL)
        let snapshot = try await store.loadSnapshot()
        guard snapshot.items.count == 1, let item = snapshot.items.first else {
            throw ProbeError.unexpectedState
        }
        let document = try LANPreprocessedSourceDocument(
            source: ReportSource(attachmentID: UUID(), displayName: item.displayName.rawValue, pageCount: 1),
            contentTypeIdentifier: "public.jpeg", blocks: []
        )
        let sink = try await store.beginItemDerivedArtifact(itemID: item.id, expectedRevision: item.revision)
        try await sink.write(canonicalJSON(document)).value
        _ = try await sink.finish()
        let completed = try await store.loadSnapshot()
        guard completed.items.count == 1, completed.blobs.count == 1,
              completed.items.first?.derivedArtifact != nil else { throw ProbeError.unexpectedState }
        report.set("durable_blob_count", completed.blobs.count)
        report.set("derived_document_count", completed.items.compactMap(\.derivedArtifact).count)
    }

    // MARK: - Backup

    /// Runs the production publisher end to end: repository scan, source
    /// plan, encrypted streaming write, full read-back and durable witness.
    /// The command deadline bounds actual execution; timings include full verification.
    private static func backup(
        _ configuration: Configuration,
        into report: inout ProbeReport
    ) async throws {
        let selected = configuration.workDirectory.appendingPathComponent("selected", isDirectory: true)
        if configuration.command == .logicalBackup || configuration.command == .logicalCapacity {
            for name in ["selected", "BackupIdentity", "restored"] {
                guard !FileManager.default.fileExists(atPath: configuration.workDirectory.appendingPathComponent(name).path) else {
                    throw ProbeError.invalidWorkDirectory
                }
            }
        }
        let repositoryURL = selected.appendingPathComponent(".kinlogue-backup-v1", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repositoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(selected.path, 0o700) == 0, chmod(repositoryURL.path, 0o700) == 0 else {
            throw ProbeError.unexpectedState
        }
        let material = try BackupKeyHierarchy.makeEnrollment()
        let repositoryIdentity = try directoryIdentity(repositoryURL)
        try BackupEnrollmentRepository().publish(
            descriptor: material.descriptor,
            authorization: material.authorization,
            repositoryURL: repositoryURL,
            expectedIdentity: repositoryIdentity
        )
        let configurationStore = BackupLocalConfigurationStore(
            rootURL: configuration.workDirectory.appendingPathComponent(
                "BackupIdentity",
                isDirectory: true
            )
        )
        let created = try await configurationStore.createPending(try BackupPendingEnrollment(
            bookmarkData: Data("synthetic-scale-probe-bookmark".utf8),
            selectedDirectoryIdentity: try directoryIdentity(selected),
            repositoryDirectoryIdentity: repositoryIdentity,
            descriptor: material.descriptor,
            authorization: material.authorization,
            deviceSigningSeed: material.deviceSigningSeed,
            writerEpoch: material.writerEpoch
        ))
        let enabled = try await configurationStore.promotePending(
            enrollmentEpoch: created.enrollmentEpoch,
            expectedRevision: created.revision
        )

        if configuration.command == .logicalBackup || configuration.command == .logicalCapacity {
            try await logicalBackup(configuration, repositoryURL: repositoryURL, configurationStore: configurationStore,
                enabled: enabled, recoveryCode: material.recoveryCode, into: &report)
            return
        }

        let vault = try PlaintextVault(rootURL: configuration.rootURL)
        let inboxStore = try PlaintextLANInboxStore(rootURL: configuration.rootURL)
        let source = try PlaintextLibraryBackupSource(vault: vault, inboxStore: inboxStore)
        var started = now()
        let plan: PlaintextLibraryBackupPlan
        do {
            plan = try await source.prepare()
        } catch PlaintextLibraryBackupSourceError.resourceLimit {
            // The library is valid but exceeds what one restore point may hold.
            report.set("prepare_source_plan_ms", milliseconds(since: started))
            report.set("publish_outcome", "refusedResourceLimit")
            report.set("format_maximum_entry_count", BackupFormatLimits.maximumEntryCount)
            report.set("format_maximum_plaintext_bytes", BackupFormatLimits.maximumPlaintextByteCount)
            try describe(try await vault.loadCatalog(), rootURL: configuration.rootURL, into: &report)
            return
        }
        report.set("prepare_source_plan_ms", milliseconds(since: started))
        report.set("plan_entry_count", plan.entryCount)
        report.set("plan_plaintext_bytes", plan.totalPlaintextByteCount)

        // Full validation is now paid at final publication, once per snapshot.
        // The old per-entry multiplier no longer predicts this implementation.
        started = now()
        try await source.validateCurrentPair(for: plan)
        report.set("final_source_pair_validation_ms", milliseconds(since: started))

        let before = Memory.current()
        started = now()
        let result = try await BackupCheckpointPublisher(
            repository: BackupRepository(
                repositoryURL: repositoryURL,
                expectedIdentity: enabled.repositoryDirectoryIdentity,
                trustedDescriptor: enabled.descriptor,
                expectedAuthorizationID: enabled.authorization.authorizationID,
                leaseAuthority: .init(
                    configurationRootURL: configurationStore.rootURL,
                    configuration: enabled
                )
            ),
            writer: EncryptedCheckpointWriter(source: source, configurationStore: configurationStore),
            configurationStore: configurationStore
        ).publishNext(configuration: enabled)
        report.set("publish_restore_point_ms", milliseconds(since: started))
        report.set("publish_outcome", "published")
        let after = Memory.current()
        report.set("restore_point_bytes", result.fileIdentity.byteCount)
        report.set("footprint_before_bytes", before.footprint)
        report.set("footprint_peak_bytes", after.peakFootprint)
        report.set("max_rss_bytes", after.maximumResidentSize)

        let destination = configuration.workDirectory.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let restoredRoot = destination.appendingPathComponent("Vault", isDirectory: true)
        let verifier = try BackupRestoreVerifier(stableParentURL: destination, activeRootURL: restoredRoot)
        started = now()
        let prepared = try await verifier.prepare(
            checkpointURL: repositoryURL.appendingPathComponent(result.finalLeafName),
            recoveryCode: material.recoveryCode
        )
        guard prepared.summary.revisionPair == plan.revisionPair else { throw ProbeError.unexpectedState }
        let transaction = try BackupRestoreTransaction(activeRootURL: restoredRoot)
        _ = try await transaction.activate(prepared: prepared, resetWriter: {})
        _ = try await transaction.reconcile()
        report.set("strict_restore_ms", milliseconds(since: started))
        report.set("restore_outcome", "verifiedAndActivated")
        report.set("restore_footprint_peak_bytes", Memory.current().peakFootprint)
    }

    private static func logicalBackup(
        _ configuration: Configuration, repositoryURL: URL, configurationStore: BackupLocalConfigurationStore,
        enabled: BackupLocalConfiguration, recoveryCode: String, into report: inout ProbeReport
    ) async throws {
        let store = try SQLiteLibraryStore(rootURL: configuration.rootURL)
        defer { try? store.close() }
        let repository = SQLiteReportRepository(store: store)
        let members = try await repository.members()
        let sourceCounts = try await logicalCounts(repository)
        let drafts = try await repository.drafts()
        var sampleDraft: ImportDraft?
        if let first = drafts.items.first { sampleDraft = try await repository.draft(first.id) }
        var sampleDocument: ImportDraftDocument?
        if let sampleDraft, sampleDraft.documentObjectID != nil { sampleDocument = try await repository.loadDocument(draftID: sampleDraft.id) }
        let page = try await repository.reportPage()
        var sampleRecords: [HealthRecord] = []
        for item in page.items.prefix(8) { sampleRecords.append(try await repository.record(item.id)) }
        let inbox = try SQLiteLANInboxStore(store: store)
        let sourceInbox = try await inbox.loadSnapshot()
        var sampleLAN: LANPreprocessedSourceDocument?
        if let item = sourceInbox.items.first, item.derivedArtifact != nil {
            sampleLAN = try await inbox.loadPreprocessedDocument(itemID: item.id, expectedRevision: item.revision)
        }
        let phases = LogicalCapturePhases()
        let source = SQLiteLogicalBackupSource(store: store, captureObservation: phases.record)
        let expectedPair = try source.currentRevision()
        let before = Memory.current()
        let peaks = LogicalCaptureFDPeak()
        peaks.sample()
        let sampler = Task.detached {
            while !Task.isCancelled { peaks.sample(); try? await Task.sleep(for: .milliseconds(5)) }
        }
        var started = now()
        do {
            let result = try await BackupCheckpointPublisher(
                repository: BackupRepository(repositoryURL: repositoryURL,
                    expectedIdentity: enabled.repositoryDirectoryIdentity, trustedDescriptor: enabled.descriptor,
                    expectedAuthorizationID: enabled.authorization.authorizationID,
                    leaseAuthority: .init(configurationRootURL: configurationStore.rootURL, configuration: enabled)),
                writer: EncryptedCheckpointWriter(source: source, configurationStore: configurationStore),
                configurationStore: configurationStore
            ).publishNext(configuration: enabled)
            report.set("publish_restore_point_ms", milliseconds(since: started))
            report.set("publish_outcome", "published")
            report.set("restore_point_bytes", result.fileIdentity.byteCount)
            report.set("publish_footprint_peak_bytes", Memory.current().peakFootprint)
            report.set("publish_footprint_peak_sampled_bytes", peaks.footprint)
            report.set("publish_footprint_increment_sampled_bytes", peaks.footprint > before.footprint ? peaks.footprint - before.footprint : 0)
            report.set("writer_maximum_buffered_bytes", result.maximumBufferedPlaintextByteCount)
            report.set("writer_maximum_source_files", result.maximumSimultaneousSourceFileCount)
            guard result.revisionPair == expectedPair, try source.currentRevision() == expectedPair,
                  phases.values.filter({ $0.0 == 0 }).count == 1 else { throw ProbeError.unexpectedState }
            let counts = Dictionary(uniqueKeysWithValues: phases.values.map { ($0.0, $0.1) })
            guard counts[BackupLogicalKind.original.rawValue] == sourceCounts.0 + sourceCounts.1 + sourceInbox.items.count,
                  (counts[BackupLogicalKind.report.rawValue] ?? 0) == sourceCounts.0,
                  (counts[BackupLogicalKind.draft.rawValue] ?? 0) == sourceCounts.1,
                  (counts[BackupLogicalKind.inbox.rawValue] ?? 0) == sourceInbox.items.count else { throw ProbeError.unexpectedState }
            let originalCount = counts[242] ?? 0
            report.set("captured_original_count", originalCount)
            report.set("container_entry_count_inferred_minimum", originalCount + 1)
            if configuration.command == .logicalCapacity {
                guard originalCount == configuration.reportCount + 1, sourceCounts.1 == configuration.reportCount,
                      sampleLAN != nil else { throw ProbeError.unexpectedState }
            }
            let destination = configuration.workDirectory.appendingPathComponent("restored", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let restoredRoot = destination.appendingPathComponent("Vault", isDirectory: true)
            let owner = try SQLiteLibraryOwner(rootURL: restoredRoot)
            let verifier = try BackupRestoreVerifier(owner: owner)
            started = now()
            let prepared = try await verifier.prepare(checkpointURL: repositoryURL.appendingPathComponent(result.finalLeafName), recoveryCode: recoveryCode)
            report.set("restore_prepare_ms", milliseconds(since: started))
            guard prepared.summary.revisionPair == expectedPair, prepared.summary.logicalDigest?.count == 32,
                  prepared.summary.memberCount == members.count, prepared.summary.recordCount == sourceCounts.0,
                  prepared.summary.inboxItemCount == sourceInbox.items.count else { throw ProbeError.unexpectedState }
            let transaction = try BackupRestoreTransaction(owner: owner)
            let activation = try await transaction.activate(prepared: prepared, resetWriter: {})
            guard activation.summary == prepared.summary, try await transaction.reconcile() == .committed else { throw ProbeError.unexpectedState }
            report.set("strict_restore_ms", milliseconds(since: started))
            report.set("restore_outcome", "verifiedAndActivated")
            report.set("plaintext_bytes", prepared.summary.plaintextByteCount)
            let restored = try SQLiteLibraryStore(owner: owner, mode: .strictExisting)
            defer { try? restored.close() }
            let restoredReports = SQLiteReportRepository(store: restored)
            let restoredCounts = try await logicalCounts(restoredReports)
            guard restoredCounts == sourceCounts, try await restoredReports.members() == members,
                  try SQLiteLogicalBackupSource(store: restored).currentRevision() == expectedPair else { throw ProbeError.unexpectedState }
            for record in sampleRecords { guard try await restoredReports.record(record.id) == record else { throw ProbeError.unexpectedState } }
            if let draft = sampleDraft {
                let after = try await restoredReports.draft(draft.id)
                guard after.sources == draft.sources, after.memberID == draft.memberID else { throw ProbeError.unexpectedState }
                if let sampleDocument {
                    guard after == draft, try await restoredReports.loadDocument(draftID: draft.id) == sampleDocument else { throw ProbeError.unexpectedState }
                } else {
                    guard after.state == .failed, after.failureCode == .cancelled else { throw ProbeError.unexpectedState }
                }
            }
            let restoredInbox = try SQLiteLANInboxStore(store: restored)
            let afterInbox = try await restoredInbox.loadSnapshot()
            guard afterInbox.items == sourceInbox.items, afterInbox.transportReceipts == sourceInbox.transportReceipts else { throw ProbeError.unexpectedState }
            if let sampleLAN, let item = afterInbox.items.first {
                guard try await restoredInbox.loadPreprocessedDocument(itemID: item.id, expectedRevision: item.revision) == sampleLAN else { throw ProbeError.unexpectedState }
            }
            report.set("record_count", sourceCounts.0); report.set("draft_count", sourceCounts.1)
            report.set("member_count", members.count); report.set("inbox_item_count", sourceInbox.items.count)
            report.set("representative_record_count", sampleRecords.count)
            report.set("representative_user_note_count", sampleRecords.reduce(0) { $0 + $1.notes.count })
            report.set("representative_ocr_block_count", sampleDocument?.blocks.count ?? 0)
            report.set("representative_review_state_count", sampleDocument?.reviewState == nil ? 0 : 1)
            report.set("representative_lan_document_count", sampleLAN == nil ? 0 : 1)
            report.set("invariants", "captured-pair,strict-activation,all-counts,representative-content verified")
        } catch {
            report.set("failed_phase_elapsed_ms", milliseconds(since: started))
            report.set("outcome", error as? SQLiteLogicalBackupError == .captureTimedOut ? "captureTimedOut" : "failed")
            sampler.cancel(); await sampler.value
            recordLogicalResources(phases, peaks: peaks, before: before, into: &report)
            print(report.json)
            throw error
        }
        sampler.cancel(); await sampler.value
        recordLogicalResources(phases, peaks: peaks, before: before, into: &report)
    }

    private static func logicalCounts(_ repository: SQLiteReportRepository) async throws -> (Int, Int) {
        var reports = 0, drafts = 0
        var cursor: LibraryQueryCursor?
        repeat {
            let page = try await repository.reportPage(cursor: cursor)
            guard page.damagedIDs.isEmpty, page.damagedMemberIDs.isEmpty else { throw ProbeError.unexpectedState }
            reports += page.items.count; cursor = page.nextCursor
        } while cursor != nil
        repeat {
            let page = try await repository.drafts(cursor: cursor)
            guard page.damagedIDs.isEmpty else { throw ProbeError.unexpectedState }
            drafts += page.items.count; cursor = page.nextCursor
        } while cursor != nil
        return (reports, drafts)
    }

    private static func recordLogicalResources(_ phases: LogicalCapturePhases, peaks: LogicalCaptureFDPeak,
                                               before: Memory, into report: inout ProbeReport) {
        report.set("footprint_before_bytes", before.footprint)
        report.set("footprint_peak_bytes", Memory.current().peakFootprint)
        report.set("footprint_peak_sampled_bytes", peaks.footprint)
        report.set("fd_peak_sampled", peaks.value)
        report.set("max_rss_bytes", Memory.current().maximumResidentSize)
        for (kind, count, duration, footprint, peak) in phases.values {
            report.set("phase_\(kind)_emitted_count", count); report.set("phase_\(kind)_ms", duration * 1_000)
            report.set("phase_\(kind)_footprint_bytes", footprint); report.set("phase_\(kind)_peak_bytes", peak)
        }
    }

    // MARK: - Helpers

    private static func describe(
        _ catalog: VaultCatalog,
        rootURL: URL,
        into report: inout ProbeReport
    ) throws {
        let byteCount = catalog.attachments.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
        report.set("vault_object_count", catalog.reachableObjectReferences.count)
        report.set("member_count", catalog.members.count)
        report.set("record_count", catalog.records.count)
        report.set("draft_count", catalog.importDrafts.count)
        report.set("attachment_count", catalog.attachments.count)
        report.set("dicom_study_count", catalog.dicomStudies.count)
        report.set("attachment_bytes", byteCount)
        report.set(
            "manifest_bytes",
            try fileByteCount(rootURL.appendingPathComponent("library.json", isDirectory: false))
        )
    }

    private static func requireAvailableCapacity(at url: URL, byteCount: Int64) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              available >= byteCount else {
            throw ProbeError.insufficientDiskSpace
        }
    }

    private static func fileByteCount(_ url: URL) throws -> Int {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw ProbeError.unexpectedState
        }
        return Int(metadata.st_size)
    }

    private static func directoryIdentity(_ url: URL) throws -> BackupFilesystemIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ProbeError.unexpectedState
        }
        return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }

    /// Same settings as the Platform's canonical Vault JSON.
    private static func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    private static func digest(_ label: String) -> Data {
        ContentDigest.sha256(Data(label.utf8))
    }

    private static let vocabulary = [
        "合成", "项目", "结果", "参考", "区间", "单位", "数值", "样本", "编号", "正常",
        "偏高", "偏低", "未见", "复查", "synthetic", "value", "range",
    ]

    private static func syntheticText(seed: Int, characterCount: Int) -> String {
        var generator = SplitMix64(state: UInt64(truncatingIfNeeded: seed) &+ 0x9E37_79B9_7F4A_7C15)
        var text = ""
        while text.count < characterCount {
            let word = vocabulary[Int(generator.next() % UInt64(vocabulary.count))]
            text += word
            text += generator.next() % 3 == 0 ? " \(generator.next() % 1_000) " : " "
        }
        return String(text.prefix(characterCount)).trimmingCharacters(in: .whitespaces)
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func milliseconds(since started: UInt64) -> Double {
        Double(now() - started) / 1_000_000
    }
}

private extension VaultCatalog {
    func replacing(
        members: [FamilyMember]? = nil,
        records: [HealthRecord]? = nil,
        attachments: [Attachment]? = nil,
        importDrafts: [ImportDraft]? = nil,
        dicomStudies: [DICOMStudy]? = nil
    ) throws -> VaultCatalog {
        try VaultCatalog(
            vaultID: vaultID,
            generation: try VaultGeneration.successor(of: generation),
            members: members ?? self.members,
            records: records ?? self.records,
            attachments: attachments ?? self.attachments,
            importDrafts: importDrafts ?? self.importDrafts,
            dicomStudies: dicomStudies ?? self.dicomStudies
        )
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// Unique, incompressible-looking content without holding more than one
/// shared megabyte of generator output.
private struct SyntheticBytes {
    private let block: Data

    init() {
        var generator = SplitMix64(state: 0x4B4C_4753_4341_4C45)
        var block = Data(capacity: 1_024 * 1_024)
        for _ in 0..<(1_024 * 1_024 / 8) {
            withUnsafeBytes(of: generator.next()) { block.append(contentsOf: $0) }
        }
        self.block = block
    }

    func make(byteCount: Int, domain: UInt8, ordinal: Int) -> Data {
        var data = Data(capacity: byteCount)
        var header = Data([domain, 0x4B, 0x4C, 0x47])
        withUnsafeBytes(of: UInt64(ordinal).bigEndian) { header.append(contentsOf: $0) }
        data.append(header.prefix(byteCount))
        while data.count < byteCount {
            data.append(block.prefix(byteCount - data.count))
        }
        return data
    }
}

private struct Samples {
    private(set) var values: [Double] = []

    mutating func append(_ value: Double) { values.append(value) }

    var median: Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    var logicalReport: ProbeReport {
        var result = report
        let sorted = values.sorted()
        result.set("p50_ms", sorted[(sorted.count - 1) / 2])
        result.set("empirical_p95_ms", sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1])
        for (index, value) in values.enumerated() { result.set("sample_\(index)_ms", value) }
        return result
    }

    var report: ProbeReport {
        var report = ProbeReport()
        report.set("n", values.count)
        report.set("min_ms", values.min() ?? 0)
        report.set("median_ms", median)
        report.set("max_ms", values.max() ?? 0)
        return report
    }
}

private struct Memory {
    let footprint: UInt64
    let peakFootprint: UInt64
    let maximumResidentSize: UInt64

    static func current() -> Memory {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Memory(
            footprint: result == KERN_SUCCESS ? info.phys_footprint : 0,
            peakFootprint: result == KERN_SUCCESS
                ? UInt64(max(0, info.ledger_phys_footprint_peak))
                : 0,
            maximumResidentSize: UInt64(max(0, usage.ru_maxrss))
        )
    }
}

/// Insertion-ordered JSON object so the emitted line reads in probe order.
private struct ProbeReport {
    private var fields: [(key: String, fragment: String)] = []

    mutating func set(_ key: String, _ value: Int) { fields.append((key, String(value))) }
    mutating func set(_ key: String, _ value: Int64) { fields.append((key, String(value))) }
    mutating func set(_ key: String, _ value: UInt64) { fields.append((key, String(value))) }
    mutating func set(_ key: String, _ value: Double) {
        fields.append((key, String(format: "%.3f", value)))
    }
    mutating func set(_ key: String, _ value: String) {
        fields.append((key, "\"\(value)\""))
    }
    mutating func set(_ key: String, _ value: Samples) { fields.append((key, value.report.json)) }
    mutating func set(_ key: String, _ value: ProbeReport) { fields.append((key, value.json)) }

    var json: String {
        "{" + fields.map { "\"\($0.key)\":\($0.fragment)" }.joined(separator: ",") + "}"
    }
}

// SAFETY: lock protects metrics shared by the probe and GRDB callback; reads return copies.
private final class LogicalCapturePhases: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(UInt8, Int, TimeInterval, UInt64, UInt64)] = []
    var values: [(UInt8, Int, TimeInterval, UInt64, UInt64)] { lock.withLock { storage } }
    func record(_ kind: UInt8, _ count: Int, _ duration: TimeInterval) {
        let memory = Memory.current()
        lock.withLock { storage.append((kind, count, duration, memory.footprint, memory.peakFootprint)) }
    }
}

// SAFETY: lock protects FD/footprint peaks shared by the sampler and probe task.
private final class LogicalCaptureFDPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0
    private var memoryPeak: UInt64 = 0
    var footprint: UInt64 { lock.withLock { memoryPeak } }
    var value: Int { lock.withLock { peak } }
    func sample() {
        let count = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).compactMap(Int32.init)
            .filter { fcntl($0, F_GETFD) != -1 }.count
        let memory = Memory.current().footprint
        lock.withLock { peak = max(peak, count); memoryPeak = max(memoryPeak, memory) }
    }
}
