import Darwin
import Foundation
import KinlogueCore

public enum DICOMSecurityScopeRequirement: Sendable {
    case required
    case notRequiredForTesting
}

protocol DICOMSecurityScopeAccess: Sendable {
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
}

struct SystemDICOMSecurityScopeAccess: DICOMSecurityScopeAccess {
    func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Content-free test synchronization at admission and worker boundaries.
protocol DICOMFolderScannerControl: Sendable {
    func sourceAdmitted(ordinal: Int) async throws
    func workerStarted() async throws
}

public struct DICOMFolderScanResult: Equatable, Sendable {
    public let stagedObjects: [VaultDICOMStagedObject]
    public let inspectedEntryCount: Int
    public let ignoredNonDICOMCount: Int
    public let ignoredNonRegularCount: Int
    public let ignoredDuplicateCount: Int
    public let stagedByteCount: Int
}

public struct DICOMFolderScanner: Sendable {
    private let policy: DICOMImportPolicy
    private let metrics: DICOMImportMetricsRecorder?
    private let control: (any DICOMFolderScannerControl)?
    private let securityScopeAccess: any DICOMSecurityScopeAccess

    public init(policy: DICOMImportPolicy = .default) {
        self.init(
            policy: policy,
            metrics: nil,
            control: nil,
            securityScopeAccess: SystemDICOMSecurityScopeAccess()
        )
    }

    init(
        policy: DICOMImportPolicy = .default,
        metrics: DICOMImportMetricsRecorder? = nil,
        control: (any DICOMFolderScannerControl)? = nil,
        securityScopeAccess: any DICOMSecurityScopeAccess = SystemDICOMSecurityScopeAccess()
    ) {
        self.policy = policy
        self.metrics = metrics
        self.control = control
        self.securityScopeAccess = securityScopeAccess
    }

    public func scan(
        directoryURL: URL,
        operationID: UUID,
        securityScope: DICOMSecurityScopeRequirement = .required,
        staging: VaultDICOMStudyStaging,
        ownership: VaultDICOMStagingOwnership
    ) async throws -> DICOMFolderScanResult {
        try await scan(
            directoryURL: directoryURL,
            operationID: operationID,
            securityScope: securityScope,
            staging: staging,
            ownership: ownership,
            willBeginStaging: nil
        )
    }

    func scan(
        directoryURL: URL,
        operationID: UUID,
        securityScope: DICOMSecurityScopeRequirement,
        staging: VaultDICOMStudyStaging,
        ownership: VaultDICOMStagingOwnership,
        willBeginStaging: (@Sendable () async -> Void)?
    ) async throws -> DICOMFolderScanResult {
        guard ownership.operationID == operationID else {
            throw DICOMImportError.integrityFailure
        }
        let didStartScope: Bool
        switch securityScope {
        case .required:
            didStartScope = securityScopeAccess.start(directoryURL)
            guard didStartScope else { throw DICOMImportError.accessDenied }
        case .notRequiredForTesting:
            didStartScope = false
        }
        defer { if didStartScope { securityScopeAccess.stop(directoryURL) } }

        let root = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard root >= 0 else { throw DICOMImportError.invalidDirectory }
        await metrics?.recordSourceDescriptorOpened()

        let operationLease: VaultDICOMOperationDescriptorLease
        do {
            // openOperationDirectory transiently owns Vault root + staging +
            // operation descriptors and returns only the operation descriptor.
            await metrics?.recordStagingDescriptorsOpened(3)
            operationLease = try staging.openOperationDescriptorLease(ownership: ownership)
            await metrics?.recordStagingDescriptorsClosed(2)
        } catch {
            await metrics?.recordStagingDescriptorsClosed(3)
            Darwin.close(root)
            await metrics?.recordSourceDescriptorClosed()
            throw error
        }

        do {
            var accumulator = Accumulator()
            try await traverse(
                rootDescriptor: root,
                staging: staging,
                ownership: ownership,
                operationLease: operationLease,
                willBeginStaging: willBeginStaging,
                accumulator: &accumulator
            )
            guard !accumulator.stagedObjects.isEmpty else {
                throw DICOMImportError.noDICOMObjects
            }
            let result = DICOMFolderScanResult(
                stagedObjects: accumulator.stagedObjects,
                inspectedEntryCount: accumulator.inspectedEntryCount,
                ignoredNonDICOMCount: accumulator.ignoredNonDICOMCount,
                ignoredNonRegularCount: accumulator.ignoredNonRegularCount,
                ignoredDuplicateCount: accumulator.ignoredDuplicateCount,
                stagedByteCount: accumulator.stagedByteCount
            )
            operationLease.close()
            await metrics?.recordStagingDescriptorClosed()
            Darwin.close(root)
            await metrics?.recordSourceDescriptorClosed()
            return result
        } catch {
            operationLease.close()
            await metrics?.recordStagingDescriptorClosed()
            Darwin.close(root)
            await metrics?.recordSourceDescriptorClosed()
            try? staging.cleanup(ownership: ownership)
            if Task.isCancelled { throw DICOMImportError.cancelled }
            if let error = error as? DICOMImportError { throw error }
            throw DICOMImportError.invalidDirectory
        }
    }

