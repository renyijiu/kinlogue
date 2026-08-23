import Darwin
import Foundation
import KinlogueCore

/// Produces one physical path for aliases of the same vault. Existing final
/// roots are never followed when they are symbolic links; intermediate aliases
/// are resolved once so later storage paths no longer depend on mutable alias
/// components.
enum VaultCanonicalRootPath {
    struct CoordinatorIdentity: Sendable {
        let registryKey: String
        let lockLocations: [VaultProcessLockLocation]
    }

    static func rootURL(
        for rootURL: URL,
        allowMissing: Bool
    ) throws -> URL {
        let standardized = try validatedShape(rootURL)
        var initialMetadata = stat()
        guard lstat(standardized.path, &initialMetadata) == 0 else {
            if errno == ENOENT, allowMissing {
                return URL(
                    fileURLWithPath: legacyCoordinatorKey(for: standardized),
                    isDirectory: true
                ).standardizedFileURL
            }
            if errno == ENOENT { throw VaultError.vaultMissing }
            throw VaultError.ioFailure(errno)
        }
        guard (initialMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw VaultError.invalidPath
        }

        let canonical = try physicalURL(forExistingURL: standardized)
        var canonicalMetadata = stat()
        var currentMetadata = stat()
        guard lstat(canonical.path, &canonicalMetadata) == 0,
              lstat(standardized.path, &currentMetadata) == 0,
              (canonicalMetadata.st_mode & S_IFMT) == S_IFDIR,
              (currentMetadata.st_mode & S_IFMT) == S_IFDIR,
              sameObject(initialMetadata, canonicalMetadata),
              sameObject(initialMetadata, currentMetadata) else {
            throw VaultError.invalidPath
        }
        return canonical
    }

    /// Builds a case-stable key without abandoning the lock file used by the
    /// previous path-keyed implementation.
    ///
    /// `realpath(3)` resolves aliases but, on a case-insensitive volume, can
    /// preserve the spelling supplied by the caller. The parent descriptor's
    /// kernel path and `_PC_CASE_SENSITIVE` value give all new processes the
    /// same comparison key. Compatibility locations retain the old key, and
    /// an existing root contributes the kernel's spelling of its directory
    /// entry so an upgraded process also coordinates with an older process.
    static func coordinatorIdentity(for rootURL: URL) -> CoordinatorIdentity {
        let standardized = rootURL.standardizedFileURL
        let legacyKey = legacyCoordinatorKey(for: standardized)
        let requestedParent = standardized.deletingLastPathComponent()

        guard let parent = physicalDirectoryIdentity(for: requestedParent) else {
            return CoordinatorIdentity(
                registryKey: legacyKey,
                lockLocations: [VaultProcessLockLocation(
                    parentURL: URL(fileURLWithPath: legacyKey)
                        .deletingLastPathComponent(),
                    namingKey: legacyKey
                )]
            )
        }

        let requestedName = standardized.lastPathComponent
            .precomposedStringWithCanonicalMapping
        let comparisonName = parent.isCaseSensitive
            ? requestedName
            : requestedName.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).precomposedStringWithCanonicalMapping
        let stableKey = parent.url.appendingPathComponent(comparisonName)
            .standardizedFileURL.path.precomposedStringWithCanonicalMapping

