import Foundation
import KinlogueCore
import KinloguePlatform
import Testing
@testable import KinlogueApp

@Test
func setupRequiresIndependentSaveAndExactFullRecoveryCodeReentryBeforePersisting() async throws {
    try await withSetupFixture { fixture in
        let session = try await fixture.service.begin(
            selectedParent: fixture.parent,
            activeVaultURL: fixture.vault
        )
        #expect(try await fixture.store.load() == nil)

        await #expect(throws: BackupSetupError.independentSaveNotConfirmed) {
            _ = try await fixture.service.complete(
                session,
                recoveryCodeReentry: session.recoveryCode,
                independentlySaved: false
            )
        }
        #expect(try await fixture.store.load() == nil)

        await #expect(throws: BackupSetupError.recoveryCodeMismatch) {
            _ = try await fixture.service.complete(
                session,
                recoveryCodeReentry: String(session.recoveryCode.dropLast()),
                independentlySaved: true
            )
        }
        #expect(try await fixture.store.load() == nil)
    }
}

@Test
func successfulSetupPublishesThenCASPromotesSameNonDecryptingWriter() async throws {
    try await withSetupFixture { fixture in
        let session = try await fixture.service.begin(
            selectedParent: fixture.parent,
            activeVaultURL: fixture.vault
        )
        fixture.bookmarks.stale = true
        let configuration = try await fixture.service.complete(
            session,
            recoveryCodeReentry: session.recoveryCode,
            independentlySaved: true
        )
        let reopened = try #require(await fixture.store.load())

        #expect(configuration == reopened)
        #expect(configuration.phase == .enabled)
        #expect(!configuration.automation.isAutomaticBackupEnabled)
        #expect(configuration.descriptor == session.descriptor)
        #expect(configuration.authorization == session.authorization)
        #expect(configuration.bookmarkData == Data("refreshed-bookmark".utf8))
        #expect(fixture.bookmarks.startCount == 1)
        #expect(fixture.bookmarks.stopCount == 1)
    }
}

@Test
func publicationFailureLeavesDisabledPendingAndResumeRequiresRecoveryCode() async throws {
    try await withSetupFixture { fixture in
        fixture.bookmarks.resolvedURL = fixture.parent
        fixture.publisher.failure = .repositoryOffline
        let session = try await fixture.service.begin(
            selectedParent: fixture.parent,
            activeVaultURL: fixture.vault
        )
        await #expect(throws: BackupDestinationAuthorityError.repositoryOffline) {
            _ = try await fixture.service.complete(
                session,
                recoveryCodeReentry: session.recoveryCode,
                independentlySaved: true
            )
        }
        let pending = try #require(await fixture.store.load())
        #expect(pending.phase == .pending)
        #expect(!pending.automation.isAutomaticBackupEnabled)

        fixture.publisher.failure = nil
        await #expect(throws: BackupSetupError.recoveryCodeMismatch) {
            _ = try await fixture.service.resumePending(recoveryCode: "KLG1-invalid")
        }
        #expect(try await fixture.store.load()?.phase == .pending)

        fixture.bookmarks.stale = true
        let enabled = try await fixture.service.resumePending(recoveryCode: session.recoveryCode)
        #expect(enabled.phase == .enabled)
        #expect(enabled.bookmarkData == Data("refreshed-bookmark".utf8))
        #expect(fixture.publisher.publishedDescriptor == session.descriptor.canonicalBytes)
    }
}

@Test
func setupDoesNotGenerateASecondSignerWhenConfigurationAlreadyExists() async throws {
    try await withSetupFixture { fixture in
        let session = try await fixture.service.begin(
            selectedParent: fixture.parent,
            activeVaultURL: fixture.vault
        )
        _ = try await fixture.service.complete(
            session,
            recoveryCodeReentry: session.recoveryCode,
            independentlySaved: true
        )
        let generationCount = fixture.generator.count

        await #expect(throws: BackupSetupError.configurationAlreadyExists) {
            _ = try await fixture.service.begin(
                selectedParent: fixture.parent,
                activeVaultURL: fixture.vault
            )
        }
        #expect(fixture.generator.count == generationCount)
    }
}

private struct SetupFixture {
    let base: URL
    let parent: URL
    let vault: URL
    let store: BackupLocalConfigurationStore
    let bookmarks: MutableBookmarkAccess
    let publisher: RecordingEnrollmentPublisher
    let generator: CountingEnrollmentGenerator
    let service: BackupSetupService
}

private func withSetupFixture(_ body: (SetupFixture) async throws -> Void) async throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("KinlogueSetup-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let parent = base.appendingPathComponent("selected", isDirectory: true)
    let vault = base.appendingPathComponent("support/Kinlogue/Vault", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    let store = BackupLocalConfigurationStore(
        rootURL: base.appendingPathComponent("support/Kinlogue/BackupIdentity", isDirectory: true)
    )
    let bookmarks = MutableBookmarkAccess(resolvedURL: parent)
    let authority = BackupDestinationAuthority(bookmarks: bookmarks)
    let publisher = RecordingEnrollmentPublisher(authority: authority)
    let generator = CountingEnrollmentGenerator()
    let service = BackupSetupService(
        configurationStore: store,
        destinationAuthority: authority,
        enrollmentPublisher: publisher,
        enrollmentGenerator: generator.make
    )
    try await body(.init(
        base: base,
        parent: parent,
        vault: vault,
        store: store,
        bookmarks: bookmarks,
        publisher: publisher,
        generator: generator,
        service: service
    ))
}

private final class MutableBookmarkAccess: BackupBookmarkAccessing, @unchecked Sendable {
    var resolvedURL: URL
    var stale = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    init(resolvedURL: URL) { self.resolvedURL = resolvedURL }
    func createBookmark(for url: URL) throws -> Data { Data("bookmark".utf8) }
    func resolveBookmark(_ data: Data) throws -> BackupResolvedBookmark {
        .init(url: resolvedURL, isStale: stale)
    }
    func refreshBookmark(for url: URL) throws -> Data { Data("refreshed-bookmark".utf8) }
    func startAccessing(_ url: URL) -> Bool {
        startCount += 1
        return true
    }
    func stopAccessing(_ url: URL) { stopCount += 1 }
}

private final class RecordingEnrollmentPublisher: BackupEnrollmentPublishing, @unchecked Sendable {
    let authority: BackupDestinationAuthority
    var failure: BackupDestinationAuthorityError?
    var publishedDescriptor: Data?

    init(authority: BackupDestinationAuthority) { self.authority = authority }

    func publish(
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        selection: BackupDestinationSelection
    ) throws -> Data? {
        if let failure { throw failure }
        let refreshed = try authority.publish(
            descriptor: descriptor,
            authorization: authorization,
            selection: selection
        )
        publishedDescriptor = descriptor.canonicalBytes
        return refreshed
    }

    func publish(configuration: BackupLocalConfiguration) throws -> Data? {
        if let failure { throw failure }
        let refreshed = try authority.publishStoredEnrollment(configuration)
        publishedDescriptor = configuration.descriptor.canonicalBytes
        return refreshed
    }
}

private final class CountingEnrollmentGenerator: @unchecked Sendable {
    private(set) var count = 0
    func make() throws -> BackupEnrollmentMaterial {
        count += 1
        return try BackupKeyHierarchy.makeEnrollment()
    }
}
