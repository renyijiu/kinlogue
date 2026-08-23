import Darwin
import Foundation
import KinlogueCore
import KinlogueDICOMTestSupport
@testable import KinloguePlatform
import Testing

@Test
func twoRealSwiftProcessesAllowExactlyOneStaleCatalogWriter() async throws {
    try await withOwnedVaultFixture { fixture in
        let initial = try await PlaintextVault(rootURL: fixture.rootURL).initialize()
        #expect(initial.generation == 1)

        try await withStorageProcessFixture(processCount: 2) { processes in
            let first = processes[0]
            let second = processes[1]
            try first.send(.init(operation: "loadCatalog", rootURL: fixture.rootURL))
            try second.send(.init(operation: "loadCatalog", rootURL: fixture.rootURL))
            #expect(try await first.nextResponse().event == "catalogLoaded")
            #expect(try await second.nextResponse().event == "catalogLoaded")

            try first.send(.init(operation: "holdCatalogCommit", variant: 1))
            let held = try await first.nextResponse()
            #expect(held.event == "leaseHeld")
            #expect(held.ok)

            try second.send(.init(
                operation: "barrierCommitLoadedCatalog",
                variant: 2
            ))
            let attempting = try await second.nextResponse()
            #expect(attempting.event == "catalogCommitAttempting")
            #expect(attempting.ok)
            try first.send(.init(operation: "release"))

            let responses = try await [first.nextResponse(), second.nextResponse()]
            let committed = try #require(responses.first(where: {
                $0.event == "catalogCommitted" && $0.ok
            }))
            let rejected = try #require(responses.first(where: {
                $0.event == "operationFailed" && !$0.ok
            }))

            #expect(responses.filter { $0.event == "catalogCommitted" }.count == 1)
            #expect(responses.filter { $0.event == "operationFailed" }.count == 1)
            #expect(rejected.code == "staleRevision")

            let catalog = try await PlaintextVault(rootURL: fixture.rootURL).loadCatalog()
            #expect(catalog.generation == 2)
            #expect(catalog.members.count == 1)
            #expect(catalog.members.first?.id == memberID(for: try #require(committed.variant)))
        }
    }
}

@Test
func competingRealProcessesPreserveTheLoadedV3DICOMGraphAndOneGenerationWins() async throws {
    try await withOwnedVaultFixture { fixture in
        let vault = try PlaintextVault(rootURL: fixture.rootURL)
        let initial = try await vault.initialize()
        let seeded = try await seedSyntheticDICOMStudy(in: vault, catalog: initial)

        try await withStorageProcessFixture(processCount: 2) { processes in
            let first = processes[0]
            let second = processes[1]
            try first.send(.init(operation: "loadCatalog", rootURL: fixture.rootURL))
            try second.send(.init(operation: "loadCatalog", rootURL: fixture.rootURL))
            #expect(try await first.nextResponse().generation == seeded.catalog.generation)
            #expect(try await second.nextResponse().generation == seeded.catalog.generation)

            try first.send(.init(operation: "holdCatalogCommit", variant: 1))
            #expect(try await first.nextResponse().event == "leaseHeld")
            try second.send(.init(operation: "barrierCommitLoadedCatalog", variant: 2))
            #expect(try await second.nextResponse().event == "catalogCommitAttempting")
            try first.send(.init(operation: "release"))

            let responses = try await [first.nextResponse(), second.nextResponse()]
            #expect(responses.count { $0.event == "catalogCommitted" && $0.ok } == 1)
            #expect(responses.count { $0.code == "staleRevision" && !$0.ok } == 1)
        }

        let reopened = try PlaintextVault(rootURL: fixture.rootURL)
        let final = try await reopened.loadCatalog()
        #expect(final.formatVersion == VaultCatalog.currentFormatVersion)
        #expect(final.generation == seeded.catalog.generation + 1)
        #expect(final.dicomStudies == seeded.catalog.dicomStudies)
        #expect(try await reopened.readObject(seeded.indexReference) == seeded.indexData)
    }
}

