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
    let exporter = PlaintextOriginalArchiveExporter(vault: fixture.vault)

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
        vault: fixture.vault,
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
    let layout = try PlaintextVaultLayout(rootURL: fixture.vaultRoot)
    let reference = VaultObjectReference(id: fixture.attachment.id, kind: .attachment)
    let objectURL = fixture.vaultRoot.appendingPathComponent(layout.objectPath(reference))
    try Data(repeating: 0x44, count: fixture.bytes.count).write(to: objectURL)
    let exporter = PlaintextOriginalArchiveExporter(vault: fixture.vault)

    let preparation = try await exporter.prepare(undatedToken: "Undated")
    await #expect(throws: PlaintextOriginalArchiveExportError.sourceIntegrityFailure) {
        _ = try await exporter.export(preparation, to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test
func originalArchiveExporterAbortsWhenVaultRevisionChangesBeforeCommit() async throws {
    let fixture = try await OriginalArchiveExportFixture.make(byteCount: 2 * 1_024 * 1_024)
    defer { fixture.remove() }
    let destination = fixture.container.appendingPathComponent("all-originals.zip")
    let gate = ExportRevisionGate()
    let exporter = PlaintextOriginalArchiveExporter(
        vault: fixture.vault,
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
    let current = try await fixture.vault.loadCatalog()
    let next = try VaultCatalog(
        vaultID: current.vaultID,
        generation: current.generation + 1,
        members: current.members,
        records: current.records,
        attachments: current.attachments,
        importDrafts: current.importDrafts,
        dicomStudies: current.dicomStudies
    )
    _ = try await fixture.vault.commit(try VaultCommitRequest(
        expectedGeneration: current.generation,
        catalog: next,
        writes: []
    ))
    gate.release()

    await #expect(throws: PlaintextOriginalArchiveExportError.vaultChanged) {
        _ = try await exportTask.value
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test
func originalArchiveExporterRejectsInvalidDestinations() async throws {
    let fixture = try await OriginalArchiveExportFixture.make()
    defer { fixture.remove() }
    let exporter = PlaintextOriginalArchiveExporter(vault: fixture.vault)
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
        vault: fixture.vault,
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
        vault: fixture.vault,
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
        vault: fixture.vault,
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
        vault: fixture.vault,
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
    let exporter = PlaintextOriginalArchiveExporter(vault: fixture.vault)
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
    let exporter = PlaintextOriginalArchiveExporter(vault: fixture.vault)
    let preparation = try await exporter.prepare(undatedToken: "Undated")
    await #expect(throws: PlaintextOriginalArchiveExportError.invalidDestination) {
        _ = try await exporter.export(preparation, to: destination)
    }

    try FileManager.default.removeItem(at: destination)
    let access = DestinationAccessCounter()
    let failingExporter = PlaintextOriginalArchiveExporter(
        vault: fixture.vault,
        destinationAccess: .init(
            start: { _ in access.started(); return .granted },
            stop: { _ in access.stopped() }
        ),
        failureInjector: { $0 == .beforeVerification }
    )
    await #expect(throws: PlaintextOriginalArchiveExportError.injectedFailure) {
        _ = try await failingExporter.export(preparation, to: destination)
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
        vault: fixture.vault,
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
        vault: fixture.vault,
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
        vault: fixture.vault,
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
    let vault: PlaintextVault
    let attachment: KinlogueCore.Attachment
    let bytes: Data

    static func make(byteCount: Int = 128 * 1_024) async throws -> Self {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = container.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let vault = try PlaintextVault(rootURL: root)
        let initial = try await vault.initialize()
        let member = try FamilyMember(displayName: "Synthetic Member")
        let bytes = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0) })
        let attachment = try KinlogueCore.Attachment(
            contentTypeIdentifier: "com.adobe.pdf",
            byteCount: bytes.count,
            sha256Digest: Data(SHA256.hash(data: bytes))
        )
        let record = try HealthRecord(
            memberID: member.id,
            attachmentID: attachment.id,
            importState: .confirmed
        )
        let catalog = try VaultCatalog(
            vaultID: initial.vaultID,
            generation: initial.generation + 1,
            members: [member],
            records: [record],
            attachments: [attachment]
        )
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: catalog,
            writes: [VaultObjectWrite(
                reference: .init(id: attachment.id, kind: .attachment),
                plaintext: bytes
            )]
        ))
        return Self(
            container: container,
            vaultRoot: root,
            vault: vault,
            attachment: attachment,
            bytes: bytes
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
