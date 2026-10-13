import Darwin
import Foundation
import KinlogueCore
@_spi(Testing) import KinloguePlatform

/// Runs a whole-root restore inside a signed, installed, sandboxed build and kills itself at a
/// chosen point, so the next process has to settle what was left.
///
/// It calls the production verifier and transaction and declares no receipt, phase or rollback
/// rule of its own. The probe once also carried synthetic formats that showed, before the backup
/// code existed, that identity storage, key separation, repository publication, bookmarks and
/// large streaming writes were feasible in the sandbox; production code and its tests cover those
/// now, and that part was removed.
enum BackupCapabilityProbe {
    static func run(arguments: [String]) async -> Int32 {
        do {
            let configuration = try Configuration(arguments: arguments)
            switch configuration.operation {
            case .activationSeed:
                try await activationSeed(configuration: configuration)
                try emit(SimpleResult(category: "activation", status: "passed"))
            case .activationExecute:
                try await activationExecute(configuration: configuration)
                try emit(SimpleResult(category: "activation", status: "passed"))
            case .activationReconcile:
                try await activationReconcile(configuration: configuration)
                try emit(SimpleResult(category: "activation", status: "passed"))
            case .activationVerify:
                try emit(try await activationVerify(configuration: configuration))
            case .activationTruncateReceipt:
                try activationTruncateReceipt(configuration: configuration)
                try emit(SimpleResult(category: "activation", status: "passed"))
            }
            return EXIT_SUCCESS
        } catch let error as ProbeError {
            try? emit(FailureResult(code: error.code))
            return error.exitCode
        } catch {
            try? emit(FailureResult(code: "unexpectedFailure"))
            return EX_SOFTWARE
        }
    }
}

private extension BackupCapabilityProbe {
    enum Operation: String {
        case activationSeed = "activation-seed"
        case activationExecute = "activation-execute"
        case activationReconcile = "activation-reconcile"
        case activationVerify = "activation-verify"
        case activationTruncateReceipt = "activation-truncate-receipt"
    }

    struct Configuration {
        let operation: Operation
        let workingDirectory: URL?
        let runID: String?
        let caseID: String
        let scenario: ActivationScenario?
        let fault: ActivationFault?

