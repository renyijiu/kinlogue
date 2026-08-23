import AppKit
import CryptoKit
import Darwin
import Foundation
import KinlogueCore
@_spi(Testing) import KinloguePlatform

enum BackupCapabilityProbe {
    private static let defaultStreamByteCount = 2 * 1_024 * 1_024 * 1_024
    private static let maximumStreamByteCount = defaultStreamByteCount
    private static let selectedChunkByteCount = 256 * 1_024
    private static let candidateChunkByteCounts = [
        64 * 1_024,
        selectedChunkByteCount,
        1_024 * 1_024,
    ]

    static func run(arguments: [String]) async -> Int32 {
        do {
            let configuration = try Configuration(arguments: arguments)
            switch configuration.operation {
            case .identityCreate:
                try emit(try identityCreate(configuration: configuration))
            case .identityRead:
                try emit(try identityRead(configuration: configuration))
            case .identityUpgrade:
                try emit(try identityUpgrade(configuration: configuration))
            case .cryptoPublicWriter:
                try emit(try cryptoPublicWriter(configuration: configuration))
            case .cryptoPublicDecrypt:
                try emit(try cryptoPublicDecrypt(configuration: configuration))
            case .cryptoSeedRecover:
                try emit(try cryptoSeedRecover(configuration: configuration))
            case .repositoryPublication:
                try emit(try repositoryPublicationProbe(configuration: configuration))
            case .selectedTargetPublication:
                try emit(try selectedTargetPublicationProbe(configuration: configuration))
            case .bookmarkCreate:
                try emit(try await bookmarkCreate(configuration: configuration))
            case .bookmarkResolve:
                try emit(try bookmarkResolve(configuration: configuration))
            case .activationSeed:
                try await activationSeed(configuration: configuration)
                try emit(SimpleResult(category: "activation", status: "passed"))
            case .activationSeedWriter:
                try await activationSeedWriter(configuration: configuration)
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
            case .namedDataset:
                try emit(try namedDatasetProbe(configuration: configuration))
            case .chunk:
                try emit(try chunkProbe(totalByteCount: configuration.streamByteCount))
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
        case identityCreate = "identity-create"
        case identityRead = "identity-read"
        case identityUpgrade = "identity-upgrade"
        case cryptoPublicWriter = "crypto-public-writer"
        case cryptoPublicDecrypt = "crypto-public-decrypt"
        case cryptoSeedRecover = "crypto-seed-recover"
        case repositoryPublication = "repository-publication"
        case selectedTargetPublication = "selected-target-publication"
        case bookmarkCreate = "bookmark-create"
        case bookmarkResolve = "bookmark-resolve"
        case activationSeed = "activation-seed"
        case activationSeedWriter = "activation-seed-writer"
        case activationExecute = "activation-execute"
        case activationReconcile = "activation-reconcile"
        case activationVerify = "activation-verify"
        case activationTruncateReceipt = "activation-truncate-receipt"
        case namedDataset = "named-dataset"
        case chunk
    }

    struct Configuration {
        let operation: Operation
        let workingDirectory: URL?
        let runID: String?
        let caseID: String
        let scenario: ActivationScenario?
        let fault: ActivationFault?
        let candidateDirectory: URL?
        let refreshStaleBookmark: Bool
        let streamByteCount: Int
        let objectCount: Int

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
            var candidateDirectory: URL?
            var refreshStaleBookmark = false
            var streamByteCount = BackupCapabilityProbe.defaultStreamByteCount
            var objectCount = BackupCapabilityProbe.maximumSourceObjectCount
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
                case "--candidate-directory":
                    index += 1
                    guard index < arguments.count else {
                        throw ProbeError.invalidArguments
                    }
                    candidateDirectory = URL(
                        fileURLWithPath: arguments[index],
                        isDirectory: true
                    ).standardizedFileURL
                case "--refresh-if-stale":
                    refreshStaleBookmark = true
                case "--stream-byte-count":
                    index += 1
                    guard index < arguments.count,
                          let value = Int(arguments[index]),
                          (1...BackupCapabilityProbe.maximumStreamByteCount).contains(value) else {
                        throw ProbeError.invalidArguments
                    }
                    streamByteCount = value
                case "--object-count":
                    index += 1
                    guard index < arguments.count,
                          let value = Int(arguments[index]),
                          (1...BackupCapabilityProbe.maximumSourceObjectCount).contains(value) else {
                        throw ProbeError.invalidArguments
                    }
                    objectCount = value
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
            self.candidateDirectory = candidateDirectory
            self.refreshStaleBookmark = refreshStaleBookmark
            self.streamByteCount = streamByteCount
            guard streamByteCount >= objectCount else { throw ProbeError.invalidArguments }
            self.objectCount = objectCount
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
        case identityInvalid
        case identityPermissionFailure
        case cryptoProfileInvalid
        case recoveryMaterialUnavailable
        case repositoryInvalid
        case adversarialSetupUnavailable
        case capacityInsufficient
        case bookmarkCancelled
        case bookmarkInvalid
        case bookmarkSelectionMismatch
        case bookmarkDataUnavailable
        case bookmarkRecordCollision
        case scopeUnavailable
        case receiptInvalid
        case activationInvalid
        case ioFailure(Int32)
        case resourceLimit
        case datasetInvalid
        case datasetCancelled

        var code: String {
            switch self {
            case .invalidArguments: "invalidArguments"
            case .invalidWorkingDirectory: "invalidWorkingDirectory"
            case .identityInvalid: "identityInvalid"
            case .identityPermissionFailure: "identityPermissionFailure"
            case .cryptoProfileInvalid: "cryptoProfileInvalid"
            case .recoveryMaterialUnavailable: "recoveryMaterialUnavailable"
            case .repositoryInvalid: "repositoryInvalid"
            case .adversarialSetupUnavailable: "adversarialSetupUnavailable"
            case .capacityInsufficient: "capacityInsufficient"
            case .bookmarkCancelled: "bookmarkCancelled"
            case .bookmarkInvalid: "bookmarkInvalid"
            case .bookmarkSelectionMismatch: "bookmarkSelectionMismatch"
            case .bookmarkDataUnavailable: "bookmarkDataUnavailable"
            case .bookmarkRecordCollision: "bookmarkRecordCollision"
            case .scopeUnavailable: "scopeUnavailable"
            case .receiptInvalid: "receiptInvalid"
            case .activationInvalid: "activationInvalid"
            case .ioFailure: "ioFailure"
            case .resourceLimit: "resourceLimit"
            case .datasetInvalid: "datasetInvalid"
            case .datasetCancelled: "datasetCancelled"
            }
        }

        var exitCode: Int32 {
            switch self {
            case .invalidArguments: EX_USAGE
            case .bookmarkCancelled: 2
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

// MARK: - App-private non-decrypting identity

private extension BackupCapabilityProbe {
    struct SyntheticDescriptor: Codable {
        let magic: String
        let version: Int
        let suite: String
        let setID: Data
        let signingPublicKey: Data
        let recipientPublicKey: Data
    }

    struct SyntheticAuthorization: Codable {
        let magic: String
        let version: Int
        let descriptorDigest: Data
        let authorizationID: Data
        let deviceID: Data
        let devicePublicKey: Data
        let sequenceFloor: UInt64
    }

    struct DeviceIdentityRecord: Codable {
        let magic: String
        let version: Int
        let generation: Int
        let writerEpoch: UInt64
        let descriptor: SyntheticDescriptor
        let descriptorDigest: Data
        let descriptorPublicKey: Data
        let recipientPublicKey: Data
        let descriptorSignature: Data
        let authorization: SyntheticAuthorization
        let authorizationSignature: Data
        let deviceSigningSeed: Data
        let devicePublicKey: Data
    }

    struct IdentityResult: Encodable {
        let category = "identity"
        let status = "passed"
        let operation: String
        let generation: Int
        let parentMode: Int
        let recordMode: Int
        let publicIdentity: String
        let descriptorDigest: String
    }

    static func identityCreate(configuration: Configuration) throws -> IdentityResult {
        let parent = try configuration.baseDirectory(createIfMissing: true)
        let parentDescriptor = try openPrivateParent(parent)
        defer { Darwin.close(parentDescriptor) }
        guard try leafIsAbsent(parentDescriptor, name: identityLeafName),
              try leafIsAbsent(parentDescriptor, name: recoverySeedLeafName) else {
            throw ProbeError.identityInvalid
        }
        let recoverySeed = try randomData(byteCount: 32)
        let setID = try randomData(byteCount: 16)
        let signingRoot = try Curve25519.Signing.PrivateKey(
            rawRepresentation: derivedSeed(recoverySeed, setID: setID, role: "signing-root")
        )
        let recipientRoot = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: derivedSeed(recoverySeed, setID: setID, role: "hpke-root")
        )
        let descriptor = SyntheticDescriptor(
            magic: "KLG-U0-BACKUP-SET-1",
            version: 1,
            suite: "Curve25519-SHA256-ChaChaPoly+AES256-GCM",
            setID: setID,
            signingPublicKey: signingRoot.publicKey.rawRepresentation,
            recipientPublicKey: recipientRoot.publicKey.rawRepresentation
        )
        let descriptorBytes = try canonicalJSON(descriptor)
        let descriptorDigest = Data(SHA256.hash(data: descriptorBytes))
        let descriptorSignature = try signingRoot.signature(for: descriptorBytes)
        let signingKey = Curve25519.Signing.PrivateKey()
        let authorization = SyntheticAuthorization(
            magic: "KLG-U0-DEVICE-AUTHORIZATION-1",
            version: 1,
            descriptorDigest: descriptorDigest,
            authorizationID: try randomData(byteCount: 16),
            deviceID: try randomData(byteCount: 16),
            devicePublicKey: signingKey.publicKey.rawRepresentation,
            sequenceFloor: 1
        )
        let authorizationSignature = try signingRoot.signature(
            for: canonicalJSON(authorization)
        )
        let record = DeviceIdentityRecord(
            magic: "KLG-U0-DEVICE-IDENTITY-1",
            version: 1,
            generation: 1,
            writerEpoch: 1,
            descriptor: descriptor,
            descriptorDigest: descriptorDigest,
            descriptorPublicKey: descriptor.signingPublicKey,
            recipientPublicKey: descriptor.recipientPublicKey,
            descriptorSignature: descriptorSignature,
            authorization: authorization,
            authorizationSignature: authorizationSignature,
            deviceSigningSeed: signingKey.rawRepresentation,
            devicePublicKey: signingKey.publicKey.rawRepresentation
        )
        let seedIdentity = try writeExclusiveLeaf(
            recoverySeed,
            parentDescriptor: parentDescriptor,
            name: recoverySeedLeafName,
            failure: .identityInvalid
        )
        do {
            let recordBytes = try canonicalJSON(record)
            _ = try writeExclusiveLeaf(
                recordBytes,
                parentDescriptor: parentDescriptor,
                name: identityLeafName,
                failure: .identityInvalid
            )
            let readBack = try readValidatedLeaf(
                parentDescriptor: parentDescriptor,
                name: identityLeafName,
                maximumByteCount: identityMaximumByteCount,
                failure: .identityInvalid
            )
            guard readBack.data == recordBytes else { throw ProbeError.identityInvalid }
        } catch {
            try? unlinkLeaf(
                parentDescriptor: parentDescriptor,
                name: recoverySeedLeafName,
                expectedIdentity: seedIdentity,
                failure: .identityInvalid
            )
            throw error
        }
        try syncDescriptor(parentDescriptor)
        try recheckVisibleParent(
            parent,
            expected: try descriptorIdentity(parentDescriptor),
            expectedMode: 0o700,
            failure: .identityInvalid
        )
        return identityResult(record, operation: "create")
    }

    static func identityRead(configuration: Configuration) throws -> IdentityResult {
        let url = try identityURL(configuration: configuration, createParent: false)
        let record = try readIdentity(
            at: url,
            adversarialCase: configuration.caseID == "case" ? nil : configuration.caseID
        )
        return identityResult(record, operation: "read")
    }

    static func identityUpgrade(configuration: Configuration) throws -> IdentityResult {
        let url = try identityURL(configuration: configuration, createParent: false)
        let parent = url.deletingLastPathComponent()
        let parentDescriptor = try openPrivateParent(parent)
        defer { Darwin.close(parentDescriptor) }
        let currentRead = try readValidatedLeaf(
            parentDescriptor: parentDescriptor,
            name: identityLeafName,
            maximumByteCount: identityMaximumByteCount,
            failure: .identityInvalid
        )
        let current = try decodeAndValidateIdentity(currentRead.data)
        guard current.generation < Int.max else { throw ProbeError.identityInvalid }
        let upgraded = DeviceIdentityRecord(
            magic: current.magic,
            version: current.version,
            generation: current.generation + 1,
            writerEpoch: current.writerEpoch,
            descriptor: current.descriptor,
            descriptorDigest: current.descriptorDigest,
            descriptorPublicKey: current.descriptorPublicKey,
            recipientPublicKey: current.recipientPublicKey,
            descriptorSignature: current.descriptorSignature,
            authorization: current.authorization,
            authorizationSignature: current.authorizationSignature,
            deviceSigningSeed: current.deviceSigningSeed,
            devicePublicKey: current.devicePublicKey
        )
        let restoration = try installIdentityAdversaryIfRequested(
            configuration.caseID == "case" ? nil : configuration.caseID,
            parent: parent,
            parentDescriptor: parentDescriptor,
            leafName: identityLeafName
        )
        defer { restoration?() }
        let upgradedBytes = try canonicalJSON(upgraded)
        _ = try replaceLeaf(
            upgradedBytes,
            parentDescriptor: parentDescriptor,
            name: identityLeafName,
            expectedIdentity: currentRead.identity,
            expectedBytes: currentRead.data,
            maximumByteCount: identityMaximumByteCount,
            failure: .identityInvalid
        )
        let finalRead = try readValidatedLeaf(
            parentDescriptor: parentDescriptor,
            name: identityLeafName,
            maximumByteCount: identityMaximumByteCount,
            failure: .identityInvalid
        )
        guard finalRead.data == upgradedBytes else { throw ProbeError.identityInvalid }
        _ = try decodeAndValidateIdentity(finalRead.data)
        try recheckVisibleParent(
            parent,
            expected: try descriptorIdentity(parentDescriptor),
            expectedMode: 0o700,
            failure: .identityInvalid
        )
        return identityResult(upgraded, operation: "upgrade")
    }

    static func identityURL(
        configuration: Configuration,
        createParent: Bool = false
    ) throws -> URL {
        try configuration.baseDirectory(createIfMissing: createParent).appendingPathComponent(
            "device-identity.json",
            isDirectory: false
        )
    }

    static func recoverySeedURL(
        configuration: Configuration,
        createParent: Bool = false
    ) throws -> URL {
        try configuration.baseDirectory(createIfMissing: createParent).appendingPathComponent(
            "synthetic-recovery-seed.bin",
            isDirectory: false
        )
    }

    static let identityLeafName = "device-identity.json"
    static let recoverySeedLeafName = "synthetic-recovery-seed.bin"
    static let identityMaximumByteCount = 16 * 1_024

    static func readIdentity(
        at url: URL,
        adversarialCase: String? = nil
    ) throws -> DeviceIdentityRecord {
        let parent = url.deletingLastPathComponent()
        guard url.lastPathComponent == identityLeafName else { throw ProbeError.identityInvalid }
        let parentDescriptor = try openPrivateParent(parent)
        defer { Darwin.close(parentDescriptor) }
        let read = try readValidatedLeaf(
            parentDescriptor: parentDescriptor,
            name: identityLeafName,
            maximumByteCount: identityMaximumByteCount,
            failure: .identityInvalid
        )
        let restoration = try installIdentityAdversaryIfRequested(
            adversarialCase,
            parent: parent,
            parentDescriptor: parentDescriptor,
            leafName: identityLeafName
        )
        defer { restoration?() }
        try recheckLeaf(
            parentDescriptor: parentDescriptor,
            name: identityLeafName,
            expectedIdentity: read.identity,
            failure: .identityInvalid
        )
        let record = try decodeAndValidateIdentity(read.data)
        try recheckVisibleParent(
            parent,
            expected: try descriptorIdentity(parentDescriptor),
            expectedMode: 0o700,
            failure: .identityInvalid
        )
        return record
    }

    static func decodeAndValidateIdentity(_ data: Data) throws -> DeviceIdentityRecord {
        guard let record = try? JSONDecoder().decode(DeviceIdentityRecord.self, from: data),
              record.magic == "KLG-U0-DEVICE-IDENTITY-1",
              record.version == 1,
              record.generation > 0,
              record.writerEpoch > 0,
              record.descriptor.magic == "KLG-U0-BACKUP-SET-1",
              record.descriptor.version == 1,
              record.descriptor.suite == "Curve25519-SHA256-ChaChaPoly+AES256-GCM",
              record.descriptor.setID.count == 16,
              record.descriptor.signingPublicKey.count == 32,
              record.descriptor.recipientPublicKey.count == 32,
              record.descriptorPublicKey == record.descriptor.signingPublicKey,
              record.recipientPublicKey == record.descriptor.recipientPublicKey,
              record.descriptorDigest.count == 32,
              record.descriptorSignature.count == 64,
              record.authorization.magic == "KLG-U0-DEVICE-AUTHORIZATION-1",
              record.authorization.version == 1,
              record.authorization.authorizationID.count == 16,
              record.authorization.deviceID.count == 16,
              record.authorization.sequenceFloor > 0,
              record.deviceSigningSeed.count == 32,
              record.devicePublicKey.count == 32,
              (try? canonicalJSON(record)) == data,
              let descriptorBytes = try? canonicalJSON(record.descriptor),
              Data(SHA256.hash(data: descriptorBytes)) == record.descriptorDigest,
              record.authorization.descriptorDigest == record.descriptorDigest,
              record.authorization.devicePublicKey == record.devicePublicKey,
              let signingRoot = try? Curve25519.Signing.PublicKey(
                rawRepresentation: record.descriptorPublicKey
              ),
              signingRoot.isValidSignature(
                record.descriptorSignature,
                for: descriptorBytes
              ),
              let authorizationBytes = try? canonicalJSON(record.authorization),
              signingRoot.isValidSignature(
                record.authorizationSignature,
                for: authorizationBytes
              ),
              (try? Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: record.recipientPublicKey
              )) != nil,
              let signingKey = try? Curve25519.Signing.PrivateKey(
                rawRepresentation: record.deviceSigningSeed
              ),
              signingKey.publicKey.rawRepresentation == record.devicePublicKey else {
            throw ProbeError.identityInvalid
        }
        return record
    }

    static func identityResult(
        _ record: DeviceIdentityRecord,
        operation: String
    ) -> IdentityResult {
        IdentityResult(
            operation: operation,
            generation: record.generation,
            parentMode: 0o700,
            recordMode: 0o600,
            publicIdentity: record.devicePublicKey.base64EncodedString(),
            descriptorDigest: hashHex(record.descriptorDigest)
        )
    }
}

// MARK: - Public-only writer and seed-only recovery profiles

private extension BackupCapabilityProbe {
    struct SyntheticCheckpointHeader: Codable {
        let magic: String
        let version: Int
        let checkpointID: Data
        let publicSequence: UInt64
        let descriptorDigest: Data
        let authorizationDigest: Data
        let plaintextByteCount: Int
    }

    struct SyntheticCheckpointCommitmentRecord: Codable {
        let header: SyntheticCheckpointHeader
        let descriptor: SyntheticDescriptor
        let descriptorSignature: Data
        let authorization: SyntheticAuthorization
        let authorizationSignature: Data
        let encapsulatedKey: Data
        let wrappedDEK: Data
        let bulkNonce: Data
        let ciphertext: Data
        let tag: Data
    }

    struct SyntheticCheckpoint: Codable {
        let header: SyntheticCheckpointHeader
        let descriptor: SyntheticDescriptor
        let descriptorSignature: Data
        let authorization: SyntheticAuthorization
        let authorizationSignature: Data
        let encapsulatedKey: Data
        let wrappedDEK: Data
        let bulkNonce: Data
        let ciphertext: Data
        let tag: Data
        let ciphertextCommitment: Data
        let deviceSignature: Data
    }

    struct PublicWriterResult: Encodable {
        let category = "publicOnlyWriter"
        let status = "passed"
        let suite = "Curve25519-SHA256-ChaChaPoly+AES256-GCM"
        let publicOnlyEncrypted: Bool
        let profileContainedRecoveryMaterial: Bool
        let checkpointDigest: String
    }

    struct SeedOnlyRecoveryResult: Encodable {
        let category = "seedOnlyRecovery"
        let status = "passed"
        let seedOnlyRecovered: Bool
        let rootSignatureVerified: Bool
        let deviceSignatureVerified: Bool
        let reenrollmentVerified: Bool
        let checkpointDigest: String
    }

    static func cryptoPublicWriter(configuration: Configuration) throws -> PublicWriterResult {
        let identity = try readIdentity(at: identityURL(configuration: configuration))
        let seedURL = try recoverySeedURL(configuration: configuration)
        let profileContainedRecoveryMaterial = pathExists(seedURL)
        guard !profileContainedRecoveryMaterial else {
            throw ProbeError.cryptoProfileInvalid
        }
        let descriptorBytes = try canonicalJSON(identity.descriptor)
        let authorizationBytes = try canonicalJSON(identity.authorization)
        let checkpointID = try randomData(byteCount: 16)
        let header = SyntheticCheckpointHeader(
            magic: "KLG-U0-SYNTHETIC-CHECKPOINT-1",
            version: 1,
            checkpointID: checkpointID,
            publicSequence: identity.authorization.sequenceFloor,
            descriptorDigest: identity.descriptorDigest,
            authorizationDigest: Data(SHA256.hash(data: authorizationBytes)),
            plaintextByteCount: selectedChunkByteCount
        )
        let headerBytes = try canonicalJSON(header)
        let info = Data("com.kinlogue.backup.v1.hpke-dek-envelope".utf8)
            + descriptorBytes + headerBytes
        let aad = Data(SHA256.hash(data: authorizationBytes + headerBytes))
        let recipientPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: identity.recipientPublicKey
        )
        let dekBytes = try randomData(byteCount: 32)
        var sender = try HPKE.Sender(
            recipientKey: recipientPublicKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info
        )
        let wrappedDEK = try sender.seal(dekBytes, authenticating: aad)
        let payload = syntheticPayload()
        let bulkNonce = AES.GCM.Nonce()
        let bulk = try AES.GCM.seal(
            payload,
            using: SymmetricKey(data: dekBytes),
            nonce: bulkNonce,
            authenticating: headerBytes + descriptorBytes
        )
        let nonceData = bulkNonce.withUnsafeBytes { Data($0) }
        let commitmentRecord = SyntheticCheckpointCommitmentRecord(
            header: header,
            descriptor: identity.descriptor,
            descriptorSignature: identity.descriptorSignature,
            authorization: identity.authorization,
            authorizationSignature: identity.authorizationSignature,
            encapsulatedKey: sender.encapsulatedKey,
            wrappedDEK: wrappedDEK,
            bulkNonce: nonceData,
            ciphertext: bulk.ciphertext,
            tag: bulk.tag
        )
        let commitment = try checkpointCommitment(commitmentRecord)
        let deviceSigner = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.deviceSigningSeed
        )
        let deviceSignature = try deviceSigner.signature(
            for: checkpointSignatureInput(commitment)
        )
        let checkpoint = SyntheticCheckpoint(
            header: header,
            descriptor: identity.descriptor,
            descriptorSignature: identity.descriptorSignature,
            authorization: identity.authorization,
            authorizationSignature: identity.authorizationSignature,
            encapsulatedKey: sender.encapsulatedKey,
            wrappedDEK: wrappedDEK,
            bulkNonce: nonceData,
            ciphertext: bulk.ciphertext,
            tag: bulk.tag,
            ciphertextCommitment: commitment,
            deviceSignature: deviceSignature
        )
        let checkpointBytes = try canonicalJSON(checkpoint)
        guard checkpointBytes.count <= 512 * 1_024 else { throw ProbeError.resourceLimit }
        try writeExclusivePrivateFile(
            checkpointBytes,
            to: try checkpointURL(configuration: configuration)
        )
        return PublicWriterResult(
            publicOnlyEncrypted: !wrappedDEK.isEmpty && bulk.ciphertext.count == payload.count,
            profileContainedRecoveryMaterial: profileContainedRecoveryMaterial,
            checkpointDigest: hashHex(Data(SHA256.hash(data: checkpointBytes)))
        )
    }

    static func cryptoPublicDecrypt(configuration: Configuration) throws -> SimpleResult {
        _ = try readCheckpoint(configuration: configuration)
        guard pathExists(try recoverySeedURL(configuration: configuration)) else {
            throw ProbeError.recoveryMaterialUnavailable
        }
        throw ProbeError.cryptoProfileInvalid
    }

    static func cryptoSeedRecover(configuration: Configuration) throws -> SeedOnlyRecoveryResult {
        guard !pathExists(try identityURL(configuration: configuration)),
              !pathExists(try bookmarkURL(configuration: configuration)) else {
            throw ProbeError.cryptoProfileInvalid
        }
        let recoverySeed: Data
        do {
            recoverySeed = try readPrivateFile(
                try recoverySeedURL(configuration: configuration),
                maximumByteCount: 32
            )
        } catch {
            throw ProbeError.recoveryMaterialUnavailable
        }
        guard recoverySeed.count == 32 else { throw ProbeError.cryptoProfileInvalid }
        let (checkpoint, checkpointBytes) = try readCheckpoint(configuration: configuration)
        let descriptorBytes = try canonicalJSON(checkpoint.descriptor)
        let authorizationBytes = try canonicalJSON(checkpoint.authorization)
        let headerBytes = try canonicalJSON(checkpoint.header)
        let cleanSigningRoot = try Curve25519.Signing.PrivateKey(
            rawRepresentation: derivedSeed(
                recoverySeed,
                setID: checkpoint.descriptor.setID,
                role: "signing-root"
            )
        )
        let cleanRecipientRoot = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: derivedSeed(
                recoverySeed,
                setID: checkpoint.descriptor.setID,
                role: "hpke-root"
            )
        )
        let rootSignatureVerified = cleanSigningRoot.publicKey.isValidSignature(
            checkpoint.descriptorSignature,
            for: descriptorBytes
        ) && cleanSigningRoot.publicKey.isValidSignature(
            checkpoint.authorizationSignature,
            for: authorizationBytes
        )
        let commitmentRecord = SyntheticCheckpointCommitmentRecord(
            header: checkpoint.header,
            descriptor: checkpoint.descriptor,
            descriptorSignature: checkpoint.descriptorSignature,
            authorization: checkpoint.authorization,
            authorizationSignature: checkpoint.authorizationSignature,
            encapsulatedKey: checkpoint.encapsulatedKey,
            wrappedDEK: checkpoint.wrappedDEK,
            bulkNonce: checkpoint.bulkNonce,
            ciphertext: checkpoint.ciphertext,
            tag: checkpoint.tag
        )
        let expectedCommitment = try checkpointCommitment(commitmentRecord)
        let authorizedDeviceKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: checkpoint.authorization.devicePublicKey
        )
        let deviceSignatureVerified = authorizedDeviceKey.isValidSignature(
            checkpoint.deviceSignature,
            for: checkpointSignatureInput(expectedCommitment)
        )
        guard checkpoint.descriptor.signingPublicKey
                == cleanSigningRoot.publicKey.rawRepresentation,
              checkpoint.descriptor.recipientPublicKey
                == cleanRecipientRoot.publicKey.rawRepresentation,
              checkpoint.ciphertextCommitment == expectedCommitment,
              rootSignatureVerified,
              deviceSignatureVerified else {
            throw ProbeError.cryptoProfileInvalid
        }
        let info = Data("com.kinlogue.backup.v1.hpke-dek-envelope".utf8)
            + descriptorBytes + headerBytes
        let aad = Data(SHA256.hash(data: authorizationBytes + headerBytes))
        var recipient = try HPKE.Recipient(
            privateKey: cleanRecipientRoot,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info,
            encapsulatedKey: checkpoint.encapsulatedKey
        )
        let recoveredDEK: Data
        let recoveredPayload: Data
        do {
            recoveredDEK = try recipient.open(checkpoint.wrappedDEK, authenticating: aad)
            let combined = checkpoint.bulkNonce + checkpoint.ciphertext + checkpoint.tag
            recoveredPayload = try AES.GCM.open(
                AES.GCM.SealedBox(combined: combined),
                using: SymmetricKey(data: recoveredDEK),
                authenticating: headerBytes + descriptorBytes
            )
        } catch {
            throw ProbeError.cryptoProfileInvalid
        }
        let nextSequence = checkpoint.header.publicSequence.addingReportingOverflow(1)
        guard !nextSequence.overflow else { throw ProbeError.cryptoProfileInvalid }
        let replacementDevice = Curve25519.Signing.PrivateKey()
        let replacementAuthorization = SyntheticAuthorization(
            magic: checkpoint.authorization.magic,
            version: checkpoint.authorization.version,
            descriptorDigest: checkpoint.authorization.descriptorDigest,
            authorizationID: try randomData(byteCount: 16),
            deviceID: try randomData(byteCount: 16),
            devicePublicKey: replacementDevice.publicKey.rawRepresentation,
            sequenceFloor: nextSequence.partialValue
        )
        let replacementBytes = try canonicalJSON(replacementAuthorization)
        let replacementSignature = try cleanSigningRoot.signature(for: replacementBytes)
        let reenrollmentVerified = cleanSigningRoot.publicKey.isValidSignature(
            replacementSignature,
            for: replacementBytes
        )
        let seedOnlyRecovered = recoveredDEK.count == 32
            && recoveredPayload == syntheticPayload()
        guard seedOnlyRecovered,
              reenrollmentVerified else {
            throw ProbeError.cryptoProfileInvalid
        }
        return SeedOnlyRecoveryResult(
            seedOnlyRecovered: seedOnlyRecovered,
            rootSignatureVerified: rootSignatureVerified,
            deviceSignatureVerified: deviceSignatureVerified,
            reenrollmentVerified: reenrollmentVerified,
            checkpointDigest: hashHex(Data(SHA256.hash(data: checkpointBytes)))
        )
    }