    /// Iterative worklist traversal retains only the selected root plus one
    /// current directory. Each deeper directory is reopened component-by-
    /// component from the root with no-follow and identity validation, closing
    /// the previous component immediately.
    private func traverse(
        rootDescriptor: Int32,
        staging: VaultDICOMStudyStaging,
        ownership: VaultDICOMStagingOwnership,
        operationLease: VaultDICOMOperationDescriptorLease,
        willBeginStaging: (@Sendable () async -> Void)?,
        accumulator: inout Accumulator
    ) async throws {
        var worklist = [DirectoryJob(components: [], depth: 0)]
        while let job = worklist.popLast() {
            if Task.isCancelled { throw DICOMImportError.cancelled }
            let opened = try await openDirectory(
                rootDescriptor: rootDescriptor,
                components: job.components
            )
            do {
                let names = try await entryNames(
                    directoryDescriptor: opened.descriptor,
                    accumulator: &accumulator
                )
                var discoveredDirectories: [DirectoryJob] = []
                for name in names.sorted() {
                    if Task.isCancelled { throw DICOMImportError.cancelled }
                    var metadata = stat()
                    guard name.withCString({
                        fstatat(opened.descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
                    }) == 0 else { throw DICOMImportError.sourceChanged }
                    switch metadata.st_mode & S_IFMT {
                    case S_IFDIR:
                        guard job.depth < policy.maximumTraversalDepth else {
                            throw DICOMImportError.resourceLimit
                        }
                        discoveredDirectories.append(.init(
                            components: job.components + [
                                .init(name: name, snapshot: DirectorySnapshot(metadata))
                            ],
                            depth: job.depth + 1
                        ))
                    case S_IFREG:
                        try await admitRegularFile(
                            name: name,
                            metadata: metadata,
                            parentDescriptor: opened.descriptor,
                            staging: staging,
                            ownership: ownership,
                            operationLease: operationLease,
                            willBeginStaging: willBeginStaging,
                            accumulator: &accumulator
                        )
                    default:
                        accumulator.ignoredNonRegularCount += 1
                    }
                }
                try await flush(
                    parentDescriptor: opened.descriptor,
                    staging: staging,
                    ownership: ownership,
                    operationLease: operationLease,
                    willBeginStaging: willBeginStaging,
                    accumulator: &accumulator
                )
                if opened.mustClose {
                    Darwin.close(opened.descriptor)
                    await metrics?.recordSourceDescriptorClosed()
                }
                worklist.append(contentsOf: discoveredDirectories.reversed())
            } catch {
                if opened.mustClose {
                    Darwin.close(opened.descriptor)
                    await metrics?.recordSourceDescriptorClosed()
                }
                throw error
            }
        }
    }

    private func entryNames(
        directoryDescriptor: Int32,
        accumulator: inout Accumulator
    ) async throws -> [String] {
        let duplicate = dup(directoryDescriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw DICOMImportError.invalidDirectory
        }
        await metrics?.recordSourceDescriptorOpened()
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            accumulator.inspectedEntryCount += 1
            guard accumulator.inspectedEntryCount <= policy.maximumDirectoryEntries else {
                closedir(directory)
                await metrics?.recordSourceDescriptorClosed()
                throw DICOMImportError.resourceLimit
            }
            names.append(name)
        }
        closedir(directory)
        await metrics?.recordSourceDescriptorClosed()
        return names
    }

