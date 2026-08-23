import Darwin
import Foundation
import KinlogueCore
import KinlogueDICOMIPC
@_spi(KinlogueStorageProcessFixture) import KinloguePlatform

@main
enum KinlogueStorageProcessFixture {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--backup-capability" {
            Darwin.exit(await BackupCapabilityProbe.run(
                arguments: Array(arguments.dropFirst())
            ))
        }

        let runtime = FixtureRuntime()
        while let line = readLine(strippingNewline: true) {
            guard line.utf8.count <= FixtureProtocol.maximumLineByteCount,
                  let data = line.data(using: .utf8),
                  let command = try? JSONDecoder().decode(FixtureCommand.self, from: data) else {
                FixtureProtocol.write(.init(event: .rejected, ok: false, code: .invalidCommand))
                Darwin.exit(EX_USAGE)
            }
            do {
                if try await runtime.handle(command) == .exit {
                    Darwin.exit(EXIT_SUCCESS)
                }
            } catch {
                FixtureProtocol.write(.init(
                    event: .operationFailed,
                    ok: false,
                    code: FixtureFailureCode(error)
                ))
            }
        }
        Darwin.exit(EXIT_SUCCESS)
    }
}

private final class FixtureRuntime {
    private struct LoadedCatalog {
        let rootURL: URL
        let catalog: VaultCatalog
    }

    enum Action {
        case keepRunning
        case exit
    }

    private var loadedCatalog: LoadedCatalog?

