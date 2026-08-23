import Foundation
import KinlogueCore

public enum LANHTTPJSONError: Error, Equatable, Sendable {
    case bodyTooLarge
    case invalidSyntax
    case topLevelObjectRequired
    case duplicateKey
    case invalidSchema
    case encodingFailed
}

public enum LANHTTPDTOValidationError: Error, Equatable, Sendable {
    case invalidValue
}

/// Strict JSON boundary for the temporary LAN receiver.
///
/// Request JSON is deliberately small and object-shaped. A lexical pass runs
/// before `JSONDecoder` so duplicate members cannot be hidden by Foundation's
/// last-value behavior. Every DTO below also rejects unknown members.
public enum LANHTTPJSONCodec {
    public static let maximumRequestByteCount = 64 * 1_024

    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        guard data.count <= maximumRequestByteCount else {
            throw LANHTTPJSONError.bodyTooLarge
        }
        var scanner = StrictJSONScanner(data: data)
        try scanner.validateTopLevelObject()
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LANHTTPJSONError.invalidSchema
        }
    }

    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            var scanner = StrictJSONScanner(data: data)
            try scanner.validateTopLevelObject()
            return data
        } catch let error as LANHTTPJSONError {
            throw error
        } catch {
            throw LANHTTPJSONError.encodingFailed
        }
    }
}

public struct LANPairRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case code }

    public let code: String

    public init(code: String) throws {
        guard code.utf8.count == 6,
              code.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw LANHTTPDTOValidationError.invalidValue
        }
        self.code = code
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(CodingKeys.self, from: decoder)
        do {
            try self.init(code: container.decode(String.self, forKey: .code))
        } catch {
            throw invalidDTO(decoder)
        }
    }
}

public struct LANPairResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case csrfToken }

    public let csrfToken: String

    public init(csrfToken: String) throws {
        try validateCapabilityToken(csrfToken)
        self.csrfToken = csrfToken
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(CodingKeys.self, from: decoder)
        do {
            try self.init(csrfToken: container.decode(String.self, forKey: .csrfToken))
        } catch {
            throw invalidDTO(decoder)
        }
    }
}

public struct LANReserveFileRequest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case remoteFileID
        case displayName
        case declaredByteCount
        case mediaType
        case attemptRevision
    }

    public let remoteFileID: UUID
    public let displayName: String
    public let declaredByteCount: Int64
    public let mediaType: String?
    public let attemptRevision: UInt64

    public init(
        remoteFileID: UUID,
        displayName: String,
        declaredByteCount: Int64,
        mediaType: String? = nil,
        attemptRevision: UInt64
    ) throws {
        guard declaredByteCount >= 0 else {
            throw LANHTTPDTOValidationError.invalidValue
        }
        let normalizedType = mediaType?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedType?.utf8.count ?? 0
                <= LANInboxTransportMetadata.maximumMediaTypeUTF8ByteCount,
              normalizedType?.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) != true else {
            throw LANHTTPDTOValidationError.invalidValue
        }
        self.remoteFileID = remoteFileID
        self.displayName = try validatedRequestDisplayName(displayName)
        self.declaredByteCount = declaredByteCount
        self.mediaType = normalizedType.flatMap { $0.isEmpty ? nil : $0 }
        self.attemptRevision = attemptRevision
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(CodingKeys.self, from: decoder)
        do {
            try self.init(
                remoteFileID: container.decodeCanonicalUUID(forKey: .remoteFileID),
                displayName: container.decode(String.self, forKey: .displayName),
                declaredByteCount: container.decode(Int64.self, forKey: .declaredByteCount),
                mediaType: container.decodeStrictlyIfPresent(String.self, forKey: .mediaType),
                attemptRevision: container.decode(UInt64.self, forKey: .attemptRevision)
            )
        } catch {
            throw invalidDTO(decoder)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeCanonicalUUID(remoteFileID, forKey: .remoteFileID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(declaredByteCount, forKey: .declaredByteCount)
        try container.encodeIfPresent(mediaType, forKey: .mediaType)
        try container.encode(attemptRevision, forKey: .attemptRevision)
    }
}

public enum LANPhoneFileStatusState: String, Codable, Equatable, Sendable {
    case reserved
    case receiving
    case saved
    case interrupted
    case cancelled
}

