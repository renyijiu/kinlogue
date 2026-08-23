import Foundation
import KinlogueCore

/// Maps server-generated inbox identities onto the independent LAN inbox
/// subtree. Display metadata is deliberately not accepted by any path API.
struct LANInboxLayout: Sendable {
    let rootURL: URL

    /// Validates an existing vault root without creating the inbox subtree.
    init(rootURL: URL) throws {
        self.rootURL = try VaultCanonicalRootPath.rootURL(
            for: rootURL,
            allowMissing: false
        )
    }

    var inboxDirectoryPath: String { "lan-inbox" }
    var manifestPath: String { "lan-inbox/inbox.json" }
    var blobsDirectoryPath: String { "lan-inbox/blobs" }
    var partialsDirectoryPath: String { "lan-inbox/partials" }
    var derivedDirectoryPath: String { "lan-inbox/derived" }

    var inboxDirectoryURL: URL {
        rootURL.appendingPathComponent(inboxDirectoryPath, isDirectory: true)
    }

    var manifestURL: URL {
        inboxDirectoryURL.appendingPathComponent("inbox.json", isDirectory: false)
    }

    var blobsDirectoryURL: URL {
        inboxDirectoryURL.appendingPathComponent("blobs", isDirectory: true)
    }

    var partialsDirectoryURL: URL {
        inboxDirectoryURL.appendingPathComponent("partials", isDirectory: true)
    }

    var derivedDirectoryURL: URL {
        inboxDirectoryURL.appendingPathComponent("derived", isDirectory: true)
    }

    func blobPath(_ id: UUID) -> String {
        objectPath(directory: "blobs", id: id, fileExtension: "blob")
    }

    func partialPath(_ id: UUID) -> String {
        objectPath(directory: "partials", id: id, fileExtension: "partial")
    }

    func derivedPath(_ id: UUID) -> String {
        objectPath(directory: "derived", id: id, fileExtension: "data")
    }

    func blobURL(_ id: UUID) -> URL {
        objectURL(directory: "blobs", id: id, fileExtension: "blob")
    }

    func partialURL(_ id: UUID) -> URL {
        objectURL(directory: "partials", id: id, fileExtension: "partial")
    }

    func derivedURL(_ id: UUID) -> URL {
        objectURL(directory: "derived", id: id, fileExtension: "data")
    }

    func blobID(at relativePath: String) -> UUID? {
        objectID(
            at: relativePath,
            directory: "blobs",
            fileExtension: "blob",
            canonicalPath: blobPath
        )
    }

    func partialID(at relativePath: String) -> UUID? {
        objectID(
            at: relativePath,
            directory: "partials",
            fileExtension: "partial",
            canonicalPath: partialPath
        )
    }

    func derivedID(at relativePath: String) -> UUID? {
        objectID(
            at: relativePath,
            directory: "derived",
            fileExtension: "data",
            canonicalPath: derivedPath
        )
    }

    private func objectPath(
        directory: String,
        id: UUID,
        fileExtension: String
    ) -> String {
        "lan-inbox/\(directory)/\(id.uuidString.lowercased()).\(fileExtension)"
    }

    private func objectURL(
        directory: String,
        id: UUID,
        fileExtension: String
    ) -> URL {
        let directoryURL: URL
        switch directory {
        case "blobs": directoryURL = blobsDirectoryURL
        case "partials": directoryURL = partialsDirectoryURL
        case "derived": directoryURL = derivedDirectoryURL
        default:
            preconditionFailure("LAN inbox directory must be server-defined")
        }
        return directoryURL
            .appendingPathComponent(
                "\(id.uuidString.lowercased()).\(fileExtension)",
                isDirectory: false
            )
    }

    private func objectID(
        at relativePath: String,
        directory: String,
        fileExtension: String,
        canonicalPath: (UUID) -> String
    ) -> UUID? {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              components[0] == "lan-inbox",
              components[1] == Substring(directory) else {
            return nil
        }

        let suffix = ".\(fileExtension)"
        let filename = String(components[2])
        guard filename.hasSuffix(suffix),
              let id = UUID(
                uuidString: String(filename.dropLast(suffix.count))
              ),
              canonicalPath(id) == relativePath else {
            return nil
        }
        return id
    }
}

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
