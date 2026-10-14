import Dispatch

/// Where blocking storage work runs.
///
/// The SQLite kernel is synchronous: a call waits for the library's admission lock, for SQLite
/// and for file I/O. On Swift's cooperative pool, which has one thread per core, a few such
/// waits would occupy every thread and stall unrelated tasks across the process. Each
/// asynchronous entry point of the storage layer therefore runs its body through `run`, which
/// moves the task onto threads that are allowed to block and leaves the cooperative pool free.
package final class LibraryStorageExecutor: TaskExecutor {
    package static let shared = LibraryStorageExecutor()

    private let queue = DispatchQueue(label: "com.kinlogue.library-storage", attributes: .concurrent)

    package func enqueue(_ job: consuming ExecutorJob) {
        let qos = DispatchQoS(qosClass: DispatchQoS.QoSClass(rawValue: qos_class_t(UInt32(job.priority.rawValue))) ?? .default,
                              relativePriority: 0)
        let job = UnownedJob(job)
        queue.async(qos: qos, flags: .enforceQoS) { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    /// Runs `body` with the storage threads as its task's preferred executor: the nonisolated
    /// calls it makes, and actors without an executor of their own, run there. Code isolated to
    /// the caller's actor stays on that actor.
    package static func run<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await withTaskExecutorPreference(shared, isolation: isolation, operation: body)
    }

    /// Whether the calling thread belongs to Swift's cooperative pool, where storage must not
    /// wait. Diagnostic only: it reads the label libdispatch gives those threads.
    package static var callerIsOnCooperativePool: Bool {
        String(cString: __dispatch_queue_get_label(nil)).hasSuffix(".cooperative")
    }
}