    func handle(_ command: FixtureCommand) async throws -> Action {
        switch command.operation {
        case .handshake:
            guard command.protocolVersion == FixtureProtocol.version else {
                throw FixtureError.invalidCommand
            }
            FixtureProtocol.write(.init(
                event: .handshake,
                ok: true,
                protocolVersion: FixtureProtocol.version
            ))
        case .initialize:
            let rootURL = try FixtureRoot.validate(command.rootPath)
            let catalog = try await PlaintextVault(rootURL: rootURL).initialize()
            FixtureProtocol.write(.init(
                event: .initialized,
                ok: true,
                generation: catalog.generation
            ))
        case .loadCatalog:
            let rootURL = try FixtureRoot.validate(command.rootPath)
            let catalog = try await PlaintextVault(rootURL: rootURL).loadCatalog()
            loadedCatalog = LoadedCatalog(rootURL: rootURL, catalog: catalog)
            FixtureProtocol.write(.init(
                event: .catalogLoaded,
                ok: true,
                generation: catalog.generation
            ))
        case .commitLoadedCatalog:
            let committed = try await commitLoadedCatalog(variant: command.variant)
            FixtureProtocol.write(.init(
                event: .catalogCommitted,
                ok: true,
                variant: command.variant,
                generation: committed.generation
            ))
        case .barrierCommitLoadedCatalog:
            FixtureProtocol.write(.init(event: .catalogCommitAttempting, ok: true))
            let committed = try await commitLoadedCatalog(variant: command.variant)
            FixtureProtocol.write(.init(
                event: .catalogCommitted,
                ok: true,
                variant: command.variant,
                generation: committed.generation
            ))
        case .holdCatalogCommit:
            let loaded = try requireLoadedCatalog()
            let vault = try PlaintextVault(
                rootURL: loaded.rootURL,
                transactionFailureInjector: { point in
                    guard point == .afterObjects else { return false }
                    FixtureProtocol.write(.init(event: .leaseHeld, ok: true))
                    guard let releaseLine = readLine(strippingNewline: true),
                          releaseLine.utf8.count <= FixtureProtocol.maximumLineByteCount,
                          let releaseData = releaseLine.data(using: .utf8),
                          let release = try? JSONDecoder().decode(
                            FixtureCommand.self,
                            from: releaseData
                          ),
                          release.operation == .release else {
                        return true
                    }
                    return false
                }
            )
            let committed = try await vault.commit(try nextCommit(
                loaded: loaded,
                variant: command.variant
            ))
            loadedCatalog = LoadedCatalog(rootURL: loaded.rootURL, catalog: committed)
            FixtureProtocol.write(.init(
                event: .catalogCommitted,
                ok: true,
                variant: command.variant,
                generation: committed.generation
            ))
        case .rejectOversizedDICOMProposal:
            let loaded = try requireLoadedCatalog()
            do {
                _ = try oversizedDICOMCatalog(from: loaded.catalog)
                throw FixtureError.invalidCommand
            } catch DomainValidationError.invalidCatalogReference {
                FixtureProtocol.write(.init(
                    event: .operationFailed,
                    ok: false,
                    code: .resourceLimitExceeded
                ))
            }
        case .holdDICOMImport:
            let rootURL = try FixtureRoot.validate(command.rootPath)
            let sourceURL = rootURL.deletingLastPathComponent().appendingPathComponent(
                "DICOMSource",
                isDirectory: true
            )
            let sourceDescriptor = Darwin.open(
                sourceURL.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard sourceDescriptor >= 0 else { throw FixtureError.invalidRoot }
            Darwin.close(sourceDescriptor)
            let vault = try PlaintextVault(rootURL: rootURL)
            let workflow = try DICOMImportWorkflow(
                rootURL: rootURL,
                vault: vault,
                decoder: BlockingProcessDICOMDecoder()
            )
            _ = try await workflow.importDirectory(
                sourceURL,
                securityScope: .notRequiredForTesting
            )
            FixtureProtocol.write(.init(event: .dicomImported, ok: true))
        case .barrierPublishBackup:
            let rootURL = try FixtureRoot.validate(command.rootPath)
            let base = rootURL.deletingLastPathComponent()
            let configurationStore = BackupLocalConfigurationStore(
                rootURL: base.appendingPathComponent(
                    "BackupIdentity",
                    isDirectory: true
                )
            )
            guard let configuration = try await configurationStore.load(),
                  configuration.phase == .enabled else {
                throw FixtureError.invalidCommand
            }
            let vault = try PlaintextVault(rootURL: rootURL)
            let inbox = try PlaintextLANInboxStore(rootURL: rootURL)
            let source = try PlaintextLibraryBackupSource(
                vault: vault,
                inboxStore: inbox
            )
            let repositoryURL = base
                .appendingPathComponent("selected", isDirectory: true)
                .appendingPathComponent(
                    ".kinlogue-backup-v1",
                    isDirectory: true
                )
            let repository = BackupRepository(
                repositoryURL: repositoryURL,
                expectedIdentity: configuration.repositoryDirectoryIdentity,
                trustedDescriptor: configuration.descriptor,
                expectedAuthorizationID: configuration.authorization.authorizationID,
                leaseAuthority: .init(
                    configurationRootURL: configurationStore.rootURL,
                    configuration: configuration
                )
            )
            let writer = EncryptedCheckpointWriter(
                source: source,
                configurationStore: configurationStore
            )
            let published = try await BackupCheckpointPublisher(
                repository: repository,
                writer: writer,
                configurationStore: configurationStore,
                criticalSectionHook: {
                    FixtureProtocol.write(.init(
                        event: .backupPublicationCriticalSectionEntered,
                        ok: true
                    ))
                    guard let releaseLine = readLine(strippingNewline: true),
                          releaseLine.utf8.count <= FixtureProtocol.maximumLineByteCount,
                          let releaseData = releaseLine.data(using: .utf8),
                          let release = try? JSONDecoder().decode(
                            FixtureCommand.self,
                            from: releaseData
                          ),
                          release.operation == .release else {
                        throw FixtureError.invalidCommand
                    }
                }
            ).publishNext(configuration: configuration)
            FixtureProtocol.write(.init(
                event: .backupPublished,
                ok: true,
                generation: published.witness.sequence
            ))
        case .barrierDestroy:
            FixtureProtocol.write(.init(event: .destroyAttempting, ok: true))
            let rootURL = try FixtureRoot.validate(command.rootPath)
            try await PlaintextVault(rootURL: rootURL).destroy()
            FixtureProtocol.write(.init(event: .destroyed, ok: true))
        case .destroyAndInitialize:
            let rootURL = try FixtureRoot.validate(command.rootPath)
            try await PlaintextVault(rootURL: rootURL).destroy()
            let catalog = try await PlaintextVault(rootURL: rootURL).initialize()
            loadedCatalog = nil
            FixtureProtocol.write(.init(
                event: .reinitialized,
                ok: true,
                generation: catalog.generation
            ))
        case .release:
            throw FixtureError.invalidCommand
        case .exit:
            FixtureProtocol.write(.init(event: .exiting, ok: true))
            return .exit
        }
        return .keepRunning
    }

    private func commitLoadedCatalog(variant: Int?) async throws -> VaultCatalog {
        let loaded = try requireLoadedCatalog()
        let committed = try await PlaintextVault(rootURL: loaded.rootURL).commit(
            try nextCommit(loaded: loaded, variant: variant)
        )
        loadedCatalog = LoadedCatalog(rootURL: loaded.rootURL, catalog: committed)
        return committed
    }

    private func nextCommit(
        loaded: LoadedCatalog,
        variant: Int?
    ) throws -> VaultCommitRequest {
        let variant = try FixtureVariant(rawValue: variant)
        let member = try FamilyMember(
            id: variant.memberID,
            displayName: variant.displayName
        )
        let catalog = loaded.catalog
        return try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: VaultCatalog(
                vaultID: catalog.vaultID,
                generation: try VaultGeneration.successor(of: catalog.generation),
                members: catalog.members + [member],
                records: catalog.records,
                attachments: catalog.attachments,
                importDrafts: catalog.importDrafts,
                dicomStudies: catalog.dicomStudies
            ),
            writes: []
        )
    }

