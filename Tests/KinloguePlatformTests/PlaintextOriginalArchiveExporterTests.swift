import CryptoKit
import Darwin
import Foundation
import Testing
import ZIPFoundation
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func originalArchiveExporterStreamsConfirmedOriginalsAndPublishesAReadableZIP() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    try Data("replace me".utf8).write(to: destination)
    let exporter = PlaintextOriginalArchiveExporter(store: fixture.store)

    let preparation = try await exporter.prepare(undatedToken: "Undated")
    #expect(preparation.entryCount == 1)
    #expect(preparation.totalByteCount == fixture.bytes.count)
    let result = try await exporter.export(preparation, to: destination)

    #expect(result.destinationURL == destination)
    #expect(result.entryCount == 1)
    let archive = try Archive(url: destination, accessMode: .read)
    let entries = Array(archive)
    #expect(entries.count == 1)
    #expect(entries[0].path == "Synthetic Member/Undated - Report 0001 - Source 0001 - Report.pdf")
    var extracted = Data()
    _ = try archive.extract(entries[0], bufferSize: 64 * 1_024) { extracted.append($0) }
    #expect(extracted == fixture.bytes)
}

@Test
func originalArchiveExporterPreservesExistingDestinationAndLeavesNoSuccessLookingPartial() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    let prior = Data("prior archive bytes".utf8)
    try prior.write(to: destination)
    let exporter = PlaintextOriginalArchiveExporter(
        store: fixture.store,
        fileManager: .default,
        failureInjector: { $0 == .beforeVerification }
    )

    let preparation = try await exporter.prepare(undatedToken: "Undated")
    await #expect(throws: PlaintextOriginalArchiveExportError.injectedFailure) {
        _ = try await exporter.export(preparation, to: destination)
    }

    #expect(try Data(contentsOf: destination) == prior)
    let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.container.path)
    #expect(siblings.filter { $0.hasSuffix(".zip") } == ["all-originals.zip"])
}

@Test
func originalArchiveExporterRejectsSourceDigestMismatchBeforePublication() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    try Data(repeating: 0x44, count: fixture.bytes.count).write(to: fixture.originalURL)
    let exporter = PlaintextOriginalArchiveExporter(store: fixture.store)

    let preparation = try await exporter.prepare(undatedToken: "Undated")
    await #expect(throws: PlaintextOriginalArchiveExportError.sourceIntegrityFailure) {
        _ = try await exporter.export(preparation, to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test
func originalArchiveExporterKeepsItsCapturedOriginalsWhenTheLibraryChangesBeforeCommit() async throws {
    let fixture = try await OriginalArchiveExportFixture.make(byteCount: 2 * 1_024 * 1_024)
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    let gate = ExportRevisionGate()
    let exporter = PlaintextOriginalArchiveExporter(
        store: fixture.store,
        fileManager: .default,
        failureInjector: { fault in
            guard fault == .beforeFinalRevisionCheck else { return false }
            gate.reachAndWait()
            return false
        }
    )
    let preparation = try await exporter.prepare(undatedToken: "Undated")
    let exportTask = Task {
        try await exporter.export(preparation, to: destination)
    }
    await gate.waitUntilReached()
    defer { gate.release() }
    // The archive was written from pinned originals. Deleting the report now removes its last
    // reference, yet the pinned bytes stay until the export lets go of them.
    try await fixture.reports.deleteRecord(fixture.record.id, expectedRevision: fixture.record.revision)
    #expect(FileManager.default.fileExists(atPath: fixture.originalURL.path))
    gate.release()

    let result = try await exportTask.value
    #expect(result.entryCount == 1)
    let archive = try Archive(url: destination, accessMode: .read)
    var extracted = Data()
    _ = try archive.extract(try #require(Array(archive).first), bufferSize: 64 * 1_024) { extracted.append($0) }
    #expect(extracted == fixture.bytes)
    #expect(!FileManager.default.fileExists(atPath: fixture.originalURL.path))
}

@Test
func originalArchiveExporterRejectsInvalidDestinations() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let exporter = PlaintextOriginalArchiveExporter(store: fixture.store)
    let preparation = try await exporter.prepare(undatedToken: "Undated")

    await #expect(throws: PlaintextOriginalArchiveExportError.invalidDestination) {
        _ = try await exporter.export(
            preparation,
            to: fixture.container.appendingPathComponent("not-a-zip.txt")
        )
    }
    await #expect(throws: PlaintextOriginalArchiveExportError.invalidDestination) {
        _ = try await exporter.export(
            preparation,
            to: fixture.vaultRoot.appendingPathComponent("leak.zip")
        )
    }
}