    static func checkpointURL(configuration: Configuration) throws -> URL {
        try configuration.baseDirectory().appendingPathComponent(
            "synthetic-checkpoint.json",
            isDirectory: false
        )
    }

    static func readCheckpoint(
        configuration: Configuration
    ) throws -> (SyntheticCheckpoint, Data) {
        do {
            let data = try readPrivateFile(
                try checkpointURL(configuration: configuration),
                maximumByteCount: 512 * 1_024
            )
            let checkpoint = try JSONDecoder().decode(SyntheticCheckpoint.self, from: data)
            let descriptorBytes = try canonicalJSON(checkpoint.descriptor)
            let authorizationBytes = try canonicalJSON(checkpoint.authorization)
            guard try canonicalJSON(checkpoint) == data,
                  checkpoint.header.magic == "KLG-U0-SYNTHETIC-CHECKPOINT-1",
                  checkpoint.header.version == 1,
                  checkpoint.header.checkpointID.count == 16,
                  checkpoint.header.publicSequence >= checkpoint.authorization.sequenceFloor,
                  checkpoint.header.plaintextByteCount == selectedChunkByteCount,
                  checkpoint.descriptor.magic == "KLG-U0-BACKUP-SET-1",
                  checkpoint.descriptor.version == 1,
                  checkpoint.descriptor.suite
                    == "Curve25519-SHA256-ChaChaPoly+AES256-GCM",
                  checkpoint.descriptor.setID.count == 16,
                  checkpoint.descriptor.signingPublicKey.count == 32,
                  checkpoint.descriptor.recipientPublicKey.count == 32,
                  checkpoint.descriptorSignature.count == 64,
                  checkpoint.authorization.magic == "KLG-U0-DEVICE-AUTHORIZATION-1",
                  checkpoint.authorization.version == 1,
                  checkpoint.authorization.authorizationID.count == 16,
                  checkpoint.authorization.deviceID.count == 16,
                  checkpoint.authorization.devicePublicKey.count == 32,
                  checkpoint.authorizationSignature.count == 64,
                  checkpoint.encapsulatedKey.count == 32,
                  checkpoint.wrappedDEK.count == 48,
                  checkpoint.bulkNonce.count == 12,
                  checkpoint.ciphertext.count == selectedChunkByteCount,
                  checkpoint.tag.count == 16,
                  checkpoint.ciphertextCommitment.count == 32,
                  checkpoint.deviceSignature.count == 64,
                  checkpoint.header.descriptorDigest
                    == Data(SHA256.hash(data: descriptorBytes)),
                  checkpoint.authorization.descriptorDigest
                    == checkpoint.header.descriptorDigest,
                  checkpoint.header.authorizationDigest
                    == Data(SHA256.hash(data: authorizationBytes)) else {
                throw ProbeError.cryptoProfileInvalid
            }
            return (checkpoint, data)
        } catch let error as ProbeError {
            if case .resourceLimit = error { throw error }
            throw ProbeError.cryptoProfileInvalid
        } catch {
            throw ProbeError.cryptoProfileInvalid
        }
    }