    private func requireLoadedCatalog() throws -> LoadedCatalog {
        guard let loadedCatalog else { throw FixtureError.catalogNotLoaded }
        return loadedCatalog
    }

    private func oversizedDICOMCatalog(from catalog: VaultCatalog) throws -> VaultCatalog {
        var attachments: [Attachment] = []
        var studies: [DICOMStudy] = []
        attachments.reserveCapacity(VaultCatalog.maximumRetainedDICOMObjectCount + 1)
        studies.reserveCapacity(6)
        var ordinal = 0
        for objectCount in [2_000, 2_000, 2_000, 2_000, 2_000, 1] {
            var owned: [Attachment] = []
            owned.reserveCapacity(objectCount)
            for _ in 0..<objectCount {
                let attachment = try Attachment(
                    contentTypeIdentifier: "application/dicom",
                    byteCount: 1,
                    sha256Digest: Self.syntheticDigest(ordinal)
                )
                ordinal += 1
                owned.append(attachment)
            }
            let fingerprint = try DICOMStudyFingerprint(objects: owned.map {
                try DICOMStudyFingerprint.ObjectDigest(
                    sha256Digest: $0.sha256Digest,
                    byteCount: $0.byteCount
                )
            })
            studies.append(try DICOMStudy(
                state: .needsReview,
                fingerprint: fingerprint,
                indexObjectID: UUID(),
                attachmentIDs: owned.map(\.id)
            ))
            attachments.append(contentsOf: owned)
        }
        return try VaultCatalog(
            vaultID: catalog.vaultID,
            generation: try VaultGeneration.successor(of: catalog.generation),
            members: catalog.members,
            records: catalog.records,
            attachments: catalog.attachments + attachments,
            importDrafts: catalog.importDrafts,
            dicomStudies: catalog.dicomStudies + studies
        )
    }