@Test
func realProcessRejectsCatalogWideDICOMOverflowBeforeChangingAnyVaultFile() async throws {
    try await withOwnedVaultFixture { fixture in
        let initial = try await PlaintextVault(rootURL: fixture.rootURL).initialize()
        let before = try storageProcessRegularFileSnapshot(root: fixture.rootURL)

        try await withStorageProcessFixture(processCount: 1) { processes in
            let process = processes[0]
            try process.send(.init(operation: "loadCatalog", rootURL: fixture.rootURL))
            #expect(try await process.nextResponse().generation == initial.generation)
            try process.send(.init(operation: "rejectOversizedDICOMProposal"))
            let rejected = try await process.nextResponse()
            #expect(rejected.event == "operationFailed")
            #expect(!rejected.ok)
            #expect(rejected.code == "resourceLimitExceeded")
        }

        #expect(try storageProcessRegularFileSnapshot(root: fixture.rootURL) == before)
        #expect(try await PlaintextVault(rootURL: fixture.rootURL).loadCatalog() == initial)
    }
}

@Test(.enabled(
    if: catalogProcessTestVolumeIsCaseInsensitive,
    "Requires a case-insensitive filesystem"
))
func differentlyCasedAliasesSerializeTwoRealCatalogWriters() async throws {
    try await withOwnedVaultFixture { fixture in
        _ = try await PlaintextVault(rootURL: fixture.rootURL).initialize()
        let casedAlias = fixture.parentURL.appendingPathComponent(
            "vault",
            isDirectory: true
        )

        try await withStorageProcessFixture(processCount: 2) { processes in
            let canonicalWriter = processes[0]
            let aliasWriter = processes[1]
            try canonicalWriter.send(.init(
                operation: "loadCatalog",
                rootURL: fixture.rootURL
            ))
            try aliasWriter.send(.init(
                operation: "loadCatalog",
                rootURL: casedAlias
            ))
            #expect(try await canonicalWriter.nextResponse().event == "catalogLoaded")
            #expect(try await aliasWriter.nextResponse().event == "catalogLoaded")

            try canonicalWriter.send(.init(operation: "holdCatalogCommit", variant: 1))
            let held = try await canonicalWriter.nextResponse()
            #expect(held.event == "leaseHeld")
            #expect(held.ok)

            try aliasWriter.send(.init(
                operation: "barrierCommitLoadedCatalog",
                variant: 2
            ))
            let attempting = try await aliasWriter.nextResponse()
            #expect(attempting.event == "catalogCommitAttempting")
            #expect(attempting.ok)
            try canonicalWriter.send(.init(operation: "release"))

            let canonicalResult = try await canonicalWriter.nextResponse()
            let aliasResult = try await aliasWriter.nextResponse()
            #expect(canonicalResult.event == "catalogCommitted")
            #expect(canonicalResult.ok)
            #expect(canonicalResult.variant == 1)
            #expect(aliasResult.event == "operationFailed")
            #expect(!aliasResult.ok)
            #expect(aliasResult.code == "staleRevision")

            let catalog = try await PlaintextVault(rootURL: fixture.rootURL).loadCatalog()
            #expect(catalog.generation == 2)
            #expect(catalog.members.map(\.id) == [memberID(for: 1)])
        }
    }
}

@Test
func wholeVaultDeletionWaitsForCatalogCommitAndRejectsItsLateWriter() async throws {
    try await withOwnedVaultFixture { fixture in
        _ = try await PlaintextVault(rootURL: fixture.rootURL).initialize()

        try await withStorageProcessFixture(processCount: 2) { processes in
            let staleWriter = processes[0]
            let destroyer = processes[1]
            try staleWriter.send(.init(operation: "loadCatalog", rootURL: fixture.rootURL))
            #expect(try await staleWriter.nextResponse().event == "catalogLoaded")

            try staleWriter.send(.init(operation: "holdCatalogCommit", variant: 1))
            let held = try await staleWriter.nextResponse()
            #expect(held.event == "leaseHeld")
            #expect(held.ok)

            try destroyer.send(.init(
                operation: "barrierDestroy",
                rootURL: fixture.rootURL
            ))
            let attempting = try await destroyer.nextResponse()
            #expect(attempting.event == "destroyAttempting")
            #expect(attempting.ok)
            try staleWriter.send(.init(operation: "release"))

            let committed = try await staleWriter.nextResponse()
            #expect(committed.event == "catalogCommitted")
            #expect(committed.variant == 1)
            let destroyed = try await destroyer.nextResponse()
            #expect(destroyed.event == "destroyed")
            #expect(destroyed.ok)

            try staleWriter.send(.init(operation: "commitLoadedCatalog", variant: 2))
            let rejected = try await staleWriter.nextResponse()
            #expect(rejected.event == "operationFailed")
            #expect(rejected.code == "vaultMissing")
            #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.path))
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.path))
    }
}

