import Foundation
import KinloguePlatform

enum AppRuntimeIdentityError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case missingBundleIdentifier
    case bundleIdentifierMismatch
    case invalidAcceptanceConfiguration
    case invalidAcceptanceRunID
    case invalidSyntheticSmokeArguments
    case syntheticSmokeRequiresAcceptance
}

enum AppRuntimeMode: Equatable, Sendable {
    case production
    case acceptance(runID: String)
}

struct RuntimeVaultIdentity: Equatable, Sendable {
    let rootURL: URL
}

struct RuntimeBackupIdentity: Equatable, Sendable {
    let rootURL: URL
}

struct AppRuntimeIdentity: Equatable, Sendable {
    static let productionBundleIdentifier = "com.kinlogue.mac"
    static let acceptanceEnabledInfoKey = "KinlogueAcceptanceEnabled"
    static let acceptanceRunIDInfoKey = "KinlogueAcceptanceRunID"
    static let syntheticSmokeArgument = "--synthetic-smoke"

    let mode: AppRuntimeMode
    let sourceVault: RuntimeVaultIdentity
    let backupIdentity: RuntimeBackupIdentity
    let syntheticSmokeRequested: Bool

    private init(
        mode: AppRuntimeMode,
        sourceVault: RuntimeVaultIdentity,
        backupIdentity: RuntimeBackupIdentity,
        syntheticSmokeRequested: Bool
    ) {
        self.mode = mode
        self.sourceVault = sourceVault
        self.backupIdentity = backupIdentity
        self.syntheticSmokeRequested = syntheticSmokeRequested
    }

    static func current() throws -> AppRuntimeIdentity {
        let applicationSupportDirectory: URL
        do {
            applicationSupportDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw AppRuntimeIdentityError.applicationSupportUnavailable
        }

        return try resolve(
            bundleInfo: Bundle.main.infoDictionary ?? [:],
            arguments: CommandLine.arguments,
            trustedApplicationSupportDirectory: applicationSupportDirectory
        )
    }

    /// Resolves only values read from the signed bundle and the OS-provided
    /// Application Support location. It deliberately has no environment or
    /// user-supplied path input.
    static func resolve(
        bundleInfo: [String: Any],
        arguments: [String],
        trustedApplicationSupportDirectory: URL
    ) throws -> AppRuntimeIdentity {
        guard let bundleIdentifier = bundleInfo["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            throw AppRuntimeIdentityError.missingBundleIdentifier
        }
        let smokeArgumentCount = arguments.lazy
            .filter { $0 == syntheticSmokeArgument }
            .count
        guard smokeArgumentCount <= 1 else {
            throw AppRuntimeIdentityError.invalidSyntheticSmokeArguments
        }
        let syntheticSmokeRequested = smokeArgumentCount == 1

        let marker = try acceptanceMarker(from: bundleInfo)
        let runIDValue = bundleInfo[acceptanceRunIDInfoKey]

        guard marker else {
            guard runIDValue == nil else {
                throw AppRuntimeIdentityError.invalidAcceptanceConfiguration
            }
            guard bundleIdentifier == productionBundleIdentifier else {
                throw AppRuntimeIdentityError.bundleIdentifierMismatch
            }
            guard !syntheticSmokeRequested else {
                throw AppRuntimeIdentityError.syntheticSmokeRequiresAcceptance
            }

            let rootURL = trustedApplicationSupportDirectory
                .appendingPathComponent("Kinlogue", isDirectory: true)
                .appendingPathComponent("Vault", isDirectory: true)
            let backupIdentityURL = rootURL.deletingLastPathComponent()
                .appendingPathComponent("BackupIdentity", isDirectory: true)
            return AppRuntimeIdentity(
                mode: .production,
                sourceVault: RuntimeVaultIdentity(
                    rootURL: rootURL
                ),
                backupIdentity: RuntimeBackupIdentity(rootURL: backupIdentityURL),
                syntheticSmokeRequested: false
            )
        }

        guard let runID = runIDValue as? String else {
            throw AppRuntimeIdentityError.invalidAcceptanceConfiguration
        }
        guard validRunID(runID) else {
            throw AppRuntimeIdentityError.invalidAcceptanceRunID
        }

        let acceptanceBundleIdentifier = "\(productionBundleIdentifier).acceptance.\(runID)"
        guard bundleIdentifier == acceptanceBundleIdentifier else {
            throw AppRuntimeIdentityError.bundleIdentifierMismatch
        }

        let sourceVault = acceptanceSourceVault(
            applicationSupport: trustedApplicationSupportDirectory,
            runID: runID
        )
        return AppRuntimeIdentity(
            mode: .acceptance(runID: runID),
            sourceVault: sourceVault,
            backupIdentity: RuntimeBackupIdentity(
                rootURL: sourceVault.rootURL.deletingLastPathComponent()
                    .appendingPathComponent("BackupIdentity", isDirectory: true)
            ),
            syntheticSmokeRequested: syntheticSmokeRequested
        )
    }

    private static func acceptanceMarker(from bundleInfo: [String: Any]) throws -> Bool {
        guard let value = bundleInfo[acceptanceEnabledInfoKey] else { return false }
        guard let marker = value as? Bool else {
            throw AppRuntimeIdentityError.invalidAcceptanceConfiguration
        }
        return marker
    }

    private static func acceptanceSourceVault(
        applicationSupport: URL,
        runID: String
    ) -> RuntimeVaultIdentity {
        let rootURL = applicationSupport
            .appendingPathComponent("Kinlogue", isDirectory: true)
            .appendingPathComponent("Acceptance", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
            .appendingPathComponent("SourceVault", isDirectory: true)
        return RuntimeVaultIdentity(rootURL: rootURL)
    }

    static func validRunID(_ runID: String) -> Bool {
        let bytes = runID.utf8
        guard (24...32).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}
