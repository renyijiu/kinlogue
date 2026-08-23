import Foundation

// SAFETY: `lock` protects every reservation counter and map; immutable limits
// are initialized before the budget is shared.
final class DICOMSliceMemoryBudget: @unchecked Sendable {
    static let defaultMaximumBytes = 384 * 1_024 * 1_024

    struct Reservation: Hashable, Sendable { fileprivate let id: UUID }
    struct RenderReservation: Hashable, Sendable { fileprivate let id: UUID }
    struct Snapshot: Equatable, Sendable {
        let activeBytes: Int
        let cacheBytes: Int
        let renderBytes: Int
        let reservationCount: Int
        let renderReservationCount: Int
    }

    // SAFETY: `lock` makes release idempotent; the referenced budget is itself
    // lock-protected and outlives each reservation callback.
    final class ActiveLease: @unchecked Sendable {
        fileprivate let reservation: Reservation
        private let budget: DICOMSliceMemoryBudget
        private let lock = NSLock()
        private var isReleased = false

        fileprivate init(budget: DICOMSliceMemoryBudget, reservation: Reservation) {
            self.budget = budget
            self.reservation = reservation
        }

        func release() {
            let shouldRelease = lock.withLock { () -> Bool in
                guard !isReleased else { return false }
                isReleased = true
                return true
            }
            if shouldRelease { budget.release(reservation) }
        }

        deinit { release() }
    }

    // SAFETY: `lock` makes release idempotent; the referenced budget is itself
    // lock-protected and outlives each reservation callback.
    final class RenderLease: @unchecked Sendable {
        fileprivate let reservation: RenderReservation
        private let budget: DICOMSliceMemoryBudget
        private let lock = NSLock()
        private var isReleased = false

        fileprivate init(budget: DICOMSliceMemoryBudget, reservation: RenderReservation) {
            self.budget = budget
            self.reservation = reservation
        }

        func release() {
            let shouldRelease = lock.withLock { () -> Bool in
                guard !isReleased else { return false }
                isReleased = true
                return true
            }
            if shouldRelease { budget.releaseRender(reservation) }
        }

        deinit { release() }
    }

    private let maximumBytes: Int
    private let lock = NSLock()
    private var activeBytes = 0
    private var cacheBytes = 0
    private var renderBytes = 0
    private var reservations: [UUID: Int] = [:]
    private var renderReservations: [UUID: Int] = [:]

    init(maximumBytes: Int = defaultMaximumBytes) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    func reserve(_ bytes: Int) throws -> Reservation {
        try lock.withLock {
            guard bytes >= 0 else { throw DICOMSliceServiceError.resourceLimit }
            let next = activeBytes.addingReportingOverflow(bytes)
            let withCache = next.partialValue.addingReportingOverflow(cacheBytes)
            let total = withCache.partialValue.addingReportingOverflow(renderBytes)
            guard !next.overflow, !withCache.overflow, !total.overflow,
                  total.partialValue <= maximumBytes else {
                throw DICOMSliceServiceError.resourceLimit
            }
            let reservation = Reservation(id: UUID())
            activeBytes = next.partialValue
            reservations[reservation.id] = bytes
            return reservation
        }
    }

    func reserveLease(_ bytes: Int) throws -> ActiveLease {
        ActiveLease(budget: self, reservation: try reserve(bytes))
    }

    func release(_ reservation: Reservation) {
        lock.withLock {
            guard let bytes = reservations.removeValue(forKey: reservation.id) else { return }
            activeBytes -= bytes
        }
    }

    func reserveRender(_ bytes: Int) throws -> RenderReservation {
        try lock.withLock {
            guard bytes >= 0 else {
                throw DICOMSliceServiceError.resourceLimit
            }
            let partial = activeBytes.addingReportingOverflow(cacheBytes)
            let nextRender = renderBytes.addingReportingOverflow(bytes)
            let total = partial.partialValue.addingReportingOverflow(nextRender.partialValue)
            guard !partial.overflow, !nextRender.overflow, !total.overflow,
                  total.partialValue <= maximumBytes else {
                throw DICOMSliceServiceError.resourceLimit
            }
            let reservation = RenderReservation(id: UUID())
            renderReservations[reservation.id] = bytes
            renderBytes = nextRender.partialValue
            return reservation
        }
    }

