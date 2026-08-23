import Dispatch
import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

struct LANInboxAdmissionPolicyTests {
    @Test
    func productionLimitsMatchTheProtocolContract() throws {
        let policy = try LANInboxAdmissionPolicy()

        #expect(policy.limits == .init(
            maximumActiveUploads: 2,
            maximumPendingBytesPerUpload: 4 * 1_024 * 1_024,
            maximumTotalPendingBytes: 16 * 1_024 * 1_024
        ))
    }

    @Test
    func concurrentUploadRaceAdmitsExactlyTheConfiguredCount() throws {
        let policy = try LANInboxAdmissionPolicy(limits: limits(
            maximumActiveUploads: 2
        ))
        let results = UploadPermitResults()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                results.append(try policy.acquireUploadPermit())
            } catch {
                results.recordRejection(error)
            }
        }

        #expect(results.permitCount == 2)
        #expect(results.rejectionCount == 62)
        #expect(results.onlyResourceLimitRejections)
        #expect(policy.currentUsage.activeUploadCount == 2)
        results.releaseAll()
        #expect(policy.currentUsage == .init(
            activeUploadCount: 0,
            totalPendingByteCount: 0
        ))
    }

    @Test
    func pendingMemoryRaceIsAtomicAndAllPermitsReleaseExactlyOnce() throws {
        let policy = try LANInboxAdmissionPolicy(limits: limits(
            maximumActiveUploads: 1,
            maximumPendingBytesPerUpload: 64,
            maximumTotalPendingBytes: 64
        ))
        let upload = try policy.acquireUploadPermit()
        let results = PendingPermitResults()

        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            do {
                results.append(
                    try upload.acquirePendingMemoryPermit(byteCount: 1)
                )
            } catch {
                results.recordRejection(error)
            }
        }

        #expect(results.permitCount == 64)
        #expect(results.rejectionCount == 64)
        #expect(results.onlyResourceLimitRejections)
        #expect(policy.currentUsage == .init(
            activeUploadCount: 1,
            totalPendingByteCount: 64
        ))

        upload.release()
        upload.release()
        #expect(policy.currentUsage.activeUploadCount == 1)
        #expect(throws: LANInboxError.invalidModel) {
            try upload.acquirePendingMemoryPermit(byteCount: 1)
        }

        results.releaseAllTwice()
        #expect(policy.currentUsage == .init(
            activeUploadCount: 0,
            totalPendingByteCount: 0
        ))
    }

    @Test
    func concurrentUploadReleaseAndPendingAcquisitionDrainToZero() throws {
        let policy = try LANInboxAdmissionPolicy(limits: limits(
            maximumActiveUploads: 1,
            maximumPendingBytesPerUpload: 64,
            maximumTotalPendingBytes: 64
        ))
        let upload = try policy.acquireUploadPermit()
        let results = PendingPermitResults()

        DispatchQueue.concurrentPerform(iterations: 65) { iteration in
            if iteration == 0 {
                upload.release()
                return
            }
            do {
                results.append(
                    try upload.acquirePendingMemoryPermit(byteCount: 1)
                )
            } catch {
                results.recordRejection(error)
            }
        }

        upload.release()
        results.releaseAllTwice()
        #expect(policy.currentUsage == .init(
            activeUploadCount: 0,
            totalPendingByteCount: 0
        ))
    }

    @Test
    func pendingMemoryHasIndependentPerUploadAndGlobalBounds() throws {
        let policy = try LANInboxAdmissionPolicy(limits: limits(
            maximumActiveUploads: 3,
            maximumPendingBytesPerUpload: 10,
            maximumTotalPendingBytes: 16
        ))
        let first = try policy.acquireUploadPermit()
        let second = try policy.acquireUploadPermit()
        let firstMemory = try first.acquirePendingMemoryPermit(byteCount: 10)
        let secondMemory = try second.acquirePendingMemoryPermit(byteCount: 6)

        #expect(throws: LANInboxError.resourceLimitExceeded) {
            try first.acquirePendingMemoryPermit(byteCount: 1)
        }
        #expect(throws: LANInboxError.resourceLimitExceeded) {
            try second.acquirePendingMemoryPermit(byteCount: 1)
        }
        #expect(policy.currentUsage.totalPendingByteCount == 16)

        firstMemory.release()
        secondMemory.release()
        first.release()
        second.release()
        #expect(policy.currentUsage == .init(
            activeUploadCount: 0,
            totalPendingByteCount: 0
        ))
    }

    @Test
    func failedReservationsAndAutomaticDestructionDoNotLeakCapacity() throws {
        let policy = try LANInboxAdmissionPolicy(limits: limits(
            maximumActiveUploads: 1,
            maximumPendingBytesPerUpload: 4,
            maximumTotalPendingBytes: 4
        ))

        func exerciseScopedPermits() throws {
            let upload = try policy.acquireUploadPermit()
            let pending = try upload.acquirePendingMemoryPermit(byteCount: 4)
            #expect(policy.currentUsage.totalPendingByteCount == 4)
            #expect(throws: LANInboxError.resourceLimitExceeded) {
                try upload.acquirePendingMemoryPermit(byteCount: Int.max)
            }
            withExtendedLifetime(pending) {}
        }

        try exerciseScopedPermits()
        #expect(policy.currentUsage == .init(
            activeUploadCount: 0,
            totalPendingByteCount: 0
        ))
        let replacement = try policy.acquireUploadPermit()
        replacement.release()
    }

    @Test
    func invalidLimitsAndReservationsAreRejected() throws {
        #expect(throws: LANInboxError.invalidModel) {
            try LANInboxAdmissionPolicy(limits: limits(
                maximumPendingBytesPerUpload: 0
            ))
        }
        let policy = try LANInboxAdmissionPolicy()
        let upload = try policy.acquireUploadPermit()
        let zero = try upload.acquirePendingMemoryPermit(byteCount: 0)
        #expect(policy.currentUsage.totalPendingByteCount == 0)
        zero.release()
        #expect(throws: LANInboxError.invalidModel) {
            try upload.acquirePendingMemoryPermit(byteCount: -1)
        }
        #expect(policy.currentUsage.totalPendingByteCount == 0)
        upload.release()
    }

    private func limits(
        maximumActiveUploads: Int = 2,
        maximumPendingBytesPerUpload: Int = 4 * 1_024 * 1_024,
        maximumTotalPendingBytes: Int = 16 * 1_024 * 1_024
    ) -> LANInboxAdmissionPolicy.Limits {
        .init(
            maximumActiveUploads: maximumActiveUploads,
            maximumPendingBytesPerUpload: maximumPendingBytesPerUpload,
            maximumTotalPendingBytes: maximumTotalPendingBytes
        )
    }
}