@Test
func originalArchiveExporterRevalidatesAParentReplacedBeforePublication() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let exportParent = fixture.container.appendingPathComponent("Export", isDirectory: true)
    try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: false)
    let destination = exportParent.appendingPathComponent("all-originals.zip")
    let prior = Data("prior archive bytes".utf8)
    try prior.write(to: destination)
    let replacement = fixture.container.appendingPathComponent(
        "OriginalExportParent",
        isDirectory: true
    )
    let swap = DestinationParentSwap(
        parent: exportParent,
        replacement: replacement,
        symlinkTarget: fixture.vaultRoot
    )
    let exporter = PlaintextOriginalArchiveExporter(
        store: fixture.store,
        fileManager: .default,
        destinationAccess: .init(start: { _ in .notRequired }, stop: { _ in }),
        failureInjector: { fault in
            if fault == .beforeCommit { swap.perform() }
            return false
        }
    )

    await #expect(throws: PlaintextOriginalArchiveExportError.invalidDestination) {
        _ = try await exporter.export(
            try await exporter.prepare(undatedToken: "Undated"),
            to: destination
        )
    }

    #expect(swap.succeeded)
    #expect(!FileManager.default.fileExists(
        atPath: fixture.vaultRoot.appendingPathComponent("all-originals.zip").path
    ))
    #expect(try Data(contentsOf: replacement.appendingPathComponent("all-originals.zip")) == prior)
}

@Test
func originalArchiveExporterKeepsFinalPublicationBoundToTheValidatedParent() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let exportParent = fixture.container.appendingPathComponent("Export", isDirectory: true)
    try FileManager.default.createDirectory(at: exportParent, withIntermediateDirectories: false)
    let destination = exportParent.appendingPathComponent("all-originals.zip")
    let replacement = fixture.container.appendingPathComponent(
        "OriginalExportParent",
        isDirectory: true
    )
    let swap = DestinationParentSwap(
        parent: exportParent,
        replacement: replacement,
        symlinkTarget: fixture.vaultRoot
    )
    let exporter = PlaintextOriginalArchiveExporter(
        store: fixture.store,
        fileManager: .default,
        destinationAccess: .init(start: { _ in .notRequired }, stop: { _ in }),
        failureInjector: { fault in
            if fault == .afterDestinationParentBinding { swap.perform() }
            return false
        }
    )

    await #expect(throws: PlaintextOriginalArchiveExportError.invalidDestination) {
        _ = try await exporter.export(
            try await exporter.prepare(undatedToken: "Undated"),
            to: destination
        )
    }

    #expect(swap.succeeded)
    #expect(!FileManager.default.fileExists(
        atPath: fixture.vaultRoot.appendingPathComponent("all-originals.zip").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: replacement.appendingPathComponent("all-originals.zip").path
    ))
    #expect(try FileManager.default.contentsOfDirectory(atPath: replacement.path).isEmpty)
}

@Test
func originalArchiveExporterDetectsPayloadCorruptionDuringFullVerification() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    let prior = Data("prior archive bytes".utf8)
    try prior.write(to: destination)
    let exporter = PlaintextOriginalArchiveExporter(
        store: fixture.store,
        fileManager: .default,
        failureInjector: { $0 == .corruptWorkArchiveBeforeVerification }
    )

    await #expect(throws: PlaintextOriginalArchiveExportError.archiveIntegrityFailure) {
        _ = try await exporter.export(
            try await exporter.prepare(undatedToken: "Undated"),
            to: destination
        )
    }
    #expect(try Data(contentsOf: destination) == prior)
}