        var namingKeys = Set([stableKey, legacyKey])
        if let existingRoot = physicalDirectoryIdentity(for: standardized),
           existingRoot.url.deletingLastPathComponent().standardizedFileURL
               == parent.url.standardizedFileURL {
            namingKeys.insert(
                existingRoot.url.standardizedFileURL.path
                    .precomposedStringWithCanonicalMapping
            )
        }
        return CoordinatorIdentity(
            registryKey: stableKey,
            lockLocations: namingKeys.sorted().map {
                VaultProcessLockLocation(
                    parentURL: parent.url,
                    namingKey: $0
                )
            }
        )
    }

    private static func legacyCoordinatorKey(for standardized: URL) -> String {
        var existingAncestor = standardized
        var missingComponents: [String] = []
        while true {
            var metadata = stat()
            if lstat(existingAncestor.path, &metadata) == 0 { break }
            let parent = existingAncestor.deletingLastPathComponent()
            guard errno == ENOENT,
                  parent.path != existingAncestor.path else {
                return standardized.path.precomposedStringWithCanonicalMapping
            }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor = parent
        }

        var canonical = (try? physicalURL(forExistingURL: existingAncestor))
            ?? existingAncestor.standardizedFileURL
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component)
        }
        return canonical.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
    }

    private struct PhysicalDirectoryIdentity {
        let url: URL
        let isCaseSensitive: Bool
    }

    /// Resolves aliases, then validates the opened directory against the
    /// kernel-reported physical path and spelling.
    private static func physicalDirectoryIdentity(
        for url: URL
    ) -> PhysicalDirectoryIdentity? {
        guard let resolved = try? physicalURL(forExistingURL: url) else {
            return nil
        }
        let descriptor = Darwin.open(
            resolved.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFDIR,
              let device = UInt64(exactly: openedMetadata.st_dev),
              let inode = UInt64(exactly: openedMetadata.st_ino),
              device > 0,
              inode > 0 else {
            return nil
        }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &pathBuffer) == 0 else {
            return nil
        }
        guard let terminator = pathBuffer.firstIndex(of: 0) else { return nil }
        let physicalPath = String(
            decoding: pathBuffer[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let physicalURL = URL(
            fileURLWithPath: physicalPath,
            isDirectory: true
        ).standardizedFileURL
        var namedMetadata = stat()
        guard lstat(physicalURL.path, &namedMetadata) == 0,
              sameObject(openedMetadata, namedMetadata),
              (namedMetadata.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }

        errno = 0
        let caseSensitive = fpathconf(descriptor, _PC_CASE_SENSITIVE)
        guard caseSensitive == 0 || caseSensitive == 1 else {
            return nil
        }
        return PhysicalDirectoryIdentity(
            url: physicalURL,
            isCaseSensitive: caseSensitive == 1
        )
    }

    private static func validatedShape(_ rootURL: URL) throws -> URL {
        let standardized = rootURL.standardizedFileURL
        guard standardized.isFileURL,
              standardized.path != "/",
              !standardized.lastPathComponent.isEmpty,
              !standardized.path.utf8.contains(0) else {
            throw VaultError.invalidPath
        }
        return standardized
    }

    private static func physicalURL(forExistingURL url: URL) throws -> URL {
        errno = 0
        let pointer = url.path.withCString { path in
            realpath(path, nil)
        }
        guard let pointer else {
            if errno == ENOENT { throw VaultError.vaultMissing }
            if errno == ELOOP || errno == ENOTDIR { throw VaultError.invalidPath }
            throw VaultError.ioFailure(errno)
        }
        defer { free(pointer) }
        return URL(
            fileURLWithPath: String(cString: pointer),
            isDirectory: true
        ).standardizedFileURL
    }

    private static func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }
}

fileprivate struct VaultMutationCoordinatorIdentity: Equatable, Sendable {
    let canonicalRootPath: String
    let token: UUID
}