    static func checkpointCommitment(
        _ record: SyntheticCheckpointCommitmentRecord
    ) throws -> Data {
        var bytes = Data("com.kinlogue.backup.v1.ciphertext-commitment".utf8)
        bytes.append(try canonicalJSON(record))
        return Data(SHA256.hash(data: bytes))
    }

    static func checkpointSignatureInput(_ commitment: Data) -> Data {
        Data("com.kinlogue.backup.v1.device-commit".utf8) + commitment
    }

    static func syntheticPayload() -> Data {
        Data((0..<selectedChunkByteCount).map {
            UInt8(truncatingIfNeeded: ($0 &* 31) &+ 7)
        })
    }

    static func randomData(byteCount: Int) throws -> Data {
        guard byteCount > 0, byteCount <= 32 else { throw ProbeError.resourceLimit }
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return Data(bytes.prefix(byteCount))
    }

    static func hashHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func derivedSeed(_ seed: Data, setID: Data, role: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: seed),
            salt: setID,
            info: Data("com.kinlogue.backup.v1.\(role)".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Repository publication and capacity

private extension BackupCapabilityProbe {
    static let maximumSourceObjectCount = 20_000
    static let maximumSourceByteCount: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let backupFormatAllowanceByteCount: Int64 = 64 * 1_024 * 1_024
    static let capacityHeadroomByteCount: Int64 = 256 * 1_024 * 1_024

    struct RepositoryResult: Encodable {
        let category = "repositoryPublication"
        let status = "passed"
        let nonSuccessWorkName: Bool
        let exclusiveNonOverwrite: Bool
        let finalIdentityReadBack: Bool
        let parentSynced: Bool
        let coordinatedPublication: Bool
        let plaintextCanaryAbsent: Bool
        let maximumSourceObjectCount: Int
        let maximumSourceByteCount: Int64
        let targetRequiredByteCount: Int64
        let privateRestoreRequiredByteCount: Int64
        let availableCapacitySufficient: Bool
        let publicationDurationMilliseconds: Int
    }

    struct SelectedTargetRepositoryResult: Encodable {
        let category = "selectedTargetPublication"
        let status = "passed"
        let targetCategory = "ordinaryDirectory"
        let testBookmarkSeam: Bool
        let securityScopeStarted: Bool
        let coordinatedPublication: Bool
        let selectedIdentityMatched: Bool
        let repositoryIdentityMatched: Bool
        let nonSuccessWorkName: Bool
        let exclusiveNonOverwrite: Bool
        let finalIdentityReadBack: Bool
        let parentSynced: Bool
        let plaintextCanaryAbsent: Bool
        let targetRequiredByteCount: Int64
        let privateRestoreRequiredByteCount: Int64
        let targetAvailableCapacityByteCount: Int64
        let privateRestoreAvailableCapacityByteCount: Int64
        let targetAvailableCapacitySufficient: Bool
        let privateRestoreAvailableCapacitySufficient: Bool
        let publicationDurationMilliseconds: Int
    }

    struct SelectedPublicationMeasurement {
        let testBookmarkSeam: Bool
        let securityScopeStarted: Bool
        let coordinatedPublication: Bool
        let targetAvailableCapacityByteCount: Int64
        let privateRestoreAvailableCapacityByteCount: Int64
        let durationMilliseconds: Int
    }

    static func repositoryPublicationProbe(
        configuration: Configuration
    ) throws -> RepositoryResult {
        let repository = try configuration.baseDirectory().appendingPathComponent(
            "repository",
            isDirectory: true
        )
        try ensureOwnedDirectory(repository)
        let selectedDescriptor = try openRepositoryParent(repository)
        defer { Darwin.close(selectedDescriptor) }
        let repositoryIdentity = try descriptorIdentity(selectedDescriptor)
        let workName = ".u0-checkpoint.opaque-work"
        let finalName = "u0-checkpoint.kinloguebackup"

        let targetRequired = try checkedAdd(
            try checkedAdd(maximumSourceByteCount, backupFormatAllowanceByteCount),
            capacityHeadroomByteCount
        )
        let tripleSource = try checkedMultiply(maximumSourceByteCount, 3)
        let privateRestoreRequired = try checkedAdd(
            tripleSource,
            capacityHeadroomByteCount
        )
        let available = try availableCapacityByteCount(descriptor: selectedDescriptor)
        guard available >= targetRequired,
              available >= privateRestoreRequired else {
            throw ProbeError.capacityInsufficient
        }

        let plaintextCanary = Data("KLG-U0-REPOSITORY-PLAINTEXT-CANARY".utf8)
        let key = SymmetricKey(data: Data(repeating: 0x72, count: 32))
        let nonceData = Data(repeating: 0x19, count: 12)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(
            plaintextCanary,
            using: key,
            nonce: nonce,
            authenticating: Data("KLG-U0-REPOSITORY-AAD".utf8)
        )
        var opaqueBytes = nonceData
        opaqueBytes.append(sealed.ciphertext)
        opaqueBytes.append(sealed.tag)
        let started = DispatchTime.now().uptimeNanoseconds
        let coordinatedPublication = configuration.workingDirectory == nil
        if coordinatedPublication {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var publicationError: Error?
            coordinator.coordinate(
                writingItemAt: repository,
                options: [],
                error: &coordinationError
            ) { coordinatedRepository in
                do {
                    let coordinatedDescriptor = try openRepositoryParent(coordinatedRepository)
                    defer { Darwin.close(coordinatedDescriptor) }
                    guard try descriptorIdentity(coordinatedDescriptor) == repositoryIdentity else {
                        throw ProbeError.repositoryInvalid
                    }
                    try performRepositoryPublication(
                        parentDescriptor: coordinatedDescriptor,
                        workName: workName,
                        finalName: finalName,
                        opaqueBytes: opaqueBytes,
                        plaintextCanary: plaintextCanary,
                        adversarialCase: configuration.caseID == "case"
                            ? nil
                            : configuration.caseID,
                        visibleParent: coordinatedRepository
                    )
                } catch {
                    publicationError = error
                }
            }
            if coordinationError != nil { throw ProbeError.repositoryInvalid }
            if let publicationError { throw publicationError }
        } else {
            // Unsandboxed SwiftPM processes do not have a Powerbox coordination
            // purpose and macOS rejects their temporary URLs. Installed evidence
            // exercises the coordinated branch; unit tests still exercise the
            // exact no-follow/exclusive publication primitive used inside it.
            guard try descriptorIdentity(selectedDescriptor) == repositoryIdentity else {
                throw ProbeError.repositoryInvalid
            }
            try performRepositoryPublication(
                parentDescriptor: selectedDescriptor,
                workName: workName,
                finalName: finalName,
                opaqueBytes: opaqueBytes,
                plaintextCanary: plaintextCanary,
                adversarialCase: configuration.caseID == "case" ? nil : configuration.caseID,
                visibleParent: repository
            )
        }
        try recheckVisibleParent(repository, expected: repositoryIdentity, failure: .repositoryInvalid)
        let duration = Int(
            (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        )
        return RepositoryResult(
            nonSuccessWorkName: !workName.hasSuffix(".kinloguebackup"),
            exclusiveNonOverwrite: true,
            finalIdentityReadBack: true,
            parentSynced: true,
            coordinatedPublication: coordinatedPublication,
            plaintextCanaryAbsent: true,
            maximumSourceObjectCount: maximumSourceObjectCount,
            maximumSourceByteCount: maximumSourceByteCount,
            targetRequiredByteCount: targetRequired,
            privateRestoreRequiredByteCount: privateRestoreRequired,
            availableCapacitySufficient: true,
            publicationDurationMilliseconds: duration
        )
    }

    static func selectedTargetPublicationProbe(
        configuration: Configuration
    ) throws -> SelectedTargetRepositoryResult {
        let targetRequired = try checkedAdd(
            try checkedAdd(maximumSourceByteCount, backupFormatAllowanceByteCount),
            capacityHeadroomByteCount
        )
        let privateRestoreRequired = try checkedAdd(
            try checkedMultiply(maximumSourceByteCount, 3),
            capacityHeadroomByteCount
        )
        let privateDirectory = try configuration.baseDirectory()
        let privateDescriptor = try openPrivateParent(privateDirectory)
        defer { Darwin.close(privateDescriptor) }
        let privateAvailable = try availableCapacityByteCount(descriptor: privateDescriptor)
        guard privateAvailable >= privateRestoreRequired else {
            throw ProbeError.capacityInsufficient
        }

        let plaintextCanary = Data("KLG-U0-SELECTED-TARGET-PLAINTEXT-CANARY".utf8)
        let key = SymmetricKey(data: Data(repeating: 0x73, count: 32))
        let nonceData = Data(repeating: 0x29, count: 12)
        let sealed = try AES.GCM.seal(
            plaintextCanary,
            using: key,
            nonce: try AES.GCM.Nonce(data: nonceData),
            authenticating: Data("KLG-U0-SELECTED-TARGET-AAD".utf8)
        )
        var opaqueBytes = nonceData
        opaqueBytes.append(sealed.ciphertext)
        opaqueBytes.append(sealed.tag)
        let workName = ".u0-\(configuration.caseID).opaque-work"
        let finalName = "u0-\(configuration.caseID).kinloguebackup"
        let adversarialCase = ["parent-replacement", "final-replacement"]
            .contains(configuration.caseID) ? configuration.caseID : nil
        let started = DispatchTime.now().uptimeNanoseconds

        let measurement = try withResolvedSelectedDirectory(configuration: configuration) {
            selected, initialRecord, scopeStarted, testBookmarkSeam in
            var record = initialRecord
            let coordinatedPublication = !testBookmarkSeam

            func publish(at coordinatedSelected: URL) throws -> Int64 {
                let selectedDescriptor = try openRepositoryParent(coordinatedSelected)
                defer { Darwin.close(selectedDescriptor) }
                guard try descriptorIdentity(selectedDescriptor) == record.selectedIdentity else {
                    throw ProbeError.bookmarkInvalid
                }
                try recheckVisibleParent(
                    coordinatedSelected,
                    expected: record.selectedIdentity,
                    failure: .bookmarkInvalid
                )

                let repository = try openOrCreateSelectedRepository(
                    selectedParentDescriptor: selectedDescriptor,
                    expectedIdentity: record.repositoryIdentity
                )
                defer { Darwin.close(repository.descriptor) }
                if repository.created {
                    let updated = BookmarkRecord(
                        magic: record.magic,
                        version: record.version,
                        bookmarkData: record.bookmarkData,
                        selectedIdentity: record.selectedIdentity,
                        repositoryIdentity: repository.identity
                    )
                    do {
                        try writeBookmarkRecord(updated, configuration: configuration)
                        record = updated
                    } catch {
                        // The newly-created empty directory is intentionally left in place.
                        // Without the durable app-private identity record, a later process
                        // must not infer ownership or delete the visible name.
                        throw error
                    }
                }
                guard record.repositoryIdentity == repository.identity else {
                    throw ProbeError.repositoryInvalid
                }
                try recheckDirectoryLeaf(
                    parentDescriptor: selectedDescriptor,
                    name: selectedRepositoryLeafName,
                    expectedIdentity: repository.identity,
                    failure: .repositoryInvalid
                )
                let coordinatedRepository = coordinatedSelected.appendingPathComponent(
                    selectedRepositoryLeafName,
                    isDirectory: true
                )
                try recheckVisibleParent(
                    coordinatedRepository,
                    expected: repository.identity,
                    expectedMode: 0o700,
                    failure: .repositoryInvalid
                )
                let targetAvailable = try availableCapacityByteCount(
                    descriptor: repository.descriptor
                )
                guard targetAvailable >= targetRequired else {
                    throw ProbeError.capacityInsufficient
                }
                try performRepositoryPublication(
                    parentDescriptor: repository.descriptor,
                    workName: workName,
                    finalName: finalName,
                    opaqueBytes: opaqueBytes,
                    plaintextCanary: plaintextCanary,
                    adversarialCase: adversarialCase,
                    visibleParent: coordinatedRepository
                )
                try recheckDirectoryLeaf(
                    parentDescriptor: selectedDescriptor,
                    name: selectedRepositoryLeafName,
                    expectedIdentity: repository.identity,
                    failure: .repositoryInvalid
                )
                try recheckVisibleParent(
                    coordinatedSelected,
                    expected: record.selectedIdentity,
                    failure: .bookmarkInvalid
                )
                return targetAvailable
            }

            let targetAvailable: Int64
            if coordinatedPublication {
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinationError: NSError?
                var callbackResult: Result<Int64, Error>?
                coordinator.coordinate(
                    writingItemAt: selected,
                    options: [],
                    error: &coordinationError
                ) { coordinatedSelected in
                    callbackResult = Result { try publish(at: coordinatedSelected) }
                }
                guard coordinationError == nil, let callbackResult else {
                    throw ProbeError.repositoryInvalid
                }
                targetAvailable = try callbackResult.get()
            } else {
                targetAvailable = try publish(at: selected)
            }
            try recheckVisibleParent(
                selected,
                expected: record.selectedIdentity,
                failure: .bookmarkInvalid
            )
            return SelectedPublicationMeasurement(
                testBookmarkSeam: testBookmarkSeam,
                securityScopeStarted: scopeStarted,
                coordinatedPublication: coordinatedPublication,
                targetAvailableCapacityByteCount: targetAvailable,
                privateRestoreAvailableCapacityByteCount: privateAvailable,
                durationMilliseconds: Int(
                    (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                )
            )
        }

        return SelectedTargetRepositoryResult(
            testBookmarkSeam: measurement.testBookmarkSeam,
            securityScopeStarted: measurement.securityScopeStarted,
            coordinatedPublication: measurement.coordinatedPublication,
            selectedIdentityMatched: true,
            repositoryIdentityMatched: true,
            nonSuccessWorkName: !workName.hasSuffix(".kinloguebackup"),
            exclusiveNonOverwrite: true,
            finalIdentityReadBack: true,
            parentSynced: true,
            plaintextCanaryAbsent: true,
            targetRequiredByteCount: targetRequired,
            privateRestoreRequiredByteCount: privateRestoreRequired,
            targetAvailableCapacityByteCount: measurement.targetAvailableCapacityByteCount,
            privateRestoreAvailableCapacityByteCount:
                measurement.privateRestoreAvailableCapacityByteCount,
            targetAvailableCapacitySufficient: true,
            privateRestoreAvailableCapacitySufficient: true,
            publicationDurationMilliseconds: measurement.durationMilliseconds
        )
    }

    static func performRepositoryPublication(
        parentDescriptor: Int32,
        workName: String,
        finalName: String,
        opaqueBytes: Data,
        plaintextCanary: Data,
        adversarialCase: String?,
        visibleParent: URL
    ) throws {
        guard try leafIsAbsent(parentDescriptor, name: workName),
              try leafIsAbsent(parentDescriptor, name: finalName) else {
            throw ProbeError.repositoryInvalid
        }
        let workIdentity = try writeExclusiveLeaf(
            opaqueBytes,
            parentDescriptor: parentDescriptor,
            name: workName,
            failure: .repositoryInvalid
        )
        var ownedWorkIdentity: RegularLeafIdentity? = workIdentity
        defer {
            if let ownedWorkIdentity {
                removeExactLeafIfPresent(
                    parentDescriptor: parentDescriptor,
                    name: workName,
                    expectedIdentity: ownedWorkIdentity
                )
            }
        }
        let parentRestoration: (() -> Void)?
        if adversarialCase == "parent-replacement" {
            parentRestoration = try installParentReplacement(at: visibleParent)
        } else {
            parentRestoration = nil
        }
        defer { parentRestoration?() }

        try recheckVisibleParent(
            visibleParent,
            expected: try descriptorIdentity(parentDescriptor),
            failure: .repositoryInvalid
        )

        guard renameatx_np(
            parentDescriptor,
            workName,
            parentDescriptor,
            finalName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw ProbeError.repositoryInvalid
        }
        ownedWorkIdentity = nil
        try syncDescriptor(parentDescriptor)
        let finalRestoration: (() -> Void)?
        if adversarialCase == "final-replacement" {
            finalRestoration = try installLeafReplacement(
                parentDescriptor: parentDescriptor,
                leafName: finalName,
                failure: .repositoryInvalid
            )
        } else {
            finalRestoration = nil
        }
        defer { finalRestoration?() }

        let readBack = try readValidatedLeaf(
            parentDescriptor: parentDescriptor,
            name: finalName,
            maximumByteCount: 4 * 1_024,
            failure: .repositoryInvalid
        )
        guard readBack.data == opaqueBytes,
              readBack.data.range(of: plaintextCanary) == nil else {
            throw ProbeError.repositoryInvalid
        }
        let exclusiveDescriptor = openat(
            parentDescriptor,
            finalName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard exclusiveDescriptor < 0, errno == EEXIST else {
            if exclusiveDescriptor >= 0 { Darwin.close(exclusiveDescriptor) }
            throw ProbeError.repositoryInvalid
        }
        try recheckVisibleParent(
            visibleParent,
            expected: try descriptorIdentity(parentDescriptor),
            failure: .repositoryInvalid
        )
    }
}

// MARK: - Security-scoped bookmark

private extension BackupCapabilityProbe {
    static let selectedRepositoryLeafName = ".kinlogue-backup-capability-u0"
    static let maximumBookmarkRecordByteCount = 128 * 1_024

    struct BookmarkRecord: Codable {
        let magic: String
        let version: Int
        let bookmarkData: Data
        let selectedIdentity: DirectoryIdentity
        let repositoryIdentity: DirectoryIdentity?
    }

    struct BookmarkResult: Encodable {
        let category = "bookmark"
        let operation: String
        let status: String
        let stale: Bool?
        let scopeStarted: Bool?
        let refreshed: Bool?
    }

    static func bookmarkCreate(configuration: Configuration) async throws -> BookmarkResult {
        guard let candidate = configuration.candidateDirectory else {
            throw ProbeError.invalidArguments
        }
        let selected: URL? = await MainActor.run {
            let application = NSApplication.shared
            guard application.setActivationPolicy(.regular) else { return nil }
            application.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.directoryURL = candidate
            panel.prompt = "Choose"
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }
        guard let selected else { throw ProbeError.bookmarkCancelled }
        guard selected.resolvingSymlinksInPath().standardizedFileURL
                == candidate.resolvingSymlinksInPath().standardizedFileURL else {
            throw ProbeError.bookmarkSelectionMismatch
        }
        let expectedIdentity = try directoryIdentity(selected)
        let data: Data
        do {
            data = try selected.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw ProbeError.bookmarkDataUnavailable
        }
        let record = BookmarkRecord(
            magic: "KLG-U0-BOOKMARK-1",
            version: 1,
            bookmarkData: data,
            selectedIdentity: expectedIdentity,
            repositoryIdentity: nil
        )
        guard !pathExists(try bookmarkURL(configuration: configuration)) else {
            throw ProbeError.bookmarkRecordCollision
        }
        try writeBookmarkRecord(record, configuration: configuration)
        return BookmarkResult(
            operation: "create",
            status: "passed",
            stale: nil,
            scopeStarted: nil,
            refreshed: nil
        )
    }

    static func bookmarkResolve(configuration: Configuration) throws -> BookmarkResult {
        var record = try readBookmarkRecord(configuration: configuration)
        guard !record.bookmarkData.isEmpty else { throw ProbeError.bookmarkInvalid }
        var bookmarkDataIsStale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: record.bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkDataIsStale
            )
        } catch {
            throw ProbeError.bookmarkInvalid
        }
        guard resolved.startAccessingSecurityScopedResource() else {
            throw ProbeError.scopeUnavailable
        }
        defer { resolved.stopAccessingSecurityScopedResource() }
        guard (try? directoryIdentity(resolved)) == record.selectedIdentity else {
            throw ProbeError.bookmarkInvalid
        }
        let descriptor = Darwin.open(
            resolved.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw ProbeError.ioFailure(errno) }
        Darwin.close(descriptor)

        var refreshed = false
        if bookmarkDataIsStale && configuration.refreshStaleBookmark {
            let replacement: Data
            do {
                replacement = try resolved.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                throw ProbeError.bookmarkInvalid
            }
            record = BookmarkRecord(
                magic: record.magic,
                version: record.version,
                bookmarkData: replacement,
                selectedIdentity: record.selectedIdentity,
                repositoryIdentity: record.repositoryIdentity
            )
            try writeBookmarkRecord(record, configuration: configuration)
            refreshed = true
        }
        return BookmarkResult(
            operation: "resolve",
            status: "passed",
            stale: bookmarkDataIsStale,
            scopeStarted: true,
            refreshed: refreshed
        )
    }

    static func bookmarkURL(configuration: Configuration) throws -> URL {
        try configuration.baseDirectory().appendingPathComponent(
            "directory.bookmark",
            isDirectory: false
        )
    }

    static func readBookmarkRecord(configuration: Configuration) throws -> BookmarkRecord {
        do {
            let data = try readPrivateFile(
                try bookmarkURL(configuration: configuration),
                maximumByteCount: maximumBookmarkRecordByteCount
            )
            let record = try JSONDecoder().decode(BookmarkRecord.self, from: data)
            guard record.magic == "KLG-U0-BOOKMARK-1",
                  record.version == 1,
                  try canonicalJSON(record) == data else {
                throw ProbeError.bookmarkInvalid
            }
            return record
        } catch let error as ProbeError where error.code == ProbeError.bookmarkInvalid.code {
            throw error
        } catch {
            throw ProbeError.bookmarkInvalid
        }
    }

    static func writeBookmarkRecord(
        _ record: BookmarkRecord,
        configuration: Configuration
    ) throws {
        let bytes = try canonicalJSON(record)
        guard bytes.count <= maximumBookmarkRecordByteCount else {
            throw ProbeError.bookmarkInvalid
        }
        try writePrivateFile(bytes, to: try bookmarkURL(configuration: configuration))
    }

    static func withResolvedSelectedDirectory<Value>(
        configuration: Configuration,
        _ body: (
            _ selected: URL,
            _ record: BookmarkRecord,
            _ securityScopeStarted: Bool,
            _ testBookmarkSeam: Bool
        ) throws -> Value
    ) throws -> Value {
        if configuration.workingDirectory != nil {
            guard let candidate = configuration.candidateDirectory else {
                throw ProbeError.invalidArguments
            }
            let identity: DirectoryIdentity
            do {
                identity = try directoryIdentity(candidate)
            } catch {
                throw ProbeError.bookmarkInvalid
            }
            let record: BookmarkRecord
            if pathExists(try bookmarkURL(configuration: configuration)) {
                record = try readBookmarkRecord(configuration: configuration)
                guard record.bookmarkData.isEmpty,
                      record.selectedIdentity == identity else {
                    throw ProbeError.bookmarkInvalid
                }
            } else {
                record = BookmarkRecord(
                    magic: "KLG-U0-BOOKMARK-1",
                    version: 1,
                    bookmarkData: Data(),
                    selectedIdentity: identity,
                    repositoryIdentity: nil
                )
                try writeBookmarkRecord(record, configuration: configuration)
            }
            return try body(candidate, record, false, true)
        }

        var record = try readBookmarkRecord(configuration: configuration)
        guard !record.bookmarkData.isEmpty else { throw ProbeError.bookmarkInvalid }
        var stale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: record.bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw ProbeError.bookmarkInvalid
        }
        guard resolved.startAccessingSecurityScopedResource() else {
            throw ProbeError.scopeUnavailable
        }
        defer { resolved.stopAccessingSecurityScopedResource() }
        guard (try? directoryIdentity(resolved)) == record.selectedIdentity else {
            throw ProbeError.bookmarkInvalid
        }
        if stale {
            guard configuration.refreshStaleBookmark else {
                throw ProbeError.bookmarkInvalid
            }
            let replacement: Data
            do {
                replacement = try resolved.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                throw ProbeError.bookmarkInvalid
            }
            record = BookmarkRecord(
                magic: record.magic,
                version: record.version,
                bookmarkData: replacement,
                selectedIdentity: record.selectedIdentity,
                repositoryIdentity: record.repositoryIdentity
            )
            try writeBookmarkRecord(record, configuration: configuration)
        }
        return try body(resolved, record, true, false)
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

    struct RootSemanticIdentity: Codable, Equatable {
        let state: RootState
        let vaultID: UUID
        let vaultGeneration: UInt64
        let vaultCommitID: UUID
        let vaultCatalogDigest: Data
        let vaultObjectCount: Int
        let vaultObjectDigest: Data
        let inboxGeneration: UInt64
        let inboxCommitID: UUID
        let inboxManifestDigest: Data
        let inboxItemCount: Int
        let inboxBlobCount: Int
        let inboxTerminalCount: Int
        let rootTreeDigest: Data
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
        let vaultGeneration: UInt64
        let inboxGeneration: UInt64
        let vaultObjectCount: Int
        let inboxItemCount: Int
        let inboxBlobCount: Int
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
        let vault = try PlaintextVault(rootURL: workspace.source)
        let inbox = try PlaintextLANInboxStore(rootURL: workspace.source)
        let source = try PlaintextLibraryBackupSource(vault: vault, inboxStore: inbox)
        let plan = try await source.prepare()
        let enrollment = try BackupKeyHierarchy.makeEnrollment()
        let signer = try BackupDeviceSigner(
            descriptor: enrollment.descriptor,
            authorization: enrollment.authorization,
            deviceSigningSeed: enrollment.deviceSigningSeed
        )
        let bytes = ActivationCheckpointBytes()
        _ = try await EncryptedBackupContainerWriter().write(
            entries: await source.containerSources(for: plan),
            revisionPair: plan.revisionPair,
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

    static func activationSeedWriter(configuration: Configuration) async throws {
        guard configuration.scenario == .existing else {
            throw ProbeError.invalidArguments
        }
        try await activationSeed(configuration: configuration)
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
            let verifier = try BackupRestoreVerifier(
                stableParentURL: workspace.parent,
                activeRootURL: workspace.current
            )
            let prepared = try await verifier.prepare(
                checkpointURL: workspace.checkpoint,
                recoveryCode: recoveryCode
            )
            let productionFault = fault.productionFault
            let transaction = try BackupRestoreTransaction(
                activeRootURL: workspace.current,
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
            _ = try await BackupRestoreTransaction(activeRootURL: workspace.current).reconcile()
            try BackupRestoreVerifier(
                stableParentURL: workspace.parent,
                activeRootURL: workspace.current
            ).reconcileAbandonedPreflights()
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
            vaultGeneration: semantic?.vaultGeneration ?? 0,
            inboxGeneration: semantic?.inboxGeneration ?? 0,
            vaultObjectCount: semantic?.vaultObjectCount ?? 0,
            inboxItemCount: semantic?.inboxItemCount ?? 0,
            inboxBlobCount: semantic?.inboxBlobCount ?? 0,
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
        guard let restore = error as? BackupRestoreError else {
            return error as? ProbeError ?? .activationInvalid
        }
        switch restore {
        case .receiptInvalid: return .receiptInvalid
        case let .ioFailure(code): return .ioFailure(code)
        default: return .activationInvalid
        }
    }

    static func createCommittedRoot(
        at root: URL,
        state: RootState
    ) async throws -> RootSemanticIdentity {
        let vault = try PlaintextVault(rootURL: root)
        let initial = try await vault.initialize()
        let vaultBytes = try activationVaultBytes(state)
        let attachment = try Attachment(
            contentTypeIdentifier: "public.data",
            byteCount: vaultBytes.count,
            sha256Digest: ContentDigest.sha256(vaultBytes)
        )
        let next = try VaultCatalog(
            vaultID: initial.vaultID,
            generation: try VaultGeneration.successor(of: initial.generation),
            attachments: [attachment]
        )
        var committedCatalog = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: initial.generation,
            catalog: next,
            writes: [VaultObjectWrite(
                reference: VaultObjectReference(id: attachment.id, kind: .attachment),
                plaintext: vaultBytes
            )]
        ))
        if state == .new {
            committedCatalog = try await vault.commit(try VaultCommitRequest(
                expectedGeneration: committedCatalog.generation,
                catalog: VaultCatalog(
                    vaultID: committedCatalog.vaultID,
                    generation: try VaultGeneration.successor(
                        of: committedCatalog.generation
                    ),
                    members: [try FamilyMember(displayName: "Synthetic restored root")],
                    attachments: committedCatalog.attachments
                ),
                writes: []
            ))
        }

        let inbox = try PlaintextLANInboxStore(rootURL: root)
        _ = try await inbox.initialize()
        let retainedSessionID = UUID()
        try await uploadActivationInboxBytes(
            try activationInboxBytes(state),
            name: "synthetic-retained.bin",
            sessionID: retainedSessionID,
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
            activeSessionID: terminalSessionID,
            admissionGenerationCutoff: beforeDelete.generation
        )
        let semantic = try await strictValidateCommittedRoot(at: root)
        guard semantic.state == state else { throw ProbeError.activationInvalid }
        return semantic
    }

    static func uploadActivationInboxBytes(
        _ bytes: Data,
        name: String,
        sessionID: UUID,
        store: PlaintextLANInboxStore
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

    static func strictValidateCommittedRoot(
        at root: URL,
        expected: RootSemanticIdentity? = nil
    ) async throws -> RootSemanticIdentity {
        try validateOwnedDirectory(root)
        let beforeTreeDigest = try capabilityTreeDigest(root)

        let vault = try PlaintextVault(rootURL: root)
        let (catalog, revision) = try await vault.loadCatalogHead()
        let readSnapshot = try await vault.readSnapshot { catalog in
            catalog.reachableObjectReferences
        }
        guard readSnapshot.catalog == catalog,
              catalog.reachableObjectReferences.count == 1,
              readSnapshot.objects.count == 1,
              let reference = catalog.reachableObjectReferences.first,
              let vaultBytes = readSnapshot.objects[reference] else {
            throw ProbeError.activationInvalid
        }
        let state = try activationState(vaultBytes: vaultBytes)

        let inboxStore = try PlaintextLANInboxStore(rootURL: root)
        let projection = try await inboxStore.snapshotAndStorageSummary()
        let inbox = projection.snapshot
        guard inbox.vaultID == catalog.vaultID,
              inbox.items.count == 1,
              inbox.blobs.count == 1,
              inbox.contentTerminals.count == 1,
              inbox.archiveIntents.isEmpty,
              inbox.archiveTerminals.isEmpty,
              let item = inbox.items.first,
              let blob = inbox.blobs.first,
              item.blobID == blob.id,
              case .stored = item.state,
              let terminal = inbox.contentTerminals.first,
              case .deleted = terminal.kind else {
            throw ProbeError.activationInvalid
        }
        let blobURL = root
            .appendingPathComponent("lan-inbox", isDirectory: true)
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(
                "\(blob.id.uuidString.lowercased()).blob",
                isDirectory: false
            )
        let blobBytes = try readPrivateFile(blobURL, maximumByteCount: 1 * 1_024 * 1_024)
        let expectedInboxBytes = try activationInboxBytes(state)
        let expectedTerminalBytes = try activationTerminalBytes(state)
        guard blobBytes.count == blob.byteCount,
              ContentDigest.sha256(blobBytes) == blob.sha256Digest,
              blobBytes == expectedInboxBytes,
              terminal.contentIdentity.sha256Digest
                == ContentDigest.sha256(expectedTerminalBytes),
              terminal.contentIdentity.byteCount == expectedTerminalBytes.count else {
            throw ProbeError.activationInvalid
        }
        let inboxManifest = try readPrivateFile(
            root.appendingPathComponent("lan-inbox/inbox.json"),
            maximumByteCount: 4 * 1_024 * 1_024
        )

        let afterTreeDigest = try capabilityTreeDigest(root)
        guard beforeTreeDigest == afterTreeDigest else {
            throw ProbeError.activationInvalid
        }
        let semantic = RootSemanticIdentity(
            state: state,
            vaultID: catalog.vaultID,
            vaultGeneration: revision.generation,
            vaultCommitID: revision.commitID,
            vaultCatalogDigest: revision.catalogDigest,
            vaultObjectCount: readSnapshot.objects.count,
            vaultObjectDigest: ContentDigest.sha256(vaultBytes),
            inboxGeneration: inbox.generation,
            inboxCommitID: inbox.commitID,
            inboxManifestDigest: ContentDigest.sha256(inboxManifest),
            inboxItemCount: inbox.items.count,
            inboxBlobCount: inbox.blobs.count,
            inboxTerminalCount: inbox.contentTerminals.count,
            rootTreeDigest: afterTreeDigest
        )
        if let expected, semantic != expected {
            throw ProbeError.activationInvalid
        }
        return semantic
    }

    static func activationVaultBytes(_ state: RootState) throws -> Data {
        switch state {
        case .old: Data("KLG-U0-VAULT-OLD-COMMITTED".utf8)
        case .new: Data("KLG-U0-VAULT-NEW-COMMITTED".utf8)
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

    static func activationState(vaultBytes: Data) throws -> RootState {
        if vaultBytes == (try activationVaultBytes(.old)) { return .old }
        if vaultBytes == (try activationVaultBytes(.new)) { return .new }
        throw ProbeError.activationInvalid
    }

    static func capabilityTreeDigest(_ root: URL) throws -> Data {
        var hasher = SHA256()
        var entryCount = 0
        var totalBytes = 0
        try hashCapabilityTree(
            root,
            relativePath: "",
            depth: 0,
            entryCount: &entryCount,
            totalBytes: &totalBytes,
            hasher: &hasher
        )
        return Data(hasher.finalize())
    }

    static func hashCapabilityTree(
        _ directory: URL,
        relativePath: String,
        depth: Int,
        entryCount: inout Int,
        totalBytes: inout Int,
        hasher: inout SHA256
    ) throws {
        guard depth <= 32 else { throw ProbeError.resourceLimit }
        try validateOwnedDirectory(directory)
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            entryCount += 1
            guard entryCount <= 4_096 else { throw ProbeError.resourceLimit }
            let childRelative = relativePath.isEmpty
                ? child.lastPathComponent
                : "\(relativePath)/\(child.lastPathComponent)"
            var metadata = stat()
            guard lstat(child.path, &metadata) == 0,
                  metadata.st_uid == geteuid() else {
                throw ProbeError.activationInvalid
            }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                hasher.update(data: Data("D\0\(childRelative)\0".utf8))
                try hashCapabilityTree(
                    child,
                    relativePath: childRelative,
                    depth: depth + 1,
                    entryCount: &entryCount,
                    totalBytes: &totalBytes,
                    hasher: &hasher
                )
            } else if metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_nlink == 1,
                      metadata.st_size >= 0,
                      metadata.st_size <= 4 * 1_024 * 1_024 {
                let data = try readPrivateFile(child, maximumByteCount: 4 * 1_024 * 1_024)
                let nextTotal = totalBytes.addingReportingOverflow(data.count)
                guard !nextTotal.overflow,
                      nextTotal.partialValue <= 64 * 1_024 * 1_024 else {
                    throw ProbeError.resourceLimit
                }
                totalBytes = nextTotal.partialValue
                hasher.update(data: Data("F\0\(childRelative)\0\(data.count)\0".utf8))
                hasher.update(data: data)
            } else {
                throw ProbeError.activationInvalid
            }
        }
    }

}

// MARK: - Named 20,000-object / 2 GiB encrypted dataset

private extension BackupCapabilityProbe {
    static let datasetFormat = "KLG-U0-DATASET-PROBE-1"
    static let datasetWorkLeafName = ".u0-named-dataset.opaque-work"
    static let datasetFinalLeafName = "u0-named-worst-case.kinloguebackup"
    static let datasetBackupBudgetMilliseconds = 15 * 60 * 1_000
    static let datasetRestoreBudgetMilliseconds = 15 * 60 * 1_000
    static let datasetPeakRSSDeltaBudgetBytes = UInt64(96 * 1_024 * 1_024)
    static let datasetFileDescriptorBudgetCount = 64
    static let datasetHeaderByteCount = 48
    static let datasetObjectHeaderByteCount = 36
    static let datasetFrameHeaderByteCount = 28
    static let datasetFooterPayloadByteCount = 84
    static let datasetFooterByteCount = datasetFooterPayloadByteCount + 16 + 8

    struct NamedDatasetResult: Encodable {
        let category = "namedDataset"
        let status = "passed"
        let passed: Bool
        let format: String
        let objectCount: Int
        let frameCount: Int
        let plaintextByteCount: Int64
        let fileByteCount: Int64
        let allocatedByteCount: Int64
        let selectedChunkByteCount: Int
        let backupDurationMilliseconds: Int
        let restoreDurationMilliseconds: Int
        let backupBudgetMilliseconds: Int
        let restoreBudgetMilliseconds: Int
        let peakRSSDeltaBytes: UInt64
        let peakRSSDeltaBudgetBytes: UInt64
        let fileDescriptorHighWaterCount: Int
        let fileDescriptorBudgetCount: Int
        let sourceSHA256: String
        let backupSHA256: String
        let fullReaderVerified: Bool
        let footerAuthenticated: Bool
        let nonSparse: Bool
        let exclusiveNonOverwrite: Bool
        let cleaned: Bool
    }

    struct DatasetWriteMeasurement {
        let objectCount: Int
        let frameCount: Int
        let plaintextByteCount: Int64
        let fileByteCount: Int64
        let allocatedByteCount: Int64
        let sourceDigest: Data
        let backupDigest: Data
        let durationMilliseconds: Int
        let peakRSS: UInt64
        let fileDescriptorHighWaterCount: Int
        let identity: RegularLeafIdentity
    }

    struct DatasetReadMeasurement {
        let objectCount: Int
        let frameCount: Int
        let plaintextByteCount: Int64
        let sourceDigest: Data
        let backupDigest: Data
        let durationMilliseconds: Int
        let peakRSS: UInt64
        let fileDescriptorHighWaterCount: Int
        let footerAuthenticated: Bool
    }

    static func namedDatasetProbe(configuration: Configuration) throws -> NamedDatasetResult {
        let repository = try configuration.baseDirectory().appendingPathComponent(
            "repository",
            isDirectory: true
        )
        try ensureOwnedDirectory(repository)
        let parentDescriptor = try openRepositoryParent(repository)
        defer { Darwin.close(parentDescriptor) }
        let parentIdentity = try descriptorIdentity(parentDescriptor)
        let backupStarted = DispatchTime.now().uptimeNanoseconds
        guard try leafIsAbsent(parentDescriptor, name: datasetWorkLeafName),
              try leafIsAbsent(parentDescriptor, name: datasetFinalLeafName) else {
            throw ProbeError.datasetInvalid
        }

        let requestedBytes = Int64(configuration.streamByteCount)
        let minimumCapacity = try checkedAdd(requestedBytes, backupFormatAllowanceByteCount)
        guard try availableCapacityByteCount(descriptor: parentDescriptor) >= minimumCapacity else {
            throw ProbeError.capacityInsufficient
        }

        var ownedDescriptor = openat(
            parentDescriptor,
            datasetWorkLeafName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard ownedDescriptor >= 0 else { throw ProbeError.datasetInvalid }
        var ownedLeafName = datasetWorkLeafName
        defer {
            if ownedDescriptor >= 0 {
                if let identity = try? validatedDatasetLeafIdentity(
                    descriptor: ownedDescriptor,
                    maximumByteCount: try? maximumDatasetFileByteCount(
                        objectCount: configuration.objectCount,
                        plaintextByteCount: requestedBytes
                    )
                ).identity {
                    removeExactLeafIfPresent(
                        parentDescriptor: parentDescriptor,
                        name: ownedLeafName,
                        expectedIdentity: identity
                    )
                }
                Darwin.close(ownedDescriptor)
            }
        }

        let baselineRSS = residentMemoryByteCount()
        let baselineFDs = openFileDescriptorCount()
        let key = SymmetricKey(data: try randomData(byteCount: 32))
        let attemptID = try randomData(byteCount: 16)
        let noncePrefix = try randomData(byteCount: 4)
        let write = try writeNamedDataset(
            descriptor: ownedDescriptor,
            objectCount: configuration.objectCount,
            plaintextByteCount: requestedBytes,
            key: key,
            attemptID: attemptID,
            noncePrefix: noncePrefix,
            caseID: configuration.caseID,
            baselineRSS: baselineRSS,
            baselineFDs: baselineFDs
        )
        guard write.peakRSS >= baselineRSS,
              write.peakRSS - baselineRSS <= datasetPeakRSSDeltaBudgetBytes,
              write.fileDescriptorHighWaterCount <= datasetFileDescriptorBudgetCount,
              write.allocatedByteCount >= requestedBytes else {
            throw ProbeError.resourceLimit
        }

        guard renameatx_np(
            parentDescriptor,
            datasetWorkLeafName,
            parentDescriptor,
            datasetFinalLeafName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw ProbeError.datasetInvalid
        }
        ownedLeafName = datasetFinalLeafName
        try syncDescriptor(parentDescriptor)
        try recheckLeaf(
            parentDescriptor: parentDescriptor,
            name: datasetFinalLeafName,
            expectedIdentity: write.identity,
            failure: .datasetInvalid
        )
        try recheckVisibleParent(repository, expected: parentIdentity, failure: .datasetInvalid)
        let backupDurationMilliseconds = elapsedMilliseconds(since: backupStarted)
        guard backupDurationMilliseconds <= datasetBackupBudgetMilliseconds else {
            throw ProbeError.resourceLimit
        }

        if configuration.caseID == "corrupt" {
            var byte = UInt8(0)
            let corruptionOffset = off_t(
                datasetHeaderByteCount + datasetObjectHeaderByteCount
                    + datasetFrameHeaderByteCount + 7
            )
            guard pread(ownedDescriptor, &byte, 1, corruptionOffset) == 1 else {
                throw ProbeError.datasetInvalid
            }
            byte ^= 0xff
            guard pwrite(
                ownedDescriptor,
                &byte,
                1,
                corruptionOffset
            ) == 1 else {
                throw ProbeError.datasetInvalid
            }
            try syncFileDescriptor(ownedDescriptor, failure: .datasetInvalid)
        } else if configuration.caseID == "truncated" {
            let replacement = try replaceDatasetWithTruncatedCopy(
                parentDescriptor: parentDescriptor,
                originalDescriptor: ownedDescriptor,
                originalIdentity: write.identity
            )
            Darwin.close(ownedDescriptor)
            ownedDescriptor = replacement.descriptor
        } else if configuration.caseID != "case" {
            throw ProbeError.invalidArguments
        }

        let published = try validatedDatasetLeafIdentity(
            descriptor: ownedDescriptor,
            maximumByteCount: try maximumDatasetFileByteCount(
                objectCount: configuration.objectCount,
                plaintextByteCount: requestedBytes
            )
        )
        let read = try readNamedDataset(
            parentDescriptor: parentDescriptor,
            expectedIdentity: published.identity,
            key: key,
            expectedAttemptID: attemptID,
            expectedNoncePrefix: noncePrefix,
            baselineRSS: baselineRSS,
            baselineFDs: baselineFDs
        )
        guard read.durationMilliseconds <= datasetRestoreBudgetMilliseconds,
              read.peakRSS >= baselineRSS,
              read.peakRSS - baselineRSS <= datasetPeakRSSDeltaBudgetBytes,
              read.fileDescriptorHighWaterCount <= datasetFileDescriptorBudgetCount,
              read.objectCount == write.objectCount,
              read.frameCount == write.frameCount,
              read.plaintextByteCount == write.plaintextByteCount,
              read.sourceDigest == write.sourceDigest,
              read.backupDigest == write.backupDigest,
              read.footerAuthenticated else {
            throw ProbeError.datasetInvalid
        }

        removeExactLeafIfPresent(
            parentDescriptor: parentDescriptor,
            name: datasetFinalLeafName,
            expectedIdentity: published.identity
        )
        guard try leafIsAbsent(parentDescriptor, name: datasetFinalLeafName) else {
            throw ProbeError.datasetInvalid
        }
        guard Darwin.close(ownedDescriptor) == 0 else { throw ProbeError.datasetInvalid }
        ownedDescriptor = -1
        try syncDescriptor(parentDescriptor)
        let peakRSS = max(write.peakRSS, read.peakRSS)
        return NamedDatasetResult(
            passed: true,
            format: datasetFormat,
            objectCount: write.objectCount,
            frameCount: write.frameCount,
            plaintextByteCount: write.plaintextByteCount,
            fileByteCount: write.fileByteCount,
            allocatedByteCount: write.allocatedByteCount,
            selectedChunkByteCount: selectedChunkByteCount,
            backupDurationMilliseconds: backupDurationMilliseconds,
            restoreDurationMilliseconds: read.durationMilliseconds,
            backupBudgetMilliseconds: datasetBackupBudgetMilliseconds,
            restoreBudgetMilliseconds: datasetRestoreBudgetMilliseconds,
            peakRSSDeltaBytes: peakRSS - baselineRSS,
            peakRSSDeltaBudgetBytes: datasetPeakRSSDeltaBudgetBytes,
            fileDescriptorHighWaterCount: max(
                write.fileDescriptorHighWaterCount,
                read.fileDescriptorHighWaterCount
            ),
            fileDescriptorBudgetCount: datasetFileDescriptorBudgetCount,
            sourceSHA256: hashHex(write.sourceDigest),
            backupSHA256: hashHex(write.backupDigest),
            fullReaderVerified: true,
            footerAuthenticated: true,
            nonSparse: true,
            exclusiveNonOverwrite: true,
            cleaned: true
        )
    }

    static func writeNamedDataset(
        descriptor: Int32,
        objectCount: Int,
        plaintextByteCount: Int64,
        key: SymmetricKey,
        attemptID: Data,
        noncePrefix: Data,
        caseID: String,
        baselineRSS: UInt64,
        baselineFDs: Int
    ) throws -> DatasetWriteMeasurement {
        guard objectCount > 0,
              objectCount <= maximumSourceObjectCount,
              plaintextByteCount >= Int64(objectCount),
              plaintextByteCount <= maximumSourceByteCount,
              attemptID.count == 16,
              noncePrefix.count == 4 else {
            throw ProbeError.invalidArguments
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var sourceHasher = SHA256()
        var fileHasher = SHA256()
        var fileByteCount: Int64 = 0
        var frameCounter: UInt64 = 0
        var globalOffset: Int64 = 0
        var peakRSS = baselineRSS
        var fdHighWater = baselineFDs

        var header = Data("KLGU0DS1".utf8)
        appendUInt32(UInt32(1), to: &header)
        appendUInt32(UInt32(objectCount), to: &header)
        appendUInt64(UInt64(plaintextByteCount), to: &header)
        appendUInt32(UInt32(selectedChunkByteCount), to: &header)
        header.append(attemptID)
        header.append(noncePrefix)
        guard header.count == datasetHeaderByteCount else { throw ProbeError.datasetInvalid }
        try writeDatasetBytes(
            header,
            descriptor: descriptor,
            fileHasher: &fileHasher,
            fileByteCount: &fileByteCount
        )

        for objectIndex in 0..<objectCount {
            let objectLength = datasetObjectLength(
                index: objectIndex,
                objectCount: objectCount,
                totalByteCount: plaintextByteCount
            )
            let frameCount = Int(
                (objectLength + Int64(selectedChunkByteCount) - 1)
                    / Int64(selectedChunkByteCount)
            )
            let objectID = datasetObjectID(
                index: objectIndex,
                objectLength: objectLength,
                totalByteCount: plaintextByteCount
            )
            var objectHeader = Data("OBJ1".utf8)
            appendUInt32(UInt32(objectIndex), to: &objectHeader)
            objectHeader.append(objectID)
            appendUInt64(UInt64(objectLength), to: &objectHeader)
            appendUInt32(UInt32(frameCount), to: &objectHeader)
            guard objectHeader.count == datasetObjectHeaderByteCount else {
                throw ProbeError.datasetInvalid
            }
            sourceHasher.update(data: objectHeader)
            try writeDatasetBytes(
                objectHeader,
                descriptor: descriptor,
                fileHasher: &fileHasher,
                fileByteCount: &fileByteCount
            )

            var objectOffset: Int64 = 0
            for frameIndex in 0..<frameCount {
                if caseID == "cancel", frameCounter == 2 {
                    throw ProbeError.datasetCancelled
                }
                if caseID == "injected-disk-full", frameCounter == 2 {
                    throw ProbeError.capacityInsufficient
                }
                let remaining = objectLength - objectOffset
                let count = Int(min(Int64(selectedChunkByteCount), remaining))
                let plaintext = deterministicDatasetBytes(
                    objectIndex: objectIndex,
                    globalOffset: globalOffset,
                    count: count
                )
                sourceHasher.update(data: plaintext)
                let nonce = try datasetNonce(prefix: noncePrefix, counter: frameCounter)
                let aad = datasetFrameAAD(
                    objectIndex: objectIndex,
                    frameIndex: frameIndex,
                    plaintextByteCount: count,
                    objectByteCount: objectLength,
                    totalByteCount: plaintextByteCount,
                    counter: frameCounter,
                    objectID: objectID
                )
                let sealed = try AES.GCM.seal(
                    plaintext,
                    using: key,
                    nonce: nonce,
                    authenticating: aad
                )
                guard sealed.ciphertext.count == count, sealed.tag.count == 16 else {
                    throw ProbeError.datasetInvalid
                }
                var frameHeader = Data("FRM1".utf8)
                appendUInt32(UInt32(objectIndex), to: &frameHeader)
                appendUInt32(UInt32(frameIndex), to: &frameHeader)
                appendUInt64(frameCounter, to: &frameHeader)
                appendUInt32(UInt32(count), to: &frameHeader)
                appendUInt32(UInt32(sealed.ciphertext.count), to: &frameHeader)
                guard frameHeader.count == datasetFrameHeaderByteCount else {
                    throw ProbeError.datasetInvalid
                }
                try writeDatasetBytes(
                    frameHeader,
                    descriptor: descriptor,
                    fileHasher: &fileHasher,
                    fileByteCount: &fileByteCount
                )
                try writeDatasetBytes(
                    sealed.ciphertext,
                    descriptor: descriptor,
                    fileHasher: &fileHasher,
                    fileByteCount: &fileByteCount
                )
                try writeDatasetBytes(
                    sealed.tag,
                    descriptor: descriptor,
                    fileHasher: &fileHasher,
                    fileByteCount: &fileByteCount
                )
                objectOffset += Int64(count)
                globalOffset += Int64(count)
                frameCounter += 1
            }
            guard objectOffset == objectLength else { throw ProbeError.datasetInvalid }
            if objectIndex % 64 == 0 || objectIndex + 1 == objectCount {
                peakRSS = max(peakRSS, residentMemoryByteCount())
                fdHighWater = max(fdHighWater, openFileDescriptorCount())
            }
        }
        guard globalOffset == plaintextByteCount,
              frameCounter <= UInt64(Int.max) else {
            throw ProbeError.datasetInvalid
        }
        let sourceDigest = Data(sourceHasher.finalize())
        var footerPayload = Data("KLGU0FTR".utf8)
        appendUInt32(UInt32(objectCount), to: &footerPayload)
        appendUInt64(frameCounter, to: &footerPayload)
        appendUInt64(UInt64(plaintextByteCount), to: &footerPayload)
        footerPayload.append(sourceDigest)
        footerPayload.append(attemptID)
        appendUInt64(frameCounter, to: &footerPayload)
        guard footerPayload.count == datasetFooterPayloadByteCount else {
            throw ProbeError.datasetInvalid
        }
        let commitMarker = Data("KLGU0END".utf8)
        var authenticatedFooter = footerPayload
        authenticatedFooter.append(commitMarker)
        let footerBox = try AES.GCM.seal(
            Data(),
            using: key,
            nonce: try datasetNonce(prefix: noncePrefix, counter: frameCounter),
            authenticating: authenticatedFooter
        )
        guard footerBox.ciphertext.isEmpty, footerBox.tag.count == 16 else {
            throw ProbeError.datasetInvalid
        }
        try writeDatasetBytes(
            footerPayload,
            descriptor: descriptor,
            fileHasher: &fileHasher,
            fileByteCount: &fileByteCount
        )
        try writeDatasetBytes(
            footerBox.tag,
            descriptor: descriptor,
            fileHasher: &fileHasher,
            fileByteCount: &fileByteCount
        )
        try writeDatasetBytes(
            commitMarker,
            descriptor: descriptor,
            fileHasher: &fileHasher,
            fileByteCount: &fileByteCount
        )
        try syncFileDescriptor(descriptor, failure: .datasetInvalid)
        let maximum = try maximumDatasetFileByteCount(
            objectCount: objectCount,
            plaintextByteCount: plaintextByteCount
        )
        let validated = try validatedDatasetLeafIdentity(
            descriptor: descriptor,
            maximumByteCount: maximum
        )
        guard validated.identity.byteCount == fileByteCount,
              validated.allocatedByteCount >= plaintextByteCount else {
            throw ProbeError.resourceLimit
        }
        peakRSS = max(peakRSS, residentMemoryByteCount())
        fdHighWater = max(fdHighWater, openFileDescriptorCount())
        return DatasetWriteMeasurement(
            objectCount: objectCount,
            frameCount: Int(frameCounter),
            plaintextByteCount: plaintextByteCount,
            fileByteCount: fileByteCount,
            allocatedByteCount: validated.allocatedByteCount,
            sourceDigest: sourceDigest,
            backupDigest: Data(fileHasher.finalize()),
            durationMilliseconds: elapsedMilliseconds(since: started),
            peakRSS: peakRSS,
            fileDescriptorHighWaterCount: fdHighWater,
            identity: validated.identity
        )
    }

    static func readNamedDataset(
        parentDescriptor: Int32,
        expectedIdentity: RegularLeafIdentity,
        key: SymmetricKey,
        expectedAttemptID: Data,
        expectedNoncePrefix: Data,
        baselineRSS: UInt64,
        baselineFDs: Int
    ) throws -> DatasetReadMeasurement {
        let started = DispatchTime.now().uptimeNanoseconds
        let descriptor = openat(
            parentDescriptor,
            datasetFinalLeafName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw ProbeError.datasetInvalid }
        defer { Darwin.close(descriptor) }
        let initial = try validatedDatasetLeafIdentity(
            descriptor: descriptor,
            maximumByteCount: expectedIdentity.byteCount
        )
        guard initial.identity == expectedIdentity else { throw ProbeError.datasetInvalid }
        var fileHasher = SHA256()
        var sourceHasher = SHA256()
        var peakRSS = baselineRSS
        var fdHighWater = max(baselineFDs, openFileDescriptorCount())
        let header = try readDatasetBytes(
            count: datasetHeaderByteCount,
            descriptor: descriptor,
            fileHasher: &fileHasher
        )
        guard Data(header.prefix(8)) == Data("KLGU0DS1".utf8),
              decodeUInt32(header, at: 8) == 1,
              let objectCount = Int(exactly: decodeUInt32(header, at: 12)),
              let plaintextByteCount = Int64(exactly: decodeUInt64(header, at: 16)),
              decodeUInt32(header, at: 24) == UInt32(selectedChunkByteCount),
              Data(header[28..<44]) == expectedAttemptID,
              Data(header[44..<48]) == expectedNoncePrefix,
              objectCount > 0,
              objectCount <= maximumSourceObjectCount,
              plaintextByteCount >= Int64(objectCount),
              plaintextByteCount <= maximumSourceByteCount else {
            throw ProbeError.datasetInvalid
        }

        var globalOffset: Int64 = 0
        var frameCounter: UInt64 = 0
        for objectIndex in 0..<objectCount {
            let objectHeader = try readDatasetBytes(
                count: datasetObjectHeaderByteCount,
                descriptor: descriptor,
                fileHasher: &fileHasher
            )
            let expectedLength = datasetObjectLength(
                index: objectIndex,
                objectCount: objectCount,
                totalByteCount: plaintextByteCount
            )
            let expectedObjectID = datasetObjectID(
                index: objectIndex,
                objectLength: expectedLength,
                totalByteCount: plaintextByteCount
            )
            let expectedFrames = Int(
                (expectedLength + Int64(selectedChunkByteCount) - 1)
                    / Int64(selectedChunkByteCount)
            )
            guard Data(objectHeader.prefix(4)) == Data("OBJ1".utf8),
                  decodeUInt32(objectHeader, at: 4) == UInt32(objectIndex),
                  Data(objectHeader[8..<24]) == expectedObjectID,
                  decodeUInt64(objectHeader, at: 24) == UInt64(expectedLength),
                  decodeUInt32(objectHeader, at: 32) == UInt32(expectedFrames) else {
                throw ProbeError.datasetInvalid
            }
            sourceHasher.update(data: objectHeader)
            var objectOffset: Int64 = 0
            for frameIndex in 0..<expectedFrames {
                let frameHeader = try readDatasetBytes(
                    count: datasetFrameHeaderByteCount,
                    descriptor: descriptor,
                    fileHasher: &fileHasher
                )
                let remaining = expectedLength - objectOffset
                let expectedCount = Int(min(Int64(selectedChunkByteCount), remaining))
                guard Data(frameHeader.prefix(4)) == Data("FRM1".utf8),
                      decodeUInt32(frameHeader, at: 4) == UInt32(objectIndex),
                      decodeUInt32(frameHeader, at: 8) == UInt32(frameIndex),
                      decodeUInt64(frameHeader, at: 12) == frameCounter,
                      decodeUInt32(frameHeader, at: 20) == UInt32(expectedCount),
                      decodeUInt32(frameHeader, at: 24) == UInt32(expectedCount) else {
                    throw ProbeError.datasetInvalid
                }
                let ciphertext = try readDatasetBytes(
                    count: expectedCount,
                    descriptor: descriptor,
                    fileHasher: &fileHasher
                )
                let tag = try readDatasetBytes(
                    count: 16,
                    descriptor: descriptor,
                    fileHasher: &fileHasher
                )
                let nonce = try datasetNonce(prefix: expectedNoncePrefix, counter: frameCounter)
                guard let box = try? AES.GCM.SealedBox(
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag
                ), let plaintext = try? AES.GCM.open(
                    box,
                    using: key,
                    authenticating: datasetFrameAAD(
                        objectIndex: objectIndex,
                        frameIndex: frameIndex,
                        plaintextByteCount: expectedCount,
                        objectByteCount: expectedLength,
                        totalByteCount: plaintextByteCount,
                        counter: frameCounter,
                        objectID: expectedObjectID
                    )
                ) else {
                    throw ProbeError.datasetInvalid
                }
                guard plaintext == deterministicDatasetBytes(
                    objectIndex: objectIndex,
                    globalOffset: globalOffset,
                    count: expectedCount
                ) else {
                    throw ProbeError.datasetInvalid
                }
                sourceHasher.update(data: plaintext)
                objectOffset += Int64(expectedCount)
                globalOffset += Int64(expectedCount)
                frameCounter += 1
            }
            guard objectOffset == expectedLength else { throw ProbeError.datasetInvalid }
            if objectIndex % 64 == 0 || objectIndex + 1 == objectCount {
                peakRSS = max(peakRSS, residentMemoryByteCount())
                fdHighWater = max(fdHighWater, openFileDescriptorCount())
            }
        }
        guard globalOffset == plaintextByteCount else { throw ProbeError.datasetInvalid }
        let footerPayload = try readDatasetBytes(
            count: datasetFooterPayloadByteCount,
            descriptor: descriptor,
            fileHasher: &fileHasher
        )
        let footerTag = try readDatasetBytes(
            count: 16,
            descriptor: descriptor,
            fileHasher: &fileHasher
        )
        let commit = try readDatasetBytes(
            count: 8,
            descriptor: descriptor,
            fileHasher: &fileHasher
        )
        let sourceDigest = Data(sourceHasher.finalize())
        guard Data(footerPayload.prefix(8)) == Data("KLGU0FTR".utf8),
              decodeUInt32(footerPayload, at: 8) == UInt32(objectCount),
              decodeUInt64(footerPayload, at: 12) == frameCounter,
              decodeUInt64(footerPayload, at: 20) == UInt64(plaintextByteCount),
              Data(footerPayload[28..<60]) == sourceDigest,
              Data(footerPayload[60..<76]) == expectedAttemptID,
              decodeUInt64(footerPayload, at: 76) == frameCounter,
              commit == Data("KLGU0END".utf8) else {
            throw ProbeError.datasetInvalid
        }
        var authenticatedFooter = footerPayload
        authenticatedFooter.append(commit)
        guard let footerBox = try? AES.GCM.SealedBox(
            nonce: try datasetNonce(prefix: expectedNoncePrefix, counter: frameCounter),
            ciphertext: Data(),
            tag: footerTag
        ), (try? AES.GCM.open(
            footerBox,
            using: key,
            authenticating: authenticatedFooter
        )) != nil else {
            throw ProbeError.datasetInvalid
        }
        var extra = UInt8(0)
        let extraCount = Darwin.read(descriptor, &extra, 1)
        guard extraCount == 0 else { throw ProbeError.datasetInvalid }
        let final = try validatedDatasetLeafIdentity(
            descriptor: descriptor,
            maximumByteCount: expectedIdentity.byteCount
        )
        guard final.identity == expectedIdentity else { throw ProbeError.datasetInvalid }
        try recheckLeaf(
            parentDescriptor: parentDescriptor,
            name: datasetFinalLeafName,
            expectedIdentity: expectedIdentity,
            failure: .datasetInvalid
        )
        peakRSS = max(peakRSS, residentMemoryByteCount())
        fdHighWater = max(fdHighWater, openFileDescriptorCount())
        return DatasetReadMeasurement(
            objectCount: objectCount,
            frameCount: Int(frameCounter),
            plaintextByteCount: plaintextByteCount,
            sourceDigest: sourceDigest,
            backupDigest: Data(fileHasher.finalize()),
            durationMilliseconds: elapsedMilliseconds(since: started),
            peakRSS: peakRSS,
            fileDescriptorHighWaterCount: fdHighWater,
            footerAuthenticated: true
        )
    }

    static func datasetObjectLength(
        index: Int,
        objectCount: Int,
        totalByteCount: Int64
    ) -> Int64 {
        let base = totalByteCount / Int64(objectCount)
        let remainder = totalByteCount % Int64(objectCount)
        return base + (Int64(index) < remainder ? 1 : 0)
    }

    static func datasetObjectID(
        index: Int,
        objectLength: Int64,
        totalByteCount: Int64
    ) -> Data {
        var input = Data("KLG-U0-OBJECT-ID-1".utf8)
        appendUInt32(UInt32(index), to: &input)
        appendUInt64(UInt64(objectLength), to: &input)
        appendUInt64(UInt64(totalByteCount), to: &input)
        return Data(SHA256.hash(data: input).prefix(16))
    }

    static func deterministicDatasetBytes(
        objectIndex: Int,
        globalOffset: Int64,
        count: Int
    ) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for index in 0..<count {
                let position = UInt64(globalOffset + Int64(index))
                let mixed = position &* 0x9e3779b185ebca87
                    ^ UInt64(objectIndex) &* 0xd6e8feb86659fd93
                    ^ (position >> 17)
                bytes[index] = UInt8(truncatingIfNeeded: mixed ^ (mixed >> 29))
            }
        }
        return data
    }

    static func datasetFrameAAD(
        objectIndex: Int,
        frameIndex: Int,
        plaintextByteCount: Int,
        objectByteCount: Int64,
        totalByteCount: Int64,
        counter: UInt64,
        objectID: Data
    ) -> Data {
        var aad = Data("KLG-U0-DATASET-FRAME-1".utf8)
        appendUInt32(UInt32(objectIndex), to: &aad)
        appendUInt32(UInt32(frameIndex), to: &aad)
        appendUInt32(UInt32(plaintextByteCount), to: &aad)
        appendUInt64(UInt64(objectByteCount), to: &aad)
        appendUInt64(UInt64(totalByteCount), to: &aad)
        appendUInt64(counter, to: &aad)
        aad.append(objectID)
        return aad
    }

    static func datasetNonce(prefix: Data, counter: UInt64) throws -> AES.GCM.Nonce {
        guard prefix.count == 4 else { throw ProbeError.datasetInvalid }
        var data = prefix
        appendUInt64(counter, to: &data)
        return try AES.GCM.Nonce(data: data)
    }

    static func maximumDatasetFileByteCount(
        objectCount: Int,
        plaintextByteCount: Int64
    ) throws -> Int64 {
        let maximumFrames = try checkedAdd(
            plaintextByteCount / Int64(selectedChunkByteCount),
            Int64(objectCount)
        )
        var total = try checkedAdd(plaintextByteCount, Int64(datasetHeaderByteCount))
        total = try checkedAdd(
            total,
            try checkedMultiply(Int64(objectCount), Int64(datasetObjectHeaderByteCount))
        )
        total = try checkedAdd(
            total,
            try checkedMultiply(
                maximumFrames,
                Int64(datasetFrameHeaderByteCount + 16)
            )
        )
        return try checkedAdd(total, Int64(datasetFooterByteCount))
    }

    static func writeDatasetBytes(
        _ data: Data,
        descriptor: Int32,
        fileHasher: inout SHA256,
        fileByteCount: inout Int64
    ) throws {
        guard data.count <= selectedChunkByteCount else {
            throw ProbeError.resourceLimit
        }
        try writeAll(data, descriptor: descriptor, failure: .datasetInvalid)
        fileHasher.update(data: data)
        fileByteCount = try checkedAdd(fileByteCount, Int64(data.count))
    }

    static func readDatasetBytes(
        count: Int,
        descriptor: Int32,
        fileHasher: inout SHA256
    ) throws -> Data {
        guard count >= 0, count <= selectedChunkByteCount else {
            throw ProbeError.resourceLimit
        }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while offset < count {
                let readCount = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset
                )
                if readCount < 0 {
                    if errno == EINTR { continue }
                    throw ProbeError.datasetInvalid
                }
                guard readCount > 0 else { throw ProbeError.datasetInvalid }
                offset += readCount
            }
        }
        fileHasher.update(data: data)
        return data
    }

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    static func decodeUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func decodeUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    static func syncFileDescriptor(_ descriptor: Int32, failure: ProbeError) throws {
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw failure
        }
    }

    static func validatedDatasetLeafIdentity(
        descriptor: Int32,
        maximumByteCount: Int64?
    ) throws -> (identity: RegularLeafIdentity, allocatedByteCount: Int64) {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & mode_t(0o777) == mode_t(0o600),
              metadata.st_size >= 0,
              maximumByteCount.map({ metadata.st_size <= $0 }) ?? true,
              metadata.st_blocks >= 0,
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino) else {
            throw ProbeError.datasetInvalid
        }
        let allocated = try checkedMultiply(Int64(metadata.st_blocks), 512)
        return (
            RegularLeafIdentity(
                device: device,
                inode: inode,
                byteCount: metadata.st_size
            ),
            allocated
        )
    }

    static func replaceDatasetWithTruncatedCopy(
        parentDescriptor: Int32,
        originalDescriptor: Int32,
        originalIdentity: RegularLeafIdentity
    ) throws -> (descriptor: Int32, identity: RegularLeafIdentity) {
        let adversaryName = ".u0-named-dataset.truncated-adversary"
        guard originalIdentity.byteCount > 32,
              try leafIsAbsent(parentDescriptor, name: adversaryName) else {
            throw ProbeError.datasetInvalid
        }
        let replacement = openat(
            parentDescriptor,
            adversaryName,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard replacement >= 0 else { throw ProbeError.datasetInvalid }
        var shouldClose = true
        var replacementIdentity: RegularLeafIdentity?
        defer {
            if shouldClose { Darwin.close(replacement) }
            if let replacementIdentity {
                removeExactLeafIfPresent(
                    parentDescriptor: parentDescriptor,
                    name: adversaryName,
                    expectedIdentity: replacementIdentity
                )
            }
        }
        guard lseek(originalDescriptor, 0, SEEK_SET) == 0 else {
            throw ProbeError.datasetInvalid
        }
        var remaining = originalIdentity.byteCount - 32
        var buffer = [UInt8](repeating: 0, count: selectedChunkByteCount)
        while remaining > 0 {
            let requested = Int(min(Int64(buffer.count), remaining))
            let count = Darwin.read(originalDescriptor, &buffer, requested)
            if count < 0 {
                if errno == EINTR { continue }
                throw ProbeError.datasetInvalid
            }
            guard count > 0 else { throw ProbeError.datasetInvalid }
            try buffer.withUnsafeBytes { bytes in
                try writeAll(
                    Data(bytes.prefix(count)),
                    descriptor: replacement,
                    failure: .datasetInvalid
                )
            }
            remaining -= Int64(count)
        }
        try syncFileDescriptor(replacement, failure: .datasetInvalid)
        let validated = try validatedDatasetLeafIdentity(
            descriptor: replacement,
            maximumByteCount: originalIdentity.byteCount
        )
        replacementIdentity = validated.identity
        guard renameatx_np(
            parentDescriptor,
            adversaryName,
            parentDescriptor,
            datasetFinalLeafName,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw ProbeError.datasetInvalid
        }
        replacementIdentity = originalIdentity
        try unlinkLeaf(
            parentDescriptor: parentDescriptor,
            name: adversaryName,
            expectedIdentity: originalIdentity,
            failure: .datasetInvalid
        )
        replacementIdentity = nil
        try syncDescriptor(parentDescriptor)
        shouldClose = false
        return (replacement, validated.identity)
    }

    static func openFileDescriptorCount() -> Int {
        let entryByteCount = MemoryLayout<proc_fdinfo>.stride
        var buffer = [UInt8](repeating: 0, count: 256 * entryByteCount)
        let byteCount = buffer.withUnsafeMutableBytes { bytes in
            proc_pidinfo(
                getpid(),
                PROC_PIDLISTFDS,
                0,
                bytes.baseAddress,
                Int32(bytes.count)
            )
        }
        guard byteCount > 0 else { return Int.max }
        return Int(byteCount) / entryByteCount
    }

    static func elapsedMilliseconds(since started: UInt64) -> Int {
        max(1, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
    }
}

// MARK: - Chunk sizing

private extension BackupCapabilityProbe {
    struct ChunkMetric: Encodable {
        let chunkByteCount: Int
        let durationMilliseconds: Int
        let throughputMiBPerSecond: Double
        let peakRSSDeltaBytes: UInt64
        let cancellationLatencyMilliseconds: Int
        let cancellationObserved: Bool
        let cancellationProcessedByteCount: Int
        let processedByteCount: Int
    }

    struct ChunkCancellationMeasurement {
        let latencyMilliseconds: Int
        let processedByteCount: Int
    }

    struct ChunkProbeResult: Encodable {
        let category = "chunk"
        let status = "passed"
        let passed: Bool
        let totalStreamByteCount: Int
        let selectedChunkByteCount: Int
        let selectionPolicy: String
        let goldenVectorSHA256: String
        let metrics: [ChunkMetric]
    }

    static func chunkProbe(totalByteCount: Int) throws -> ChunkProbeResult {
        let metrics = try candidateChunkByteCounts.map {
            try measureChunk(byteCount: $0, totalByteCount: totalByteCount)
        }
        let bounded = metrics.allSatisfy {
            $0.processedByteCount == totalByteCount
                && $0.peakRSSDeltaBytes <= UInt64(64 * 1_024 * 1_024)
                && $0.cancellationObserved
                && $0.cancellationProcessedByteCount == 2 * $0.chunkByteCount
                && $0.cancellationLatencyMilliseconds <= 1_000
        }
        guard bounded else { throw ProbeError.resourceLimit }
        return ChunkProbeResult(
            passed: true,
            totalStreamByteCount: totalByteCount,
            selectedChunkByteCount: selectedChunkByteCount,
            selectionPolicy: "256KiB-balanced-v1-candidate",
            goldenVectorSHA256: try goldenVectorDigest(),
            metrics: metrics
        )
    }

    static func measureChunk(byteCount: Int, totalByteCount: Int) throws -> ChunkMetric {
        let key = SymmetricKey(data: Data(repeating: 0x4b, count: 32))
        let plaintext = Data(repeating: 0x53, count: byteCount)
        let baselineRSS = residentMemoryByteCount()
        var peakRSS = baselineRSS
        var processed = 0
        var counter: UInt64 = 0
        var checksum = 0
        let rssSampleInterval = 16 * 1_024 * 1_024
        var nextRSSSample = min(rssSampleInterval, totalByteCount)
        let started = DispatchTime.now().uptimeNanoseconds
        while processed < totalByteCount {
            let count = min(byteCount, totalByteCount - processed)
            let chunk = count == byteCount ? plaintext : Data(plaintext.prefix(count))
            let nonce = try AES.GCM.Nonce(data: nonceData(counter))
            let aad = Data("KLG-U0-CHUNK-\(byteCount)-\(counter)".utf8)
            let sealed = try AES.GCM.seal(chunk, using: key, nonce: nonce, authenticating: aad)
            checksum ^= sealed.ciphertext.count
            checksum ^= sealed.tag.first.map(Int.init) ?? 0
            processed += count
            counter += 1
            if processed >= nextRSSSample || processed == totalByteCount {
                peakRSS = max(peakRSS, residentMemoryByteCount())
                nextRSSSample = min(
                    totalByteCount,
                    nextRSSSample + rssSampleInterval
                )
            }
        }
        guard checksum >= 0 else { throw ProbeError.activationInvalid }
        let duration = max(
            1,
            Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        )
        let throughput = (Double(totalByteCount) / Double(1_024 * 1_024))
            / (Double(duration) / 1_000)
        let cancellation = try exerciseChunkCancellation(byteCount: byteCount)
        peakRSS = max(peakRSS, residentMemoryByteCount())
        return ChunkMetric(
            chunkByteCount: byteCount,
            durationMilliseconds: duration,
            throughputMiBPerSecond: throughput,
            peakRSSDeltaBytes: peakRSS >= baselineRSS ? peakRSS - baselineRSS : 0,
            cancellationLatencyMilliseconds: cancellation.latencyMilliseconds,
            cancellationObserved: true,
            cancellationProcessedByteCount: cancellation.processedByteCount,
            processedByteCount: processed
        )
    }

    static func exerciseChunkCancellation(
        byteCount: Int
    ) throws -> ChunkCancellationMeasurement {
        let state = ChunkCancellationState()
        let requestAfterByteCount = 2 * byteCount
        DispatchQueue.global(qos: .userInitiated).async {
            state.finish(Result {
                let key = SymmetricKey(data: Data(repeating: 0x43, count: 32))
                let plaintext = Data(repeating: 0x58, count: byteCount)
                var processed = 0
                var counter: UInt64 = 0
                var checksum = 0
                while processed < 8 * byteCount {
                    if state.isCancellationRequested { break }
                    let nonce = try AES.GCM.Nonce(data: nonceData(counter))
                    let sealed = try AES.GCM.seal(
                        plaintext,
                        using: key,
                        nonce: nonce,
                        authenticating: Data("KLG-U0-CANCEL-\(byteCount)-\(counter)".utf8)
                    )
                    checksum ^= sealed.ciphertext.count
                    checksum ^= sealed.tag.first.map(Int.init) ?? 0
                    processed += byteCount
                    counter += 1
                    if processed == requestAfterByteCount {
                        state.publishProgressAndWaitForCancellation()
                    }
                }
                guard state.isCancellationRequested,
                      processed == requestAfterByteCount,
                      checksum >= 0 else {
                    throw ProbeError.resourceLimit
                }
                return processed
            })
        }
        return try state.requestCancellationAfterProgress(timeout: 5)
    }

    static func goldenVectorDigest() throws -> String {
        let key = SymmetricKey(data: Data(repeating: 0x47, count: 32))
        let nonceBytes = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let plaintext = Data((0..<1_024).map { UInt8(truncatingIfNeeded: $0) })
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: Data("KLG-U0-GOLDEN-256K".utf8)
        )
        var bytes = nonceBytes
        bytes.append(sealed.ciphertext)
        bytes.append(sealed.tag)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func nonceData(_ counter: UInt64) -> Data {
        var prefix = UInt32(0x4b4c4730).bigEndian
        var suffix = counter.bigEndian
        var data = Data()
        withUnsafeBytes(of: &prefix) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &suffix) { data.append(contentsOf: $0) }
        return data
    }

    static func residentMemoryByteCount() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

// SAFETY: All cancellation state is protected by the private condition lock.
// Callers receive only copied timestamps and the completed result.
private final class ChunkCancellationState: @unchecked Sendable {
    private let condition = NSCondition()
    private var progressReached = false
    private var cancellationRequestedAt: UInt64?
    private var completedAt: UInt64?
    private var result: Result<Int, Error>?

    var isCancellationRequested: Bool {
        condition.withLock { cancellationRequestedAt != nil }
    }

    func publishProgressAndWaitForCancellation() {
        condition.lock()
        progressReached = true
        condition.broadcast()
        while cancellationRequestedAt == nil {
            condition.wait()
        }
        condition.unlock()
    }

    func finish(_ result: Result<Int, Error>) {
        condition.withLock {
            self.result = result
            completedAt = DispatchTime.now().uptimeNanoseconds
            condition.broadcast()
        }
    }

    func requestCancellationAfterProgress(
        timeout: TimeInterval
    ) throws -> BackupCapabilityProbe.ChunkCancellationMeasurement {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !progressReached, result == nil {
            guard condition.wait(until: deadline) else {
                cancellationRequestedAt = DispatchTime.now().uptimeNanoseconds
                condition.broadcast()
                throw BackupCapabilityProbe.ProbeError.resourceLimit
            }
        }
        if let result {
            _ = try result.get()
            throw BackupCapabilityProbe.ProbeError.resourceLimit
        }
        let requestedAt = DispatchTime.now().uptimeNanoseconds
        cancellationRequestedAt = requestedAt
        condition.broadcast()
        while result == nil {
            guard condition.wait(until: deadline) else {
                throw BackupCapabilityProbe.ProbeError.resourceLimit
            }
        }
        guard let result, let completedAt else {
            throw BackupCapabilityProbe.ProbeError.resourceLimit
        }
        return try BackupCapabilityProbe.ChunkCancellationMeasurement(
            latencyMilliseconds: Int((completedAt - requestedAt) / 1_000_000),
            processedByteCount: result.get()
        )
    }
}

// MARK: - Filesystem primitives

private extension BackupCapabilityProbe {
    struct RegularLeafIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let byteCount: Int64
    }

    struct ValidatedLeafRead {
        let data: Data
        let identity: RegularLeafIdentity
    }

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

    static func validateExactPermissions(
        _ url: URL,
        expectedMode: mode_t,
        directory: Bool
    ) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              metadata.st_uid == geteuid(),
              directory || metadata.st_nlink == 1 else {
            throw ProbeError.identityInvalid
        }
        guard metadata.st_mode & mode_t(0o777) == expectedMode else {
            throw ProbeError.identityPermissionFailure
        }
    }

    static func directoryIdentity(_ url: URL) throws -> DirectoryIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              device > 0,
              inode > 0 else {
            throw ProbeError.activationInvalid
        }
        return DirectoryIdentity(device: device, inode: inode)
    }

