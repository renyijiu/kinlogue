import Foundation
import Testing
@testable import KinlogueApp

@MainActor
struct LibraryReadRegistryTests {
    @Test
    func cancelAllCancelsActiveReadsAndItsDrainsWaitForThemToEnd() async {
        let registry = LibraryReadRegistry()
        let gate = AsyncOperationGate()
        let ended = ReadEndLog()
        let read = Task {
            // The read ignores cancellation until the gate opens, as a storage call may.
            _ = try? await registry.run {
                await gate.wait()
                await ended.note(cancelled: Task.isCancelled)
                return 1
            }
        }
        #expect(await gate.waitUntilStarted())
        let drains = registry.cancelAll()
        #expect(drains.count == 1)
        let drained = Task { for drain in drains { await drain() } }
        #expect(await ended.cancelledValues.isEmpty)
        await gate.open()
        await drained.value
        #expect(await ended.cancelledValues == [true])
        await read.value
        #expect(registry.cancelAll().isEmpty)
    }

    @Test
    func cancellingTheCallerCancelsTheReadAndEndsItsRegistration() async {
        let registry = LibraryReadRegistry()
        let gate = AsyncOperationGate()
        let caller = Task {
            try await registry.run {
                await gate.wait()
                try Task.checkCancellation()
                return 1
            }
        }
        #expect(await gate.waitUntilStarted())
        caller.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(registry.cancelAll().isEmpty)
    }

    @Test
    func unawaitedWorkStaysRegisteredOnlyWhileItRuns() async {
        let registry = LibraryReadRegistry()
        let gate = AsyncOperationGate()
        registry.start { await gate.wait() }
        #expect(await gate.waitUntilStarted())
        let drains = registry.cancelAll()
        #expect(drains.count == 1)
        await gate.open()
        for drain in drains { await drain() }
        #expect(registry.cancelAll().isEmpty)
    }

    @Test
    func aTaskRegisteredByHandIsDrainedUntilItsEndIsReported() async {
        let registry = LibraryReadRegistry()
        let task = Task<Int, Error> { 7 }
        let id = registry.register(task)
        #expect(registry.cancelAll().count == 1)
        registry.end(id)
        #expect(registry.cancelAll().isEmpty)
        _ = try? await task.value
    }
}

private actor ReadEndLog {
    private(set) var cancelledValues: [Bool] = []
    func note(cancelled: Bool) { cancelledValues.append(cancelled) }
}