@Test
func originalArchiveExporterRejectsAnInjectedShortSourceRead() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    let exporter = PlaintextOriginalArchiveExporter(
        store: fixture.store,
        fileManager: .default,
        failureInjector: { $0 == .shortSourceRead }
    )

    await #expect(throws: PlaintextOriginalArchiveExportError.sourceIntegrityFailure) {
        _ = try await exporter.export(
            try await exporter.prepare(undatedToken: "Undated"),
            to: destination
        )
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test
func originalArchiveExporterHonorsTaskCancellationBeforeCommit() async throws {
    let fixture = try await OriginalArchiveExportFixture.make(byteCount: 2 * 1_024 * 1_024)
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    let exporter = PlaintextOriginalArchiveExporter(store: fixture.store)
    let preparation = try await exporter.prepare(undatedToken: "Undated")
    let taskBox = ExportTaskBox()
    let task = Task {
        try await exporter.export(preparation, to: destination) { progress in
            if progress.phase == .writing, progress.completedByteCount > 0 {
                taskBox.cancel()
            }
        }
    }
    taskBox.set(task)

    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test
func originalArchiveExporterRejectsSymlinkTargetAndBalancesGrantedDestinationAccess() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    let symlinkTarget = fixture.container.appendingPathComponent("target.data")
    try Data("target".utf8).write(to: symlinkTarget)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: symlinkTarget)
    let exporter = PlaintextOriginalArchiveExporter(store: fixture.store)
    let preparation = try await exporter.prepare(undatedToken: "Undated")
    await #expect(throws: PlaintextOriginalArchiveExportError.invalidDestination) {
        _ = try await exporter.export(preparation, to: destination)
    }

    try FileManager.default.removeItem(at: destination)
    let access = DestinationAccessCounter()
    let failingExporter = PlaintextOriginalArchiveExporter(
        store: fixture.store,
        fileManager: .default,
        destinationAccess: .init(
            start: { _ in access.started(); return .granted },
            stop: { _ in access.stopped() }
        ),
        failureInjector: { $0 == .beforeVerification }
    )
    // An export consumes its preparation: it releases the originals it had pinned.
    let retried = try await failingExporter.prepare(undatedToken: "Undated")
    await #expect(throws: PlaintextOriginalArchiveExportError.injectedFailure) {
        _ = try await failingExporter.export(retried, to: destination)
    }
    #expect(access.counts == (1, 1))
}

@Test
func originalArchiveExporterDeniesDestinationAccessWithoutCreatingOutput() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    let access = DestinationAccessCounter()
    let exporter = PlaintextOriginalArchiveExporter(
        store: fixture.store,
        fileManager: .default,
        destinationAccess: .init(
            start: { _ in access.started(); return .denied },
            stop: { _ in access.stopped() }
        )
    )

    await #expect(throws: PlaintextOriginalArchiveExportError.destinationAccessDenied) {
        _ = try await exporter.export(
            try await exporter.prepare(undatedToken: "Undated"),
            to: destination
        )
    }
    #expect(access.counts == (1, 0))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test
func originalArchiveExporterReportsIndeterminateWhenParentSyncFailsAfterCommit() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    let exporter = PlaintextOriginalArchiveExporter(
        store: fixture.store,
        fileManager: .default,
        parentDirectorySync: { _ in
            throw PlaintextOriginalArchiveExportError.ioFailure(EIO)
        }
    )

    await #expect(throws: PlaintextOriginalArchiveExportError.publicationIndeterminate) {
        _ = try await exporter.export(
            try await exporter.prepare(undatedToken: "Undated"),
            to: destination
        )
    }

    let archive = try Archive(url: destination, accessMode: .read)
    #expect(Array(archive).count == 1)
}

