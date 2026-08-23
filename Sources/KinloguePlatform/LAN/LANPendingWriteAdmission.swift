import Foundation
import KinlogueCore

/// Process-local accounting for chunks retained by derived-artifact sinks.
///
/// Owners isolate each sink's allowance while every owner created from the
/// same admission instance also contributes to the shared Store allowance.
/// Permits are RAII and remain charged until descriptor IO has drained.
// SAFETY: `lock` protects all owner totals and high-water state; limits are
// immutable after initialization.
final class LANPendingWriteAdmission: @unchecked Sendable {
    struct Limits: Equatable, Sendable {
        let maximumPendingBytesPerOwner: Int
        let maximumTotalPendingBytes: Int
        let maximumPendingChunksPerOwner: Int
        let maximumTotalPendingChunks: Int

        static let derivedProduction = Self(
            maximumPendingBytesPerOwner: 4 * 1_024 * 1_024,
            maximumTotalPendingBytes: 16 * 1_024 * 1_024,
            maximumPendingChunksPerOwner: 64,
            maximumTotalPendingChunks: 256
        )
    }

    struct Usage: Equatable, Sendable {
        let activeOwnerCount: Int
        let pendingByteCount: Int
        let pendingChunkCount: Int
    }

    struct HighWaterMark: Equatable, Sendable {
        let pendingByteCount: Int
        let pendingChunkCount: Int
    }

    // SAFETY: The owner lock makes release idempotent; shared accounting is
    // mutated only through the lock-protected admission object.
    final class Owner: @unchecked Sendable {
        private let lock = NSLock()
        private let admission: LANPendingWriteAdmission
        private let id: UUID
        private var isReleased = false

        fileprivate init(admission: LANPendingWriteAdmission, id: UUID) {
            self.admission = admission
            self.id = id
        }

        func acquire(byteCount: Int) throws -> Permit {
            try lock.withLock {
                guard !isReleased else { throw LANInboxError.invalidState }
                try admission.reserve(byteCount: byteCount, for: id)
                return Permit(owner: self, byteCount: byteCount)
            }
        }

        func release() {
            let needsRelease = lock.withLock {
                guard !isReleased else { return false }
                isReleased = true
                return true
            }
            if needsRelease { admission.releaseOwner(id) }
        }

        fileprivate func releasePending(byteCount: Int) {
            admission.releasePending(byteCount: byteCount, for: id)
        }

        deinit { release() }
    }

    // SAFETY: `lock` protects the optional owner so pending-byte release occurs
    // at most once, including during deinitialization.
    final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: Owner?
        private let byteCount: Int

        fileprivate init(owner: Owner, byteCount: Int) {
            self.owner = owner
            self.byteCount = byteCount
        }

        func release() {
            let owner = lock.withLock { () -> Owner? in
                defer { self.owner = nil }
                return self.owner
            }
            owner?.releasePending(byteCount: byteCount)
        }

        deinit { release() }
    }

    private struct OwnerState {
        var pendingByteCount = 0
        var pendingChunkCount = 0
        var releaseRequested = false
    }

    let limits: Limits
    private let lock = NSLock()
    private var owners: [UUID: OwnerState] = [:]
    private var totalPendingByteCount = 0
    private var totalPendingChunkCount = 0
    private var peakPendingByteCount = 0
    private var peakPendingChunkCount = 0

    init(limits: Limits) throws {
        guard limits.maximumPendingBytesPerOwner > 0,
              limits.maximumTotalPendingBytes > 0,
              limits.maximumPendingChunksPerOwner > 0,
              limits.maximumTotalPendingChunks > 0 else {
            throw LANInboxError.invalidModel
        }
        self.limits = limits
    }

    func acquireOwner() -> Owner {
        lock.withLock {
            var id = UUID()
            while owners[id] != nil { id = UUID() }
            owners[id] = OwnerState()
            return Owner(admission: self, id: id)
        }
    }

    var currentUsage: Usage {
        lock.withLock {
            Usage(
                activeOwnerCount: owners.count,
                pendingByteCount: totalPendingByteCount,
                pendingChunkCount: totalPendingChunkCount
            )
        }
    }

    var highWaterMark: HighWaterMark {
        lock.withLock {
            HighWaterMark(
                pendingByteCount: peakPendingByteCount,
                pendingChunkCount: peakPendingChunkCount
            )
        }
    }

    private func reserve(byteCount: Int, for id: UUID) throws {
        guard byteCount > 0 else { throw LANInboxError.invalidModel }
        try lock.withLock {
            guard var owner = owners[id], !owner.releaseRequested else {
                throw LANInboxError.invalidState
            }
            let ownerBytes = try checkedSum(owner.pendingByteCount, byteCount)
            let totalBytes = try checkedSum(totalPendingByteCount, byteCount)
            let ownerChunks = try checkedSum(owner.pendingChunkCount, 1)
            let totalChunks = try checkedSum(totalPendingChunkCount, 1)
            guard ownerBytes <= limits.maximumPendingBytesPerOwner,
                  totalBytes <= limits.maximumTotalPendingBytes,
                  ownerChunks <= limits.maximumPendingChunksPerOwner,
                  totalChunks <= limits.maximumTotalPendingChunks else {
                throw LANInboxError.resourceLimitExceeded
            }

            owner.pendingByteCount = ownerBytes
            owner.pendingChunkCount = ownerChunks
            owners[id] = owner
            totalPendingByteCount = totalBytes
            totalPendingChunkCount = totalChunks
            peakPendingByteCount = max(peakPendingByteCount, totalBytes)
            peakPendingChunkCount = max(peakPendingChunkCount, totalChunks)
        }
    }

    private func releasePending(byteCount: Int, for id: UUID) {
        lock.withLock {
            guard var owner = owners[id],
                  byteCount <= owner.pendingByteCount,
                  byteCount <= totalPendingByteCount,
                  owner.pendingChunkCount > 0,
                  totalPendingChunkCount > 0 else {
                return
            }
            owner.pendingByteCount -= byteCount
            owner.pendingChunkCount -= 1
            totalPendingByteCount -= byteCount
            totalPendingChunkCount -= 1
            if owner.pendingChunkCount == 0, owner.releaseRequested {
                owners.removeValue(forKey: id)
            } else {
                owners[id] = owner
            }
        }
    }

    private func releaseOwner(_ id: UUID) {
        lock.withLock {
            guard var owner = owners[id] else { return }
            if owner.pendingChunkCount == 0 {
                owners.removeValue(forKey: id)
            } else {
                owner.releaseRequested = true
                owners[id] = owner
            }
        }
    }

    private func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw LANInboxError.resourceLimitExceeded }
        return sum
    }
}
