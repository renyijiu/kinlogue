import Darwin
import Foundation
import KinlogueCore
import KinloguePlatform

/// Characterizes the SQLite library and its LAN inbox at synthetic scale.
///
/// Every byte is generated at run time inside an owned temporary work
/// directory. The probe drives the production repositories through their own
/// API; it does not reimplement commit, query or backup algorithms, and it
/// never opens the App's Application Support library.
enum StorageScaleProbe {
    private static let workDirectoryPrefix = "kinlogue-storage-scale-probe."
    private static let reserveByteCount: Int64 = 16 * 1_024 * 1_024 * 1_024
    private static let memberCount = 6
    private static let ocrBlockCount = 60

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

    private static func logicalGenerate(_ configuration: Configuration, into report: inout ProbeReport) async throws {
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
        for ordinal in 0..<configuration.reportCount {
            let data = bytes.make(byteCount: configuration.attachmentByteCount, domain: 1, ordinal: ordinal)
            let file = try ValidatedImportedFile(data: data, kind: .image, contentTypeIdentifier: "public.jpeg", sha256Digest: ContentDigest.sha256(data))
            guard case let .created(id) = try await repository.stage(file) else { throw ProbeError.unexpectedState }
            let initial = try await repository.draft(id)
            let member = members[ordinal % members.count]
            let document = try makeDocument(ordinal: ordinal, member: member, source: initial.sources.elements[0])
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
            let document = try makeDocument(ordinal: iteration, member: member, source: initial.sources.first)
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
            // The first query of the process also decodes every row and derives its key.
            let firstStarted = now()
            let checked = try await repository.measureReportSearch(query)
            let firstElapsed = milliseconds(since: firstStarted)
            guard expected.ids == checked.ids, expected.damagedIDs == checked.damagedIDs else { throw ProbeError.unexpectedState }
            var result = ProbeReport()
            result.set("first_checked_ms", firstElapsed)
            result.set("match_count", checked.ids.count)
            result.set("oracle_ids_equal", "true")
            result.set("peak_batch_bytes", checked.peakBatchBytes)
            result.set("maximum_lanes", checked.maximumLanes)
            result.set("candidate_count", checked.candidateCount)
            result.set("cached_row_count", checked.cachedRowCount)
            var pageValues: [Double] = [], fullValues: [Double] = [], sqlValues: [Double] = [], directoryValues: [Double] = []
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
                directoryValues.append(full.directoryMilliseconds)
                result.set("full_match_sample_\(iteration)", fullElapsed)
                result.set("sql_read_sample_\(iteration)", full.sqlReadMilliseconds)
            }
            for (prefix, values) in [("first_page", pageValues), ("full_match", fullValues), ("sql_read", sqlValues), ("directory_read", directoryValues)] {
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

    /// One single-page report shaped like a reviewed lab report: 60 OCR
    /// blocks, nine sourced fields, two date candidates and three abnormal
    /// items. Text is obviously synthetic and carries no real identity.
    private static func makeDocument(
        ordinal: Int,
        member: FamilyMember,
        source: ReportSource
    ) throws -> ImportDraftDocument {
        let sources = try ReportSources([source])
        let blocks = try (0..<ocrBlockCount).map { blockIndex in
            try OCRBlock(
                sourceID: source.id,
                attachmentID: source.attachmentID,
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
                    attachmentID: source.attachmentID,
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
        return try ImportDraftDocument(blocks: blocks, candidates: candidates)
            .attributedAndValidated(for: sources)
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

    // MARK: - Backup

    /// Runs the production publisher end to end: repository scan, source
    /// plan, encrypted streaming write, full read-back and durable witness.
    /// The command deadline bounds actual execution; timings include full verification.
    private static func backup(
        _ configuration: Configuration,
        into report: inout ProbeReport
    ) async throws {
        let selected = configuration.workDirectory.appendingPathComponent("selected", isDirectory: true)
        for name in ["selected", "BackupIdentity", "restored"] {
            guard !FileManager.default.fileExists(atPath: configuration.workDirectory.appendingPathComponent(name).path) else {
                throw ProbeError.invalidWorkDirectory
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

        try await logicalBackup(configuration, repositoryURL: repositoryURL, configurationStore: configurationStore,
            enabled: enabled, recoveryCode: material.recoveryCode, into: &report)
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
            guard prepared.summary.revisionPair == expectedPair, prepared.summary.logicalDigest.count == 32,
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
