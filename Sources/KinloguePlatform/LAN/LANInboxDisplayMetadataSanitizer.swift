import Foundation
import KinlogueCore

/// Normalizes untrusted display-only metadata. Sanitized values remain
/// metadata and must never be used to construct filesystem paths.
public struct LANInboxDisplayMetadataSanitizer: Sendable {
    public static let defaultMaximumUTF8ByteCount = LANInboxDisplayName.maxUTF8ByteCount
    public static let fallbackDisplayName = "_"

    public let maximumUTF8ByteCount: Int

    public init(
        maximumUTF8ByteCount: Int = Self.defaultMaximumUTF8ByteCount
    ) throws {
        guard maximumUTF8ByteCount > 0,
              maximumUTF8ByteCount <= Self.defaultMaximumUTF8ByteCount else {
            throw LANInboxError.invalidModel
        }
        self.maximumUTF8ByteCount = maximumUTF8ByteCount
    }

    public func sanitize(_ untrustedValue: String) -> String {
        sanitizeWithMetadata(untrustedValue).displayName
    }

    public func sanitizeWithMetadata(
        _ untrustedValue: String
    ) -> (displayName: String, wasGenerated: Bool) {
        let normalized = untrustedValue.precomposedStringWithCanonicalMapping
        var replaced = String.UnicodeScalarView()
        replaced.reserveCapacity(normalized.unicodeScalars.count)

        for scalar in normalized.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.illegalCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || scalar == "/"
                || scalar == "\\"
                || scalar == ":"
                || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) {
                replaced.append("_")
            } else {
                replaced.append(scalar)
            }
        }

        let trimmed = String(replaced)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        let bounded = utf8BoundedPrefix(of: trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !bounded.isEmpty, bounded != ".", bounded != ".." {
            return (bounded, false)
        }

        let fallback = utf8BoundedPrefix(of: Self.fallbackDisplayName)
        return (fallback.isEmpty ? "_" : fallback, true)
    }

    private func utf8BoundedPrefix(of value: String) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let characterBytes = character.utf8.count
            let (nextCount, overflow) = byteCount.addingReportingOverflow(
                characterBytes
            )
            guard !overflow, nextCount <= maximumUTF8ByteCount else { break }
            result.append(character)
            byteCount = nextCount
        }
        return result
    }
}
