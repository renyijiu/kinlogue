import Foundation
import KinlogueCore

public struct PlaintextVaultLayout: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) throws {
        let standardized = rootURL.standardizedFileURL
        guard standardized.isFileURL,
              standardized.path != "/",
              !standardized.lastPathComponent.isEmpty else {
            throw VaultError.invalidPath
        }
        self.rootURL = standardized
    }

    public var manifestPath: String { "library.json" }
    public var legacyEncryptedMarkerPath: String { "vault.marker" }
    public static let dicomImportStagingDirectoryPath = "dicom-import-staging"
    public static let dicomImportJournalDirectoryPath = "dicom-import-journals"

    public var dicomImportStagingDirectoryPath: String {
        Self.dicomImportStagingDirectoryPath
    }

    public var dicomImportJournalDirectoryPath: String {
        Self.dicomImportJournalDirectoryPath
    }

    public func dicomImportStagingDirectoryPath(operationID: UUID) -> String {
        Self.dicomImportStagingDirectoryPath(operationID: operationID)
    }

    public static func dicomImportStagingDirectoryPath(operationID: UUID) -> String {
        "\(dicomImportStagingDirectoryPath)/\(operationID.uuidString.lowercased())"
    }

    public func dicomImportJournalPath(operationID: UUID) -> String {
        "\(dicomImportJournalDirectoryPath)/\(operationID.uuidString.lowercased()).json"
    }

    var initializationReceiptURL: URL {
        rootURL.deletingLastPathComponent().appendingPathComponent(
            ".kinlogue-vault-initialization-\(transactionPathDigest).json",
            isDirectory: false
        )
    }

    var transactionCanonicalRootPath: String {
        rootURL.path.precomposedStringWithCanonicalMapping
    }

    static func isAtomicTemporaryFilename(_ name: String) -> Bool {
        let prefix = ".kinlogue-"
        let suffix = ".tmp"
        guard name.hasPrefix(prefix),
              name.hasSuffix(suffix),
              name.count == prefix.count + 36 + suffix.count else {
            return false
        }
        return UUID(
            uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))
        ) != nil
    }

    public func objectPath(_ reference: VaultObjectReference) -> String {
        let fileExtension = reference.kind == .ocr ? "json" : "data"
        return "objects/\(reference.kind.storageComponent)/"
            + "\(reference.id.uuidString.lowercased()).\(fileExtension)"
    }

    func objectReference(at relativePath: String) -> VaultObjectReference? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "objects",
              let kind = VaultObjectKind.allCases.first(where: {
                  $0.storageComponent == components[1]
              }) else { return nil }

        let fileExtension = kind == .ocr ? ".json" : ".data"
        let filename = String(components[2])
        guard filename.hasSuffix(fileExtension),
              let id = UUID(uuidString: String(filename.dropLast(fileExtension.count))) else {
            return nil
        }
        let reference = VaultObjectReference(id: id, kind: kind)
        return objectPath(reference) == relativePath ? reference : nil
    }

    private var transactionPathDigest: String {
        ContentDigest.sha256(Data(transactionCanonicalRootPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension VaultObjectKind {
    var storageComponent: String {
        switch self {
        case .catalog: "catalog"
        case .record: "record"
        case .attachment: "attachment"
        case .ocr: "ocr"
        case .thumbnail: "thumbnail"
        case .descriptor: "descriptor"
        }
    }
}