        init(arguments: [String]) throws {
            var arguments = arguments
            var workingDirectory: URL?
            if arguments.first == "--working-directory" {
                guard arguments.count >= 3 else { throw ProbeError.invalidArguments }
                workingDirectory = try Self.validatedWorkingDirectory(arguments[1])
                arguments.removeFirst(2)
            }
            guard let rawOperation = arguments.first,
                  let operation = Operation(rawValue: rawOperation) else {
                throw ProbeError.invalidArguments
            }
            arguments.removeFirst()

            var runID: String?
            var caseID = "case"
            var scenario: ActivationScenario?
            var fault: ActivationFault?
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--run-id":
                    index += 1
                    guard index < arguments.count,
                          Self.isSafeIdentifier(arguments[index]) else {
                        throw ProbeError.invalidArguments
                    }
                    runID = arguments[index]
                case "--case-id":
                    index += 1
                    guard index < arguments.count,
                          Self.isSafeIdentifier(arguments[index]) else {
                        throw ProbeError.invalidArguments
                    }
                    caseID = arguments[index]
                case "--scenario":
                    index += 1
                    guard index < arguments.count,
                          let value = ActivationScenario(rawValue: arguments[index]) else {
                        throw ProbeError.invalidArguments
                    }
                    scenario = value
                case "--fault":
                    index += 1
                    guard index < arguments.count,
                          let value = ActivationFault(rawValue: arguments[index]) else {
                        throw ProbeError.invalidArguments
                    }
                    fault = value
                default:
                    throw ProbeError.invalidArguments
                }
                index += 1
            }
            self.operation = operation
            self.workingDirectory = workingDirectory
            self.runID = runID
            self.caseID = caseID
            self.scenario = scenario
            self.fault = fault
        }

        func baseDirectory(createIfMissing: Bool = true) throws -> URL {
            if let workingDirectory { return workingDirectory }
            guard let runID else { throw ProbeError.invalidArguments }
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw ProbeError.invalidWorkingDirectory
            }
            let root = applicationSupport
                .appendingPathComponent("Kinlogue", isDirectory: true)
                .appendingPathComponent("BackupCapability", isDirectory: true)
                .appendingPathComponent(runID, isDirectory: true)
            if createIfMissing {
                try ensureOwnedDirectory(root)
            } else {
                try validateOwnedDirectory(root)
            }
            return root
        }

        private static func validatedWorkingDirectory(_ rawPath: String) throws -> URL {
            guard rawPath.hasPrefix("/") else { throw ProbeError.invalidWorkingDirectory }
            let url = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            let temporary = FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath().standardizedFileURL
            guard url.lastPathComponent.hasPrefix("kinlogue-backup-capability-"),
                  url.deletingLastPathComponent().resolvingSymlinksInPath()
                    .standardizedFileURL == temporary,
                  url.resolvingSymlinksInPath().standardizedFileURL == url else {
                throw ProbeError.invalidWorkingDirectory
            }
            try validateOwnedDirectory(url)
            return url
        }

        private static func isSafeIdentifier(_ value: String) -> Bool {
            let bytes = value.utf8
            return (1...64).contains(bytes.count)
                && bytes.allSatisfy {
                    ($0 >= 0x30 && $0 <= 0x39)
                        || ($0 >= 0x61 && $0 <= 0x7a)
                        || $0 == 0x2d
                }
        }
    }

    struct SimpleResult: Codable {
        let category: String
        let status: String
    }

    struct FailureResult: Encodable {
        let category = "capability"
        let status = "blocked"
        let code: String
    }

    enum ProbeError: Error {
        case invalidArguments
        case invalidWorkingDirectory
        case receiptInvalid
        case activationInvalid
        case libraryOccupied
        case ioFailure(Int32)
        case resourceLimit

        var code: String {
            switch self {
            case .invalidArguments: "invalidArguments"
            case .invalidWorkingDirectory: "invalidWorkingDirectory"
            case .receiptInvalid: "receiptInvalid"
            case .activationInvalid: "activationInvalid"
            case .libraryOccupied: "libraryOccupied"
            case .ioFailure: "ioFailure"
            case .resourceLimit: "resourceLimit"
            }
        }

        var exitCode: Int32 {
            switch self {
            case .invalidArguments: EX_USAGE
            default: 1
            }
        }
    }

    static func emit<Value: Encodable>(_ value: Value) throws {
        let data = try canonicalJSON(value)
        guard data.count <= 64 * 1_024 else { throw ProbeError.resourceLimit }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}

// MARK: - Whole-root activation

private extension BackupCapabilityProbe {
    enum ActivationScenario: String, Codable {
        case existing
        case absent
    }

    enum ActivationFault: String {
        case none
        case afterIntent = "after-intent"
        case afterWriterReset = "after-writer-reset"
        case afterOldRootMove = "after-old-root-move"
        case afterNewRootActivation = "after-new-root-activation"
        case afterValidation = "after-validation"
        case afterCommit = "after-commit"

        var productionFault: BackupRestoreTransactionFault? {
            switch self {
            case .none: nil
            case .afterIntent: .afterIntent
            case .afterWriterReset: .afterWriterReset
            case .afterOldRootMove: .afterOldRootMove
            case .afterNewRootActivation: .afterNewRootActivation
            case .afterValidation: .afterValidation
            case .afterCommit: .afterCommit
            }
        }
    }

    enum RootState: String, Codable {
        case old
        case new
        case absent
    }

    struct DirectoryIdentity: Codable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    struct RootSemanticIdentity: Equatable {
        let state: RootState
        let generation: UInt64
        let logicalDigest: Data
        let memberCount: Int
        let inboxItemCount: Int
        let inboxTerminalCount: Int
    }

    struct ActivationVerification: Encodable {
        let category = "activation"
        let status = "passed"
        let rootState: RootState
        let mixedState: Bool
        let receiptPresent: Bool
        let stagingPresent: Bool
        let rollbackPresent: Bool
        let semanticValidated: Bool
        let libraryGeneration: UInt64
        let memberCount: Int
        let inboxItemCount: Int
        let inboxTerminalCount: Int
    }

    struct ActivationWorkspace {
        let parent: URL
        let current: URL
        let source: URL
        let checkpoint: URL
        let recoveryCode: URL