    private static func syntheticDigest(_ ordinal: Int) -> Data {
        var digest = Data(repeating: 0, count: 32)
        var value = UInt64(ordinal).bigEndian
        withUnsafeBytes(of: &value) { digest.replaceSubrange(24..<32, with: $0) }
        return digest
    }
}

private enum FixtureVariant: Int {
    case first = 1
    case second = 2

    init(rawValue: Int?) throws {
        guard let rawValue, let value = Self(rawValue: rawValue) else {
            throw FixtureError.invalidCommand
        }
        self = value
    }

    var memberID: UUID {
        switch self {
        case .first: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        case .second: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        }
    }

    var displayName: String {
        switch self {
        case .first: "Synthetic Process One"
        case .second: "Synthetic Process Two"
        }
    }
}

private enum FixtureRoot {
    static func validate(_ rawPath: String?) throws -> URL {
        guard let rawPath,
              rawPath.hasPrefix("/"),
              !rawPath.contains("\n"),
              !rawPath.contains("\r") else {
            throw FixtureError.invalidRoot
        }
        let rootURL = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
        let parentURL = rootURL.deletingLastPathComponent()
        let temporaryURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let isStorageProcessFixture =
            parentURL.lastPathComponent.hasPrefix("kinlogue-storage-process-")
                && parentURL.deletingLastPathComponent().resolvingSymlinksInPath()
                    .standardizedFileURL == temporaryURL
        let isBackupCapabilityFixture = isOwnedBackupCapabilityParent(
            parentURL,
            temporaryURL: temporaryURL
        )
        guard isStorageProcessFixture || isBackupCapabilityFixture,
              parentURL.resolvingSymlinksInPath().standardizedFileURL == parentURL else {
            throw FixtureError.invalidRoot
        }
        var metadata = stat()
        guard lstat(parentURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw FixtureError.invalidRoot
        }
        let descriptor = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw FixtureError.invalidRoot }
        defer { Darwin.close(descriptor) }
        let requestedName = rootURL.lastPathComponent
        let exact = requestedName == "Vault"
        let supportedAlias = requestedName.caseInsensitiveCompare("Vault") == .orderedSame
            && fpathconf(descriptor, _PC_CASE_SENSITIVE) == 0
        guard exact || supportedAlias else { throw FixtureError.invalidRoot }
        return rootURL
    }

    private static func isOwnedBackupCapabilityParent(
        _ parentURL: URL,
        temporaryURL: URL
    ) -> Bool {
        guard parentURL.lastPathComponent == "activation-real-writer" else {
            return false
        }
        let runDirectory = parentURL.deletingLastPathComponent()
        let runID = runDirectory.lastPathComponent
        let isTemporaryFixture = runID.hasPrefix("kinlogue-backup-capability-")
            && runDirectory.deletingLastPathComponent().resolvingSymlinksInPath()
                .standardizedFileURL == temporaryURL
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.standardizedFileURL
        let capabilityRoot = applicationSupport?
            .appendingPathComponent("Kinlogue", isDirectory: true)
            .appendingPathComponent("BackupCapability", isDirectory: true)
        let isInstalledFixture = runID.utf8.count == 32
            && runID.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
            }
            && runDirectory.deletingLastPathComponent().standardizedFileURL
                == capabilityRoot
        return isTemporaryFixture || isInstalledFixture
    }
}

private enum FixtureOperation: String, Codable {
    case handshake
    case initialize
    case loadCatalog
    case commitLoadedCatalog
    case barrierCommitLoadedCatalog
    case holdCatalogCommit
    case rejectOversizedDICOMProposal
    case holdDICOMImport
    case barrierPublishBackup
    case release
    case barrierDestroy
    case destroyAndInitialize
    case exit
}

private struct FixtureCommand: Codable {
    let operation: FixtureOperation
    let rootPath: String?
    let variant: Int?
    let protocolVersion: Int?
}

