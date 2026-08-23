import Foundation
import KinlogueCore
import KinlogueDICOMIPC

public enum DICOMSliceServiceError: Error, Equatable, Sendable {
    case studyUnavailable
    case seriesUnavailable
    case instanceUnavailable
    case staleSession
    case integrityFailure
    case resourceLimit
    case decoderUnavailable
    case cancelled
    case closed
}

public struct DICOMVaultSessionToken: Hashable, Sendable {
    public let vaultID: UUID
    public let generation: UInt64
    public let commitID: UUID
    public let catalogDigest: Data

    public init(vaultID: UUID, revision: VaultRevision) throws {
        guard revision.catalogDigest.count == 32 else {
            throw DICOMSliceServiceError.integrityFailure
        }
        self.vaultID = vaultID
        generation = revision.generation
        commitID = revision.commitID
        catalogDigest = revision.catalogDigest
    }
}

public struct DICOMSliceInstanceDescriptor: Equatable, Sendable {
    public let id: DICOMStudyIndex.Instance.ID
    public let attachmentID: Attachment.ID
    public let contentDigest: Data
    public let objectByteCount: Int
    public let attributes: DICOMStudyIndex.ImageAttributes

    public init(
        id: DICOMStudyIndex.Instance.ID,
        attachmentID: Attachment.ID,
        contentDigest: Data,
        objectByteCount: Int,
        attributes: DICOMStudyIndex.ImageAttributes
    ) throws {
        guard contentDigest.count == 32, objectByteCount > 0 else {
            throw DICOMSliceServiceError.integrityFailure
        }
        self.id = id
        self.attachmentID = attachmentID
        self.contentDigest = contentDigest
        self.objectByteCount = objectByteCount
        self.attributes = attributes
    }
}

public struct DICOMSliceSeriesSession: Equatable, Sendable {
    public let token: DICOMVaultSessionToken
    public let studyID: DICOMStudy.ID
    public let seriesID: DICOMStudyIndex.Series.ID
    public let orderingProvenance: DICOMStudyIndex.OrderingProvenance
    public let instances: [DICOMSliceInstanceDescriptor]

    public init(
        token: DICOMVaultSessionToken,
        studyID: DICOMStudy.ID,
        seriesID: DICOMStudyIndex.Series.ID,
        orderingProvenance: DICOMStudyIndex.OrderingProvenance,
        instances: [DICOMSliceInstanceDescriptor]
    ) throws {
        guard !instances.isEmpty, Set(instances.map(\.id)).count == instances.count else {
            throw DICOMSliceServiceError.integrityFailure
        }
        self.token = token
        self.studyID = studyID
        self.seriesID = seriesID
        self.orderingProvenance = orderingProvenance
        self.instances = instances
    }
}

public struct DICOMSliceImage: Sendable {
    public let renderID: UUID
    public let instanceID: DICOMStudyIndex.Instance.ID
    public let rows: Int
    public let columns: Int
    public let windowCenter: Double
    public let windowWidth: Double
    private let pixels: DICOMSlicePixelBuffer

    init(
        instanceID: DICOMStudyIndex.Instance.ID,
        rows: Int,
        columns: Int,
        windowCenter: Double,
        windowWidth: Double,
        pixels: DICOMSlicePixelBuffer
    ) {
        renderID = UUID()
        self.instanceID = instanceID
        self.rows = rows
        self.columns = columns
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.pixels = pixels
    }

    /// Gives synchronous, non-escaping access to the current 8-bit pixels.
    /// The buffer becomes invalid when its service changes series, handles
    /// memory pressure, or closes.
    public func withGrayscaleBytes<Result>(
        _ operation: (UnsafeRawBufferPointer) throws -> Result
    ) throws -> Result {
        try pixels.withBytes(operation)
    }
}

