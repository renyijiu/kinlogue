import Combine
import Foundation
import KinloguePlatform

/// A single App-owned idle task. Foreground operations cancel and drain it before using storage.
@MainActor
final class AppIntegrityCoordinator: ObservableObject {
    enum Status: Equatable { case notInspected, waiting, inspecting(Int), incomplete, completed(Date, Int), unavailable }
    @Published private(set) var status = Status.notInspected
    typealias Inspection = @Sendable (@escaping @Sendable (Int) async throws -> Void) async throws -> SQLiteIntegrityReport
    private let inspect: Inspection
    private let lifecycle: LibraryLifecycleCoordinator
    private let onCompleted: () async -> Void
    private let onUnsafe: () async -> Void
    private let registrationID = UUID()
    private var registered = false
    private var revoked = false
    private var task: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var taskToken: UInt64?

    init(store: SQLiteLibraryStore, lifecycle: LibraryLifecycleCoordinator,
         onCompleted: @escaping () async -> Void, onUnsafe: @escaping () async -> Void,
         inspect: Inspection? = nil) {
        self.inspect = inspect ?? { progress in try await SQLiteLibraryIntegrityScrubber(store: store).run(progress: progress) }
        self.lifecycle = lifecycle
        self.onCompleted = onCompleted; self.onUnsafe = onUnsafe
    }

    func start() async {
        guard !revoked else { return }
        if !registered {
            do {
                try await lifecycle.register(id: registrationID) { [weak self] in await self?.stop() }
                try await lifecycle.observeIntegrityActivity { [weak self] active in
                    if active { await self?.pause() } else { await self?.resumeWhenIdle() }
                }
                registered = true
            } catch { return }
        }
        await resumeWhenIdle()
    }

    func resumeWhenIdle() async {
        guard registered, !revoked, task == nil else { return }
        if case .completed = status { return }
        let observedGeneration = generation
        guard await lifecycle.isIdle(), observedGeneration == generation, !revoked, task == nil else { return }
        generation += 1
        let token = generation
        taskToken = token
        status = .waiting
        task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                guard await lifecycle.isIdle(), token == generation, !revoked, !Task.isCancelled else {
                    if taskToken == token { task = nil; taskToken = nil; status = .incomplete }
                    return
                }
                let result = try await inspect { [weak self] count in
                    try Task.checkCancellation()
                    await self?.update(count, token: token)
                }
                guard token == generation, !revoked, !Task.isCancelled else { return }
                task = nil; taskToken = nil
                if result.completed {
                    status = .completed(result.checkedAt, result.damagedTargets.count)
                    await onCompleted()
                } else {
                    status = .incomplete
                    await resumeWhenIdle()
                }
            } catch is CancellationError {
                if token == generation { task = nil; taskToken = nil; status = .incomplete }
            } catch {
                guard token == generation, !revoked else { return }
                task = nil; taskToken = nil; status = .unavailable
                await requestUnsafeShutdown()
            }
        }
    }

    func requestUnsafeShutdown() async {
        guard !revoked else { return }
        revoked = true
        status = .unavailable
        await lifecycle.requestRevocation()
        // The reporting read or observer must return before its own drain can finish.
        shutdownTask = Task {
            await onUnsafe()
            status = .unavailable
            shutdownTask = nil
        }
    }

    func libraryChanged() async {
        await pause()
        guard !revoked else { return }
        status = .incomplete
        await resumeWhenIdle()
    }

    private func update(_ count: Int, token: UInt64) {
        guard token == generation, !revoked else { return }
        status = .inspecting(count)
    }

    func pause() async {
        generation += 1
        guard let previous = task, let token = taskToken else { return }
        // Keep the same task discoverable until every cancellation path has ended.
        previous.cancel()
        await previous.value
        guard taskToken == token else { return }
        task = nil; taskToken = nil
        status = .incomplete
    }

    func stop() async { revoked = true; await pause() }
}
