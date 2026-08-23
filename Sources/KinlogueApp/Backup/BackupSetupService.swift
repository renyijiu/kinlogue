import Foundation
import KinlogueCore
import KinloguePlatform

enum BackupSetupError: Error, Equatable, Sendable {
    case configurationAlreadyExists
    case noPendingEnrollment
    case independentSaveNotConfirmed
    case recoveryCodeMismatch
}

struct BackupSetupSession: Sendable {
    let destination: BackupDestinationSelection
    fileprivate let material: BackupEnrollmentMaterial

    var recoveryCode: String { material.recoveryCode }
    var descriptor: BackupSetDescriptor { material.descriptor }
    var authorization: BackupDeviceAuthorization { material.authorization }
}

actor BackupSetupService {
    private let configurationStore: BackupLocalConfigurationStore
    private let destinationAuthority: BackupDestinationAuthority
    private let enrollmentPublisher: any BackupEnrollmentPublishing
    private let enrollmentGenerator: @Sendable () throws -> BackupEnrollmentMaterial

    init(
        configurationStore: BackupLocalConfigurationStore,
        destinationAuthority: BackupDestinationAuthority,
        enrollmentPublisher: (any BackupEnrollmentPublishing)? = nil,
        enrollmentGenerator: @escaping @Sendable () throws -> BackupEnrollmentMaterial = {
            try BackupKeyHierarchy.makeEnrollment()
        }
    ) {
        self.configurationStore = configurationStore
        self.destinationAuthority = destinationAuthority
        self.enrollmentPublisher = enrollmentPublisher ?? destinationAuthority
        self.enrollmentGenerator = enrollmentGenerator
    }

    func begin(
        selectedParent: URL,
        activeVaultURL: URL
    ) async throws -> BackupSetupSession {
        guard try await configurationStore.load() == nil else {
            throw BackupSetupError.configurationAlreadyExists
        }
        let destination = try destinationAuthority.prepareSelectedParent(
            selectedParent,
            activeVaultURL: activeVaultURL
        )
        // Generate only after confirming that no durable identity already
        // exists, so repeated setup cannot silently replace a signer.
        let material = try enrollmentGenerator()
        return .init(
            destination: destination,
            material: material
        )
    }

    func complete(
        _ session: BackupSetupSession,
        recoveryCodeReentry: String,
        independentlySaved: Bool
    ) async throws -> BackupLocalConfiguration {
        guard independentlySaved else {
            throw BackupSetupError.independentSaveNotConfirmed
        }
        try validateFullReentry(
            recoveryCodeReentry,
            expectedCode: session.recoveryCode,
            descriptor: session.descriptor
        )

        let pending: BackupLocalConfiguration
        if let current = try await configurationStore.load() {
            guard current.phase == .pending,
                  current.enrollmentEpoch == session.material.writerEpoch,
                  current.descriptor == session.descriptor,
                  current.authorization == session.authorization else {
                throw BackupSetupError.configurationAlreadyExists
            }
            pending = current
        } else {
            let request = try BackupPendingEnrollment(
                bookmarkData: session.destination.bookmarkData,
                selectedDirectoryIdentity: session.destination.selectedDirectoryIdentity,
                repositoryDirectoryIdentity: session.destination.repositoryDirectoryIdentity,
                descriptor: session.material.descriptor,
                authorization: session.material.authorization,
                deviceSigningSeed: session.material.deviceSigningSeed,
                writerEpoch: session.material.writerEpoch
            )
            pending = try await configurationStore.createPending(request)
        }

        let refreshedBookmark = try enrollmentPublisher.publish(
            descriptor: session.descriptor,
            authorization: session.authorization,
            selection: session.destination
        )
        let promotable: BackupLocalConfiguration
        if let refreshedBookmark {
            promotable = try await configurationStore.refreshPendingBookmark(
                refreshedBookmark,
                enrollmentEpoch: pending.enrollmentEpoch,
                expectedRevision: pending.revision
            )
        } else {
            promotable = pending
        }
        return try await configurationStore.promotePending(
            enrollmentEpoch: promotable.enrollmentEpoch,
            expectedRevision: promotable.revision
        )
    }

    func resumePending(recoveryCode: String) async throws -> BackupLocalConfiguration {
        guard let pending = try await configurationStore.load(), pending.phase == .pending else {
            throw BackupSetupError.noPendingEnrollment
        }
        try verifyRecoveryCode(recoveryCode, descriptor: pending.descriptor)
        var current = pending
        if let refreshedBookmark = try enrollmentPublisher.publish(configuration: pending) {
            current = try await configurationStore.refreshPendingBookmark(
                refreshedBookmark,
                enrollmentEpoch: pending.enrollmentEpoch,
                expectedRevision: pending.revision
            )
        }
        return try await configurationStore.promotePending(
            enrollmentEpoch: current.enrollmentEpoch,
            expectedRevision: current.revision
        )
    }

    func abandonPending() async throws {
        guard let pending = try await configurationStore.load(), pending.phase == .pending else {
            throw BackupSetupError.noPendingEnrollment
        }
        try await configurationStore.abandonPending(
            enrollmentEpoch: pending.enrollmentEpoch,
            expectedRevision: pending.revision
        )
    }

    private func verifyRecoveryCode(
        _ recoveryCode: String,
        descriptor: BackupSetDescriptor
    ) throws {
        do {
            let seed = try BackupRecoveryCode.decode(recoveryCode)
            try BackupKeyHierarchy.validateRecoverySeed(seed, descriptor: descriptor)
        } catch {
            throw BackupSetupError.recoveryCodeMismatch
        }
    }

    private func validateFullReentry(
        _ recoveryCode: String,
        expectedCode: String,
        descriptor: BackupSetDescriptor
    ) throws {
        guard recoveryCode == expectedCode else {
            throw BackupSetupError.recoveryCodeMismatch
        }
        try verifyRecoveryCode(recoveryCode, descriptor: descriptor)
    }
}