public struct LANPhoneFileStatus: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case remoteFileID
        case displayName
        case declaredByteCount
        case receivedByteCount
        case attemptRevision
        case state
    }

    public let remoteFileID: UUID
    public let displayName: String
    public let declaredByteCount: Int64
    public let receivedByteCount: Int64
    public let attemptRevision: UInt64
    public let state: LANPhoneFileStatusState

    public init(
        remoteFileID: UUID,
        displayName: String,
        declaredByteCount: Int64,
        receivedByteCount: Int64,
        attemptRevision: UInt64,
        state: LANPhoneFileStatusState
    ) throws {
        guard declaredByteCount >= 0,
              receivedByteCount >= 0,
              receivedByteCount <= declaredByteCount else {
            throw LANHTTPDTOValidationError.invalidValue
        }
        self.remoteFileID = remoteFileID
        self.displayName = try validatedDisplayName(displayName)
        self.declaredByteCount = declaredByteCount
        self.receivedByteCount = receivedByteCount
        self.attemptRevision = attemptRevision
        self.state = state
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(CodingKeys.self, from: decoder)
        do {
            try self.init(
                remoteFileID: container.decodeCanonicalUUID(forKey: .remoteFileID),
                displayName: container.decode(String.self, forKey: .displayName),
                declaredByteCount: container.decode(Int64.self, forKey: .declaredByteCount),
                receivedByteCount: container.decode(Int64.self, forKey: .receivedByteCount),
                attemptRevision: container.decode(UInt64.self, forKey: .attemptRevision),
                state: container.decode(LANPhoneFileStatusState.self, forKey: .state)
            )
        } catch {
            throw invalidDTO(decoder)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeCanonicalUUID(remoteFileID, forKey: .remoteFileID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(declaredByteCount, forKey: .declaredByteCount)
        try container.encode(receivedByteCount, forKey: .receivedByteCount)
        try container.encode(attemptRevision, forKey: .attemptRevision)
        try container.encode(state, forKey: .state)
    }
}

public struct LANReserveFileResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case file }
    public let file: LANPhoneFileStatus

    public init(file: LANPhoneFileStatus) { self.file = file }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(CodingKeys.self, from: decoder)
        file = try container.decode(LANPhoneFileStatus.self, forKey: .file)
    }
}

public struct LANFileSessionResponse: Codable, Equatable, Sendable {
    public static let maximumFileCount = 1_000

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case csrfToken
        case files
    }

    public let csrfToken: String
    public let files: [LANPhoneFileStatus]

    public init(csrfToken: String, files: [LANPhoneFileStatus]) throws {
        try validateCapabilityToken(csrfToken)
        guard files.count <= Self.maximumFileCount,
              Set(files.map(\.remoteFileID)).count == files.count else {
            throw LANHTTPDTOValidationError.invalidValue
        }
        self.csrfToken = csrfToken
        self.files = files
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(CodingKeys.self, from: decoder)
        do {
            try self.init(
                csrfToken: container.decode(String.self, forKey: .csrfToken),
                files: container.decodeBoundedArray(
                    LANPhoneFileStatus.self,
                    forKey: .files,
                    maximumCount: Self.maximumFileCount
                )
            )
        } catch {
            throw invalidDTO(decoder)
        }
    }
}

public enum LANFileSavedOutcome: String, Codable, Equatable, Sendable {
    case saved
}

public struct LANFileSavedResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case outcome }
    public let outcome: LANFileSavedOutcome

    public init(outcome: LANFileSavedOutcome = .saved) {
        self.outcome = outcome
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(CodingKeys.self, from: decoder)
        outcome = try container.decode(LANFileSavedOutcome.self, forKey: .outcome)
    }
}

public enum LANFileCancelOutcome: String, Codable, Equatable, Sendable {
    case cancelled
}

public struct LANFileCancelResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable { case outcome }
    public let outcome: LANFileCancelOutcome

    public init(outcome: LANFileCancelOutcome = .cancelled) {
        self.outcome = outcome
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(CodingKeys.self, from: decoder)
        outcome = try container.decode(LANFileCancelOutcome.self, forKey: .outcome)
    }
}

public enum LANHTTPRejectionCode: String, Codable, CaseIterable, Equatable, Sendable {
    case requestRejected
    case retryLater
    case sessionEnded
}

