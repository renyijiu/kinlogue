import Foundation

/// Package-only access to the exact mutation lock already used by every Vault
/// writer. The isolated storage-process fixture uses this to prove that a
/// future whole-root activation can fence existing writers without inventing
/// a second, incompatible lock inode.
package enum VaultMutationCapabilityLock {
    package static func acquire(rootURL: URL) async throws -> Lease {
        Lease(try await VaultMutationCoordinator.shared(for: rootURL).acquire())
    }

    // SAFETY: The wrapper owns one `VaultMutationLease`, whose internal lock
    // synchronizes resource ownership and makes repeated release idempotent.
    package final class Lease: @unchecked Sendable {
        private let lease: VaultMutationLease

        fileprivate init(_ lease: VaultMutationLease) {
            self.lease = lease
        }

        package func release() {
            lease.release()
        }
    }
}
