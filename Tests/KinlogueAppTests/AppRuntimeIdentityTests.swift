import Foundation
import Testing
@testable import KinlogueApp

struct AppRuntimeIdentityTests {
    private let supportDirectory = URL(
        fileURLWithPath: "/Users/acceptance/Library/Application Support",
        isDirectory: true
    )

    @Test
    func productionUsesTheExistingLocalVaultIdentity() throws {
        let identity = try resolve(
            bundleInfo: ["CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier]
        )

        #expect(identity.mode == .production)
        #expect(identity.sourceVault.rootURL.path
            == "/Users/acceptance/Library/Application Support/Kinlogue/Vault")
        #expect(identity.backupIdentity.rootURL.path
            == "/Users/acceptance/Library/Application Support/Kinlogue/BackupIdentity")
        #expect(identity.backupIdentity.rootURL.deletingLastPathComponent()
            == identity.sourceVault.rootURL.deletingLastPathComponent())
        #expect(!identity.syntheticSmokeRequested)
    }

    @Test
    func disabledAcceptanceMarkerStillUsesProductionIdentity() throws {
        let identity = try resolve(bundleInfo: [
            "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
            AppRuntimeIdentity.acceptanceEnabledInfoKey: false,
        ])

        #expect(identity.mode == .production)
    }

    @Test
    func productionRejectsSyntheticSmoke() {
        #expect(throws: AppRuntimeIdentityError.syntheticSmokeRequiresAcceptance) {
            try resolve(
                bundleInfo: ["CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier],
                arguments: ["Kinlogue", AppRuntimeIdentity.syntheticSmokeArgument]
            )
        }
    }

    @Test
    func acceptanceDerivesAnIsolatedSourceIdentityFromSignedBundleInfo() throws {
        let runID = "0123456789abcdef01234567"
        let bundleIdentifier = "com.kinlogue.mac.acceptance.\(runID)"
        let identity = try resolve(
            bundleInfo: [
                "CFBundleIdentifier": bundleIdentifier,
                AppRuntimeIdentity.acceptanceEnabledInfoKey: true,
                AppRuntimeIdentity.acceptanceRunIDInfoKey: runID,
            ],
            arguments: ["Kinlogue", AppRuntimeIdentity.syntheticSmokeArgument]
        )
        #expect(identity.mode == .acceptance(runID: runID))
        #expect(identity.syntheticSmokeRequested)
        #expect(identity.sourceVault.rootURL.path
            == "/Users/acceptance/Library/Application Support/Kinlogue/Acceptance/\(runID)/SourceVault")
        #expect(identity.backupIdentity.rootURL.path
            == "/Users/acceptance/Library/Application Support/Kinlogue/Acceptance/\(runID)/BackupIdentity")
        #expect(identity.backupIdentity.rootURL.deletingLastPathComponent()
            == identity.sourceVault.rootURL.deletingLastPathComponent())
    }

    @Test
    func acceptanceIdentityDoesNotRequireSmokeToBeRequested() throws {
        let runID = "abcdef0123456789abcdef01"
        let identity = try acceptanceIdentity(runID: runID)

        #expect(identity.mode == .acceptance(runID: runID))
        #expect(!identity.syntheticSmokeRequested)
    }

    @Test(arguments: [
        "0123456789abcdef0123456",
        "0123456789abcdef0123456789abcdef0",
        "0123456789ABCDEF01234567",
        "0123456789abcdef0123456g",
        "0123456789abcdef012345/7",
        "0123456789abcdef012345é",
    ])
    func acceptanceRejectsNonCanonicalRunID(_ runID: String) {
        #expect(throws: AppRuntimeIdentityError.invalidAcceptanceRunID) {
            try acceptanceIdentity(runID: runID)
        }
    }

    @Test(arguments: [
        "0123456789abcdef01234567",
        "0123456789abcdef0123456789abcdef",
    ])
    func acceptanceAllowsCanonicalRunIDBoundaryLengths(_ runID: String) throws {
        let identity = try acceptanceIdentity(runID: runID)

        #expect(identity.mode == .acceptance(runID: runID))
    }

    @Test
    func acceptanceRequiresTheBundleIdentifierToContainTheExactRunID() {
        let runID = "0123456789abcdef01234567"
        #expect(throws: AppRuntimeIdentityError.bundleIdentifierMismatch) {
            try resolve(bundleInfo: [
                "CFBundleIdentifier": "com.kinlogue.mac.acceptance.abcdef0123456789abcdef01",
                AppRuntimeIdentity.acceptanceEnabledInfoKey: true,
                AppRuntimeIdentity.acceptanceRunIDInfoKey: runID,
            ])
        }
    }

    @Test
    func acceptanceRequiresBothTheMarkerAndRunID() {
        let runID = "0123456789abcdef01234567"
        #expect(throws: AppRuntimeIdentityError.invalidAcceptanceConfiguration) {
            try resolve(bundleInfo: [
                "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
                AppRuntimeIdentity.acceptanceRunIDInfoKey: runID,
            ])
        }
        #expect(throws: AppRuntimeIdentityError.invalidAcceptanceConfiguration) {
            try resolve(bundleInfo: [
                "CFBundleIdentifier": "com.kinlogue.mac.acceptance.\(runID)",
                AppRuntimeIdentity.acceptanceEnabledInfoKey: true,
            ])
        }
        #expect(throws: AppRuntimeIdentityError.invalidAcceptanceConfiguration) {
            try resolve(bundleInfo: [
                "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
                AppRuntimeIdentity.acceptanceEnabledInfoKey: false,
                AppRuntimeIdentity.acceptanceRunIDInfoKey: runID,
            ])
        }
    }

    @Test
    func acceptanceRejectsNonBooleanMarkerAndNonStringRunID() {
        #expect(throws: AppRuntimeIdentityError.invalidAcceptanceConfiguration) {
            try resolve(bundleInfo: [
                "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
                AppRuntimeIdentity.acceptanceEnabledInfoKey: "true",
            ])
        }
        #expect(throws: AppRuntimeIdentityError.invalidAcceptanceConfiguration) {
            try resolve(bundleInfo: [
                "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
                AppRuntimeIdentity.acceptanceEnabledInfoKey: 1,
            ])
        }
        #expect(throws: AppRuntimeIdentityError.invalidAcceptanceConfiguration) {
            try resolve(bundleInfo: [
                "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
                AppRuntimeIdentity.acceptanceEnabledInfoKey: true,
                AppRuntimeIdentity.acceptanceRunIDInfoKey: 123,
            ])
        }
    }

    @Test
    func missingOrUnexpectedBundleIdentifierFailsClosed() {
        #expect(throws: AppRuntimeIdentityError.missingBundleIdentifier) {
            try resolve(bundleInfo: [:])
        }
        #expect(throws: AppRuntimeIdentityError.bundleIdentifierMismatch) {
            try resolve(bundleInfo: ["CFBundleIdentifier": "com.example.Kinlogue"])
        }
    }

    @Test
    func duplicateSyntheticSmokeArgumentFailsClosed() {
        #expect(throws: AppRuntimeIdentityError.invalidSyntheticSmokeArguments) {
            try resolve(
                bundleInfo: ["CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier],
                arguments: [
                    "Kinlogue",
                    AppRuntimeIdentity.syntheticSmokeArgument,
                    AppRuntimeIdentity.syntheticSmokeArgument,
                ]
            )
        }
    }

    @Test
    func differentRunsDeriveDisjointVaultIdentities() throws {
        let first = try acceptanceIdentity(runID: "0123456789abcdef01234567")
        let second = try acceptanceIdentity(runID: "abcdef0123456789abcdef01")

        #expect(first.sourceVault.rootURL != second.sourceVault.rootURL)
    }

    @Test
    func pathOverrideLikeInputsAreIgnored() throws {
        let identity = try resolve(
            bundleInfo: [
                "CFBundleIdentifier": AppRuntimeIdentity.productionBundleIdentifier,
                "KinlogueVaultPath": "/tmp/foreign-vault",
            ],
            arguments: [
                "Kinlogue",
                "--vault-path=/tmp/foreign-vault",
            ]
        )

        #expect(identity.sourceVault.rootURL.path
            == "/Users/acceptance/Library/Application Support/Kinlogue/Vault")
    }

    private func resolve(
        bundleInfo: [String: Any],
        arguments: [String] = ["Kinlogue"]
    ) throws -> AppRuntimeIdentity {
        try AppRuntimeIdentity.resolve(
            bundleInfo: bundleInfo,
            arguments: arguments,
            trustedApplicationSupportDirectory: supportDirectory
        )
    }

    private func acceptanceIdentity(runID: String) throws -> AppRuntimeIdentity {
        try resolve(bundleInfo: [
            "CFBundleIdentifier": "com.kinlogue.mac.acceptance.\(runID)",
            AppRuntimeIdentity.acceptanceEnabledInfoKey: true,
            AppRuntimeIdentity.acceptanceRunIDInfoKey: runID,
        ])
    }
}