        init(configuration: Configuration, createParent: Bool = false) throws {
            let base = try configuration.baseDirectory()
            parent = base.appendingPathComponent(
                "activation-\(configuration.caseID)",
                isDirectory: true
            )
            current = parent.appendingPathComponent("Vault", isDirectory: true)
            source = parent.appendingPathComponent("RestoreSource", isDirectory: true)
            checkpoint = parent.appendingPathComponent(
                "prepared.kinloguebackup",
                isDirectory: false
            )
            recoveryCode = parent.appendingPathComponent(
                "recovery-code.txt",
                isDirectory: false
            )
            if createParent {
                guard !FileManager.default.fileExists(atPath: parent.path) else {
                    throw ProbeError.activationInvalid
                }
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } else {
                try validateOwnedDirectory(parent)
            }
        }
    }

    // SAFETY: `lock` serializes all access to `storage`; `data` and `source()`
    // return immutable snapshots that do not retain the mutable buffer.
    final class ActivationCheckpointBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ bytes: Data) {
            lock.withLock { storage.append(bytes) }
        }

        var data: Data { lock.withLock { storage } }

        func source() -> BackupContainerByteSource {
            let snapshot = data
            return BackupContainerByteSource(byteCount: UInt64(snapshot.count)) {
                offset,
                maximumByteCount in
                let start = Int(offset)
                return Data(snapshot[start..<min(snapshot.count, start + maximumByteCount)])
            }
        }
    }

    static func activationSeed(configuration: Configuration) async throws {
        guard let scenario = configuration.scenario else {
            throw ProbeError.invalidArguments
        }
        let workspace = try ActivationWorkspace(configuration: configuration, createParent: true)
        if scenario == .existing {
            _ = try await createCommittedRoot(at: workspace.current, state: .old)
        }
        _ = try await createCommittedRoot(at: workspace.source, state: .new)
        let store = try SQLiteLibraryStore(rootURL: workspace.source)
        defer { try? store.close() }
        let snapshot = try await SQLiteLogicalBackupSource(store: store).prepare()
        defer { snapshot.release() }
        let enrollment = try BackupKeyHierarchy.makeEnrollment()
        let signer = try BackupDeviceSigner(
            descriptor: enrollment.descriptor,
            authorization: enrollment.authorization,
            deviceSigningSeed: enrollment.deviceSigningSeed
        )
        let bytes = ActivationCheckpointBytes()
        _ = try await EncryptedBackupContainerWriter().write(
            entries: snapshot.sources(),
            revisionPair: snapshot.revisionPair,
            sequence: 1,
            signer: signer,
            sink: BackupContainerWriteSink(
                write: bytes.append,
                readBackSource: bytes.source
            )
        )
        try writeExclusivePrivateFile(bytes.data, to: workspace.checkpoint)
        try writeExclusivePrivateFile(Data(enrollment.recoveryCode.utf8), to: workspace.recoveryCode)
        try syncParentDirectory(workspace.parent)
    }

    static func activationExecute(configuration: Configuration) async throws {
        guard let scenario = configuration.scenario,
              let fault = configuration.fault else {
            throw ProbeError.invalidArguments
        }
        let workspace = try ActivationWorkspace(configuration: configuration)
        guard (scenario == .existing && pathExists(workspace.current))
                || (scenario == .absent && !pathExists(workspace.current)) else {
            throw ProbeError.activationInvalid
        }
        let recoveryCode = String(decoding: try readPrivateFile(
            workspace.recoveryCode,
            maximumByteCount: 256
        ), as: UTF8.self)
        do {
            let owner = try SQLiteLibraryOwner(rootURL: workspace.current)
            let verifier = try BackupRestoreVerifier(owner: owner)
            let prepared = try await verifier.prepare(
                checkpointURL: workspace.checkpoint,
                recoveryCode: recoveryCode
            )
            let productionFault = fault.productionFault
            let transaction = try BackupRestoreTransaction(
                owner: owner,
                failureInjector: { actual in
                    guard actual == productionFault else { return false }
                    _ = Darwin.kill(getpid(), SIGKILL)
                    while true { _ = Darwin.pause() }
                }
            )
            _ = try await transaction.activate(prepared: prepared, resetWriter: {})
            if productionFault == nil {
                guard try await transaction.reconcile() == .committed else {
                    throw ProbeError.activationInvalid
                }
            }
        } catch {
            throw mapRestoreError(error)
        }
    }

    static func activationReconcile(configuration: Configuration) async throws {
        let workspace = try ActivationWorkspace(configuration: configuration)
        do {
            let owner = try SQLiteLibraryOwner(rootURL: workspace.current)
            _ = try await BackupRestoreTransaction(owner: owner).reconcile()
            try BackupRestoreVerifier(owner: owner).reconcileAbandonedPreflights()
        } catch {
            throw mapRestoreError(error)
        }
    }

    static func activationVerify(configuration: Configuration) async throws
        -> ActivationVerification
    {
        let workspace = try ActivationWorkspace(configuration: configuration)
        let semantic: RootSemanticIdentity?
        if pathExists(workspace.current) {
            semantic = try await strictValidateCommittedRoot(at: workspace.current)
        } else {
            semantic = nil
        }
        let artifacts = try restoreArtifactNames(in: workspace.parent)
        let staging = artifacts.contains { $0.hasSuffix(".staging") }
        let rollback = artifacts.contains { $0.hasPrefix(".kinlogue-restore-rollback-") }
        let receipt = artifacts.contains {
            $0.hasPrefix(".kinlogue-restore-transaction-")
                || $0.hasSuffix(".preflight.json")
        }
        let rootState = semantic?.state ?? .absent
        let mixed = staging && rollback
        return ActivationVerification(
            rootState: rootState,
            mixedState: mixed,
            receiptPresent: receipt,
            stagingPresent: staging,
            rollbackPresent: rollback,
            semanticValidated: true,
            libraryGeneration: semantic?.generation ?? 0,
            memberCount: semantic?.memberCount ?? 0,
            inboxItemCount: semantic?.inboxItemCount ?? 0,
            inboxTerminalCount: semantic?.inboxTerminalCount ?? 0
        )
    }

    static func activationTruncateReceipt(configuration: Configuration) throws {
        let workspace = try ActivationWorkspace(configuration: configuration)
        let receipts = try restoreArtifactNames(in: workspace.parent).filter {
            $0.hasPrefix(".kinlogue-restore-transaction-") && $0.hasSuffix(".json")
        }
        guard receipts.count == 1 else { throw ProbeError.receiptInvalid }
        try writePrivateFile(
            Data(#"{"magic":"truncated""#.utf8),
            to: workspace.parent.appendingPathComponent(receipts[0])
        )
    }

    static func restoreArtifactNames(in parent: URL) throws -> [String] {
        try validateOwnedDirectory(parent)
        return try FileManager.default.contentsOfDirectory(atPath: parent.path).filter {
            $0.hasPrefix(".kinlogue-restore-")
        }.sorted()
    }

    static func mapRestoreError(_ error: Error) -> ProbeError {
        if error as? SQLiteLibraryError == .occupied { return .libraryOccupied }
        guard let restore = error as? BackupRestoreError else {
            return error as? ProbeError ?? .activationInvalid
        }
        switch restore {
        case .receiptInvalid: return .receiptInvalid
        case let .ioFailure(code): return .ioFailure(code)
        default: return .activationInvalid
        }
    }

    /// Builds one of the two seeded libraries: a member named for the state, one retained LAN
    /// item, and one LAN item that was uploaded and then deleted.
    static func createCommittedRoot(
        at root: URL,
        state: RootState
    ) async throws -> RootSemanticIdentity {
        let store = try SQLiteLibraryStore(rootURL: root)
        do {
            try await SQLiteReportRepository(store: store).saveMember(
                FamilyMember(displayName: try activationMemberName(state)),
                replacing: nil
            )
            let inbox = try SQLiteLANInboxStore(store: store)
            try await uploadActivationInboxBytes(
                try activationInboxBytes(state),
                name: "synthetic-retained.bin",
                sessionID: UUID(),
                store: inbox
            )
            let terminalSessionID = UUID()
            let terminalBytes = try activationTerminalBytes(state)
            try await uploadActivationInboxBytes(
                terminalBytes,
                name: "synthetic-terminal.bin",
                sessionID: terminalSessionID,
                store: inbox
            )
            let beforeDelete = try await inbox.loadSnapshot()
            let terminalIdentity = try LANInboxContentIdentity(
                sha256Digest: ContentDigest.sha256(terminalBytes),
                byteCount: terminalBytes.count
            )
            guard let terminalItem = beforeDelete.item(contentIdentity: terminalIdentity) else {
                throw ProbeError.activationInvalid
            }
            _ = try await inbox.deleteItem(
                itemID: terminalItem.id,
                expectedRevision: terminalItem.revision,
                activeSessionID: terminalSessionID
            )
            try store.close()
        } catch {
            try? store.close()
            throw error
        }
        let semantic = try await strictValidateCommittedRoot(at: root)
        guard semantic.state == state else { throw ProbeError.activationInvalid }
        return semantic
    }

    static func uploadActivationInboxBytes(
        _ bytes: Data,
        name: String,
        sessionID: UUID,
        store: SQLiteLANInboxStore
    ) async throws {
        let admission = try await store.itemAdmissionGeneration()
        let transport = LANInboxTransportIdentity(
            sessionID: sessionID,
            remoteFileID: UUID()
        )
        let metadata = try LANInboxTransportMetadata(
            displayName: LANInboxDisplayName(rawValue: name),
            declaredByteCount: bytes.count,
            mediaType: "application/octet-stream"
        )
        let outcome = try await store.startItemUpload(
            transport: transport,
            metadata: metadata,
            attemptRevision: 1,
            admissionGeneration: admission
        )
        guard case let .sink(sink) = outcome else {
            throw ProbeError.activationInvalid
        }
        try await sink.write(bytes).value
        _ = try await sink.finish()
    }

    /// Opens the root the way a restore does, validates every logical record and original, and
    /// checks that it holds exactly one of the two seeded libraries.
    static func strictValidateCommittedRoot(at root: URL) async throws -> RootSemanticIdentity {
        try validateOwnedDirectory(root)
        let store = try SQLiteLibraryStore(owner: SQLiteLibraryOwner(rootURL: root), mode: .strictExisting)
        defer { try? store.close() }
        let source = SQLiteLogicalBackupSource(store: store)
        let validation = try source.validateStrict()
        let members = try await SQLiteReportRepository(store: store).members()
        guard members.count == 1 else { throw ProbeError.activationInvalid }
        let state = try activationState(memberName: members[0].displayName)

        let inboxStore = try SQLiteLANInboxStore(store: store)
        let inbox = try await inboxStore.loadSnapshot()
        guard inbox.items.count == 1,
              inbox.contentTerminals.count == 1,
              let item = inbox.items.first,
              let terminal = inbox.contentTerminals.first,
              case .deleted = terminal.kind else {
            throw ProbeError.activationInvalid
        }
        let expectedInboxBytes = try activationInboxBytes(state)
        let expectedTerminalBytes = try activationTerminalBytes(state)
        let readLimit = expectedInboxBytes.count + 1
        let storedBytes = try await inboxStore.withVerifiedItemSourceContent(itemID: item.id) { descriptor in
            var buffer = [UInt8](repeating: 0, count: readLimit)
            let count = pread(descriptor, &buffer, readLimit, 0)
            guard count >= 0 else { throw ProbeError.ioFailure(errno) }
            return Data(buffer.prefix(count))
        }
        guard storedBytes == expectedInboxBytes,
              terminal.contentIdentity.sha256Digest
                == ContentDigest.sha256(expectedTerminalBytes),
              terminal.contentIdentity.byteCount == expectedTerminalBytes.count,
              validation.memberCount == 1,
              validation.inboxItemCount == 1 else {
            throw ProbeError.activationInvalid
        }
        return RootSemanticIdentity(
            state: state,
            generation: try source.currentRevision().vault.generation,
            logicalDigest: validation.digest,
            memberCount: validation.memberCount,
            inboxItemCount: validation.inboxItemCount,
            inboxTerminalCount: inbox.contentTerminals.count
        )
    }

    static func activationMemberName(_ state: RootState) throws -> String {
        switch state {
        case .old: "Synthetic previous root"
        case .new: "Synthetic restored root"
        case .absent: throw ProbeError.activationInvalid
        }
    }

    static func activationInboxBytes(_ state: RootState) throws -> Data {
        switch state {
        case .old: Data("KLG-U0-INBOX-OLD-COMMITTED-BLOB".utf8)
        case .new: Data("KLG-U0-INBOX-NEW-COMMITTED-BLOB".utf8)
        case .absent: throw ProbeError.activationInvalid
        }
    }

    static func activationTerminalBytes(_ state: RootState) throws -> Data {
        switch state {
        case .old: Data("KLG-U0-INBOX-OLD-TERMINAL".utf8)
        case .new: Data("KLG-U0-INBOX-NEW-TERMINAL".utf8)
        case .absent: throw ProbeError.activationInvalid
        }
    }

    static func activationState(memberName: String) throws -> RootState {
        if memberName == (try activationMemberName(.old)) { return .old }
        if memberName == (try activationMemberName(.new)) { return .new }
        throw ProbeError.activationInvalid
    }
}

