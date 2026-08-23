import Foundation

struct AnyCodingKey: CodingKey, Hashable {
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

extension Decoder {
    /// `CodingKeys`-typed containers silently omit unknown input keys from
    /// `allKeys`; use an unconstrained key type for a real closed-schema gate.
    func rejectUnknownKeys(_ allowed: Set<String>) throws {
        let container = try self.container(keyedBy: AnyCodingKey.self)
        guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: codingPath,
                debugDescription: "Object contains unsupported keys"
            ))
        }
    }
}

extension KeyedDecodingContainer {
    func decodeBoundedArray<Element: Decodable>(
        _ type: Element.Type,
        forKey key: Key,
        maximumCount: Int
    ) throws -> [Element] {
        var container = try nestedUnkeyedContainer(forKey: key)
        return try container.decodeBoundedArray(type, maximumCount: maximumCount)
    }

    func decodeBoundedArrayIfPresent<Element: Decodable>(
        _ type: Element.Type,
        forKey key: Key,
        maximumCount: Int
    ) throws -> [Element]? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeBoundedArray(type, forKey: key, maximumCount: maximumCount)
    }
}

extension UnkeyedDecodingContainer {
    mutating func decodeBoundedArray<Element: Decodable>(
        _ type: Element.Type,
        maximumCount: Int
    ) throws -> [Element] {
        precondition(maximumCount >= 0)
        if let count, count > maximumCount {
            throw oversizedArrayError(maximumCount: maximumCount)
        }

        var values: [Element] = []
        if let count {
            values.reserveCapacity(count)
        }
        while !isAtEnd {
            guard values.count < maximumCount else {
                throw oversizedArrayError(maximumCount: maximumCount)
            }
            values.append(try decode(type))
        }
        return values
    }

    private func oversizedArrayError(maximumCount: Int) -> DecodingError {
        DecodingError.dataCorrupted(.init(
            codingPath: codingPath,
            debugDescription: "Array exceeds maximum allowed count of \(maximumCount)"
        ))
    }
}
