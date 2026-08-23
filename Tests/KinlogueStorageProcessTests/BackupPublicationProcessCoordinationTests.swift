import Darwin
import Foundation
import KinlogueCore
@testable import KinloguePlatform
import Testing

@Test
func twoRealProcessesPublishOneLinearWitnessedRepositoryHistory() async throws {
    try await withOwnedVaultFixture { fixture in
        let configuration = try await prepareProcessBackupFixture(fixture)
        let repositoryURL = fixture.parentURL
            .appendingPathComponent("selected", isDirectory: true)
            .appendingPathComponent(".kinlogue-backup-v1", isDirectory: true)

        try await withStorageProcessFixture(processCount: 2) { processes in
            try processes[0].send(.init(
                operation: "barrierPublishBackup",
                rootURL: fixture.rootURL
            ))
            let firstEntered = try await processes[0].nextResponse()
            #expect(firstEntered.event == "backupPublicationCriticalSectionEntered")
            #expect(firstEntered.ok)

            let replaceableRepositoryLock = repositoryURL.appendingPathComponent(
                ".kinlogue-publication.lock"
            )
            try? FileManager.default.removeItem(at: replaceableRepositoryLock)
            try Data("late replacement".utf8).write(
                to: replaceableRepositoryLock,
                options: .withoutOverwriting
            )
            #expect(chmod(replaceableRepositoryLock.path, 0o600) == 0)

            try processes[1].send(.init(
                operation: "barrierPublishBackup",
                rootURL: fixture.rootURL
            ))
            await #expect(throws: StorageProcessHarnessError.timedOut) {
                _ = try await processes[1].nextResponse(timeout: .milliseconds(250))
            }

            try processes[0].send(.init(operation: "release"))
            let firstResult = try await processes[0].nextResponse()
            #expect(firstResult.event == "backupPublished")
            #expect(firstResult.ok)

            let secondEntered = try await processes[1].nextResponse()
            #expect(secondEntered.event == "backupPublicationCriticalSectionEntered")
            #expect(secondEntered.ok)
            try processes[1].send(.init(operation: "release"))
            let secondResult = try await processes[1].nextResponse()
            #expect(secondResult.event == "backupPublished")
            #expect(secondResult.ok)

            let results = [firstResult, secondResult]
            #expect(results.allSatisfy { $0.event == "backupPublished" && $0.ok })
            #expect(Set(results.compactMap(\.generation)) == Set([
                configuration.authorization.sequenceFloor,
                configuration.authorization.sequenceFloor + 1,
            ]))
        }

        let reloaded = try #require(await BackupLocalConfigurationStore(
            rootURL: fixture.parentURL.appendingPathComponent(
                "BackupIdentity",
                isDirectory: true
            )
        ).load())
        let repository = BackupRepository(
            repositoryURL: repositoryURL,
            expectedIdentity: reloaded.repositoryDirectoryIdentity,
            trustedDescriptor: reloaded.descriptor,
            expectedAuthorizationID: reloaded.authorization.authorizationID,
            leaseAuthority: .init(
                configurationRootURL: fixture.parentURL.appendingPathComponent(
                    "BackupIdentity",
                    isDirectory: true
                ),
                configuration: reloaded
            )
        )
        let scan = try repository.scan()
        let points = scan.entries.compactMap { entry -> BackupPublicCheckpoint? in
            guard case let .verified(point) = entry.verification else { return nil }
            return point
        }
        #expect(scan.history == .linear)
        #expect(points.count == 2)
        #expect(Set(points.map(\.sequence)).count == 2)
        #expect(reloaded.verificationWitnesses.count == 2)
        #expect(Set(reloaded.verificationWitnesses.map(\.checkpointID))
            == Set(points.map(\.checkpointID)))
        #expect(points.allSatisfy { point in
            reloaded.verificationWitnesses.contains {
                $0.setID == point.setID
                    && $0.checkpointID == point.checkpointID
                    && $0.deviceID == point.deviceID
                    && $0.authorizationID == point.authorizationID
                    && $0.sequence == point.sequence
                    && $0.commitment == point.commitment
                    && $0.writerEpoch == reloaded.writerEpoch
            }
        })
    }
}

private func prepareProcessBackupFixture(
    _ fixture: StorageProcessVaultFixture
) async throws -> BackupLocalConfiguration {
    let vault = try PlaintextVault(rootURL: fixture.rootURL)
    _ = try await vault.initialize()
    _ = try await PlaintextLANInboxStore(rootURL: fixture.rootURL).initialize()
    let selected = fixture.parentURL.appendingPathComponent("selected", isDirectory: true)
    let repository = selected.appendingPathComponent(
        ".kinlogue-backup-v1",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: repository,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    #expect(chmod(repository.path, 0o700) == 0)
    let material = try BackupKeyHierarchy.makeEnrollment(
        recoverySeed: Data((1...32).map(UInt8.init)),
        setID: .init(bytes: Data((33...48).map(UInt8.init))),
        deviceSigningSeed: Data((65...96).map(UInt8.init)),
        deviceID: .init(bytes: Data((97...112).map(UInt8.init))),
        authorizationID: .init(bytes: Data((113...128).map(UInt8.init))),
        writerEpoch: .init(bytes: Data((129...144).map(UInt8.init))),
        sequenceFloor: 7
    )
    let repositoryIdentity = try processBackupDirectoryIdentity(repository)
    try BackupEnrollmentRepository().publish(
        descriptor: material.descriptor,
        authorization: material.authorization,
        repositoryURL: repository,
        expectedIdentity: repositoryIdentity
    )
    let store = BackupLocalConfigurationStore(
        rootURL: fixture.parentURL.appendingPathComponent(
            "BackupIdentity",
            isDirectory: true
        )
    )
    let pending = try BackupPendingEnrollment(
        bookmarkData: Data("synthetic-process-bookmark".utf8),
        selectedDirectoryIdentity: try processBackupDirectoryIdentity(selected),
        repositoryDirectoryIdentity: repositoryIdentity,
        descriptor: material.descriptor,
        authorization: material.authorization,
        deviceSigningSeed: material.deviceSigningSeed,
        writerEpoch: material.writerEpoch
    )
    let created = try await store.createPending(pending)
    return try await store.promotePending(
        enrollmentEpoch: created.enrollmentEpoch,
        expectedRevision: created.revision
    )
}

private func processBackupDirectoryIdentity(
    _ url: URL
) throws -> BackupFilesystemIdentity {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
          metadata.st_mode & S_IFMT == S_IFDIR else {
        throw CocoaError(.fileReadUnknown)
    }
    return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
}