    func reserveRenderLease(_ bytes: Int) throws -> RenderLease {
        RenderLease(budget: self, reservation: try reserveRender(bytes))
    }

    func transition(
        _ reservation: Reservation,
        toCacheBytes proposedCacheBytes: Int,
        renderBytes: Int
    ) throws -> RenderReservation? {
        try lock.withLock {
            guard let active = reservations[reservation.id],
                  proposedCacheBytes >= 0, renderBytes >= 0 else {
                throw DICOMSliceServiceError.integrityFailure
            }
            let remainingActive = activeBytes - active
            let partial = remainingActive.addingReportingOverflow(proposedCacheBytes)
            let nextRender = self.renderBytes.addingReportingOverflow(renderBytes)
            let total = partial.partialValue.addingReportingOverflow(nextRender.partialValue)
            guard !partial.overflow, !nextRender.overflow, !total.overflow,
                  total.partialValue <= maximumBytes else {
                throw DICOMSliceServiceError.resourceLimit
            }
            reservations.removeValue(forKey: reservation.id)
            activeBytes = remainingActive
            cacheBytes = proposedCacheBytes
            guard renderBytes > 0 else { return nil }
            let render = RenderReservation(id: UUID())
            renderReservations[render.id] = renderBytes
            self.renderBytes = nextRender.partialValue
            return render
        }
    }

    func transition(
        _ lease: ActiveLease,
        toCacheBytes proposedCacheBytes: Int,
        renderBytes: Int
    ) throws -> RenderLease? {
        guard let reservation = try transition(
            lease.reservation,
            toCacheBytes: proposedCacheBytes,
            renderBytes: renderBytes
        ) else { return nil }
        return RenderLease(budget: self, reservation: reservation)
    }

    func releaseRender(_ reservation: RenderReservation) {
        lock.withLock {
            guard let bytes = renderReservations.removeValue(forKey: reservation.id) else {
                return
            }
            renderBytes -= bytes
        }
    }

    func setCacheBytes(_ bytes: Int) -> Bool {
        lock.withLock {
            guard bytes >= 0 else { return false }
            let partial = activeBytes.addingReportingOverflow(bytes)
            let total = partial.partialValue.addingReportingOverflow(renderBytes)
            guard !partial.overflow, !total.overflow,
                  total.partialValue <= maximumBytes else { return false }
            cacheBytes = bytes
            return true
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                activeBytes: activeBytes,
                cacheBytes: cacheBytes,
                renderBytes: renderBytes,
                reservationCount: reservations.count,
                renderReservationCount: renderReservations.count
            )
        }
    }
}

