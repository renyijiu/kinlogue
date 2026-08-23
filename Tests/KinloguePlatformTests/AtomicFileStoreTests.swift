import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func immutableWriteCannotOverwriteExistingData() throws {
    try withTemporaryStore { store in
        let first = Data(repeating: 0x11, count: 24)
        let second = Data(repeating: 0x22, count: 24)

        try store.writeImmutable(first, relativePath: "objects/one.vault")
        #expect(throws: VaultError.objectAlreadyExists) {
            try store.writeImmutable(second, relativePath: "objects/one.vault")
        }
        #expect(try store.read(relativePath: "objects/one.vault", maximumByteCount: 64) == first)
    }
}

@Test
func failedAtomicReplacementPreservesTheOldValue() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let normal = try AtomicFileStore(rootURL: root)
    try normal.replaceAtomically(Data([1, 2, 3]), relativePath: "active.head")
    let failing = try AtomicFileStore(rootURL: root) { point in
        point == .afterSyncBeforeCommit
    }

    #expect(throws: VaultError.injectedFailure) {
        try failing.replaceAtomically(Data([4, 5, 6]), relativePath: "active.head")
    }
    #expect(try normal.read(relativePath: "active.head", maximumByteCount: 16) == Data([1, 2, 3]))
}

@Test
func nestedDirectoryCreationUsesTheDurabilityProtocolForEveryNewLevel() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = AtomicFileStoreFaultRecorder()
    let store = try AtomicFileStore(rootURL: root) { point in
        recorder.record(point)
        return false
    }

    try store.writeImmutable(Data([1]), relativePath: "objects/attachment/value.data")

    let directoryEvents = recorder.snapshot.filter { point in
        switch point {
        case .afterDirectoryCreateBeforeSync,
             .afterDirectorySyncBeforeParentSync,
             .afterDirectoryParentSync:
            true
        default:
            false
        }
    }
    #expect(directoryEvents == Array(repeating: [
        .afterDirectoryCreateBeforeSync,
        .afterDirectorySyncBeforeParentSync,
        .afterDirectoryParentSync,
    ], count: 3).flatMap { $0 })
}

@Test
func retryRepairsAnInterruptedDirectoryBeforeCreatingItsChild() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let interrupted = try AtomicFileStore(rootURL: root) { point in
        point == .afterDirectoryCreateBeforeSync
    }
    #expect(throws: VaultError.injectedFailure) {
        try interrupted.writeImmutable(Data([1]), relativePath: "objects/value.data")
    }

    let recorder = AtomicFileStoreFaultRecorder()
    let retry = try AtomicFileStore(rootURL: root) { point in
        recorder.record(point)
        return false
    }
    try retry.writeImmutable(Data([2]), relativePath: "objects/value.data")

    let durabilityEvents = recorder.snapshot.filter { point in
        switch point {
        case .beforeDirectoryDurabilityRepair,
             .afterDirectoryDurabilityRepair,
             .afterDirectoryCreateBeforeSync,
             .afterDirectorySyncBeforeParentSync,
             .afterDirectoryParentSync:
            true
        default:
            false
        }
    }
    #expect(Array(durabilityEvents.prefix(3)) == [
        .beforeDirectoryDurabilityRepair,
        .afterDirectoryDurabilityRepair,
        .afterDirectoryCreateBeforeSync,
    ])
    #expect(try retry.read(relativePath: "objects/value.data", maximumByteCount: 8) == Data([2]))
}

@Test
func directoryCreationRejectsASymlinkInTheRootAncestryBeforeWriting() throws {
    let container = temporaryRoot()
    let outside = temporaryRoot()
    defer {
        try? FileManager.default.removeItem(at: container)
        try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let link = container.appendingPathComponent("linked-parent", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let root = link.appendingPathComponent("vault", isDirectory: true)
    let store = try AtomicFileStore(rootURL: root)

    #expect(throws: VaultError.invalidPath) {
        try store.writeImmutable(Data([1]), relativePath: "nested/value.data")
    }
    #expect(!FileManager.default.fileExists(
        atPath: outside.appendingPathComponent("vault").path
    ))
}

@Test
func storeRejectsTraversalSymlinksAndOversizedReads() throws {
    try withTemporaryStore { store in
        try store.writeImmutable(Data(repeating: 8, count: 32), relativePath: "safe/value.vault")

        #expect(throws: VaultError.invalidPath) {
            try store.read(relativePath: "../outside", maximumByteCount: 64)
        }
        #expect(throws: VaultError.resourceLimitExceeded) {
            try store.read(relativePath: "safe/value.vault", maximumByteCount: 16)
        }

        let linkURL = store.rootURL.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: store.rootURL)
        #expect(throws: VaultError.invalidPath) {
            try store.read(relativePath: "link/safe/value.vault", maximumByteCount: 64)
        }
    }
}

private func withTemporaryStore(_ body: (AtomicFileStore) throws -> Void) throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try body(try AtomicFileStore(rootURL: root))
}

private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("kinlogue-u3-\(UUID().uuidString)", isDirectory: true)
}

private final class AtomicFileStoreFaultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [AtomicFileStoreFaultPoint] = []

    func record(_ point: AtomicFileStoreFaultPoint) {
        lock.lock()
        points.append(point)
        lock.unlock()
    }

    var snapshot: [AtomicFileStoreFaultPoint] {
        lock.lock()
        defer { lock.unlock() }
        return points
    }
}