/// Every rejected API call uses this same two-member response shape. Detailed
/// parsing, authentication, storage and duplicate causes remain Mac-only.
public struct LANHTTPRejectionResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case error
        case retryable
    }

    public let error: LANHTTPRejectionCode
    public let retryable: Bool

    public init(error: LANHTTPRejectionCode, retryable: Bool) {
        self.error = error
        self.retryable = retryable
    }

    public init(from decoder: any Decoder) throws {
        let container = try strictContainer(CodingKeys.self, from: decoder)
        do {
            self.init(
                error: try container.decode(LANHTTPRejectionCode.self, forKey: .error),
                retryable: try container.decode(Bool.self, forKey: .retryable)
            )
        } catch {
            throw invalidDTO(decoder)
        }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func strictContainer<Key>(
    _ type: Key.Type,
    from decoder: any Decoder
) throws -> KeyedDecodingContainer<Key>
where Key: CodingKey & CaseIterable {
    let raw = try decoder.container(keyedBy: AnyCodingKey.self)
    let allowed = Set(Key.allCases.map(\.stringValue))
    guard raw.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw invalidDTO(decoder)
    }
    return try decoder.container(keyedBy: Key.self)
}

private func invalidDTO(_ decoder: any Decoder) -> DecodingError {
    .dataCorrupted(.init(
        codingPath: decoder.codingPath,
        debugDescription: "Invalid LAN HTTP DTO"
    ))
}

private extension KeyedDecodingContainer {
    func decodeCanonicalUUID(forKey key: Key) throws -> UUID {
        let raw = try decode(String.self, forKey: key)
        guard let value = UUID(uuidString: raw),
              raw == value.uuidString.lowercased() else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: self,
                debugDescription: "Invalid canonical UUID"
            )
        }
        return value
    }

    func decodeStrictlyIfPresent<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> Value? {
        guard contains(key) else { return nil }
        return try decode(type, forKey: key)
    }

    func decodeBoundedArray<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key,
        maximumCount: Int
    ) throws -> [Value] {
        var container = try nestedUnkeyedContainer(forKey: key)
        var values: [Value] = []
        values.reserveCapacity(min(container.count ?? 0, maximumCount))
        while !container.isAtEnd {
            guard values.count < maximumCount else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: self,
                    debugDescription: "LAN HTTP array exceeds its item limit"
                )
            }
            values.append(try container.decode(Value.self))
        }
        return values
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeCanonicalUUID(_ value: UUID, forKey key: Key) throws {
        try encode(value.uuidString.lowercased(), forKey: key)
    }
}

private func validatedDisplayName(_ value: String) throws -> String {
    try validatedBoundedText(value, maximumUTF8ByteCount: 1_024, forbidsPathSeparators: true)
}

/// Upload filenames are untrusted metadata. Preserve every JSON string up to
/// the wire bound so U3's sanitizer can replace empty, control, separator and
/// confusable content before it becomes display metadata.
private func validatedRequestDisplayName(_ value: String) throws -> String {
    guard value.utf8.count <= 1_024 else {
        throw LANHTTPDTOValidationError.invalidValue
    }
    return value
}

private func validatedBoundedText(
    _ value: String,
    maximumUTF8ByteCount: Int,
    forbidsPathSeparators: Bool
) throws -> String {
    let normalized = value
        .precomposedStringWithCanonicalMapping
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let invalidScalar = normalized.unicodeScalars.contains { scalar in
        CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.illegalCharacters.contains(scalar)
            || (0x202A...0x202E).contains(scalar.value)
            || (0x2066...0x2069).contains(scalar.value)
            || (forbidsPathSeparators && (scalar == "/" || scalar == "\\"))
    }
    guard !normalized.isEmpty,
          normalized.utf8.count <= maximumUTF8ByteCount,
          !invalidScalar else {
        throw LANHTTPDTOValidationError.invalidValue
    }
    return normalized
}

private func validateCapabilityToken(_ value: String) throws {
    guard (16...512).contains(value.utf8.count),
          value.utf8.allSatisfy({ byte in
              (48...57).contains(byte)
                  || (65...90).contains(byte)
                  || (97...122).contains(byte)
                  || byte == 45
                  || byte == 95
          }) else {
        throw LANHTTPDTOValidationError.invalidValue
    }
}

private struct StrictJSONScanner {
    private static let maximumNestingDepth = 32

    let bytes: [UInt8]
    var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func validateTopLevelObject() throws {
        skipWhitespace()
        guard peek == 0x7B else { throw LANHTTPJSONError.topLevelObjectRequired }
        try parseObject(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw LANHTTPJSONError.invalidSyntax }
    }