    private func admitRegularFile(
        name: String,
        metadata: stat,
        parentDescriptor: Int32,
        staging: VaultDICOMStudyStaging,
        ownership: VaultDICOMStagingOwnership,
        operationLease: VaultDICOMOperationDescriptorLease,
        willBeginStaging: (@Sendable () async -> Void)?,
        accumulator: inout Accumulator
    ) async throws {
        guard metadata.st_size > 0 else {
            accumulator.ignoredNonDICOMCount += 1
            return
        }
        guard metadata.st_size <= policy.maximumObjectBytes else {
            throw DICOMImportError.resourceLimit
        }
        let source = name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard source >= 0 else { throw DICOMImportError.sourceChanged }
        await metrics?.recordSourceDescriptorOpened()
        var openedMetadata = stat()
        guard fstat(source, &openedMetadata) == 0,
              SourceSnapshot(metadata).matches(openedMetadata) else {
            Darwin.close(source)
            await metrics?.recordSourceDescriptorClosed()
            throw DICOMImportError.sourceChanged
        }
        let part10 = isPart10(source)
        Darwin.close(source)
        await metrics?.recordSourceDescriptorClosed()
        guard part10 else {
            accumulator.ignoredNonDICOMCount += 1
            return
        }

        let ordinal = accumulator.nextOrdinal
        accumulator.nextOrdinal += 1
        try await control?.sourceAdmitted(ordinal: ordinal)
        accumulator.pending.append(.init(
            ordinal: ordinal,
            name: name,
            snapshot: SourceSnapshot(metadata)
        ))
        await metrics?.recordQueueDepth(accumulator.pending.count)
        if accumulator.pending.count == policy.maximumWorkers {
            try await flush(
                parentDescriptor: parentDescriptor,
                staging: staging,
                ownership: ownership,
                operationLease: operationLease,
                willBeginStaging: willBeginStaging,
                accumulator: &accumulator
            )
        }
    }

    private func flush(
        parentDescriptor: Int32,
        staging: VaultDICOMStudyStaging,
        ownership: VaultDICOMStagingOwnership,
        operationLease: VaultDICOMOperationDescriptorLease,
        willBeginStaging: (@Sendable () async -> Void)?,
        accumulator: inout Accumulator
    ) async throws {
        guard !accumulator.pending.isEmpty else { return }
        if !accumulator.didBeginStaging {
            accumulator.didBeginStaging = true
            await willBeginStaging?()
        }
        let admissions = accumulator.pending
        accumulator.pending.removeAll(keepingCapacity: true)
        let uniqueByteCount = accumulator.stagedByteCount
        let completed = try await withThrowingTaskGroup(
            of: StagedAdmission.self,
            returning: [StagedAdmission].self
        ) { group in
            for admission in admissions {
                group.addTask {
                    try await stage(
                        admission,
                        parentDescriptor: parentDescriptor,
                        staging: staging,
                        ownership: ownership,
                        operationLease: operationLease,
                        uniqueByteCountBeforeBatch: uniqueByteCount
                    )
                }
            }
            var results: [StagedAdmission] = []
            results.reserveCapacity(admissions.count)
            for try await result in group { results.append(result) }
            return results.sorted { $0.ordinal < $1.ordinal }
        }

        for result in completed {
            let key = DICOMContentIdentity(
                digest: result.object.sha256Digest,
                byteCount: result.object.byteCount
            )
            if accumulator.contentKeys.contains(key) {
                try staging.remove(result.object, operationLease: operationLease)
                await metrics?.recordDuplicateStagingRemoval(byteCount: result.object.byteCount)
                accumulator.ignoredDuplicateCount += 1
                continue
            }
            guard accumulator.stagedObjects.count < policy.maximumDICOMObjectCount else {
                throw DICOMImportError.resourceLimit
            }
            let total = accumulator.stagedByteCount.addingReportingOverflow(result.object.byteCount)
            guard !total.overflow, total.partialValue <= policy.maximumUniqueSourceBytes else {
                throw DICOMImportError.resourceLimit
            }
            accumulator.contentKeys.insert(key)
            accumulator.stagedObjects.append(result.object)
            accumulator.stagedByteCount = total.partialValue
            await metrics?.recordAcceptedUniqueObject(
                digest: result.object.sha256Digest,
                byteCount: result.object.byteCount
            )
        }
    }

