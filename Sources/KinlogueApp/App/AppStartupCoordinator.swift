import Combine
import Foundation
import KinloguePlatform

/// The only GUI startup order: restore receipts converge before the first
/// storage-backed service call, and automatic backup starts only after the
/// normal library is confirmed ready. This prevents a stale writer or root
/// object from being exposed across restore activation.
@MainActor
final class AppStartupCoordinator: ObservableObject {
    @Published private(set) var composition: AppComposition?
    @Published var candidateFailure: SQLiteStartupFailure?
    @Published var isOpening = false
    var candidateStartingTask: Task<Bool, Never>?
    var identity: AppRuntimeIdentity?
    var disclosureAccepted = false
    var context: SQLiteStartupContext?
    var didReconcile = false
    var hasOpenedComposition = false
    var environment: LiveAppServiceEnvironment?
    var database: SQLiteLibraryStore?
    var openingTask: Task<LiveAppServiceEnvironment, Error>?
    var seedRestoreService: (any BackupRestoreServicing)?
    var openingFailure: (any Error)?
    var shutdownRequested = false

    init(identity: AppRuntimeIdentity) {
        self.identity = identity
        reconcileRestore = { false }; startStorage = { false }; startScheduler = {}
        startProcessing = {}; reconcileLibrary = {}
    }

    func publish(_ composition: AppComposition?) { self.composition = composition }
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
        if identity != nil { await composition?.startupCoordinator.reconcile(); return }
        guard case .started = state else { return }
        await reconcileLibrary()
    }

    @discardableResult
    func start() async -> Bool {
        if identity != nil { return await startSQLiteCandidate() }
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