/// A per-vault asynchronous mutex backed by both a process-local queue and a
/// kernel advisory lock shared with other app processes.
///
/// A vault is an actor, but callers can create more than one actor for the same
/// on-disk root, including from separate processes. A lease is released
/// synchronously so callers can cover a non-suspending file transaction
/// without introducing an actor reentrancy window.
// SAFETY: `lock` protects queue/ownership state and continuations are removed
// before resumption; the process lock supplies cross-process exclusion.
final class VaultMutationCoordinator: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<VaultMutationLease, Error>
    }

    private final class WeakCoordinator {
        weak var value: VaultMutationCoordinator?

        init(_ value: VaultMutationCoordinator) {
            self.value = value
        }
    }

    // SAFETY: `lock` protects the weak coordinator registry and cleanup.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var coordinators: [String: WeakCoordinator] = [:]

        func coordinator(
            for pathIdentity: VaultCanonicalRootPath.CoordinatorIdentity
        ) -> VaultMutationCoordinator {
            lock.withLock {
                if let existing = coordinators[pathIdentity.registryKey]?.value {
                    return existing
                }
                coordinators = coordinators.filter { $0.value.value != nil }
                let coordinator = VaultMutationCoordinator(pathIdentity: pathIdentity)
                coordinators[pathIdentity.registryKey] = WeakCoordinator(coordinator)
                return coordinator
            }
        }
    }

    private static let registry = Registry()

    private let lock = NSLock()
    private let processLock: VaultProcessLock
    fileprivate let identity: VaultMutationCoordinatorIdentity
    private var isHeld = false
    private var waiters: [Waiter] = []
    private var dicomSliceLifecycleGeneration: UInt64 = 0

    private init(pathIdentity: VaultCanonicalRootPath.CoordinatorIdentity) {
        identity = VaultMutationCoordinatorIdentity(
            canonicalRootPath: pathIdentity.registryKey,
            token: UUID()
        )
        processLock = VaultProcessLock(locations: pathIdentity.lockLocations)
    }

    static func shared(for rootURL: URL) -> VaultMutationCoordinator {
        registry.coordinator(
            for: VaultCanonicalRootPath.coordinatorIdentity(for: rootURL)
        )
    }

    func acquire() async throws -> VaultMutationLease {
        let waiterID = UUID()
        let lease = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                enum Action {
                    case grant
                    case enqueue
                    case reject(Error)
                }

                let action = lock.withLock { () -> Action in
                    if Task.isCancelled {
                        return .reject(CancellationError())
                    }
                    guard isHeld else {
                        isHeld = true
                        return .grant
                    }
                    waiters.append(Waiter(
                        id: waiterID,
                        continuation: continuation
                    ))
                    return .enqueue
                }
                switch action {
                case .grant:
                    continuation.resume(
                        returning: VaultMutationLease(coordinator: self)
                    )
                case .enqueue:
                    break
                case .reject(let error):
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            self.cancelWaiter(id: waiterID)
        }

        do {
            try Task.checkCancellation()
            let processLease = try await processLock.acquire()
            try lease.attach(processLease: processLease)
            try Task.checkCancellation()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    var waitingCountForTesting: Int {
        lock.withLock { waiters.count }
    }

    var processLockWaiterCountForTesting: Int {
        processLock.waiterCountForTesting
    }

    var processLockURLForTesting: URL {
        processLock.lockURL
    }

    var processLockURLsForTesting: [URL] {
        processLock.lockURLs
    }

    func invalidateDICOMSliceLifecycle() {
        lock.withLock { dicomSliceLifecycleGeneration &+= 1 }
    }

    func dicomSliceLifecycleSnapshot() -> UInt64 {
        lock.withLock { dicomSliceLifecycleGeneration }
    }

    func isDICOMSliceLifecycleCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { dicomSliceLifecycleGeneration == generation }
    }

    /// Keeps validation and the authorized synchronous transaction inside the
    /// lease lock, so a concurrent release cannot revoke the process lock in
    /// the middle of reconciliation.
    func withValidatedLease<Result>(
        _ lease: VaultMutationLease,
        perform operation: () throws -> Result
    ) throws -> Result {
        try lease.withValidatedCoordinator(
            identity,
            perform: operation
        )
    }

    fileprivate func release() {
        let next = lock.withLock { () -> Waiter? in
            guard !waiters.isEmpty else {
                isHeld = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.continuation.resume(
            returning: VaultMutationLease(coordinator: self)
        )
    }

    private func cancelWaiter(id: UUID) {
        let cancelled = lock.withLock { () -> Waiter? in
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return waiters.remove(at: index)
        }
        cancelled?.continuation.resume(throwing: CancellationError())
    }
}

// SAFETY: `lock` protects coordinator and process-lease ownership, making attach
// and release atomic and release idempotent.
final class VaultMutationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinator: VaultMutationCoordinator?
    private var processLease: VaultProcessLease?

    fileprivate init(coordinator: VaultMutationCoordinator) {
        self.coordinator = coordinator
    }

    fileprivate func attach(processLease: VaultProcessLease) throws {
        try lock.withLock {
            guard coordinator != nil, self.processLease == nil else {
                throw VaultError.mutationConflict
            }
            self.processLease = processLease
        }
    }

    fileprivate func withValidatedCoordinator<Result>(
        _ expectedIdentity: VaultMutationCoordinatorIdentity,
        perform operation: () throws -> Result
    ) throws -> Result {
        try lock.withLock {
            guard coordinator?.identity == expectedIdentity,
                  processLease != nil else {
                throw VaultError.mutationConflict
            }
            return try operation()
        }
    }

    func release() {
        let resources = lock.withLock { () -> (VaultProcessLease?, VaultMutationCoordinator?) in
            defer {
                processLease = nil
                coordinator = nil
            }
            return (processLease, coordinator)
        }
        resources.0?.release()
        resources.1?.release()
    }

    deinit {
        release()
    }
}
