import Foundation

enum AcceptanceSmokePhase: String, CaseIterable, Sendable {
    case claim
    case seed
    case restart
    case dicomImport = "dicom-import"
    case dicomRestart = "dicom-restart"
    case dicomDelete = "dicom-delete"
    case lanReceiver = "lan-receiver"
    case lanReceiverRestart = "lan-receiver-restart"
    case forcedReady = "forced-ready"
    case afterForce = "after-force"
    case cleanup

    private static let argumentPrefix = "--acceptance-phase="

    var argument: String {
        Self.argumentPrefix + rawValue
    }

    init?(argument: String) {
        guard argument.hasPrefix(Self.argumentPrefix) else { return nil }
        self.init(rawValue: String(argument.dropFirst(Self.argumentPrefix.count)))
    }
}

struct DICOMInstalledAcceptanceContext: Equatable, Sendable {
    let inputDirectory: URL

    init(runID: String, sourceVault: RuntimeVaultIdentity) throws {
        let source = sourceVault.rootURL.standardizedFileURL
        let runRoot = source.deletingLastPathComponent()
        guard source.lastPathComponent == "SourceVault",
              runRoot.lastPathComponent == runID,
              runRoot.deletingLastPathComponent().lastPathComponent == "Acceptance" else {
            throw AppRuntimeIdentityError.invalidAcceptanceConfiguration
        }
        inputDirectory = runRoot.appendingPathComponent("DICOMInput", isDirectory: true)
    }
}

struct AcceptanceSmokeRequest: Equatable, Sendable {
    let identity: AppRuntimeIdentity
    let phase: AcceptanceSmokePhase
}

enum AcceptanceSmokeEntry: Equatable, Sendable {
    case gui
    case run(AcceptanceSmokeRequest)
    case reject

    var request: AcceptanceSmokeRequest? {
        guard case let .run(request) = self else { return nil }
        return request
    }

    static func current() -> Self {
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return .reject
        }
        return resolve(
            bundleInfo: Bundle.main.infoDictionary ?? [:],
            arguments: CommandLine.arguments,
            trustedApplicationSupportDirectory: supportDirectory
        )
    }

    static func resolve(
        bundleInfo: [String: Any],
        arguments: [String],
        trustedApplicationSupportDirectory: URL
    ) -> Self {
        let identity: AppRuntimeIdentity
        do {
            identity = try AppRuntimeIdentity.resolve(
                bundleInfo: bundleInfo,
                arguments: arguments,
                trustedApplicationSupportDirectory: trustedApplicationSupportDirectory
            )
        } catch {
            return .reject
        }

        guard identity.syntheticSmokeRequested else { return .gui }
        guard case .acceptance = identity.mode else { return .reject }

        let suppliedArguments = Array(arguments.dropFirst())
        guard suppliedArguments.count == 2,
              suppliedArguments.filter({
                  $0 == AppRuntimeIdentity.syntheticSmokeArgument
              }).count == 1,
              let phaseArgument = suppliedArguments.first(where: {
                  $0 != AppRuntimeIdentity.syntheticSmokeArgument
              }),
              let phase = AcceptanceSmokePhase(argument: phaseArgument) else {
            return .reject
        }
        return .run(AcceptanceSmokeRequest(identity: identity, phase: phase))
    }
}