// SAFETY: `lock` protects the optional byte storage across all reads and
// zeroization; no raw buffer escapes the locked callback.
final class DICOMSlicePixelBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?

    init(bytes: Data) {
        self.bytes = bytes
    }

    func withBytes<Result>(
        _ operation: (UnsafeRawBufferPointer) throws -> Result
    ) throws -> Result {
        try lock.withLock {
            guard let bytes else { throw DICOMSliceServiceError.cancelled }
            return try bytes.withUnsafeBytes(operation)
        }
    }

    func invalidate() {
        lock.withLock {
            guard bytes != nil else { return }
            _ = bytes?.withUnsafeMutableBytes { buffer in
                buffer.initializeMemory(as: UInt8.self, repeating: 0)
            }
            bytes = nil
        }
    }

    deinit { invalidate() }
}

struct DICOMSliceLifecycleTicket: Sendable {
    private let validation: @Sendable () throws -> Void

    init(validation: @escaping @Sendable () throws -> Void) {
        self.validation = validation
    }

    static func transient() -> DICOMSliceLifecycleTicket {
        DICOMSliceLifecycleTicket(validation: {})
    }

    func validate() throws { try validation() }
}

struct DICOMVerifiedDecodedFrame: Sendable {
    let frame: KinlogueDICOMDecodedFrame
    let lifecycle: DICOMSliceLifecycleTicket
}

protocol DICOMVerifiedSliceSource: Sendable {
    func openSeries(
        studyID: DICOMStudy.ID,
        seriesID: DICOMStudyIndex.Series.ID
    ) async throws -> DICOMSliceSeriesSession

    func decode(
        _ instance: DICOMSliceInstanceDescriptor,
        in session: DICOMSliceSeriesSession
    ) async throws -> DICOMVerifiedDecodedFrame
}

struct PlaintextVaultDICOMSliceSource: DICOMVerifiedSliceSource, Sendable {
    let vault: PlaintextVault
    let decoder: any DICOMFrameDecoding

    func openSeries(
        studyID: DICOMStudy.ID,
        seriesID: DICOMStudyIndex.Series.ID
    ) async throws -> DICOMSliceSeriesSession {
        try await vault.openVerifiedDICOMSeries(studyID: studyID, seriesID: seriesID)
    }

    func decode(
        _ instance: DICOMSliceInstanceDescriptor,
        in session: DICOMSliceSeriesSession
    ) async throws -> DICOMVerifiedDecodedFrame {
        try await vault.decodeVerifiedDICOMInstance(
            instance,
            in: session,
            decoder: decoder
        )
    }
}

