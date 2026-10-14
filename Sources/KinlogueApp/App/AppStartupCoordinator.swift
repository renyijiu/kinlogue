import Foundation

/// The order in which one composition starts its services: restore receipts converge before the
/// first storage-backed service call, and automatic backup starts only after the library is
/// confirmed ready. This prevents a stale writer or root object from being exposed across
/// restore activation.
@MainActor
final class AppStartupCoordinator {
    typealias ReconcileRestore = () async -> Bool
    typealias StartStorage = () async -> Bool
    typealias StartScheduler = () async -> Void

    private let reconcileRestore: ReconcileRestore
    private let startStorage: StartStorage
    private let startScheduler: StartScheduler
    private let startProcessing: StartScheduler
    private let reconcileLibrary: StartScheduler
    private var state = State.idle

    private enum State {
        case idle
        case starting
        case started
    }

    init(
        reconcileRestore: @escaping ReconcileRestore,
        startStorage: @escaping StartStorage,
        startProcessing: @escaping StartScheduler = {},
        startScheduler: @escaping StartScheduler,
        reconcileLibrary: @escaping StartScheduler = {}
    ) {
        self.reconcileRestore = reconcileRestore
        self.startStorage = startStorage
        self.startScheduler = startScheduler
        self.startProcessing = startProcessing
        self.reconcileLibrary = reconcileLibrary
    }

    func reconcile() async {
        guard case .started = state else { return }
        await reconcileLibrary()
    }

    @discardableResult
    func start() async -> Bool {
        switch state {
        case .started:
            return true
        case .starting:
            return false
        case .idle:
            state = .starting
        }
        guard await reconcileRestore() else {
            state = .idle
            return false
        }
        guard await startStorage() else {
            state = .idle
            return false
        }
        await startProcessing()
        await startScheduler()
        state = .started
        return true
    }
}
