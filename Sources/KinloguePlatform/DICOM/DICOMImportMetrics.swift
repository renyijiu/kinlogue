import Foundation

struct DICOMContentIdentity: Hashable, Sendable {
    let digest: Data
    let byteCount: Int
}

/// Content- and path-free import instrumentation. Production behavior does not
/// depend on these counters; focused tests use them to prove the frozen U3
/// worker, descriptor, I/O-amplification and added-disk bounds.
public struct DICOMImportMetricsSnapshot: Equatable, Sendable {
    public let uniqueObjectCount: Int
    public let maximumConcurrentWorkers: Int
    public let maximumQueueDepth: Int
    public let maximumLiveSourceDescriptors: Int
    public let maximumLiveSourceAndStagingDescriptors: Int
    public let liveSourceAndStagingDescriptorCount: Int
    public let liveWorkerCount: Int
    public let sourceBytesRead: Int
    public let stagingBytesWritten: Int
    public let maximumManagedFullReadsPerObject: Int
    public let maximumWritesPerObject: Int
    public let managedFullReadBytes: Int
    public let promotedAttachmentBytes: Int
    public let peakAddedDiskBytes: Int
}

public actor DICOMImportMetricsRecorder {
    private var uniqueObjects: Set<DICOMContentIdentity> = []
    private var liveWorkers = 0
    private var maximumWorkers = 0
    private var maximumQueue = 0
    private var liveSourceDescriptors = 0
    private var liveStagingDescriptors = 0
    private var maximumSourceDescriptors = 0
    private var maximumSourceAndStagingDescriptors = 0
    private var sourceReadBytes = 0
    private var stagingWriteBytes = 0
    private var managedReadsByObject: [DICOMContentIdentity: Int] = [:]
    private var writesByObject: [DICOMContentIdentity: Int] = [:]
    private var managedReadBytes = 0
    private var promotedBytes = 0
    private var addedDiskBytes = 0
    private var maximumAddedDiskBytes = 0

    func recordQueueDepth(_ depth: Int) {
        precondition(depth >= 0)
        maximumQueue = max(maximumQueue, depth)
    }

    func recordWorkerStarted() {
        liveWorkers += 1
        maximumWorkers = max(maximumWorkers, liveWorkers)
    }

    func recordWorkerFinished() {
        precondition(liveWorkers > 0)
        liveWorkers -= 1
    }

    func recordSourceDescriptorOpened() {
        liveSourceDescriptors += 1
        updateDescriptorMaximums()
    }

    func recordSourceDescriptorsOpened(_ count: Int) {
        precondition(count >= 0)
        liveSourceDescriptors += count
        updateDescriptorMaximums()
    }

    func recordSourceDescriptorClosed() {
        precondition(liveSourceDescriptors > 0)
        liveSourceDescriptors -= 1
    }

    func recordSourceDescriptorsClosed(_ count: Int) {
        precondition(count >= 0 && liveSourceDescriptors >= count)
        liveSourceDescriptors -= count
    }

    func recordStagingDescriptorOpened() {
        liveStagingDescriptors += 1
        updateDescriptorMaximums()
    }

    func recordStagingDescriptorsOpened(_ count: Int) {
        precondition(count >= 0)
        liveStagingDescriptors += count
        updateDescriptorMaximums()
    }

    func recordStagingDescriptorClosed() {
        precondition(liveStagingDescriptors > 0)
        liveStagingDescriptors -= 1
    }

    func recordStagingDescriptorsClosed(_ count: Int) {
        precondition(count >= 0 && liveStagingDescriptors >= count)
        liveStagingDescriptors -= count
    }

    func recordStagingCopy(byteCount: Int) {
        sourceReadBytes += byteCount
        stagingWriteBytes += byteCount
        addedDiskBytes += byteCount
        maximumAddedDiskBytes = max(maximumAddedDiskBytes, addedDiskBytes)
    }

    func recordAcceptedUniqueObject(digest: Data, byteCount: Int) {
        let key = DICOMContentIdentity(digest: digest, byteCount: byteCount)
        uniqueObjects.insert(key)
        writesByObject[key] = max(writesByObject[key] ?? 0, 1)
    }

    func recordDuplicateStagingRemoval(byteCount: Int) {
        addedDiskBytes = max(0, addedDiskBytes - byteCount)
    }

    func recordIndexFullRead(digest: Data, byteCount: Int) {
        recordManagedFullRead(digest: digest, byteCount: byteCount)
    }

    func recordDecoderFullRead(digest: Data, byteCount: Int) {
        recordManagedFullRead(digest: digest, byteCount: byteCount)
    }

    func recordAttachmentPromotion(digest: Data, byteCount: Int) {
        recordManagedFullRead(digest: digest, byteCount: byteCount)
        let key = DICOMContentIdentity(digest: digest, byteCount: byteCount)
        writesByObject[key, default: 0] += 1
        promotedBytes += byteCount
        addedDiskBytes += byteCount
        maximumAddedDiskBytes = max(maximumAddedDiskBytes, addedDiskBytes)
    }

    func recordIndexPromotion(byteCount: Int) {
        addedDiskBytes += byteCount
        maximumAddedDiskBytes = max(maximumAddedDiskBytes, addedDiskBytes)
    }

    public init() {}

    public func snapshot() -> DICOMImportMetricsSnapshot {
        .init(
            uniqueObjectCount: uniqueObjects.count,
            maximumConcurrentWorkers: maximumWorkers,
            maximumQueueDepth: maximumQueue,
            maximumLiveSourceDescriptors: maximumSourceDescriptors,
            maximumLiveSourceAndStagingDescriptors: maximumSourceAndStagingDescriptors,
            liveSourceAndStagingDescriptorCount: liveSourceDescriptors + liveStagingDescriptors,
            liveWorkerCount: liveWorkers,
            sourceBytesRead: sourceReadBytes,
            stagingBytesWritten: stagingWriteBytes,
            maximumManagedFullReadsPerObject: managedReadsByObject.values.max() ?? 0,
            maximumWritesPerObject: writesByObject.values.max() ?? 0,
            managedFullReadBytes: managedReadBytes,
            promotedAttachmentBytes: promotedBytes,
            peakAddedDiskBytes: maximumAddedDiskBytes
        )
    }

    private func recordManagedFullRead(digest: Data, byteCount: Int) {
        let key = DICOMContentIdentity(digest: digest, byteCount: byteCount)
        managedReadsByObject[key, default: 0] += 1
        managedReadBytes += byteCount
    }

    private func updateDescriptorMaximums() {
        maximumSourceDescriptors = max(maximumSourceDescriptors, liveSourceDescriptors)
        maximumSourceAndStagingDescriptors = max(
            maximumSourceAndStagingDescriptors,
            liveSourceDescriptors + liveStagingDescriptors
        )
    }
}