struct LANInboxLayoutTests {
    @Test
    func initializerValidatesAnExistingRootWithoutCreatingAnything() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let layout = try LANInboxLayout(rootURL: root)

        #expect(
            layout.rootURL
                == root.resolvingSymlinksInPath().standardizedFileURL
        )
        #expect(layout.inboxDirectoryPath == "lan-inbox")
        #expect(layout.manifestPath == "lan-inbox/inbox.json")
        #expect(layout.blobsDirectoryPath == "lan-inbox/blobs")
        #expect(layout.partialsDirectoryPath == "lan-inbox/partials")
        #expect(layout.derivedDirectoryPath == "lan-inbox/derived")
        #expect(!FileManager.default.fileExists(
            atPath: layout.inboxDirectoryURL.path
        ))
    }

    @Test
    func initializerRejectsMissingAndSymlinkRoots() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let missing = parent.appendingPathComponent("missing", isDirectory: true)
        #expect(throws: VaultError.vaultMissing) {
            try LANInboxLayout(rootURL: missing)
        }

        let real = parent.appendingPathComponent("real", isDirectory: true)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: VaultError.invalidPath) {
            try LANInboxLayout(rootURL: link)
        }

        let regularFile = parent.appendingPathComponent("regular-file")
        try Data("synthetic".utf8).write(to: regularFile)
        #expect(throws: VaultError.invalidPath) {
            try LANInboxLayout(rootURL: regularFile)
        }
    }

    @Test
    func opaquePathsAndRecognizersRequireExactCanonicalRoundTrips() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try LANInboxLayout(rootURL: root)
        let id = try #require(UUID(uuidString: "01234567-89AB-CDEF-8123-456789ABCDEF"))
        let lowercase = "01234567-89ab-cdef-8123-456789abcdef"

        #expect(layout.blobPath(id) == "lan-inbox/blobs/\(lowercase).blob")
        #expect(layout.partialPath(id) == "lan-inbox/partials/\(lowercase).partial")
        #expect(layout.derivedPath(id) == "lan-inbox/derived/\(lowercase).data")
        #expect(layout.blobID(at: layout.blobPath(id)) == id)
        #expect(layout.partialID(at: layout.partialPath(id)) == id)
        #expect(layout.derivedID(at: layout.derivedPath(id)) == id)

        let rejected = [
            "lan-inbox/blobs/01234567-89AB-CDEF-8123-456789ABCDEF.blob",
            "lan-inbox/Blobs/\(lowercase).blob",
            "lan-inbox/blobs/\(lowercase).BLOB",
            "/lan-inbox/blobs/\(lowercase).blob",
            "lan-inbox//blobs/\(lowercase).blob",
            "lan-inbox/blobs/../\(lowercase).blob",
            "lan-inbox/blobs/\(lowercase).blob/extra",
            "lan-inbox/blobs/report.blob",
        ]
        for path in rejected {
            #expect(layout.blobID(at: path) == nil)
        }
    }

    @Test
    func displayMetadataIsCanonicalVisibleTrimmedAndPathIndependent() throws {
        let sanitizer = try LANInboxDisplayMetadataSanitizer()
        let value = "  Cafe\u{0301}/报告\\A:B\u{0000}  "

        #expect(sanitizer.sanitize(value) == "Café_报告_A_B_")
        #expect(sanitizer.sanitize(" \t\n ") == "__")
        #expect(sanitizer.sanitize("报告\u{2028}伪造\u{2029}行") == "报告_伪造_行")
        #expect(sanitizer.sanitize("安全\u{202E}伪装\u{2066}文本") == "安全_伪装_文本")
        #expect(sanitizer.sanitize("   ") == "_")
        #expect(sanitizer.sanitize("..") == "_")
        #expect(sanitizer.sanitizeWithMetadata("report.pdf").wasGenerated == false)
        #expect(sanitizer.sanitizeWithMetadata("   ").wasGenerated)
        #expect(sanitizer.sanitize(value).unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        })
        _ = try LANInboxDisplayName(rawValue: sanitizer.sanitize(value))
    }

    @Test
    func displayMetadataHasAGraphemeSafeUTF8BoundAndNonemptyFallback() throws {
        let bounded = try LANInboxDisplayMetadataSanitizer(
            maximumUTF8ByteCount: 8
        )
        #expect(bounded.sanitize("报告😀A") == "报告")
        #expect(bounded.sanitize("报告😀A").utf8.count <= 8)

        let oneByte = try LANInboxDisplayMetadataSanitizer(
            maximumUTF8ByteCount: 1
        )
        #expect(oneByte.sanitize("   ") == "_")
        #expect(oneByte.sanitize("   ").utf8.count == 1)
        let trimmedAfterBounding = try LANInboxDisplayMetadataSanitizer(
            maximumUTF8ByteCount: 3
        )
        #expect(trimmedAfterBounding.sanitize("A  😀") == "A")
        #expect(throws: LANInboxError.invalidModel) {
            try LANInboxDisplayMetadataSanitizer(maximumUTF8ByteCount: 0)
        }
        #expect(throws: LANInboxError.invalidModel) {
            try LANInboxDisplayMetadataSanitizer(
                maximumUTF8ByteCount: LANInboxDisplayName.maxUTF8ByteCount + 1
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-lan-layout-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        return root
    }
}