    static func optionalDirectoryIdentity(_ url: URL) throws -> DirectoryIdentity? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw ProbeError.ioFailure(errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              device > 0,
              inode > 0 else {
            throw ProbeError.activationInvalid
        }
        return DirectoryIdentity(device: device, inode: inode)
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
            throw ProbeError.repositoryInvalid
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

    static func openPrivateParent(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw ProbeError.identityInvalid }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            Darwin.close(descriptor)
            throw ProbeError.identityInvalid
        }
        guard metadata.st_mode & mode_t(0o777) == mode_t(0o700) else {
            Darwin.close(descriptor)
            throw ProbeError.identityPermissionFailure
        }
        return descriptor
    }

    static func openRepositoryParent(_ url: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw ProbeError.repositoryInvalid }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            Darwin.close(descriptor)
            throw ProbeError.repositoryInvalid
        }
        return descriptor
    }

    static func openOrCreateSelectedRepository(
        selectedParentDescriptor: Int32,
        expectedIdentity: DirectoryIdentity?
    ) throws -> (descriptor: Int32, identity: DirectoryIdentity, created: Bool) {
        let created: Bool
        if expectedIdentity == nil {
            guard mkdirat(
                selectedParentDescriptor,
                selectedRepositoryLeafName,
                mode_t(0o700)
            ) == 0 else {
                throw ProbeError.repositoryInvalid
            }
            created = true
        } else {
            created = false
        }
        let descriptor = openat(
            selectedParentDescriptor,
            selectedRepositoryLeafName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ProbeError.repositoryInvalid
        }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == geteuid(),
                  metadata.st_mode & mode_t(0o777) == mode_t(0o700),
                  let device = UInt64(exactly: metadata.st_dev),
                  let inode = UInt64(exactly: metadata.st_ino),
                  device > 0,
                  inode > 0 else {
                throw ProbeError.repositoryInvalid
            }
            let identity = DirectoryIdentity(device: device, inode: inode)
            if let expectedIdentity, identity != expectedIdentity {
                throw ProbeError.repositoryInvalid
            }
            try recheckDirectoryLeaf(
                parentDescriptor: selectedParentDescriptor,
                name: selectedRepositoryLeafName,
                expectedIdentity: identity,
                failure: .repositoryInvalid
            )
            return (descriptor, identity, created)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func descriptorIdentity(_ descriptor: Int32) throws -> DirectoryIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              device > 0,
              inode > 0 else {
            throw ProbeError.ioFailure(errno)
        }
        return DirectoryIdentity(device: device, inode: inode)
    }

    static func directoryLeafIdentity(
        parentDescriptor: Int32,
        name: String,
        failure: ProbeError
    ) throws -> DirectoryIdentity {
        guard isFixedLeafName(name) else { throw ProbeError.invalidArguments }
        var metadata = stat()
        guard fstatat(parentDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(0o777) == mode_t(0o700),
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              device > 0,
              inode > 0 else {
            throw failure
        }
        return DirectoryIdentity(device: device, inode: inode)
    }

    static func recheckDirectoryLeaf(
        parentDescriptor: Int32,
        name: String,
        expectedIdentity: DirectoryIdentity,
        failure: ProbeError
    ) throws {
        guard try directoryLeafIdentity(
            parentDescriptor: parentDescriptor,
            name: name,
            failure: failure
        ) == expectedIdentity else {
            throw failure
        }
    }

    static func recheckVisibleParent(
        _ url: URL,
        expected: DirectoryIdentity,
        expectedMode: mode_t? = nil,
        failure: ProbeError
    ) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              DirectoryIdentity(device: device, inode: inode) == expected else {
            throw failure
        }
        if let expectedMode,
           metadata.st_mode & mode_t(0o777) != expectedMode {
            if case .identityInvalid = failure {
                throw ProbeError.identityPermissionFailure
            }
            throw failure
        }
    }

    static func leafIsAbsent(_ parentDescriptor: Int32, name: String) throws -> Bool {
        guard isFixedLeafName(name) else { throw ProbeError.invalidArguments }
        var metadata = stat()
        if fstatat(parentDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return false
        }
        guard errno == ENOENT else { throw ProbeError.ioFailure(errno) }
        return true
    }

    static func readValidatedLeaf(
        parentDescriptor: Int32,
        name: String,
        maximumByteCount: Int,
        failure: ProbeError
    ) throws -> ValidatedLeafRead {
        guard isFixedLeafName(name), maximumByteCount > 0 else {
            throw ProbeError.invalidArguments
        }
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw failure }
        defer { Darwin.close(descriptor) }
        let initial = try validatedRegularLeafIdentity(
            descriptor: descriptor,
            maximumByteCount: maximumByteCount,
            failure: failure
        )
        var result = Data()
        result.reserveCapacity(Int(initial.byteCount))
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw failure
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumByteCount else { throw failure }
        }
        guard result.count == Int(initial.byteCount),
              try validatedRegularLeafIdentity(
                descriptor: descriptor,
                maximumByteCount: maximumByteCount,
                failure: failure
              ) == initial else {
            throw failure
        }
        try recheckLeaf(
            parentDescriptor: parentDescriptor,
            name: name,
            expectedIdentity: initial,
            failure: failure
        )
        return ValidatedLeafRead(data: result, identity: initial)
    }

    static func validatedRegularLeafIdentity(
        descriptor: Int32,
        maximumByteCount: Int,
        failure: ProbeError
    ) throws -> RegularLeafIdentity {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= maximumByteCount,
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino) else {
            throw failure
        }
        guard metadata.st_mode & mode_t(0o777) == mode_t(0o600) else {
            if case .identityInvalid = failure {
                throw ProbeError.identityPermissionFailure
            }
            throw failure
        }
        return RegularLeafIdentity(
            device: device,
            inode: inode,
            byteCount: metadata.st_size
        )
    }

    static func recheckLeaf(
        parentDescriptor: Int32,
        name: String,
        expectedIdentity: RegularLeafIdentity,
        failure: ProbeError
    ) throws {
        var metadata = stat()
        guard fstatat(parentDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino) else {
            throw failure
        }
        guard metadata.st_mode & mode_t(0o777) == mode_t(0o600) else {
            if case .identityInvalid = failure {
                throw ProbeError.identityPermissionFailure
            }
            throw failure
        }
        guard RegularLeafIdentity(
                device: device,
                inode: inode,
                byteCount: metadata.st_size
              ) == expectedIdentity else {
            throw failure
        }
    }

    @discardableResult
    static func writeExclusiveLeaf(
        _ data: Data,
        parentDescriptor: Int32,
        name: String,
        failure: ProbeError
    ) throws -> RegularLeafIdentity {
        guard isFixedLeafName(name) else { throw ProbeError.invalidArguments }
        let descriptor = openat(
            parentDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw failure }
        var closeNeeded = true
        defer { if closeNeeded { Darwin.close(descriptor) } }
        do {
            try writeAll(data, descriptor: descriptor, failure: failure)
            if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
                throw failure
            }
            let identity = try validatedRegularLeafIdentity(
                descriptor: descriptor,
                maximumByteCount: max(data.count, 1),
                failure: failure
            )
            guard identity.byteCount == data.count,
                  Darwin.close(descriptor) == 0 else {
                throw failure
            }
            closeNeeded = false
            try recheckLeaf(
                parentDescriptor: parentDescriptor,
                name: name,
                expectedIdentity: identity,
                failure: failure
            )
            return identity
        } catch {
            if let identity = try? validatedRegularLeafIdentity(
                descriptor: descriptor,
                maximumByteCount: max(data.count, 1),
                failure: failure
            ) {
                try? unlinkLeaf(
                    parentDescriptor: parentDescriptor,
                    name: name,
                    expectedIdentity: identity,
                    failure: failure
                )
            }
            throw error
        }
    }

    static func replaceLeaf(
        _ data: Data,
        parentDescriptor: Int32,
        name: String,
        expectedIdentity: RegularLeafIdentity,
        expectedBytes: Data,
        maximumByteCount: Int,
        failure: ProbeError
    ) throws -> RegularLeafIdentity {
        let temporaryName = ".\(name).u0-replacement"
        guard try leafIsAbsent(parentDescriptor, name: temporaryName) else { throw failure }
        let replacementIdentity = try writeExclusiveLeaf(
            data,
            parentDescriptor: parentDescriptor,
            name: temporaryName,
            failure: failure
        )
        var temporaryCleanupIdentity: RegularLeafIdentity? = replacementIdentity
        defer {
            if let temporaryCleanupIdentity {
                try? unlinkLeaf(
                    parentDescriptor: parentDescriptor,
                    name: temporaryName,
                    expectedIdentity: temporaryCleanupIdentity,
                    failure: failure
                )
            }
        }
        let current = try readValidatedLeaf(
            parentDescriptor: parentDescriptor,
            name: name,
            maximumByteCount: maximumByteCount,
            failure: failure
        )
        guard current.identity == expectedIdentity, current.data == expectedBytes else {
            throw failure
        }
        guard renameatx_np(
            parentDescriptor,
            temporaryName,
            parentDescriptor,
            name,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw failure
        }
        temporaryCleanupIdentity = expectedIdentity
        let displaced = try readValidatedLeaf(
            parentDescriptor: parentDescriptor,
            name: temporaryName,
            maximumByteCount: maximumByteCount,
            failure: failure
        )
        guard displaced.identity == expectedIdentity, displaced.data == expectedBytes else {
            if (try? recheckLeaf(
                parentDescriptor: parentDescriptor,
                name: name,
                expectedIdentity: replacementIdentity,
                failure: failure
            )) != nil, renameatx_np(
                    parentDescriptor,
                    temporaryName,
                    parentDescriptor,
                    name,
                    UInt32(RENAME_SWAP)
                ) == 0 {
                temporaryCleanupIdentity = replacementIdentity
            } else {
                temporaryCleanupIdentity = nil
            }
            throw failure
        }
        try unlinkLeaf(
            parentDescriptor: parentDescriptor,
            name: temporaryName,
            expectedIdentity: displaced.identity,
            failure: failure
        )
        temporaryCleanupIdentity = nil
        try syncDescriptor(parentDescriptor)
        let final = try readValidatedLeaf(
            parentDescriptor: parentDescriptor,
            name: name,
            maximumByteCount: maximumByteCount,
            failure: failure
        )
        guard final.identity == replacementIdentity, final.data == data else { throw failure }
        return final.identity
    }

    static func unlinkLeaf(
        parentDescriptor: Int32,
        name: String,
        expectedIdentity: RegularLeafIdentity,
        failure: ProbeError
    ) throws {
        try recheckLeaf(
            parentDescriptor: parentDescriptor,
            name: name,
            expectedIdentity: expectedIdentity,
            failure: failure
        )
        guard unlinkat(parentDescriptor, name, 0) == 0 else { throw failure }
    }

    static func removeExactLeafIfPresent(
        parentDescriptor: Int32,
        name: String,
        expectedIdentity: RegularLeafIdentity
    ) {
        var metadata = stat()
        guard fstatat(parentDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino),
              RegularLeafIdentity(
                  device: device,
                  inode: inode,
                  byteCount: metadata.st_size
              ) == expectedIdentity else {
            return
        }
        if unlinkat(parentDescriptor, name, 0) == 0 {
            try? syncDescriptor(parentDescriptor)
        }
    }

    static func writeAll(_ data: Data, descriptor: Int32, failure: ProbeError) throws {
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
                    throw failure
                }
                offset += count
            }
        }
    }

    static func isFixedLeafName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    static func installIdentityAdversaryIfRequested(
        _ adversarialCase: String?,
        parent: URL,
        parentDescriptor: Int32,
        leafName: String
    ) throws -> (() -> Void)? {
        switch adversarialCase {
        case nil:
            return nil
        case "parent-replacement":
            return try installParentReplacement(at: parent)
        case "leaf-replacement":
            return try installLeafReplacement(
                parentDescriptor: parentDescriptor,
                leafName: leafName,
                failure: .identityInvalid
            )
        default:
            throw ProbeError.invalidArguments
        }
    }

    static func installParentReplacement(at parent: URL) throws -> () -> Void {
        let held = parent.deletingLastPathComponent().appendingPathComponent(
            ".\(parent.lastPathComponent).u0-held",
            isDirectory: true
        )
        guard !pathExists(held), Darwin.rename(parent.path, held.path) == 0 else {
            throw ProbeError.adversarialSetupUnavailable
        }
        guard Darwin.mkdir(parent.path, mode_t(0o700)) == 0 else {
            _ = Darwin.rename(held.path, parent.path)
            throw ProbeError.adversarialSetupUnavailable
        }
        return {
            guard Darwin.rmdir(parent.path) == 0 else { return }
            _ = Darwin.rename(held.path, parent.path)
        }
    }

    static func installLeafReplacement(
        parentDescriptor: Int32,
        leafName: String,
        failure: ProbeError
    ) throws -> () -> Void {
        let heldName = ".\(leafName).u0-held"
        guard try leafIsAbsent(parentDescriptor, name: heldName),
              renameat(parentDescriptor, leafName, parentDescriptor, heldName) == 0 else {
            throw ProbeError.adversarialSetupUnavailable
        }
        let attackerBytes = Data("U0-ATTACKER-SUBSTITUTION".utf8)
        let attackerIdentity: RegularLeafIdentity
        do {
            attackerIdentity = try writeExclusiveLeaf(
                attackerBytes,
                parentDescriptor: parentDescriptor,
                name: leafName,
                failure: .adversarialSetupUnavailable
            )
        } catch {
            _ = renameat(parentDescriptor, heldName, parentDescriptor, leafName)
            throw error
        }
        return {
            guard (try? recheckLeaf(
                parentDescriptor: parentDescriptor,
                name: leafName,
                expectedIdentity: attackerIdentity,
                failure: failure
            )) != nil else { return }
            guard unlinkat(parentDescriptor, leafName, 0) == 0 else { return }
            _ = renameat(parentDescriptor, heldName, parentDescriptor, leafName)
        }
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

    static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ProbeError.resourceLimit }
        return result.partialValue
    }

    static func checkedMultiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw ProbeError.resourceLimit }
        return result.partialValue
    }

    static func availableCapacityByteCount(at url: URL) throws -> Int64 {
        var filesystem = statfs()
        guard statfs(url.path, &filesystem) == 0,
              let availableBlocks = Int64(exactly: filesystem.f_bavail),
              let blockSize = Int64(exactly: filesystem.f_bsize) else {
            throw ProbeError.ioFailure(errno)
        }
        return try checkedMultiply(availableBlocks, blockSize)
    }

    static func availableCapacityByteCount(descriptor: Int32) throws -> Int64 {
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0,
              let availableBlocks = Int64(exactly: filesystem.f_bavail),
              let blockSize = Int64(exactly: filesystem.f_bsize) else {
            throw ProbeError.ioFailure(errno)
        }
        return try checkedMultiply(availableBlocks, blockSize)
    }
}
