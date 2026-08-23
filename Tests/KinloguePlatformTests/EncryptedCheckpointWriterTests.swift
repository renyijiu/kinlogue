import CryptoKit
import Darwin
import Foundation
import KinlogueCore
import Testing
@testable import KinloguePlatform

@Suite("Encrypted checkpoint publication", .serialized)
struct EncryptedCheckpointWriterTests {
    @Test
    func publishesOneExactLeafReadsItBackAndDurablyWitnessesIt() async throws {
        try await withCheckpointWriterFixture { fixture in
            let result = try await fixture.writer.write(
                repositoryURL: fixture.repository,
                configuration: fixture.configuration,
                sequence: 1
            )

            let finalURL = fixture.repository.appendingPathComponent(result.finalLeafName)
            #expect(finalURL.pathExtension == "kinloguebackup")
            #expect(try strictTestLeafIdentity(finalURL) == result.fileIdentity)
            #expect(result.maximumBufferedPlaintextByteCount
                <= BackupFormatLimits.maximumFramePlaintextByteCount)
            #expect(result.maximumSimultaneousSourceFileCount <= 1)

            let reloaded = try #require(await fixture.configurationStore.load())
            #expect(reloaded.verificationWitnesses == [result.witness])
            #expect(result.witness.writerEpoch == fixture.configuration.writerEpoch)
            #expect(result.witness.repositoryIdentityDigest.count == 32)

            let restored = CheckpointTestLockedEntries()
            let bytes = try Data(contentsOf: finalURL)
            let read = try BackupContainerReader().read(
                source: CheckpointTestByteSource(bytes).source,
                recoverySeed: fixture.recoverySeed,
                sink: restored.sink
            )
            #expect(read.manifest.revisionPair == result.revisionPair)
            #expect(restored.value(for: "library.json") != nil)
            #expect(restored.value(for: "lan-inbox/inbox.json") != nil)
            #expect(try checkpointFiles(in: fixture.repository) == [result.finalLeafName])
        }
    }

    @Test
    func sourceMutationBeforeCommitPublishesNothingAndWritesNoWitness() async throws {
        try await withCheckpointWriterFixture { fixture in
            let writer = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                eventHandler: { event in
                    guard event == .beforeFinalSourceValidation else { return }
                    let current = try await fixture.vault.loadCatalog()
                    let member = try FamilyMember(displayName: "Concurrent mutation")
                    _ = try await fixture.vault.commit(try VaultCommitRequest(
                        expectedGeneration: current.generation,
                        catalog: VaultCatalog(
                            vaultID: current.vaultID,
                            generation: try VaultGeneration.successor(of: current.generation),
                            members: current.members + [member],
                            records: current.records,
                            attachments: current.attachments,
                            importDrafts: current.importDrafts,
                            dicomStudies: current.dicomStudies
                        ),
                        writes: []
                    ))
                }
            )

            await #expect(throws: EncryptedCheckpointWriterError.sourceChanged) {
                _ = try await writer.write(
                    repositoryURL: fixture.repository,
                    configuration: fixture.configuration,
                    sequence: 1
                )
            }
            let files = try checkpointFiles(in: fixture.repository)
            let configuration = try await fixture.configurationStore.load()
            #expect(files.isEmpty)
            #expect(configuration?.verificationWitnesses.isEmpty == true)
        }
    }

    @Test(arguments: ["regular", "symlink", "hardlink"])
    func neverOverwritesAnExistingFinalNamedNode(_ kind: String) async throws {
        try await withCheckpointWriterFixture { fixture in
            let finalURL = fixture.repository.appendingPathComponent(fixture.deterministicFinalLeafName)
            let foreign = fixture.base.appendingPathComponent("foreign")
            try Data("foreign".utf8).write(to: foreign)
            switch kind {
            case "regular": try Data("existing".utf8).write(to: finalURL)
            case "symlink": try FileManager.default.createSymbolicLink(at: finalURL, withDestinationURL: foreign)
            case "hardlink": #expect(link(foreign.path, finalURL.path) == 0)
            default: Issue.record("unknown test case")
            }
            let before = try Data(contentsOf: foreign)

            await #expect(throws: EncryptedCheckpointWriterError.finalAlreadyExists) {
                _ = try await fixture.writer.write(
                    repositoryURL: fixture.repository,
                    configuration: fixture.configuration,
                    sequence: 1
                )
            }
            let after = try Data(contentsOf: foreign)
            let configuration = try await fixture.configurationStore.load()
            #expect(after == before)
            #expect(configuration?.verificationWitnesses.isEmpty == true)
        }
    }

    @Test
    func parentReplacementFailsClosedWithoutWritingIntoReplacement() async throws {
        try await withCheckpointWriterFixture { fixture in
            let displaced = fixture.base.appendingPathComponent("displaced-repository")
            let writer = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                eventHandler: { event in
                    guard event == .beforeFinalSourceValidation else { return }
                    try FileManager.default.moveItem(at: fixture.repository, to: displaced)
                    try FileManager.default.createDirectory(
                        at: fixture.repository,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                }
            )

            await #expect(throws: EncryptedCheckpointWriterError.repositoryIdentityChanged) {
                _ = try await writer.write(
                    repositoryURL: fixture.repository,
                    configuration: fixture.configuration,
                    sequence: 1
                )
            }
            let replacementContents = try FileManager.default.contentsOfDirectory(
                atPath: fixture.repository.path
            )
            let configuration = try await fixture.configurationStore.load()
            #expect(replacementContents.isEmpty)
            #expect(configuration?.verificationWitnesses.isEmpty == true)
        }
    }

    @Test
    func cancellationBeforePublicationRemovesWorkAndCommitsNoWitness() async throws {
        try await withCheckpointWriterFixture { fixture in
            let (events, continuation) = AsyncStream<Void>.makeStream()
            let writer = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                eventHandler: { event in
                    guard event == .beforeFinalSourceValidation else { return }
                    continuation.yield(())
                    try await Task.sleep(for: .seconds(60))
                }
            )
            let task = Task {
                try await writer.write(
                    repositoryURL: fixture.repository,
                    configuration: fixture.configuration,
                    sequence: 1
                )
            }
            for await _ in events { break }
            task.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await task.value
            }
            continuation.finish()

            let names = try FileManager.default.contentsOfDirectory(
                atPath: fixture.repository.path
            )
            let configuration = try await fixture.configurationStore.load()
            #expect(names.allSatisfy { !$0.hasSuffix(".work") && !$0.hasSuffix(".kinloguebackup") })
            #expect(configuration?.verificationWitnesses.isEmpty == true)
        }
    }

    @Test
    func finalCorruptionAndInjectedDiskFullNeverCommitAWitness() async throws {
        try await withCheckpointWriterFixture { fixture in
            let corrupting = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                eventHandler: { event in
                    guard case let .afterPublication(finalURL) = event else { return }
                    let descriptor = Darwin.open(finalURL.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                    defer { Darwin.close(descriptor) }
                    var byte: UInt8 = 0xFF
                    guard pwrite(descriptor, &byte, 1, 32) == 1 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            )
            await #expect(throws: EncryptedCheckpointWriterError.verificationFailed) {
                _ = try await corrupting.write(
                    repositoryURL: fixture.repository,
                    configuration: fixture.configuration,
                    sequence: 1
                )
            }
            let configuration = try await fixture.configurationStore.load()
            #expect(configuration?.verificationWitnesses.isEmpty == true)
        }

        try await withCheckpointWriterFixture { fixture in
            let diskFull = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                writeFailureInjector: { $0 == .encryptedPayload ? ENOSPC : nil }
            )
            await #expect(throws: EncryptedCheckpointWriterError.capacityInsufficient) {
                _ = try await diskFull.write(
                    repositoryURL: fixture.repository,
                    configuration: fixture.configuration,
                    sequence: 1
                )
            }
            let files = try checkpointFiles(in: fixture.repository)
            let configuration = try await fixture.configurationStore.load()
            #expect(files.isEmpty)
            #expect(configuration?.verificationWitnesses.isEmpty == true)
        }
    }

    @Test
    func stableWriterAllowsAutomationRetentionAndSchedulerChangesBeforePublication() async throws {
        try await withCheckpointWriterFixture { fixture in
            let writer = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                eventHandler: { event in
                    guard event == .beforeFinalSourceValidation else { return }
                    var current = try #require(await fixture.configurationStore.load())
                    current = try await fixture.configurationStore.updateAutomation(
                        isAutomaticBackupEnabled: true,
                        retentionCount: try BackupRetentionCount(2),
                        expectedRevision: current.revision
                    )
                    let pair = try await fixture.source.prepare().revisionPair
                    _ = try await fixture.configurationStore.observeRevisionPair(
                        pair,
                        observedAt: Date(timeIntervalSince1970: 4_000),
                        dueAt: Date(timeIntervalSince1970: 4_300),
                        expectedRevision: current.revision
                    )
                }
            )

            let result = try await writer.write(
                repositoryURL: fixture.repository,
                configuration: fixture.configuration,
                sequence: 1
            )
            let reloaded = try #require(await fixture.configurationStore.load())
            #expect(reloaded.automation.isAutomaticBackupEnabled)
            #expect(reloaded.automation.retentionCount.value == 2)
            #expect(reloaded.scheduler.firstObservedRevisionPair == result.revisionPair)
            #expect(reloaded.verificationWitnesses == [result.witness])
        }
    }

    @Test
    func stableWriterAppendsWitnessToLatestSchedulerStateAfterPublication() async throws {
        try await withCheckpointWriterFixture { fixture in
            let writer = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                eventHandler: { event in
                    guard case .afterPublication = event else { return }
                    var current = try #require(await fixture.configurationStore.load())
                    current = try await fixture.configurationStore.updateAutomation(
                        isAutomaticBackupEnabled: true,
                        retentionCount: try BackupRetentionCount(3),
                        expectedRevision: current.revision
                    )
                    _ = try await fixture.configurationStore.markBackupFailure(
                        .repositoryOffline,
                        retryAttempt: 0,
                        retryDueAt: nil,
                        expectedRevision: current.revision
                    )
                }
            )

            let result = try await writer.write(
                repositoryURL: fixture.repository,
                configuration: fixture.configuration,
                sequence: 1
            )
            let reloaded = try #require(await fixture.configurationStore.load())
            #expect(reloaded.automation.isAutomaticBackupEnabled)
            #expect(reloaded.automation.retentionCount.value == 3)
            #expect(reloaded.scheduler.lastFailure == .repositoryOffline)
            #expect(reloaded.verificationWitnesses == [result.witness])
        }
    }

    @Test
    func destructiveWriterResetBeforePublicationFailsClosedWithoutFinalLeaf() async throws {
        try await withCheckpointWriterFixture { fixture in
            let writer = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                eventHandler: { event in
                    guard event == .beforeFinalSourceValidation else { return }
                    try await fixture.configurationStore.removeForDestructiveReset()
                }
            )

            await #expect(throws: EncryptedCheckpointWriterError.invalidConfiguration) {
                _ = try await writer.write(
                    repositoryURL: fixture.repository,
                    configuration: fixture.configuration,
                    sequence: 1
                )
            }
            let files = try checkpointFiles(in: fixture.repository)
            let configuration = try await fixture.configurationStore.load()
            #expect(files.isEmpty)
            #expect(configuration == nil)
        }
    }

    @Test
    func destructiveWriterResetAfterPublicationIsIndeterminateAndNeverDeletesFinalLeaf() async throws {
        try await withCheckpointWriterFixture { fixture in
            let writer = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                eventHandler: { event in
                    guard case .afterPublication = event else { return }
                    try await fixture.configurationStore.removeForDestructiveReset()
                }
            )

            await #expect(throws: EncryptedCheckpointWriterError.publicationIndeterminate) {
                _ = try await writer.write(
                    repositoryURL: fixture.repository,
                    configuration: fixture.configuration,
                    sequence: 1
                )
            }
            let files = try checkpointFiles(in: fixture.repository)
            let configuration = try await fixture.configurationStore.load()
            #expect(files.count == 1)
            #expect(configuration == nil)
        }
    }

    @Test
    func restartAfterLatestLeafDisappearsAllocatesAboveDurableWriterWitness() async throws {
        try await withCheckpointWriterFixture { fixture in
            let firstRepository = BackupRepository(
                repositoryURL: fixture.repository,
                expectedIdentity: fixture.configuration.repositoryDirectoryIdentity,
                trustedDescriptor: fixture.configuration.descriptor,
                expectedAuthorizationID: fixture.configuration.authorization.authorizationID,
                leaseAuthority: .init(
                    configurationRootURL: fixture.configurationStore.rootURL,
                    configuration: fixture.configuration
                )
            )
            let first = try await BackupCheckpointPublisher(
                repository: firstRepository,
                writer: EncryptedCheckpointWriter(
                    source: fixture.source,
                    configurationStore: fixture.configurationStore
                ),
                configurationStore: fixture.configurationStore
            ).publishNext(configuration: fixture.configuration)
            let firstURL = fixture.repository.appendingPathComponent(first.finalLeafName)
            let firstBytes = try Data(contentsOf: firstURL)
            try FileManager.default.removeItem(at: firstURL)

            let restartedStore = BackupLocalConfigurationStore(
                rootURL: fixture.configurationStore.rootURL
            )
            let restartedConfiguration = try #require(await restartedStore.load())
            let restartedRepository = BackupRepository(
                repositoryURL: fixture.repository,
                expectedIdentity: restartedConfiguration.repositoryDirectoryIdentity,
                trustedDescriptor: restartedConfiguration.descriptor,
                expectedAuthorizationID: restartedConfiguration.authorization.authorizationID,
                leaseAuthority: .init(
                    configurationRootURL: restartedStore.rootURL,
                    configuration: restartedConfiguration
                )
            )
            let second = try await BackupCheckpointPublisher(
                repository: restartedRepository,
                writer: EncryptedCheckpointWriter(
                    source: fixture.source,
                    configurationStore: restartedStore
                ),
                configurationStore: restartedStore
            ).publishNext(configuration: restartedConfiguration)

            #expect(second.witness.sequence == first.witness.sequence + 1)
            try firstBytes.write(to: firstURL, options: .withoutOverwriting)
            #expect(chmod(firstURL.path, 0o600) == 0)
            let rematerialized = try BackupRepository(
                repositoryURL: fixture.repository,
                expectedIdentity: restartedConfiguration.repositoryDirectoryIdentity,
                trustedDescriptor: restartedConfiguration.descriptor,
                expectedAuthorizationID: restartedConfiguration.authorization.authorizationID,
                leaseAuthority: .init(
                    configurationRootURL: restartedStore.rootURL,
                    configuration: restartedConfiguration
                )
            ).scan()
            #expect(rematerialized.history == .linear)
            #expect(Set(rematerialized.entries.compactMap { entry -> UInt64? in
                guard case let .verified(point) = entry.verification else { return nil }
                return point.sequence
            }) == Set([first.witness.sequence, second.witness.sequence]))
        }
    }

    @Test
    func repositoryNamedLockReplacementDuringWriteCannotReplacePrivateLease() async throws {
        try await withCheckpointWriterFixture { fixture in
            let writer = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                eventHandler: { event in
                    guard event == .beforeFinalSourceValidation else { return }
                    let lockURL = fixture.repository.appendingPathComponent(
                        ".kinlogue-publication.lock"
                    )
                    try? FileManager.default.removeItem(at: lockURL)
                    try Data().write(to: lockURL, options: .withoutOverwriting)
                    guard chmod(lockURL.path, 0o600) == 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            )
            let repository = BackupRepository(
                repositoryURL: fixture.repository,
                expectedIdentity: fixture.configuration.repositoryDirectoryIdentity,
                trustedDescriptor: fixture.configuration.descriptor,
                expectedAuthorizationID: fixture.configuration.authorization.authorizationID,
                leaseAuthority: .init(
                    configurationRootURL: fixture.configurationStore.rootURL,
                    configuration: fixture.configuration
                )
            )

            _ = try await BackupCheckpointPublisher(
                repository: repository,
                writer: writer,
                configurationStore: fixture.configurationStore
            ).publishNext(configuration: fixture.configuration)
            let files = try checkpointFiles(in: fixture.repository)
            let configuration = try await fixture.configurationStore.load()
            #expect(files.count == 1)
            #expect(configuration?.verificationWitnesses.count == 1)
        }
    }

    @Test
    func repositoryNamedLockReplacementAfterFinalCannotInvalidatePrivateLease() async throws {
        try await withCheckpointWriterFixture { fixture in
            let writer = EncryptedCheckpointWriter(
                source: fixture.source,
                configurationStore: fixture.configurationStore,
                containerWriter: fixture.deterministicContainerWriter,
                eventHandler: { event in
                    guard case .afterPublication = event else { return }
                    let lockURL = fixture.repository.appendingPathComponent(
                        ".kinlogue-publication.lock"
                    )
                    try? FileManager.default.removeItem(at: lockURL)
                    try Data().write(to: lockURL, options: .withoutOverwriting)
                    guard chmod(lockURL.path, 0o600) == 0 else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
            )
            let repository = BackupRepository(
                repositoryURL: fixture.repository,
                expectedIdentity: fixture.configuration.repositoryDirectoryIdentity,
                trustedDescriptor: fixture.configuration.descriptor,
                expectedAuthorizationID: fixture.configuration.authorization.authorizationID,
                leaseAuthority: .init(
                    configurationRootURL: fixture.configurationStore.rootURL,
                    configuration: fixture.configuration
                )
            )

            _ = try await BackupCheckpointPublisher(
                repository: repository,
                writer: writer,
                configurationStore: fixture.configurationStore
            ).publishNext(configuration: fixture.configuration)
            let files = try checkpointFiles(in: fixture.repository)
            let configuration = try await fixture.configurationStore.load()
            #expect(files.count == 1)
            #expect(configuration?.verificationWitnesses.count == 1)
        }
    }
}