@Test
func staleRealProcessCannotPolluteAReplacementAtTheSamePath() async throws {
    try await withOwnedVaultFixture { fixture in
        let oldCatalog = try await PlaintextVault(rootURL: fixture.rootURL).initialize()

        try await withStorageProcessFixture(processCount: 2) { processes in
            let staleWriter = processes[0]
            let replacer = processes[1]
            try staleWriter.send(.init(operation: "loadCatalog", rootURL: fixture.rootURL))
            #expect(try await staleWriter.nextResponse().event == "catalogLoaded")

            try replacer.send(.init(operation: "destroyAndInitialize", rootURL: fixture.rootURL))
            let replacement = try await replacer.nextResponse()
            #expect(replacement.event == "reinitialized")
            #expect(replacement.generation == 1)

            try staleWriter.send(.init(operation: "commitLoadedCatalog", variant: 1))
            let rejected = try await staleWriter.nextResponse()
            #expect(rejected.event == "operationFailed")
            #expect(rejected.code == "rootReplaced")

            let newCatalog = try await PlaintextVault(rootURL: fixture.rootURL).loadCatalog()
            #expect(newCatalog.vaultID != oldCatalog.vaultID)
            #expect(newCatalog.generation == 1)
            #expect(newCatalog.members.isEmpty)
        }
    }
}

@Test
func crashingARealSwiftWriterReleasesTheKernelMutationLease() async throws {
    try await withOwnedVaultFixture { fixture in
        _ = try await PlaintextVault(rootURL: fixture.rootURL).initialize()

        try await withStorageProcessFixture(processCount: 2) { processes in
            let crashingWriter = processes[0]
            let successor = processes[1]
            try crashingWriter.send(.init(operation: "loadCatalog", rootURL: fixture.rootURL))
            #expect(try await crashingWriter.nextResponse().event == "catalogLoaded")
            try crashingWriter.send(.init(operation: "holdCatalogCommit", variant: 1))
            let held = try await crashingWriter.nextResponse()
            #expect(held.event == "leaseHeld")
            #expect(held.ok)

            try await crashingWriter.crash()

            try successor.send(.init(operation: "loadCatalog", rootURL: fixture.rootURL))
            let loaded = try await successor.nextResponse()
            #expect(loaded.event == "catalogLoaded")
            #expect(loaded.generation == 1)
            try successor.send(.init(operation: "commitLoadedCatalog", variant: 2))
            let committed = try await successor.nextResponse()
            #expect(committed.event == "catalogCommitted")
            #expect(committed.variant == 2)

            let catalog = try await PlaintextVault(rootURL: fixture.rootURL).loadCatalog()
            #expect(catalog.generation == 2)
            #expect(catalog.members.map(\.id) == [memberID(for: 2)])
        }
    }
}

@Test
func crashingARealDICOMImporterReleasesItsLeaseAndReopenReclaimsStaging() async throws {
    try await withOwnedVaultFixture { fixture in
        _ = try await PlaintextVault(rootURL: fixture.rootURL).initialize()
        try createProcessDICOMSource(nextTo: fixture.rootURL)

        try await withStorageProcessFixture(processCount: 2) { processes in
            let importer = processes[0]
            let successor = processes[1]
            try importer.send(.init(operation: "holdDICOMImport", rootURL: fixture.rootURL))
            #expect(try await importer.nextResponse().event == "leaseHeld")
            #expect(try VaultDICOMImportJournal(rootURL: fixture.rootURL).pendingOperationCount() == 1)

            try await importer.crash()
            try successor.send(.init(operation: "loadCatalog", rootURL: fixture.rootURL))
            #expect(try await successor.nextResponse().event == "catalogLoaded")
            #expect(try VaultDICOMImportJournal(rootURL: fixture.rootURL).pendingOperationCount() == 0)
            let stagingRoot = fixture.rootURL.appendingPathComponent("dicom-import-staging")
            let stagingNames = (try? FileManager.default.contentsOfDirectory(
                atPath: stagingRoot.path
            )) ?? []
            #expect(stagingNames.compactMap(UUID.init(uuidString:)).isEmpty)
        }
    }
}

