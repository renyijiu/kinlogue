import Foundation

enum CanonicalVaultJSON {
    /// Projects a Date onto the fixed point produced by the configured
    /// milliseconds encode/decode strategy before strict persisted equality.
    static func persistenceStableDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970 * 1_000 / 1_000)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