private enum FixtureEvent: String, Codable {
    case handshake
    case initialized
    case catalogLoaded
    case catalogCommitted
    case catalogCommitAttempting
    case dicomImported
    case backupPublicationCriticalSectionEntered
    case backupPublished
    case leaseHeld
    case destroyed
    case destroyAttempting
    case reinitialized
    case operationFailed
    case rejected
    case exiting
}

private actor BlockingProcessDICOMDecoder: DICOMFrameDecoding {
    func decode(
        descriptor: FileHandle,
        declaredByteCount: Int
    ) async throws -> KinlogueDICOMDecodedFrame {
        _ = descriptor
        _ = declaredByteCount
        FixtureProtocol.write(.init(event: .leaseHeld, ok: true))
        guard let line = readLine(strippingNewline: true),
              line.utf8.count <= FixtureProtocol.maximumLineByteCount,
              let data = line.data(using: .utf8),
              let command = try? JSONDecoder().decode(FixtureCommand.self, from: data),
              command.operation == .release else {
            throw FixtureError.invalidCommand
        }
        return KinlogueDICOMDecodedFrame(
            transferSyntaxUID: KinlogueDICOMSupportedObject.explicitVRLittleEndian,
            sopClassUID: KinlogueDICOMSupportedObject.mrImageStorage,
            studyInstanceUID: "2.25.8822",
            seriesInstanceUID: "2.25.8823",
            sopInstanceUID: "2.25.8824",
            modality: "MR",
            instanceNumber: 1,
            rows: 2,
            columns: 2,
            samplesPerPixel: 1,
            bitsAllocated: 16,
            bitsStored: 12,
            highBit: 11,
            pixelRepresentation: 0,
            photometricInterpretation: "MONOCHROME2",
            numberOfFrames: 1,
            imagePositionPatient: [0, 0, 0],
            imageOrientationPatient: [1, 0, 0, 0, 1, 0],
            windowCenter: 128,
            windowWidth: 256,
            rescaleIntercept: 0,
            rescaleSlope: 1,
            sampleBytes: Data([0, 0, 64, 0, 128, 0, 255, 0])
        )
    }
}

private enum FixtureFailureCode: String, Codable {
    case invalidCommand
    case invalidRoot
    case catalogNotLoaded
    case staleRevision
    case vaultMissing
    case rootReplaced
    case injectedFailure
    case resourceLimitExceeded
    case storageFailure

    init(_ error: any Error) {
        switch error {
        case FixtureError.invalidCommand: self = .invalidCommand
        case FixtureError.invalidRoot: self = .invalidRoot
        case FixtureError.catalogNotLoaded: self = .catalogNotLoaded
        case VaultError.mutationConflict: self = .staleRevision
        case VaultError.vaultMissing: self = .vaultMissing
        case VaultError.vaultIDMismatch: self = .rootReplaced
        case VaultError.injectedFailure: self = .injectedFailure
        default: self = .storageFailure
        }
    }
}

private struct FixtureResponse: Codable {
    let event: FixtureEvent
    let ok: Bool
    let code: FixtureFailureCode?
    let variant: Int?
    let generation: UInt64?
    let protocolVersion: Int?

    init(
        event: FixtureEvent,
        ok: Bool,
        code: FixtureFailureCode? = nil,
        variant: Int? = nil,
        generation: UInt64? = nil,
        protocolVersion: Int? = nil
    ) {
        self.event = event
        self.ok = ok
        self.code = code
        self.variant = variant
        self.generation = generation
        self.protocolVersion = protocolVersion
    }
}

private enum FixtureProtocol {
    static let version = 2
    static let maximumLineByteCount = 16 * 1_024
    private static let outputLock = NSLock()

    static func write(_ response: FixtureResponse) {
        outputLock.withLock {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(response) else { return }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }
}

private enum FixtureError: Error {
    case invalidCommand
    case invalidRoot
    case catalogNotLoaded
}
