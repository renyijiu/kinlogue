import Darwin
import Foundation
import KinlogueCore
import KinlogueDICOMIPC
@_spi(Testing) @_spi(KinlogueStorageProcessFixture) import KinloguePlatform

@main
enum KinlogueStorageProcessFixture {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--backup-capability" {
            Darwin.exit(await BackupCapabilityProbe.run(
                arguments: Array(arguments.dropFirst())
            ))
        }

        if arguments.first == "--storage-scale" {
            Darwin.exit(await StorageScaleProbe.run(
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
    enum Action {
        case keepRunning
        case exit
    }

    private var sqliteStore: SQLiteLibraryStore?

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
        case .openSQLite:
            guard sqliteStore == nil else { throw FixtureError.invalidCommand }
            sqliteStore = try SQLiteLibraryStore(rootURL: FixtureRoot.validate(command.rootPath))
            FixtureProtocol.write(.init(event: .sqliteOpened, ok: true))
        case .suspendSQLite:
            guard let sqliteStore else { throw FixtureError.invalidCommand }
            try sqliteStore.closeDatabaseForReplacement()
            FixtureProtocol.write(.init(event: .sqliteSuspended, ok: true))
        case .closeSQLite:
            try sqliteStore?.close()
            sqliteStore = nil
            FixtureProtocol.write(.init(event: .sqliteClosed, ok: true))
        case .holdSQLiteLogicalCapture:
            let phases: [SQLiteLogicalCapturePhase] = [.directoryCreated, .receiptDurable, .copyStep, .logicalValidation]
            guard let variant = command.variant, (1...phases.count).contains(variant) else { throw FixtureError.invalidCommand }
            let store = try SQLiteLibraryStore(rootURL: FixtureRoot.validate(command.rootPath))
            defer { try? store.close() }
            let source = SQLiteLogicalBackupSource(store: store, captureHook: { phase in
                if phase == phases[variant - 1] {
                    FixtureProtocol.write(.init(event: .leaseHeld, ok: true))
                    _ = readLine(strippingNewline: true)
                    throw CancellationError()
                }
            })
            let snapshot = try await source.prepare()
            snapshot.release()
        case .holdSQLiteLogicalRestore:
            let points: [BackupRestoreTransactionFault] = [.afterIntent, .afterWriterReset, .afterOldRootMove, .afterNewRootActivation, .afterValidation, .afterCommit]
            guard let variant = command.variant, (1...points.count).contains(variant) else { throw FixtureError.invalidCommand }
            let root = try FixtureRoot.validate(command.rootPath)
            let owner = try SQLiteLibraryOwner(rootURL: root)
            let verifier = try BackupRestoreVerifier(owner: owner)
            let prepared = try await verifier.prepare(archiveURL: root.deletingLastPathComponent().appendingPathComponent("logical.zip"))
            let transaction = try BackupRestoreTransaction(owner: owner, failureInjector: { point in
                guard point == points[variant - 1] else { return false }
                FixtureProtocol.write(.init(event: .leaseHeld, ok: true))
                _ = readLine(strippingNewline: true)
                return true
            })
            _ = try await transaction.activate(prepared: prepared, resetWriter: {})
            throw FixtureError.invalidCommand
        case .holdSQLiteInitialization:
            let points: [SQLiteInitializationFaultPoint] = [
                .afterReceipt, .afterOriginalsDirectory, .afterDatabaseCreation, .afterSchemaCommit,
            ]
            guard let variant = command.variant, (1...points.count).contains(variant) else {
                throw FixtureError.invalidCommand
            }
            let point = points[variant - 1]
            let store = try SQLiteLibraryStore(rootURL: FixtureRoot.validate(command.rootPath),
                initializationFault: { current in
                    guard current == point else { return false }
                    FixtureProtocol.write(.init(event: .leaseHeld, ok: true))
                    _ = readLine(strippingNewline: true)
                    return true
                })
            try store.close()
            throw FixtureError.invalidCommand
        case .holdSQLiteLANUpload:
            let points: [SQLiteOriginalFaultPoint] = [.afterRegistration, .afterIdentityCommit, .afterRename, .afterLiveCommit]
            guard let variant = command.variant, (1...5).contains(variant) else { throw FixtureError.invalidCommand }
            let store = try SQLiteLibraryStore(rootURL: FixtureRoot.validate(command.rootPath), originalFault: { current in
                guard variant <= points.count, current == points[variant - 1] else { return false }
                FixtureProtocol.write(.init(event: .leaseHeld, ok: true))
                _ = readLine(strippingNewline: true)
                return true
            })
            let inbox = try SQLiteLANInboxStore(store: store)
            let bytes = Data("synthetic SQLite LAN upload".utf8)
            let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "synthetic.bin"), declaredByteCount: bytes.count)
            guard case let .sink(sink) = try await inbox.startItemUpload(transport: LANInboxTransportIdentity(sessionID: UUID(), remoteFileID: UUID()), metadata: metadata, attemptRevision: 0) else { throw FixtureError.invalidCommand }
            if variant == 5 {
                try await sink.write(Data(bytes.prefix(3))).value
                FixtureProtocol.write(.init(event: .leaseHeld, ok: true))
                _ = readLine(strippingNewline: true)
            } else {
                try await sink.write(bytes).value
                _ = try await sink.finish()
            }
            throw FixtureError.invalidCommand
        case .holdSQLiteDICOMImport:
            let points: [SQLiteOriginalFaultPoint] = [.afterRegistration, .afterIdentityCommit, .afterRename, .afterLiveCommit]
            guard let variant = command.variant, (1...5).contains(variant) else { throw FixtureError.invalidCommand }
            let root = try FixtureRoot.validate(command.rootPath)
            let store = try SQLiteLibraryStore(rootURL: root, originalFault: { point in
                guard variant > 1, point == points[variant - 2] else { return false }
                FixtureProtocol.write(.init(event: .leaseHeld, ok: true))
                _ = readLine(strippingNewline: true)
                return true
            })
            let repository = try SQLiteDICOMRepository(store: store)
            let workflow = try DICOMImportWorkflow(repository: repository, decoder: BlockingProcessDICOMDecoder(blocks: variant == 1))
            _ = try await workflow.importDirectory(root.deletingLastPathComponent().appendingPathComponent("DICOMSource"), securityScope: .notRequiredForTesting)
            throw FixtureError.invalidCommand
        case .holdSQLiteOriginal:
            let points: [SQLiteOriginalFaultPoint] = [
                .afterRegistration, .afterIdentityCommit, .afterFileSync, .afterRename,
                .afterLiveCommit, .afterDeletingCommit, .afterUnlink,
            ]
            guard let variant = command.variant, (1...points.count).contains(variant) else {
                throw FixtureError.invalidCommand
            }
            let point = points[variant - 1]
            let root = try FixtureRoot.validate(command.rootPath)
            let store = try SQLiteLibraryStore(rootURL: root, originalFault: { current in
                guard current == point else { return false }
                FixtureProtocol.write(.init(event: .leaseHeld, ok: true))
                _ = readLine(strippingNewline: true)
                return true
            })
            defer { try? store.close() }
            let bytes = Data("synthetic SQLite original".utf8)
            let input = root.deletingLastPathComponent().appendingPathComponent("SQLiteInput")
            try bytes.write(to: input, options: .withoutOverwriting)
            let descriptor = Darwin.open(input.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw FixtureError.invalidRoot }
            defer { Darwin.close(descriptor) }
            let operation = UUID()
            let id = try store.stageOriginal(copyingFrom: descriptor, byteCount: bytes.count,
                sha256: ContentDigest.sha256(bytes), contentType: "application/octet-stream", operationID: operation)
            try store.publishOriginal(id, operationID: operation)
            try store.deleteOriginal(id)
            throw FixtureError.invalidCommand
        case .release:
            throw FixtureError.invalidCommand
        case .exit:
            FixtureProtocol.write(.init(event: .exiting, ok: true))
            return .exit
        }
        return .keepRunning
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
    case openSQLite, suspendSQLite, closeSQLite, holdSQLiteOriginal, holdSQLiteInitialization, holdSQLiteLANUpload, holdSQLiteDICOMImport, holdSQLiteLogicalRestore, holdSQLiteLogicalCapture
    case release
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
    case sqliteOpened, sqliteSuspended, sqliteClosed
    case leaseHeld
    case operationFailed
    case rejected
    case exiting
}

private actor BlockingProcessDICOMDecoder: DICOMFrameDecoding {
    let blocks: Bool
    init(blocks: Bool = true) { self.blocks = blocks }
    func decode(
        descriptor: FileHandle,
        declaredByteCount: Int
    ) async throws -> KinlogueDICOMDecodedFrame {
        _ = descriptor
        _ = declaredByteCount
        if blocks {
        FixtureProtocol.write(.init(event: .leaseHeld, ok: true))
        guard let line = readLine(strippingNewline: true),
              line.utf8.count <= FixtureProtocol.maximumLineByteCount,
              let data = line.data(using: .utf8),
              let command = try? JSONDecoder().decode(FixtureCommand.self, from: data),
              command.operation == .release else {
            throw FixtureError.invalidCommand
        }
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
    case storageFailure
    case occupied

    init(_ error: any Error) {
        switch error {
        case SQLiteLibraryError.occupied: self = .occupied
        case FixtureError.invalidCommand: self = .invalidCommand
        case FixtureError.invalidRoot: self = .invalidRoot
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
}