public actor DICOMSliceService {
    private static let maximumPrefetchWorkingSet = 64 * 1_024 * 1_024

    private struct ScheduledDecode {
        let id: UUID
        let key: DICOMSliceCache.Key
        let task: Task<ReservedCanonicalSlice, Error>
    }

    private struct ReservedCanonicalSlice: Sendable {
        let canonical: DICOMCanonicalSlice
        let reservation: DICOMSliceMemoryBudget.ActiveLease
        let lifecycle: DICOMSliceLifecycleTicket
    }

    private struct RetainedRender: Sendable {
        let pixels: DICOMSlicePixelBuffer
        let reservation: DICOMSliceMemoryBudget.RenderLease
    }

    private let source: any DICOMVerifiedSliceSource
    private let budget: DICOMSliceMemoryBudget
    private let cache: DICOMSliceCache
    private let scheduler: DICOMSliceProcessScheduler
    private var currentSession: DICOMSliceSeriesSession?
    private var currentInstances: [DICOMStudyIndex.Instance.ID: DICOMSliceInstanceDescriptor] = [:]
    private var foreground: ScheduledDecode?
    private var prefetch: ScheduledDecode?
    private var consumingDecodeID: UUID?
    private var requestGeneration: UInt64 = 0
    private var openGeneration: UInt64 = 0
    private var retainedRender: RetainedRender?
    private var isClosed = false

    deinit {
        foreground?.task.cancel()
        prefetch?.task.cancel()
        retainedRender?.pixels.invalidate()
        retainedRender?.reservation.release()
    }

    public init(
        vault: PlaintextVault,
        decoder: any DICOMFrameDecoding = DICOMDecoderAdapter()
    ) {
        let runtime = DICOMSliceRuntime.shared
        source = PlaintextVaultDICOMSliceSource(vault: vault, decoder: decoder)
        budget = runtime.budget
        cache = runtime.cache
        scheduler = runtime.scheduler
    }

    init(
        source: any DICOMVerifiedSliceSource,
        maximumMemoryBytes: Int = DICOMSliceMemoryBudget.defaultMaximumBytes,
        maximumCacheCount: Int = DICOMSliceCache.defaultMaximumCount,
        maximumCacheBytes: Int = DICOMSliceCache.defaultMaximumBytes,
        runtime: DICOMSliceRuntime? = nil
    ) {
        let runtime = runtime ?? DICOMSliceRuntime(
            maximumMemoryBytes: maximumMemoryBytes,
            maximumCacheCount: maximumCacheCount,
            maximumCacheBytes: maximumCacheBytes
        )
        self.source = source
        budget = runtime.budget
        cache = runtime.cache
        scheduler = runtime.scheduler
    }

    public func openSeries(
        studyID: DICOMStudy.ID,
        seriesID: DICOMStudyIndex.Series.ID
    ) async throws -> DICOMSliceSeriesSession {
        guard !isClosed else { throw DICOMSliceServiceError.closed }
        openGeneration &+= 1
        let generation = openGeneration
        await invalidateCurrentSession()
        do {
            let session = try await source.openSeries(studyID: studyID, seriesID: seriesID)
            guard !Task.isCancelled, !isClosed, generation == openGeneration else {
                throw DICOMSliceServiceError.cancelled
            }
            currentSession = session
            currentInstances = Dictionary(
                uniqueKeysWithValues: session.instances.map { ($0.id, $0) }
            )
            return session
        } catch {
            throw map(error)
        }
    }

    public func render(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID,
        windowCenter: Double? = nil,
        windowWidth: Double? = nil
    ) async throws -> DICOMSliceImage {
        guard !isClosed else { throw DICOMSliceServiceError.closed }
        guard currentSession == session else { throw DICOMSliceServiceError.staleSession }
        guard let instance = currentInstances[instanceID] else {
            throw DICOMSliceServiceError.instanceUnavailable
        }
        let window = try requestedWindow(center: windowCenter, width: windowWidth)
        requestGeneration &+= 1
        let generation = requestGeneration
        let key = cacheKey(instance: instance, session: session)
        releaseRetainedRender()

        if prefetch?.key != key {
            prefetch?.task.cancel()
            prefetch = nil
        }
        if foreground?.key != key {
            foreground?.task.cancel()
            foreground = nil
        }
        if await cache.contains(key) {
            guard !Task.isCancelled, !isClosed, requestGeneration == generation,
                  currentSession == session else {
                throw DICOMSliceServiceError.cancelled
            }
            let renderReservation: DICOMSliceMemoryBudget.RenderLease
            do {
                renderReservation = try budget.reserveRenderLease(
                    try Self.renderReservationBytes(instance.attributes)
                )
            } catch {
                throw map(error)
            }
            let rendered: DICOMRenderedSlice?
            do {
                rendered = try await cache.render(key: key, window: window)
            } catch {
                await cache.removeAll(for: session.token)
                renderReservation.release()
                throw map(error)
            }
            if let rendered {
                guard !Task.isCancelled, !isClosed, requestGeneration == generation,
                      currentSession == session else {
                    renderReservation.release()
                    throw DICOMSliceServiceError.cancelled
                }
                let pixels = retain(
                    rendered: rendered,
                    reservation: renderReservation
                )
                let output = image(
                    instanceID: instanceID,
                    rendered: rendered,
                    pixels: pixels
                )
                return output
            }
            renderReservation.release()
        }

        let scheduled: ScheduledDecode
        if let existing = foreground, existing.key == key {
            scheduled = existing
        } else if let existing = prefetch, existing.key == key {
            prefetch = nil
            foreground = existing
            scheduled = existing
        } else {
            scheduled = await makeDecode(
                instance: instance,
                session: session,
                key: key,
                priority: .foreground
            )
            foreground = scheduled
        }

        let reserved: ReservedCanonicalSlice
        do {
            reserved = try await scheduled.task.value
        } catch {
            if requestGeneration == generation, foreground?.id == scheduled.id {
                foreground = nil
            }
            throw map(error)
        }
        guard !Task.isCancelled, !isClosed, requestGeneration == generation,
              currentSession == session, foreground?.id == scheduled.id else {
            if requestGeneration == generation, foreground?.id == scheduled.id {
                foreground = nil
                reserved.reservation.release()
            } else if foreground?.id != scheduled.id,
                      consumingDecodeID != scheduled.id {
                reserved.reservation.release()
            }
            throw DICOMSliceServiceError.cancelled
        }
        foreground = nil
        consumingDecodeID = scheduled.id
        let rendered: DICOMRenderedSlice
        do {
            rendered = try DICOMDisplayTransformer.render(reserved.canonical, window: window)
        } catch {
            consumingDecodeID = nil
            reserved.reservation.release()
            throw map(error)
        }
        let renderReservation: DICOMSliceMemoryBudget.RenderLease
        do {
            guard let transferred = try await cache.insertTransferring(
                reserved.canonical,
                for: key,
                reservation: reserved.reservation,
                lifecycle: reserved.lifecycle,
                renderBytes: try Self.renderReservationBytes(instance.attributes)
            ) else {
                throw DICOMSliceServiceError.integrityFailure
            }
            renderReservation = transferred
        } catch {
            consumingDecodeID = nil
            reserved.reservation.release()
            throw map(error)
        }
        consumingDecodeID = nil
        guard !Task.isCancelled, !isClosed, requestGeneration == generation,
              currentSession == session else {
            await cache.removeAll(for: session.token)
            renderReservation.release()
            throw DICOMSliceServiceError.cancelled
        }
        do {
            try reserved.lifecycle.validate()
        } catch {
            await cache.removeAll(for: session.token)
            renderReservation.release()
            throw map(error)
        }
        let pixels = retain(rendered: rendered, reservation: renderReservation)
        let output = image(
            instanceID: instanceID,
            rendered: rendered,
            pixels: pixels
        )
        return output
    }

    @discardableResult
    public func prefetch(
        session: DICOMSliceSeriesSession,
        instanceID: DICOMStudyIndex.Instance.ID
    ) async -> Bool {
        guard !isClosed, currentSession == session,
              let instance = currentInstances[instanceID],
              (try? Self.predictedWorkingSet(instance))
                .map({ $0 <= Self.maximumPrefetchWorkingSet }) == true else {
            return false
        }
        let key = cacheKey(instance: instance, session: session)
        if await cache.contains(key) || foreground?.key == key || prefetch?.key == key {
            return true
        }
        prefetch?.task.cancel()
        let scheduled = await makeDecode(
            instance: instance,
            session: session,
            key: key,
            priority: .prefetch
        )
        prefetch = scheduled
        Task.detached { [weak self] in
            let result = await scheduled.task.result
            guard let self else {
                if case .success(let reserved) = result {
                    reserved.reservation.release()
                }
                return
            }
            await self.completePrefetch(
                result,
                scheduled: scheduled,
                session: session
            )
        }
        return true
    }

    public func handleMemoryPressure() async {
        requestGeneration &+= 1
        foreground?.task.cancel()
        prefetch?.task.cancel()
        foreground = nil
        prefetch = nil
        await cache.removeAll()
        releaseRetainedRender()
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        await invalidateCurrentSession()
    }

    func cacheSnapshotForTesting() async -> DICOMSliceCache.Snapshot {
        await cache.snapshot()
    }

    func budgetSnapshotForTesting() async -> DICOMSliceMemoryBudget.Snapshot {
        budget.snapshot()
    }

    private func invalidateCurrentSession() async {
        let invalidatedToken = currentSession?.token
        requestGeneration &+= 1
        foreground?.task.cancel()
        prefetch?.task.cancel()
        foreground = nil
        prefetch = nil
        currentSession = nil
        currentInstances.removeAll(keepingCapacity: true)
        if let invalidatedToken { await cache.removeAll(for: invalidatedToken) }
        releaseRetainedRender()
    }

    private func makeDecode(
        instance: DICOMSliceInstanceDescriptor,
        session: DICOMSliceSeriesSession,
        key: DICOMSliceCache.Key,
        priority: DICOMSliceProcessScheduler.Priority
    ) async -> ScheduledDecode {
        let source = self.source
        let budget = self.budget
        let scheduler = self.scheduler
        let permit = await scheduler.claim(priority)
        let gate = DICOMSliceStartGate()
        let task = Task.detached(priority: nil) {
            await gate.wait()
            guard await scheduler.waitUntilActive(permit) else {
                throw DICOMSliceServiceError.cancelled
            }
            var reservation: DICOMSliceMemoryBudget.ActiveLease?
            do {
                try Task.checkCancellation()
                let bytes = try Self.predictedWorkingSet(instance)
                let acquired = try budget.reserveLease(bytes)
                reservation = acquired
                let decoded = try await source.decode(instance, in: session)
                try Task.checkCancellation()
                try decoded.frame.validate()
                let attributes = try DICOMImageAttributesMapper.attributes(for: decoded.frame)
                guard attributes == instance.attributes else {
                    throw DICOMSliceServiceError.integrityFailure
                }
                let canonical = try DICOMDisplayTransformer.canonicalize(
                    sampleBytes: decoded.frame.sampleBytes,
                    attributes: attributes
                )
                await scheduler.finish(permit)
                return ReservedCanonicalSlice(
                    canonical: canonical,
                    reservation: acquired,
                    lifecycle: decoded.lifecycle
                )
            } catch {
                reservation?.release()
                await scheduler.finish(permit)
                throw error
            }
        }
        await scheduler.attach(permit) { task.cancel() }
        gate.open()
        return ScheduledDecode(id: UUID(), key: key, task: task)
    }

    private func completePrefetch(
        _ result: Result<ReservedCanonicalSlice, Error>,
        scheduled: ScheduledDecode,
        session: DICOMSliceSeriesSession
    ) async {
        guard prefetch?.id == scheduled.id else {
            if foreground?.id == scheduled.id || consumingDecodeID == scheduled.id {
                return
            }
            if case .success(let reserved) = result {
                reserved.reservation.release()
            }
            return
        }
        prefetch = nil
        guard !isClosed, currentSession == session else {
            if case .success(let reserved) = result {
                reserved.reservation.release()
            }
            return
        }
        guard case .success(let reserved) = result else { return }
        do {
            try reserved.lifecycle.validate()
            _ = try await cache.insertTransferring(
                reserved.canonical,
                for: scheduled.key,
                reservation: reserved.reservation,
                lifecycle: reserved.lifecycle,
                renderBytes: 0
            )
            try reserved.lifecycle.validate()
        } catch {
            await cache.removeAll(for: session.token)
            reserved.reservation.release()
        }
    }

    private static func predictedWorkingSet(
        _ instance: DICOMSliceInstanceDescriptor
    ) throws -> Int {
        let pixels = instance.attributes.rows.multipliedReportingOverflow(
            by: instance.attributes.columns
        )
        guard !pixels.overflow else { throw DICOMSliceServiceError.resourceLimit }
        let raw = pixels.partialValue.multipliedReportingOverflow(
            by: instance.attributes.bitsAllocated / 8
        )
        let rawCopies = raw.partialValue.multipliedReportingOverflow(by: 2)
        let canonical = pixels.partialValue.multipliedReportingOverflow(
            by: MemoryLayout<Float>.stride
        )
        let renderAndUpload = try renderReservationBytes(instance.attributes)
        guard !raw.overflow, !rawCopies.overflow, !canonical.overflow else {
            throw DICOMSliceServiceError.resourceLimit
        }
        var total = instance.objectByteCount
        var allocations = [
            rawCopies.partialValue,
            canonical.partialValue,
            renderAndUpload,
        ]
        if instance.attributes.windowCenter == nil {
            allocations.append(canonical.partialValue)
        }
        for bytes in allocations {
            let addition = total.addingReportingOverflow(bytes)
            guard !addition.overflow else { throw DICOMSliceServiceError.resourceLimit }
            total = addition.partialValue
        }
        return total
    }

    private func cacheKey(
        instance: DICOMSliceInstanceDescriptor,
        session: DICOMSliceSeriesSession
    ) -> DICOMSliceCache.Key {
        .init(
            token: session.token,
            contentDigest: instance.contentDigest,
            byteCount: instance.objectByteCount
        )
    }

    private func requestedWindow(center: Double?, width: Double?) throws -> DICOMWindow? {
        guard (center == nil) == (width == nil) else {
            throw DICOMSliceServiceError.integrityFailure
        }
        guard let center, let width else { return nil }
        do { return try DICOMWindow(center: center, width: width) }
        catch { throw DICOMSliceServiceError.integrityFailure }
    }

    private static func renderReservationBytes(
        _ attributes: DICOMStudyIndex.ImageAttributes
    ) throws -> Int {
        let pixels = attributes.rows.multipliedReportingOverflow(by: attributes.columns)
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 2)
        guard !pixels.overflow, !bytes.overflow else {
            throw DICOMSliceServiceError.resourceLimit
        }
        return bytes.partialValue
    }

    private func retain(
        rendered: DICOMRenderedSlice,
        reservation: DICOMSliceMemoryBudget.RenderLease
    ) -> DICOMSlicePixelBuffer {
        let pixels = DICOMSlicePixelBuffer(bytes: rendered.grayscaleBytes)
        retainedRender = RetainedRender(
            pixels: pixels,
            reservation: reservation
        )
        return pixels
    }

    private func releaseRetainedRender() {
        guard let retainedRender else { return }
        self.retainedRender = nil
        retainedRender.pixels.invalidate()
        retainedRender.reservation.release()
    }

    private func image(
        instanceID: UUID,
        rendered: DICOMRenderedSlice,
        pixels: DICOMSlicePixelBuffer
    ) -> DICOMSliceImage {
        .init(
            instanceID: instanceID,
            rows: rendered.rows,
            columns: rendered.columns,
            windowCenter: rendered.window.center,
            windowWidth: rendered.window.width,
            pixels: pixels
        )
    }

    private func map(_ error: Error) -> DICOMSliceServiceError {
        if let error = error as? DICOMSliceServiceError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? DICOMDecoderAdapterError {
            switch error {
            case .resourceLimit: return .resourceLimit
            case .helperUnavailable, .helperInterrupted, .helperTimedOut:
                return .decoderUnavailable
            case .invalidDescriptor, .invalidPart10, .invalidResponse,
                 .unsupportedObject, .decoderFailed:
                return .integrityFailure
            }
        }
        if let error = error as? VaultError {
            switch error {
            case .resourceLimitExceeded: return .resourceLimit
            case .mutationConflict: return .staleSession
            default: return .integrityFailure
            }
        }
        if let error = error as? DICOMDisplayTransformError {
            return error == .resourceLimit ? .resourceLimit : .integrityFailure
        }
        return .integrityFailure
    }
}