actor DICOMSliceCache {
    static let defaultMaximumCount = 32
    static let defaultMaximumBytes = 192 * 1_024 * 1_024

    struct Key: Hashable, Sendable {
        let token: DICOMVaultSessionToken
        let contentDigest: Data
        let byteCount: Int
    }

    struct Snapshot: Equatable, Sendable {
        let count: Int
        let byteCount: Int
        let zeroizedByteCount: Int
    }

    private struct Entry: Sendable {
        var canonical: DICOMCanonicalSlice
        var lastAccess: UInt64
        let lifecycle: DICOMSliceLifecycleTicket
    }

    private let maximumCount: Int
    private let maximumBytes: Int
    private let budget: DICOMSliceMemoryBudget
    private var entries: [Key: Entry] = [:]
    private var byteCount = 0
    private var accessClock: UInt64 = 0
    private var zeroizedByteCount = 0

    init(
        maximumCount: Int = defaultMaximumCount,
        maximumBytes: Int = defaultMaximumBytes,
        budget: DICOMSliceMemoryBudget
    ) {
        precondition(maximumCount > 0 && maximumBytes > 0)
        self.maximumCount = maximumCount
        self.maximumBytes = maximumBytes
        self.budget = budget
    }

    func contains(_ key: Key) -> Bool { entries[key] != nil }

    func render(
        key: Key,
        window: DICOMWindow?
    ) throws -> DICOMRenderedSlice? {
        guard var entry = entries[key] else { return nil }
        try entry.lifecycle.validate()
        accessClock &+= 1
        entry.lastAccess = accessClock
        entries[key] = entry
        let rendered = try DICOMDisplayTransformer.render(entry.canonical, window: window)
        try entry.lifecycle.validate()
        return rendered
    }

    func insertTransferring(
        _ canonical: DICOMCanonicalSlice,
        for key: Key,
        reservation: DICOMSliceMemoryBudget.ActiveLease,
        lifecycle: DICOMSliceLifecycleTicket,
        renderBytes: Int
    ) throws -> DICOMSliceMemoryBudget.RenderLease? {
        let shouldCache = canonical.byteCount <= maximumBytes
        if let prior = entries.removeValue(forKey: key) {
            byteCount -= prior.canonical.byteCount
            zeroize(prior.canonical)
        }
        if shouldCache {
            while entries.count + 1 > maximumCount
                    || byteCount + canonical.byteCount > maximumBytes {
                guard let key = leastRecentlyUsedKey() else { break }
                evict(key)
            }
        } else {
            zeroize(canonical)
        }
        while true {
            let proposedCacheBytes = byteCount + (shouldCache ? canonical.byteCount : 0)
            do {
                let render = try budget.transition(
                    reservation,
                    toCacheBytes: proposedCacheBytes,
                    renderBytes: renderBytes
                )
                if shouldCache {
                    accessClock &+= 1
                    entries[key] = Entry(
                        canonical: canonical,
                        lastAccess: accessClock,
                        lifecycle: lifecycle
                    )
                    byteCount = proposedCacheBytes
                }
                return render
            } catch DICOMSliceServiceError.resourceLimit {
                guard let key = leastRecentlyUsedKey() else { throw DICOMSliceServiceError.resourceLimit }
                evict(key)
            }
        }
    }

    func removeAll() {
        for key in Array(entries.keys) { evict(key) }
        _ = budget.setCacheBytes(0)
    }

    func removeAll(for token: DICOMVaultSessionToken) {
        for key in Array(entries.keys.filter { $0.token == token }) {
            evict(key)
        }
        _ = budget.setCacheBytes(byteCount)
    }

    func snapshot() -> Snapshot {
        Snapshot(
            count: entries.count,
            byteCount: byteCount,
            zeroizedByteCount: zeroizedByteCount
        )
    }

    private func leastRecentlyUsedKey() -> Key? {
        entries.min { $0.value.lastAccess < $1.value.lastAccess }?.key
    }

    private func evict(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        byteCount -= entry.canonical.byteCount
        zeroize(entry.canonical)
    }

    private func zeroize(_ canonical: DICOMCanonicalSlice) {
        zeroizedByteCount += canonical.zeroize()
    }
}

