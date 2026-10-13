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

    public func objectPath(_ reference: VaultObjectReference) -> String {
        let fileExtension = reference.kind == .ocr ? "json" : "data"
        return "objects/\(reference.kind.storageComponent)/"
            + "\(reference.id.uuidString.lowercased()).\(fileExtension)"
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