    private func stage(
        _ admission: Admission,
        parentDescriptor: Int32,
        staging: VaultDICOMStudyStaging,
        ownership: VaultDICOMStagingOwnership,
        operationLease: VaultDICOMOperationDescriptorLease,
        uniqueByteCountBeforeBatch: Int
    ) async throws -> StagedAdmission {
        await metrics?.recordWorkerStarted()
        do {
            try await control?.workerStarted()
        } catch {
            await metrics?.recordWorkerFinished()
            throw error
        }
        if Task.isCancelled {
            await metrics?.recordWorkerFinished()
            throw DICOMImportError.cancelled
        }
        let source = admission.name.withCString {
            openat(parentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard source >= 0 else {
            await metrics?.recordWorkerFinished()
            throw DICOMImportError.sourceChanged
        }
        await metrics?.recordSourceDescriptorOpened()

        do {
            var openedMetadata = stat()
            guard fstat(source, &openedMetadata) == 0,
                  admission.snapshot.matches(openedMetadata) else {
                throw DICOMImportError.sourceChanged
            }
            await metrics?.recordStagingDescriptorOpened()
            let object: VaultDICOMStagedObject
            do {
                object = try staging.stageDeduplicationCandidate(
                    sourceDescriptor: source,
                    declaredByteCount: admission.snapshot.byteCount,
                    ownership: ownership,
                    stagedByteCountBeforeCopy: uniqueByteCountBeforeBatch,
                    operationLease: operationLease
                )
            } catch {
                await metrics?.recordStagingDescriptorClosed()
                throw error
            }
            await metrics?.recordStagingDescriptorClosed()

            var finalNameMetadata = stat()
            guard admission.name.withCString({
                fstatat(parentDescriptor, $0, &finalNameMetadata, AT_SYMLINK_NOFOLLOW)
            }) == 0, admission.snapshot.matches(finalNameMetadata) else {
                throw DICOMImportError.sourceChanged
            }
            await metrics?.recordStagingCopy(byteCount: object.byteCount)
            Darwin.close(source)
            await metrics?.recordSourceDescriptorClosed()
            await metrics?.recordWorkerFinished()
            return .init(ordinal: admission.ordinal, object: object)
        } catch {
            Darwin.close(source)
            await metrics?.recordSourceDescriptorClosed()
            await metrics?.recordWorkerFinished()
            throw error
        }
    }

    private func openDirectory(
        rootDescriptor: Int32,
        components: [DirectoryComponent]
    ) async throws -> OpenedDirectory {
        guard !components.isEmpty else {
            return .init(descriptor: rootDescriptor, mustClose: false)
        }
        var current = dup(rootDescriptor)
        guard current >= 0 else { throw DICOMImportError.sourceChanged }
        await metrics?.recordSourceDescriptorOpened()
        for component in components {
            let next = component.name.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                Darwin.close(current)
                await metrics?.recordSourceDescriptorClosed()
                throw DICOMImportError.sourceChanged
            }
            await metrics?.recordSourceDescriptorOpened()
            var metadata = stat()
            guard fstat(next, &metadata) == 0,
                  component.snapshot.matches(metadata) else {
                Darwin.close(next)
                Darwin.close(current)
                await metrics?.recordSourceDescriptorsClosed(2)
                throw DICOMImportError.sourceChanged
            }
            Darwin.close(current)
            await metrics?.recordSourceDescriptorClosed()
            current = next
        }
        return .init(descriptor: current, mustClose: true)
    }

    private func isPart10(_ descriptor: Int32) -> Bool {
        var prefix = [UInt8](repeating: 0, count: 132)
        let count = pread(descriptor, &prefix, prefix.count, 0)
        return count == prefix.count
            && prefix[128] == 0x44 && prefix[129] == 0x49
            && prefix[130] == 0x43 && prefix[131] == 0x4d
    }

    private struct Accumulator {
        var stagedObjects: [VaultDICOMStagedObject] = []
        var contentKeys: Set<DICOMContentIdentity> = []
        var pending: [Admission] = []
        var inspectedEntryCount = 0
        var ignoredNonDICOMCount = 0
        var ignoredNonRegularCount = 0
        var ignoredDuplicateCount = 0
        var stagedByteCount = 0
        var nextOrdinal = 0
        var didBeginStaging = false
    }
}

private struct SourceSnapshot: Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        byteCount = Int(metadata.st_size)
        modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        changeSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }

    func matches(_ metadata: stat) -> Bool {
        device == UInt64(metadata.st_dev)
            && inode == UInt64(metadata.st_ino)
            && byteCount == Int(metadata.st_size)
            && modificationSeconds == Int64(metadata.st_mtimespec.tv_sec)
            && modificationNanoseconds == Int64(metadata.st_mtimespec.tv_nsec)
            && changeSeconds == Int64(metadata.st_ctimespec.tv_sec)
            && changeNanoseconds == Int64(metadata.st_ctimespec.tv_nsec)
            && (metadata.st_mode & S_IFMT) == S_IFREG
    }
}

private struct DirectorySnapshot: Sendable {
    let device: UInt64
    let inode: UInt64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        changeSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }

    func matches(_ metadata: stat) -> Bool {
        device == UInt64(metadata.st_dev)
            && inode == UInt64(metadata.st_ino)
            && changeSeconds == Int64(metadata.st_ctimespec.tv_sec)
            && changeNanoseconds == Int64(metadata.st_ctimespec.tv_nsec)
            && (metadata.st_mode & S_IFMT) == S_IFDIR
    }
}

private struct DirectoryComponent: Sendable {
    let name: String
    let snapshot: DirectorySnapshot
}

private struct DirectoryJob: Sendable {
    let components: [DirectoryComponent]
    let depth: Int
}

private struct OpenedDirectory: Sendable {
    let descriptor: Int32
    let mustClose: Bool
}

private struct Admission: Sendable {
    let ordinal: Int
    let name: String
    let snapshot: SourceSnapshot
}

private struct StagedAdmission: Sendable {
    let ordinal: Int
    let object: VaultDICOMStagedObject
}
