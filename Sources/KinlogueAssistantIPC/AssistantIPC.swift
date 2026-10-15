@preconcurrency import Foundation

/// The bounded contract between the App and the assistant bridge XPC service. It carries text
/// requests, cancellation and results only; no file handle, bookmark, record ID or member name.
public enum KinlogueAssistantIPCLimits {
    public static let protocolVersion: UInt16 = 1
    public static let maximumRequestBytes = 256 * 1_024
    public static let maximumResponseBytes = 64 * 1_024
    /// The stdin text of one turn: records, resent turns and the question.
    public static let maximumInputBytes = 200 * 1_024
    public static let maximumInstructionsBytes = 8 * 1_024
    public static let maximumAnswerBytes = 32 * 1_024
    /// The model name and the CLI version.
    public static let maximumFieldBytes = 128
    public static let maximumPathBytes = 1_024
    public static let maximumProxyValueBytes = 512
    /// The only environment variables the App may pass on to the CLI.
    public static let proxyKeys: Set<String> = ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY"]
}

public enum KinlogueAssistantIPCValidationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidField
    case frameTooLarge
    case invalidEncoding
}

/// Why the bridge produced no answer. The CLI's own output never crosses the boundary.
public enum KinlogueAssistantFailureCode: String, Codable, CaseIterable, Sendable {
    case invalidRequest
    case busy
    case cliNotFound
    case unsupportedLocation
    case notLoggedIn
    case unsupportedCLI
    case toolUseDetected
    case rateLimited
    case networkUnavailable
    case timedOut
    case outputTooLarge
    case cancelled
    case failed
}

/// Which CLI to run and the proxy variables to give it. A path is only a choice among executables
/// the bridge validates itself; it grants no access.
public struct KinlogueAssistantCLIConfiguration: Codable, Equatable, Sendable {
    /// Nil asks the bridge to look in its fixed candidate locations.
    public let executablePath: String?
    public let proxy: [String: String]

    public init(executablePath: String?, proxy: [String: String]) throws {
        self.executablePath = executablePath
        self.proxy = proxy
        try validate()
    }

    public func validate() throws {
        if let executablePath {
            guard executablePath.hasPrefix("/"), executablePath.utf8.count <= KinlogueAssistantIPCLimits.maximumPathBytes,
                  !KinlogueAssistantText.containsControlCharacter(executablePath) else {
                throw KinlogueAssistantIPCValidationError.invalidField
            }
        }
        for (key, value) in proxy {
            guard KinlogueAssistantIPCLimits.proxyKeys.contains(key), !value.isEmpty,
                  value.utf8.count <= KinlogueAssistantIPCLimits.maximumProxyValueBytes,
                  !KinlogueAssistantText.containsControlCharacter(value) else {
                throw KinlogueAssistantIPCValidationError.invalidField
            }
        }
    }
}

public struct KinlogueAssistantStatusRequest: Codable, Equatable, Sendable {
    public let version: UInt16
    public let configuration: KinlogueAssistantCLIConfiguration
    /// The model the checks run with; nil uses the first model in the CLI's catalog.
    public let model: String?

    public init(
        version: UInt16 = KinlogueAssistantIPCLimits.protocolVersion,
        configuration: KinlogueAssistantCLIConfiguration,
        model: String? = nil
    ) throws {
        self.version = version
        self.configuration = configuration
        self.model = model
        try validate()
    }

    public func validate() throws {
        guard version == KinlogueAssistantIPCLimits.protocolVersion else {
            throw KinlogueAssistantIPCValidationError.unsupportedVersion
        }
        try configuration.validate()
        guard model.map(KinlogueAssistantText.isToken) ?? true else { throw KinlogueAssistantIPCValidationError.invalidField }
    }
}

/// What the settings page shows: the resolved executable, its version, login state, and the first
/// reason it cannot be used, if any.
public struct KinlogueAssistantStatus: Codable, Equatable, Sendable {
    public let executablePath: String?
    public let cliVersion: String?
    public let isLoggedIn: Bool
    /// The version passed the U0-style verification; other versions still run if every check passes.
    public let isVerifiedVersion: Bool
    /// Nil when the CLI passed every check and can be used.
    public let failure: KinlogueAssistantFailureCode?

    public init(
        executablePath: String?,
        cliVersion: String?,
        isLoggedIn: Bool,
        isVerifiedVersion: Bool,
        failure: KinlogueAssistantFailureCode?
    ) {
        self.executablePath = executablePath
        self.cliVersion = cliVersion
        self.isLoggedIn = isLoggedIn
        self.isVerifiedVersion = isVerifiedVersion
        self.failure = failure
    }

    public func validate() throws {
        guard executablePath.map({ $0.utf8.count <= KinlogueAssistantIPCLimits.maximumPathBytes }) ?? true,
              cliVersion.map(KinlogueAssistantText.isToken) ?? true else {
            throw KinlogueAssistantIPCValidationError.invalidField
        }
    }
}

public struct KinlogueAssistantTurnRequest: Codable, Equatable, Sendable {
    public let version: UInt16
    /// Identifies the turn for cancellation only.
    public let requestID: UUID
    public let configuration: KinlogueAssistantCLIConfiguration
    public let model: String
    public let instructions: String
    public let input: String

    public init(
        version: UInt16 = KinlogueAssistantIPCLimits.protocolVersion,
        requestID: UUID,
        configuration: KinlogueAssistantCLIConfiguration,
        model: String,
        instructions: String,
        input: String
    ) throws {
        self.version = version
        self.requestID = requestID
        self.configuration = configuration
        self.model = model
        self.instructions = instructions
        self.input = input
        try validate()
    }