// MARK: - Filesystem primitives

private extension BackupCapabilityProbe {
    static func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func ensureOwnedDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try validateOwnedDirectory(url)
    }

    static func validateOwnedDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw ProbeError.invalidWorkingDirectory
        }
    }

    static func pathExists(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
    }

    static func regularFileIdentity(
        _ url: URL,
        expectedMode: mode_t
    ) throws -> DirectoryIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o777) == expectedMode,
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              device > 0,
              inode > 0 else {
            throw ProbeError.receiptInvalid
        }
        return DirectoryIdentity(device: device, inode: inode)
    }

    static func openOwnedDirectory(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw ProbeError.ioFailure(errno) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            Darwin.close(descriptor)
            throw ProbeError.invalidWorkingDirectory
        }
        return descriptor
    }

    static func writePrivateFile(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try ensureOwnedDirectory(parent)
        let existingIdentity = pathExists(destination)
            ? try regularFileIdentity(destination, expectedMode: 0o600)
            : nil
        let parentDescriptor = try openOwnedDirectory(parent)
        defer { Darwin.close(parentDescriptor) }
        let temporaryName = ".\(destination.lastPathComponent).u0.tmp"
        _ = unlinkat(parentDescriptor, temporaryName, 0)
        let descriptor = openat(
            parentDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw ProbeError.ioFailure(errno) }
        var closeNeeded = true
        defer {
            if closeNeeded { Darwin.close(descriptor) }
            _ = unlinkat(parentDescriptor, temporaryName, 0)
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ProbeError.ioFailure(errno)
                }
                offset += count
            }
        }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw ProbeError.ioFailure(errno)
        }
        guard Darwin.close(descriptor) == 0 else { throw ProbeError.ioFailure(errno) }
        closeNeeded = false
        if let existingIdentity {
            guard try regularFileIdentity(destination, expectedMode: 0o600)
                    == existingIdentity,
                  renameat(
                    parentDescriptor,
                    temporaryName,
                    parentDescriptor,
                    destination.lastPathComponent
                  ) == 0 else {
                throw ProbeError.ioFailure(errno)
            }
        } else {
            guard renameatx_np(
                parentDescriptor,
                temporaryName,
                parentDescriptor,
                destination.lastPathComponent,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw ProbeError.ioFailure(errno)
            }
        }
        try syncDescriptor(parentDescriptor)
    }

    static func writeExclusivePrivateFile(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try ensureOwnedDirectory(parent)
        let parentDescriptor = try openOwnedDirectory(parent)
        defer { Darwin.close(parentDescriptor) }
        let descriptor = openat(
            parentDescriptor,
            destination.lastPathComponent,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw ProbeError.ioFailure(errno) }
        var closeNeeded = true
        defer {
            if closeNeeded { Darwin.close(descriptor) }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ProbeError.ioFailure(errno)
                }
                offset += count
            }
        }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw ProbeError.ioFailure(errno)
        }
        guard Darwin.close(descriptor) == 0 else { throw ProbeError.ioFailure(errno) }
        closeNeeded = false
        try syncDescriptor(parentDescriptor)
    }

    static func readPrivateFile(_ url: URL, maximumByteCount: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProbeError.ioFailure(errno) }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o777) == mode_t(0o600),
              metadata.st_size >= 0,
              metadata.st_size <= maximumByteCount else {
            throw ProbeError.receiptInvalid
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ProbeError.ioFailure(errno)
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumByteCount else { throw ProbeError.resourceLimit }
        }
        return result
    }

    static func syncParentDirectory(_ directory: URL) throws {
        let descriptor = try openOwnedDirectory(directory)
        defer { Darwin.close(descriptor) }
        try syncDescriptor(descriptor)
    }

    static func syncDescriptor(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else {
            throw ProbeError.ioFailure(errno)
        }
    }
}
