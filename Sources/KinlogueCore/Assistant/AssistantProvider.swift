import Foundation

/// What one turn asks of a CLI: the model, the fixed instructions and the stdin text. It holds no
/// path, record ID or member name.
package struct AssistantProviderRequest: Hashable, Sendable {
    package let model: String
    package let instructions: String
    package let input: String

    package init(model: String, instructions: String, input: String) {
        self.model = model
        self.instructions = instructions
        self.input = input
    }
}

package struct AssistantProviderReply: Hashable, Sendable {
    package let answer: String
    package let provider: AssistantProviderDescriptor

    package init(answer: String, provider: AssistantProviderDescriptor) {
        self.answer = answer
        self.provider = provider
    }
}

/// Why a turn produced no answer. The CLI's own output is never carried, only these codes.
package enum AssistantFailure: Error, Hashable, Sendable {
    case cliNotFound
    /// The CLI is installed where the bridge's sandbox may not run it.
    case unsupportedLocation
    case notLoggedIn
    case unsupportedCLI
    /// The CLI started a tool despite the hardening; the turn was stopped.
    case toolUseDetected
    /// Another turn is running.
    case busy
    /// The bridge service is missing, crashed, or answered with something unreadable.
    case bridgeUnavailable
    case rateLimited
    case networkUnavailable
    case timedOut
    case outputTooLarge
    case cancelled
    case failed(exitCode: Int32?)
}

/// A CLI that answers one turn. Each call is independent: the full input is sent every time and
/// the CLI keeps no session.
package protocol AssistantProvider: Sendable {
    func respond(to request: AssistantProviderRequest) async throws(AssistantFailure) -> AssistantProviderReply
}