@Test(arguments: [EACCES, EPERM, EINVAL, ENOTSUP, EOPNOTSUPP])
func originalArchiveExporterAcceptsUnavailableParentSyncAfterCommit(
    errorCode: Int32
) async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    let exporter = PlaintextOriginalArchiveExporter(
        store: fixture.store,
        fileManager: .default,
        parentDirectorySync: { _ in
            throw PlaintextOriginalArchiveExportError.ioFailure(errorCode)
        }
    )

    let result = try await exporter.export(
        try await exporter.prepare(undatedToken: "Undated"),
        to: destination
    )

    #expect(result.destinationURL == destination)
    let archive = try Archive(url: destination, accessMode: .read)
    #expect(Array(archive).count == 1)
}

private final class ExportTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<PlaintextOriginalArchiveExportResult, Error>?
    private var cancellationPending = false

    func set(_ task: Task<PlaintextOriginalArchiveExportResult, Error>) {
        lock.withLock {
            self.task = task
            if cancellationPending { task.cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            cancellationPending = true
            task?.cancel()
        }
    }
}

private final class DestinationAccessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    var counts: (Int, Int) { lock.withLock { (starts, stops) } }
    func started() { lock.withLock { starts += 1 } }
    func stopped() { lock.withLock { stops += 1 } }
}

private final class DestinationParentSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: URL
    private let replacement: URL
    private let symlinkTarget: URL
    private var failureDescription: String?
    private var didRun = false

    init(parent: URL, replacement: URL, symlinkTarget: URL) {
        self.parent = parent
        self.replacement = replacement
        self.symlinkTarget = symlinkTarget
    }

    var succeeded: Bool {
        lock.withLock { didRun && failureDescription == nil }
    }

    func perform() {
        lock.withLock {
            guard !didRun else { return }
            didRun = true
            do {
                try FileManager.default.moveItem(at: parent, to: replacement)
                try FileManager.default.createSymbolicLink(
                    at: parent,
                    withDestinationURL: symlinkTarget
                )
            } catch {
                failureDescription = String(describing: error)
            }
        }
    }
}

private final class ExportRevisionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var reached = false
    private var waiter: CheckedContinuation<Void, Never>?

    func reachAndWait() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            reached = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume()
        releaseSemaphore.wait()
    }

    func waitUntilReached() async {
        if lock.withLock({ reached }) { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !reached else { return true }
                waiter = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() { releaseSemaphore.signal() }
}

private struct OriginalArchiveExportFixture {
    let container: URL
    let vaultRoot: URL
    let store: SQLiteLibraryStore
    let reports: SQLiteReportRepository
    let record: HealthRecord
    let bytes: Data

    /// Where the library keeps the one original of this fixture.
    var originalURL: URL {
        store.originalsURL.appendingPathComponent(record.sources.first.attachmentID.uuidString.lowercased() + ".data")
    }

    static func make(byteCount: Int = 128 * 1_024) async throws -> Self {
        let container = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let root = container.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let store = try SQLiteLibraryStore(rootURL: root)
        let reports = SQLiteReportRepository(store: store)
        let member = try FamilyMember(displayName: "Synthetic Member")
        try await reports.saveMember(member, replacing: nil)
        let bytes = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0) })
        let file = try ValidatedImportedFile(data: bytes, kind: .pdf, contentTypeIdentifier: "com.adobe.pdf",
                                             sha256Digest: Data(SHA256.hash(data: bytes)), pageCount: 1)
        guard case .created(let draftID) = try await reports.stage(file) else { throw LibraryReportError.invalidDocument }
        let lease = try await reports.beginProcessing(draftID: draftID, attemptID: UUID())
        try await reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
        let draft = try await reports.draft(draftID)
        let record = try HealthRecord(id: draftID, memberID: member.id, sources: draft.sources,
                                      ocrDocumentObjectID: draft.documentObjectID, importState: .confirmed)
        try await reports.confirm(draftID: draftID, expectedRevision: draft.revision, record: record)
        return Self(container: container, vaultRoot: root, store: store, reports: reports, record: record, bytes: bytes)
    }

    func remove() {
        try? store.close()
        try? FileManager.default.removeItem(at: container)
    }
}
