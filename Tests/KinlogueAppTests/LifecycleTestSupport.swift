import Foundation

@testable import KinlogueApp

func installRevocationGate(
    on lifecycle: LibraryLifecycleCoordinator
) async throws -> AsyncOperationGate {
    let gate = AsyncOperationGate()
    try await lifecycle.register(id: UUID()) {
        await gate.wait()
    }
    return gate
}

actor AsyncOperationGate {
    private var started = false
    private var opened = false
    private var operationContinuations: [CheckedContinuation<Void, Never>] = []
    private var startContinuations: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        started = true
        let continuations = startContinuations.values
        startContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            if opened {
                continuation.resume()
            } else {
                operationContinuations.append(continuation)
            }
        }
    }

    func waitUntilStarted(timeout: Duration = .seconds(5)) async -> Bool {
        guard !started else { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForStartSignal()
                return true
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    func open() {
        opened = true
        let continuations = operationContinuations
        operationContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func waitForStartSignal() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if started || Task.isCancelled {
                    continuation.resume()
                } else {
                    startContinuations[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelStartWaiter(id: id) }
        }
    }

    private func cancelStartWaiter(id: UUID) {
        startContinuations.removeValue(forKey: id)?.resume()
    }
}