    public func validate() throws {
        guard version == KinlogueAssistantIPCLimits.protocolVersion else {
            throw KinlogueAssistantIPCValidationError.unsupportedVersion
        }
        try configuration.validate()
        guard KinlogueAssistantText.isToken(model),
              KinlogueAssistantText.isBoundedText(instructions, maximumBytes: KinlogueAssistantIPCLimits.maximumInstructionsBytes),
              KinlogueAssistantText.isBoundedText(input, maximumBytes: KinlogueAssistantIPCLimits.maximumInputBytes) else {
            throw KinlogueAssistantIPCValidationError.invalidField
        }
    }
}

public enum KinlogueAssistantTurnResponse: Codable, Equatable, Sendable {
    case answer(text: String, cliVersion: String, model: String)
    case failure(code: KinlogueAssistantFailureCode, exitCode: Int32?)

    public func validate() throws {
        guard case let .answer(text, cliVersion, model) = self else { return }
        guard KinlogueAssistantText.isBoundedText(text, maximumBytes: KinlogueAssistantIPCLimits.maximumAnswerBytes),
              KinlogueAssistantText.isToken(cliVersion), KinlogueAssistantText.isToken(model) else {
            throw KinlogueAssistantIPCValidationError.invalidField
        }
    }
}

public enum KinlogueAssistantText {
    /// A model name or version: 1–128 bytes of letters, digits and `.`, `_`, `:`, `-`, starting
    /// with a letter or digit, so it can never read as a command-line option.
    public static func isToken(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, value.utf8.count <= KinlogueAssistantIPCLimits.maximumFieldBytes,
              first.isASCII, CharacterSet.alphanumerics.contains(first) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || ".-_:".unicodeScalars.contains(scalar))
        }
    }

    /// Non-blank, within the byte budget, and free of NUL.
    public static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
        value.utf8.count <= maximumBytes && !value.unicodeScalars.contains("\u{0}")
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public enum KinlogueAssistantIPCCodec {
    public static func encode(_ request: KinlogueAssistantStatusRequest) throws -> Data {
        try request.validate()
        return try encodeFrame(request, limit: KinlogueAssistantIPCLimits.maximumRequestBytes)
    }

    public static func encode(_ request: KinlogueAssistantTurnRequest) throws -> Data {
        try request.validate()
        return try encodeFrame(request, limit: KinlogueAssistantIPCLimits.maximumRequestBytes)
    }

    public static func encode(_ status: KinlogueAssistantStatus) throws -> Data {
        try status.validate()
        return try encodeFrame(status, limit: KinlogueAssistantIPCLimits.maximumResponseBytes)
    }

    public static func encode(_ response: KinlogueAssistantTurnResponse) throws -> Data {
        try response.validate()
        return try encodeFrame(response, limit: KinlogueAssistantIPCLimits.maximumResponseBytes)
    }

    public static func decodeStatusRequest(_ data: Data) throws -> KinlogueAssistantStatusRequest {
        let request = try decodeFrame(KinlogueAssistantStatusRequest.self, data, limit: KinlogueAssistantIPCLimits.maximumRequestBytes)
        try request.validate()
        return request
    }

    public static func decodeTurnRequest(_ data: Data) throws -> KinlogueAssistantTurnRequest {
        let request = try decodeFrame(KinlogueAssistantTurnRequest.self, data, limit: KinlogueAssistantIPCLimits.maximumRequestBytes)
        try request.validate()
        return request
    }

    public static func decodeStatus(_ data: Data) throws -> KinlogueAssistantStatus {
        let status = try decodeFrame(KinlogueAssistantStatus.self, data, limit: KinlogueAssistantIPCLimits.maximumResponseBytes)
        try status.validate()
        return status
    }

    public static func decodeTurnResponse(_ data: Data) throws -> KinlogueAssistantTurnResponse {
        let response = try decodeFrame(KinlogueAssistantTurnResponse.self, data, limit: KinlogueAssistantIPCLimits.maximumResponseBytes)
        try response.validate()
        return response
    }

    private static func encodeFrame<Value: Encodable>(_ value: Value, limit: Int) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(value)
        guard data.count <= limit else { throw KinlogueAssistantIPCValidationError.frameTooLarge }
        return data
    }

    private static func decodeFrame<Value: Decodable>(_ type: Value.Type, _ data: Data, limit: Int) throws -> Value {
        guard !data.isEmpty, data.count <= limit else { throw KinlogueAssistantIPCValidationError.frameTooLarge }
        do {
            return try PropertyListDecoder().decode(type, from: data)
        } catch let error as KinlogueAssistantIPCValidationError {
            throw error
        } catch {
            throw KinlogueAssistantIPCValidationError.invalidEncoding
        }
    }
}

/// Replies are `@Sendable`: a turn runs off the connection's queue so that a cancel can arrive
/// while it is running.
@objc public protocol KinlogueAssistantBridgeXPCProtocol {
    func status(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func respond(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    /// Stops the turn with this request ID, if it is still running.
    func cancel(_ requestID: String, reply: @escaping @Sendable (Bool) -> Void)
}

public enum KinlogueAssistantXPCInterface {
    public static func make() -> NSXPCInterface {
        NSXPCInterface(with: KinlogueAssistantBridgeXPCProtocol.self)
    }
}