private struct CheckpointWriterFixture {
    let base: URL
    let vault: PlaintextVault
    let source: PlaintextLibraryBackupSource
    let repository: URL
    let configurationStore: BackupLocalConfigurationStore
    let configuration: BackupLocalConfiguration
    let recoverySeed: Data
    let writer: EncryptedCheckpointWriter
    let deterministicContainerWriter: EncryptedBackupContainerWriter
    let deterministicFinalLeafName: String
}

private func withCheckpointWriterFixture(
    _ body: (CheckpointWriterFixture) async throws -> Void
) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "KinlogueCheckpointWriter-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.appendingPathComponent("Vault", isDirectory: true)
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    let inbox = try PlaintextLANInboxStore(rootURL: root)
    _ = try await inbox.initialize()
    let source = try PlaintextLibraryBackupSource(vault: vault, inboxStore: inbox)

    let selected = base.appendingPathComponent("selected", isDirectory: true)
    let repository = selected.appendingPathComponent(".kinlogue-backup-v1", isDirectory: true)
    try FileManager.default.createDirectory(
        at: repository,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    #expect(chmod(repository.path, 0o700) == 0)
    let selectedIdentity = try strictTestDirectoryIdentity(selected)
    let repositoryIdentity = try strictTestDirectoryIdentity(repository)

    let recoverySeed = Data((1...32).map(UInt8.init))
    let material = try BackupKeyHierarchy.makeEnrollment(
        recoverySeed: recoverySeed,
        setID: .init(bytes: Data((33...48).map(UInt8.init))),
        deviceSigningSeed: Data((65...96).map(UInt8.init)),
        deviceID: .init(bytes: Data((97...112).map(UInt8.init))),
        authorizationID: .init(bytes: Data((113...128).map(UInt8.init))),
        writerEpoch: .init(bytes: Data((129...144).map(UInt8.init)))
    )
    try BackupEnrollmentRepository().publish(
        descriptor: material.descriptor,
        authorization: material.authorization,
        repositoryURL: repository,
        expectedIdentity: repositoryIdentity
    )
    let configurationStore = BackupLocalConfigurationStore(
        rootURL: base.appendingPathComponent("BackupIdentity", isDirectory: true)
    )
    let pending = try BackupPendingEnrollment(
        bookmarkData: Data("opaque-bookmark".utf8),
        selectedDirectoryIdentity: selectedIdentity,
        repositoryDirectoryIdentity: repositoryIdentity,
        descriptor: material.descriptor,
        authorization: material.authorization,
        deviceSigningSeed: material.deviceSigningSeed,
        writerEpoch: material.writerEpoch
    )
    let created = try await configurationStore.createPending(pending)
    let configuration = try await configurationStore.promotePending(
        enrollmentEpoch: created.enrollmentEpoch,
        expectedRevision: created.revision
    )
    let deterministicContainerWriter = EncryptedBackupContainerWriter { count in
        Data(repeating: count == 16 ? 0x11 : 0x22, count: count)
    }
    let writer = EncryptedCheckpointWriter(
        source: source,
        configurationStore: configurationStore,
        containerWriter: deterministicContainerWriter
    )
    try await body(.init(
        base: base,
        vault: vault,
        source: source,
        repository: repository,
        configurationStore: configurationStore,
        configuration: configuration,
        recoverySeed: recoverySeed,
        writer: writer,
        deterministicContainerWriter: deterministicContainerWriter,
        deterministicFinalLeafName: String(repeating: "11", count: 16) + ".kinloguebackup"
    ))
}

private func strictTestDirectoryIdentity(_ url: URL) throws -> BackupFilesystemIdentity {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
        throw CocoaError(.fileReadUnknown)
    }
    return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
}

private func strictTestLeafIdentity(_ url: URL) throws -> BackupPublishedFileIdentity {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
        throw CocoaError(.fileReadUnknown)
    }
    return .init(
        device: UInt64(metadata.st_dev),
        inode: UInt64(metadata.st_ino),
        byteCount: UInt64(metadata.st_size)
    )
}

private func checkpointFiles(in repository: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: repository.path)
        .filter { $0.hasSuffix(".kinloguebackup") }
        .sorted()
}

private struct CheckpointTestByteSource {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }
    var source: BackupContainerByteSource {
        .init(byteCount: UInt64(bytes.count)) { offset, count in
            let start = Int(offset)
            return Data(bytes[start..<min(bytes.count, start + count)])
        }
    }
}

private final class CheckpointTestLockedEntries: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    lazy var sink = BackupContainerEntrySink { [weak self] entry in
        { [weak self] bytes in
            self?.lock.withLock { self?.entries[entry.path, default: Data()].append(bytes) }
        }
    }
    func value(for path: String) -> Data? { lock.withLock { entries[path] } }
}