actor DICOMSliceProcessScheduler {
    enum Priority: Sendable { case foreground, prefetch }
    struct Permit: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate let priority: Priority
    }

    private struct Work {
        let permit: Permit
        var cancel: (@Sendable () -> Void)?
        var activation: CheckedContinuation<Bool, Never>?
    }

    private var activeForeground: Work?
    private var pendingForeground: Work?
    private var activePrefetch: Work?
    private var pendingPrefetch: Work?

    func claim(_ priority: Priority) -> Permit {
        let permit = Permit(id: UUID(), priority: priority)
        switch priority {
        case .foreground:
            enqueue(
                permit,
                active: &activeForeground,
                pending: &pendingForeground
            )
            cancelPending(&pendingPrefetch)
            activePrefetch?.cancel?()
        case .prefetch:
            enqueue(
                permit,
                active: &activePrefetch,
                pending: &pendingPrefetch
            )
        }
        return permit
    }

    func attach(_ permit: Permit, cancel: @escaping @Sendable () -> Void) {
        switch permit.priority {
        case .foreground:
            attach(
                permit,
                cancel: cancel,
                active: &activeForeground,
                pending: pendingForeground
            )
        case .prefetch:
            attach(
                permit,
                cancel: cancel,
                active: &activePrefetch,
                pending: pendingPrefetch
            )
        }
    }

    func waitUntilActive(_ permit: Permit) async -> Bool {
        await withTaskCancellationHandler {
            await waitForActivation(permit)
        } onCancel: {
            Task { await self.cancel(permit) }
        }
    }

    private func waitForActivation(_ permit: Permit) async -> Bool {
        switch permit.priority {
        case .foreground:
            if activeForeground?.permit == permit { return true }
            guard pendingForeground?.permit == permit else { return false }
            return await withCheckedContinuation { continuation in
                pendingForeground?.activation = continuation
            }
        case .prefetch:
            if activePrefetch?.permit == permit { return true }
            guard pendingPrefetch?.permit == permit else { return false }
            return await withCheckedContinuation { continuation in
                pendingPrefetch?.activation = continuation
            }
        }
    }

    private func cancel(_ permit: Permit) {
        switch permit.priority {
        case .foreground:
            if activeForeground?.permit == permit {
                activeForeground?.cancel?()
            } else if pendingForeground?.permit == permit {
                cancelPending(&pendingForeground)
            }
        case .prefetch:
            if activePrefetch?.permit == permit {
                activePrefetch?.cancel?()
            } else if pendingPrefetch?.permit == permit {
                cancelPending(&pendingPrefetch)
            }
        }
    }

    func finish(_ permit: Permit) {
        switch permit.priority {
        case .foreground:
            finish(
                permit,
                active: &activeForeground,
                pending: &pendingForeground
            )
        case .prefetch:
            finish(
                permit,
                active: &activePrefetch,
                pending: &pendingPrefetch
            )
        }
    }

    private func enqueue(
        _ permit: Permit,
        active: inout Work?,
        pending: inout Work?
    ) {
        let work = Work(permit: permit, cancel: nil, activation: nil)
        guard active != nil else {
            active = work
            return
        }
        active?.cancel?()
        cancelPending(&pending)
        pending = work
    }

    private func cancelPending(_ pending: inout Work?) {
        pending?.cancel?()
        pending?.activation?.resume(returning: false)
        pending = nil
    }

    private func attach(
        _ permit: Permit,
        cancel: @escaping @Sendable () -> Void,
        active: inout Work?,
        pending: Work?
    ) {
        if active?.permit == permit {
            active?.cancel = cancel
            if pending != nil { cancel() }
        } else if pending?.permit == permit {
            switch permit.priority {
            case .foreground: pendingForeground?.cancel = cancel
            case .prefetch: pendingPrefetch?.cancel = cancel
            }
        } else {
            cancel()
        }
    }

    private func finish(
        _ permit: Permit,
        active: inout Work?,
        pending: inout Work?
    ) {
        guard active?.permit == permit else { return }
        active = pending
        pending = nil
        active?.activation?.resume(returning: true)
        active?.activation = nil
    }
}

// SAFETY: `lock` protects the continuation and open flag, and `open()` removes
// the continuation before resuming it at most once.
final class DICOMSliceStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if isOpen { continuation.resume() }
                else { self.continuation = continuation }
            }
        }
    }

    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isOpen = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}

// SAFETY: Runtime references are immutable after initialization; the budget is
// lock-protected while cache and scheduler are actors.
final class DICOMSliceRuntime: @unchecked Sendable {
    static let shared = DICOMSliceRuntime()

    let budget: DICOMSliceMemoryBudget
    let cache: DICOMSliceCache
    let scheduler = DICOMSliceProcessScheduler()

    init(
        maximumMemoryBytes: Int = DICOMSliceMemoryBudget.defaultMaximumBytes,
        maximumCacheCount: Int = DICOMSliceCache.defaultMaximumCount,
        maximumCacheBytes: Int = DICOMSliceCache.defaultMaximumBytes
    ) {
        let budget = DICOMSliceMemoryBudget(maximumBytes: maximumMemoryBytes)
        self.budget = budget
        cache = DICOMSliceCache(
            maximumCount: maximumCacheCount,
            maximumBytes: maximumCacheBytes,
            budget: budget
        )
    }
}