    private var peek: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func parseValue(depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw LANHTTPJSONError.invalidSyntax
        }
        skipWhitespace()
        switch peek {
        case 0x7B: try parseObject(depth: depth)
        case 0x5B: try parseArray(depth: depth)
        case 0x22: _ = try parseString()
        case 0x74: try consumeLiteral("true")
        case 0x66: try consumeLiteral("false")
        case 0x6E: try consumeLiteral("null")
        case 0x2D: try parseNumber()
        case let byte? where (0x30...0x39).contains(byte): try parseNumber()
        default: throw LANHTTPJSONError.invalidSyntax
        }
    }

    private mutating func parseObject(depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw LANHTTPJSONError.invalidSyntax
        }
        try consume(0x7B)
        skipWhitespace()
        if peek == 0x7D {
            index += 1
            return
        }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            guard peek == 0x22 else { throw LANHTTPJSONError.invalidSyntax }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw LANHTTPJSONError.duplicateKey
            }
            skipWhitespace()
            try consume(0x3A)
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if peek == 0x7D {
                index += 1
                return
            }
            try consume(0x2C)
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth <= Self.maximumNestingDepth else {
            throw LANHTTPJSONError.invalidSyntax
        }
        try consume(0x5B)
        skipWhitespace()
        if peek == 0x5D {
            index += 1
            return
        }
        while true {
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if peek == 0x5D {
                index += 1
                return
            }
            try consume(0x2C)
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        try consume(0x22)
        var escaped = false
        while let byte = peek {
            if escaped {
                guard byte == 0x22 || byte == 0x5C || byte == 0x2F
                    || byte == 0x62 || byte == 0x66 || byte == 0x6E
                    || byte == 0x72 || byte == 0x74 || byte == 0x75 else {
                    throw LANHTTPJSONError.invalidSyntax
                }
                index += 1
                if byte == 0x75 {
                    for _ in 0..<4 {
                        guard let hex = peek, isHexDigit(hex) else {
                            throw LANHTTPJSONError.invalidSyntax
                        }
                        index += 1
                    }
                }
                escaped = false
                continue
            }
            if byte == 0x5C {
                escaped = true
                index += 1
                continue
            }
            if byte == 0x22 {
                index += 1
                let token = Data(bytes[start..<index])
                do {
                    return try JSONDecoder().decode(String.self, from: token)
                } catch {
                    throw LANHTTPJSONError.invalidSyntax
                }
            }
            guard byte >= 0x20 else { throw LANHTTPJSONError.invalidSyntax }
            index += 1
        }
        throw LANHTTPJSONError.invalidSyntax
    }

    private mutating func parseNumber() throws {
        let start = index
        if peek == 0x2D { index += 1 }
        guard let first = peek else { throw LANHTTPJSONError.invalidSyntax }
        if first == 0x30 {
            index += 1
            if let next = peek, (0x30...0x39).contains(next) {
                throw LANHTTPJSONError.invalidSyntax
            }
        } else if (0x31...0x39).contains(first) {
            repeat { index += 1 } while peek.map({ (0x30...0x39).contains($0) }) == true
        } else {
            throw LANHTTPJSONError.invalidSyntax
        }
        if peek == 0x2E {
            index += 1
            guard peek.map({ (0x30...0x39).contains($0) }) == true else {
                throw LANHTTPJSONError.invalidSyntax
            }
            repeat { index += 1 } while peek.map({ (0x30...0x39).contains($0) }) == true
        }
        if peek == 0x65 || peek == 0x45 {
            index += 1
            if peek == 0x2B || peek == 0x2D { index += 1 }
            guard peek.map({ (0x30...0x39).contains($0) }) == true else {
                throw LANHTTPJSONError.invalidSyntax
            }
            repeat { index += 1 } while peek.map({ (0x30...0x39).contains($0) }) == true
        }
        guard let token = String(bytes: bytes[start..<index], encoding: .utf8),
              let finite = Double(token), finite.isFinite else {
            throw LANHTTPJSONError.invalidSyntax
        }
    }

    private mutating func consumeLiteral(_ literal: StaticString) throws {
        let expected = Array(String(describing: literal).utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw LANHTTPJSONError.invalidSyntax
        }
        index += expected.count
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard peek == expected else { throw LANHTTPJSONError.invalidSyntax }
        index += 1
    }

    private mutating func skipWhitespace() {
        while let byte = peek,
              byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}