private final class UploadPermitResults: @unchecked Sendable {
    private let lock = NSLock()
    private var permits: [LANInboxAdmissionPolicy.UploadPermit] = []
    private var rejections: [LANInboxError] = []

    func append(_ permit: LANInboxAdmissionPolicy.UploadPermit) {
        lock.withLock { permits.append(permit) }
    }

    func recordRejection(_ error: any Error) {
        lock.withLock {
            if let error = error as? LANInboxError { rejections.append(error) }
        }
    }

    var permitCount: Int { lock.withLock { permits.count } }
    var rejectionCount: Int { lock.withLock { rejections.count } }
    var onlyResourceLimitRejections: Bool {
        lock.withLock { rejections.allSatisfy { $0 == .resourceLimitExceeded } }
    }

    func releaseAll() {
        let snapshot = lock.withLock { () -> [LANInboxAdmissionPolicy.UploadPermit] in
            defer { permits.removeAll() }
            return permits
        }
        snapshot.forEach { $0.release() }
    }
}

private final class PendingPermitResults: @unchecked Sendable {
    private let lock = NSLock()
    private var permits: [LANInboxAdmissionPolicy.PendingMemoryPermit] = []
    private var rejections: [LANInboxError] = []

    func append(_ permit: LANInboxAdmissionPolicy.PendingMemoryPermit) {
        lock.withLock { permits.append(permit) }
    }

    func recordRejection(_ error: any Error) {
        lock.withLock {
            if let error = error as? LANInboxError { rejections.append(error) }
        }
    }

    var permitCount: Int { lock.withLock { permits.count } }
    var rejectionCount: Int { lock.withLock { rejections.count } }
    var onlyResourceLimitRejections: Bool {
        lock.withLock { rejections.allSatisfy { $0 == .resourceLimitExceeded } }
    }

    func releaseAllTwice() {
        let snapshot: [LANInboxAdmissionPolicy.PendingMemoryPermit] = lock.withLock {
            defer { permits.removeAll() }
            return permits
        }
        snapshot.forEach {
            $0.release()
            $0.release()
        }
    }
}