@Test
func wholeVaultDeletionWaitsForAnActiveRealDICOMImport() async throws {
    try await withOwnedVaultFixture { fixture in
        _ = try await PlaintextVault(rootURL: fixture.rootURL).initialize()
        try createProcessDICOMSource(nextTo: fixture.rootURL)

        try await withStorageProcessFixture(processCount: 2) { processes in
            let importer = processes[0]
            let destroyer = processes[1]
            try importer.send(.init(operation: "holdDICOMImport", rootURL: fixture.rootURL))
            #expect(try await importer.nextResponse().event == "leaseHeld")
            try destroyer.send(.init(operation: "barrierDestroy", rootURL: fixture.rootURL))
            #expect(try await destroyer.nextResponse().event == "destroyAttempting")
            try importer.send(.init(operation: "release"))
            #expect(try await importer.nextResponse().event == "dicomImported")
            #expect(try await destroyer.nextResponse().event == "destroyed")
            #expect(!FileManager.default.fileExists(atPath: fixture.rootURL.path))
        }
    }
}

private func createProcessDICOMSource(nextTo rootURL: URL) throws {
    let source = rootURL.deletingLastPathComponent().appendingPathComponent(
        "DICOMSource",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
        to: source.appendingPathComponent("generated.bin")
    )
}

private func memberID(for variant: Int) -> UUID {
    switch variant {
    case 1: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    default: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    }
}

private func seedSyntheticDICOMStudy(
    in vault: PlaintextVault,
    catalog: VaultCatalog
) async throws -> (
    catalog: VaultCatalog,
    indexReference: VaultObjectReference,
    indexData: Data
) {
    let objectData = Data("identity-free-dicom-process-object".utf8)
    let attachment = try KinlogueCore.Attachment(
        contentTypeIdentifier: "application/dicom",
        byteCount: objectData.count,
        sha256Digest: ContentDigest.sha256(objectData)
    )
    let fingerprint = try DICOMStudyFingerprint(objects: [
        .init(sha256Digest: attachment.sha256Digest, byteCount: attachment.byteCount),
    ])
    let study = try DICOMStudy(
        state: .needsReview,
        fingerprint: fingerprint,
        indexObjectID: UUID(),
        attachmentIDs: [attachment.id]
    )
    let index = try DICOMStudyIndex(
        studyID: study.id,
        studyUIDDigest: .init(scope: .study, digest: Data(repeating: 0x31, count: 32)),
        retainedObjects: [.init(attachmentID: attachment.id, kind: .inertAttachment)],
        instances: [],
        series: []
    )
    let indexData = try CanonicalVaultJSON.encode(index)
    let indexReference = VaultObjectReference(id: study.indexObjectID, kind: .record)
    let next = try VaultCatalog(
        vaultID: catalog.vaultID,
        generation: catalog.generation + 1,
        members: catalog.members,
        records: catalog.records,
        attachments: catalog.attachments + [attachment],
        importDrafts: catalog.importDrafts,
        dicomStudies: catalog.dicomStudies + [study]
    )
    let committed = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: catalog.generation,
        catalog: next,
        writes: [
            VaultObjectWrite(
                reference: .init(id: attachment.id, kind: .attachment),
                plaintext: objectData
            ),
            VaultObjectWrite(reference: indexReference, plaintext: indexData),
        ]
    ))
    return (committed, indexReference, indexData)
}

private func storageProcessRegularFileSnapshot(root: URL) throws -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return [:] }
    var result: [String: Data] = [:]
    for case let url as URL in enumerator {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            continue
        }
        result[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
    }
    return result
}

private let catalogProcessTestVolumeIsCaseInsensitive: Bool = {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let descriptor = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    return fpathconf(descriptor, _PC_CASE_SENSITIVE) == 0
}()
