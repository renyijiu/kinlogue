import Foundation
import KinlogueAssistantIPC
import KinlogueCore

package enum AssistantCLISettingsError: Error, Equatable, Sendable {
    case invalid
}

/// Which local CLI to run and the proxy variables to give it, as chosen in Settings. Values the
/// bridge would refuse are refused here.
package struct AssistantCLISettings: Equatable, Sendable {
    let configuration: KinlogueAssistantCLIConfiguration

    package init(executablePath: String?, proxy: [String: String]) throws {
        do {
            configuration = try KinlogueAssistantCLIConfiguration(executablePath: executablePath, proxy: proxy)
        } catch {
            throw AssistantCLISettingsError.invalid
        }
    }

    package var executablePath: String? { configuration.executablePath }
    package var proxy: [String: String] { configuration.proxy }

    /// A model name the bridge accepts: a short token that cannot read as a command-line option.
    package static func isValidModel(_ model: String) -> Bool {
        KinlogueAssistantText.isToken(model)
    }
}

/// What Settings shows about the local CLI.
package struct AssistantCLIStatus: Equatable, Sendable {
    package let executablePath: String?
    package let cliVersion: String?
    package let isLoggedIn: Bool
    package let isVerifiedVersion: Bool
    /// Nil when the CLI can be used.
    package let failure: AssistantFailure?
    /// The model the checks ran with; the default model for a turn.
    package let model: String?
    /// The model a turn without a chosen one uses: the first in the CLI's catalog.
    package var defaultModel: String? = nil
    /// The models the CLI shows in its own picker, in its order.
    package var models: [AssistantModelOption] = []
}

/// A model the user may pick: the CLI's slug and the name the CLI shows for it.
package struct AssistantModelOption: Equatable, Hashable, Sendable {
    package let slug: String
    package let displayName: String

    package init(slug: String, displayName: String) {
        self.slug = slug
        self.displayName = displayName
    }
}

/// The assistant provider backed by the bridge XPC service. Each turn is one request; cancelling
/// the calling task stops it.
package final class BridgeAssistantProvider: AssistantProvider {
    /// The provider the App uses: the bridge service embedded in the App bundle.
    package static func overXPC(settings: AssistantCLISettings) -> BridgeAssistantProvider {
        BridgeAssistantProvider(client: KinlogueAssistantXPCClient(), settings: settings)
    }

    private let client: any KinlogueAssistantBridgeClient
    private let settings: AssistantCLISettings

    package init(client: any KinlogueAssistantBridgeClient, settings: AssistantCLISettings) {
        self.client = client
        self.settings = settings
    }

    package func status(model: String?) async -> AssistantCLIStatus {
        guard let request = try? KinlogueAssistantStatusRequest(configuration: settings.configuration, model: model),
              let encoded = try? KinlogueAssistantIPCCodec.encode(request) else {
            return Self.unavailableStatus(.failed(exitCode: nil))
        }
        guard let data = await client.status(encoded), let status = try? KinlogueAssistantIPCCodec.decodeStatus(data) else {
            return Self.unavailableStatus(.bridgeUnavailable)
        }
        return AssistantCLIStatus(
            executablePath: status.executablePath, cliVersion: status.cliVersion, isLoggedIn: status.isLoggedIn,
            isVerifiedVersion: status.isVerifiedVersion, failure: status.failure.map { Self.failure($0, exitCode: nil) },
            model: status.model, defaultModel: status.defaultModel,
            models: status.models.map { AssistantModelOption(slug: $0.slug, displayName: $0.displayName) }
        )
    }

    package func respond(to request: AssistantProviderRequest) async throws(AssistantFailure) -> AssistantProviderReply {
        let requestID = UUID()
        guard let turn = try? KinlogueAssistantTurnRequest(
            requestID: requestID, configuration: settings.configuration, model: request.model,
            instructions: request.instructions, input: request.input
        ), let encoded = try? KinlogueAssistantIPCCodec.encode(turn) else {
            throw .failed(exitCode: nil)
        }
        let data = await client.respond(encoded, requestID: requestID)
        if Task.isCancelled { throw .cancelled }
        guard let data, let response = try? KinlogueAssistantIPCCodec.decodeTurnResponse(data) else {
            throw .bridgeUnavailable
        }
        switch response {
        case let .answer(text, cliVersion, model):
            guard let provider = try? AssistantProviderDescriptor(kind: .codex, cliVersion: cliVersion, model: model) else {
                throw .failed(exitCode: nil)
            }
            return AssistantProviderReply(answer: text, provider: provider)
        case let .failure(code, exitCode):
            throw Self.failure(code, exitCode: exitCode)
        }
    }

    static func failure(_ code: KinlogueAssistantFailureCode, exitCode: Int32?) -> AssistantFailure {
        switch code {
        case .invalidRequest: .failed(exitCode: nil)
        case .busy: .busy
        case .cliNotFound: .cliNotFound
        case .unsupportedLocation: .unsupportedLocation
        case .notLoggedIn: .notLoggedIn
        case .unsupportedCLI: .unsupportedCLI
        case .toolUseDetected: .toolUseDetected
        case .rateLimited: .rateLimited
        case .networkUnavailable: .networkUnavailable
        case .timedOut: .timedOut
        case .outputTooLarge: .outputTooLarge
        case .cancelled: .cancelled
        case .failed: .failed(exitCode: exitCode)
        }
    }

    private static func unavailableStatus(_ failure: AssistantFailure) -> AssistantCLIStatus {
        AssistantCLIStatus(executablePath: nil, cliVersion: nil, isLoggedIn: false, isVerifiedVersion: false, failure: failure, model: nil)
    }
}
