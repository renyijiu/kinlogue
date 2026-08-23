import Foundation
import KinlogueCore

/// Synchronous, process-local admission accounting for bounded LAN work.
/// Persistent object-count checks still belong inside the vault mutation
/// lease; this policy supplies deterministic validation and memory permits.
// SAFETY: `lock` protects upload and pending-byte totals; limits are immutable.
public final class LANInboxAdmissionPolicy: @unchecked Sendable {
    /// These limits bound concurrent upload bodies and currently buffered
    /// memory. Persistent item-count checks are enforced by the manifest.
    public struct Limits: Equatable, Sendable {
        public let maximumActiveUploads: Int
        public let maximumPendingBytesPerUpload: Int
        public let maximumTotalPendingBytes: Int

        public init(
            maximumActiveUploads: Int,
            maximumPendingBytesPerUpload: Int,
            maximumTotalPendingBytes: Int
        ) {
            self.maximumActiveUploads = maximumActiveUploads
            self.maximumPendingBytesPerUpload = maximumPendingBytesPerUpload
            self.maximumTotalPendingBytes = maximumTotalPendingBytes
        }

        public static let production = Self(
            maximumActiveUploads: 2,
            maximumPendingBytesPerUpload: 4 * 1_024 * 1_024,
            maximumTotalPendingBytes: 16 * 1_024 * 1_024
        )
    }

    public struct Usage: Equatable, Sendable {
        public let activeUploadCount: Int
        public let totalPendingByteCount: Int

        public init(activeUploadCount: Int, totalPendingByteCount: Int) {
            self.activeUploadCount = activeUploadCount
            self.totalPendingByteCount = totalPendingByteCount
        }
    }

    // SAFETY: The permit lock makes release idempotent; policy accounting is
    // mutated only through the policy's lock-protected methods.
    public final class UploadPermit: @unchecked Sendable {
        private let lock = NSLock()
        private let policy: LANInboxAdmissionPolicy
        private let id: UUID
        private var isReleased = false

        fileprivate init(policy: LANInboxAdmissionPolicy, id: UUID) {
            self.policy = policy
            self.id = id
        }

        public func acquirePendingMemoryPermit(
            byteCount: Int
        ) throws -> PendingMemoryPermit {
            try lock.withLock {
                guard !isReleased else { throw LANInboxError.invalidModel }
                try policy.reservePendingBytes(byteCount, for: id)
                return PendingMemoryPermit(
                    uploadPermit: self,
                    byteCount: byteCount
                )
            }
        }

        public func release() {
            let needsRelease = lock.withLock {
                guard !isReleased else { return false }
                isReleased = true
                return true
            }
            if needsRelease { policy.releaseUpload(id) }
        }

        fileprivate func releasePendingBytes(_ byteCount: Int) {
            policy.releasePendingBytes(byteCount, for: id)
        }

        deinit {
            release()
        }
    }

    // SAFETY: `lock` protects optional permit ownership so byte reservations are
    // released at most once, including during deinitialization.
    public final class PendingMemoryPermit: @unchecked Sendable {
        private let lock = NSLock()
        private var uploadPermit: UploadPermit?
        private let byteCount: Int

        fileprivate init(uploadPermit: UploadPermit, byteCount: Int) {
            self.uploadPermit = uploadPermit
            self.byteCount = byteCount
        }

        public func release() {
            let upload = lock.withLock { () -> UploadPermit? in
                defer { uploadPermit = nil }
                return uploadPermit
            }
            upload?.releasePendingBytes(byteCount)
        }

        deinit {
            release()
        }
    }

    private struct UploadState {
        var pendingByteCount = 0
        var releaseRequested = false
    }

    public let limits: Limits
    private let lock = NSLock()
    private var uploads: [UUID: UploadState] = [:]
    private var totalPendingByteCount = 0

    public init(limits: Limits = .production) throws {
        guard limits.maximumActiveUploads > 0,
              limits.maximumPendingBytesPerUpload > 0,
              limits.maximumTotalPendingBytes > 0 else {
            throw LANInboxError.invalidModel
        }
        self.limits = limits
    }

    public func acquireUploadPermit() throws -> UploadPermit {
        try lock.withLock {
            guard uploads.count < limits.maximumActiveUploads else {
                throw LANInboxError.resourceLimitExceeded
            }
            var id = UUID()
            while uploads[id] != nil { id = UUID() }
            uploads[id] = UploadState()
            return UploadPermit(policy: self, id: id)
        }
    }

    public var currentUsage: Usage {
        lock.withLock {
            Usage(
                activeUploadCount: uploads.count,
                totalPendingByteCount: totalPendingByteCount
            )
        }
    }

    private func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw LANInboxError.resourceLimitExceeded }
        return result.partialValue
    }

    private func reservePendingBytes(_ byteCount: Int, for id: UUID) throws {
        guard byteCount >= 0 else { throw LANInboxError.invalidModel }
        try lock.withLock {
            guard var upload = uploads[id], !upload.releaseRequested else {
                throw LANInboxError.invalidModel
            }
            let uploadTotal = try checkedSum(upload.pendingByteCount, byteCount)
            let globalTotal = try checkedSum(totalPendingByteCount, byteCount)
            guard uploadTotal <= limits.maximumPendingBytesPerUpload,
                  globalTotal <= limits.maximumTotalPendingBytes else {
                throw LANInboxError.resourceLimitExceeded
            }
            upload.pendingByteCount = uploadTotal
            uploads[id] = upload
            totalPendingByteCount = globalTotal
        }
    }

    private func releasePendingBytes(_ byteCount: Int, for id: UUID) {
        lock.withLock {
            guard var upload = uploads[id],
                  byteCount <= upload.pendingByteCount,
                  byteCount <= totalPendingByteCount else {
                return
            }
            upload.pendingByteCount -= byteCount
            totalPendingByteCount -= byteCount
            if upload.pendingByteCount == 0, upload.releaseRequested {
                uploads.removeValue(forKey: id)
            } else {
                uploads[id] = upload
            }
        }
    }

    private func releaseUpload(_ id: UUID) {
        lock.withLock {
            guard var upload = uploads[id] else { return }
            if upload.pendingByteCount == 0 {
                uploads.removeValue(forKey: id)
            } else {
                upload.releaseRequested = true
                uploads[id] = upload
            }
        }
    }
}
