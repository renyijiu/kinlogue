import Combine
import Foundation
import KinloguePlatform

/// Owns the library for one launch of the app.
///
/// Construction touches nothing. After the storage disclosure is accepted, `start` takes the
/// single-instance owner, converges restore and deletion receipts, opens the database and
/// publishes the composition built on it. Without a runtime identity it reports the library as
/// unavailable instead of resolving any other location.
@MainActor
final class LibraryLaunchCoordinator: ObservableObject {
    @Published private(set) var composition: AppComposition?
    @Published private(set) var failure: SQLiteStartupFailure?
    @Published private(set) var isOpening = false
    private(set) var hasOpenedComposition = false
    private(set) var seedRestoreService: (any BackupRestoreServicing)?
    private(set) var database: SQLiteLibraryStore?
    private let identity: AppRuntimeIdentity?
    private var disclosureAccepted = false
    private var context: SQLiteStartupContext?
    private var didReconcile = false
    private(set) var environment: LiveAppServiceEnvironment?
    private var openingTask: Task<LiveAppServiceEnvironment, Error>?
    private var openingFailure: (any Error)?
    private var startingTask: Task<Bool, Never>?
    private var shutdownRequested = false

    init(identity: AppRuntimeIdentity?) { self.identity = identity }

    /// The GUI's only way to a library: the SQLite library under the trusted runtime identity.
    static func makeDefault() -> LibraryLaunchCoordinator {
        LibraryLaunchCoordinator(identity: try? AppRuntimeIdentity.current())
    }

    /// Asks the opened composition to catch up after the app was inactive or asleep.
    func reconcile() async { await composition?.startupCoordinator.reconcile() }

    private func publish(_ composition: AppComposition?) { self.composition = composition }

    func acknowledgeStorageDisclosure() { disclosureAccepted = true }

    func openEnvironment() async throws -> LiveAppServiceEnvironment {
        guard disclosureAccepted else { throw AppStartupError.disclosureRequired }
        guard !shutdownRequested else { throw LibraryLifecycleCoordinatorError.revoked }
        if let context { try await context.lifecycle.requireActive() }
        if let environment { return environment }
        if let openingTask { return try await openingTask.value }
        // A failed-format launch offers seed-only restore, never hot rebinding while
        // a confirmation prepared against that launch may still be outstanding.
        if seedRestoreService != nil, let openingFailure { throw openingFailure }
        let task = Task { try await performOpening() }
        openingTask = task
        defer { openingTask = nil }
        return try await task.value
    }

    private func performOpening() async throws -> LiveAppServiceEnvironment {
        guard let identity else { throw AppServiceError.runtimeUnavailable }
        if context == nil { context = try await SQLiteStartupContext.make(identity: identity) }
        guard let context else { throw AppServiceError.runtimeUnavailable }
        if !didReconcile {
            try await context.reconcile()
            didReconcile = true
        }
        do {
            let store = try await context.open()
            database = store
            let services = try await LiveAppServiceEnvironment.makeOpened(identity: identity, store: store, lifecycle: context.lifecycle)
            try Task.checkCancellation()
            try await context.lifecycle.requireActive()
            environment = services
            openingFailure = nil
            return services
        } catch {
            if let database {
                // Keep authority if closing cannot be proved; a later launch must recover.
                do { try await SQLiteStartupContext.close(database, releasingOwner: false); self.database = nil }
                catch { shutdownRequested = true; throw error }
            }
            openingFailure = error
            if let failure = error as? SQLiteLibraryError,
               [.unsupportedFormat, .unsupportedConfiguration, .damaged, .databaseUnavailable].contains(failure) {
                seedRestoreService = context.seedRestore()
            }
            throw error
        }
    }

    @discardableResult
    func start() async -> Bool {
        if let startingTask { return await startingTask.value }
        isOpening = true
        let task = Task { await performStart() }
        startingTask = task
        defer { startingTask = nil; isOpening = false }
        return await task.value
    }

    private func performStart() async -> Bool {
        do {
            let services = try await openEnvironment()
            try Task.checkCancellation()
            if !hasOpenedComposition, let identity, let context, let database {
                publish(AppComposition.makeOpened(identity: identity, services: services, context: context, database: database))
                hasOpenedComposition = true
            }
            let ready = await composition?.startupCoordinator.start() ?? false
            failure = ready ? nil : .unavailable
            return ready
        } catch {
            if !disclosureAccepted { return false }
            if shutdownRequested || error is LibraryLifecycleCoordinatorError { failure = .restartRequired }
            else if error as? SQLiteLibraryError == .occupied { failure = .occupied }
            else if seedRestoreService != nil { failure = .unrecognized }
            else if context != nil && !didReconcile { failure = .recoveryUnresolved }
            else { failure = .unavailable }
            if composition == nil { publish(AppComposition.makeUnavailable(restoreService: seedRestoreService)) }
            return false
        }
    }

    func shutdown() async {
        shutdownRequested = true
        startingTask?.cancel()
        let opening = openingTask
        opening?.cancel()
        _ = try? await opening?.value
        _ = await startingTask?.value
        await composition?.libraryObserver?.stop()
        await composition?.appModel.beginDestructiveVaultLifecycle()
        await context?.lifecycle.revoke()
        do { if let database { try await SQLiteStartupContext.close(database, releasingOwner: true) } } catch { return } // Preserve authority on a failed close.
        environment = nil; database = nil; publish(nil)
        seedRestoreService = nil; context = nil
    }
}
