import Darwin
import Foundation

package enum SQLiteInitializationFaultPoint: Sendable {
    case afterReceipt, afterOriginalsDirectory, afterDatabaseCreation, afterSchemaCommit
}

/// This receipt authorizes only finishing a new empty-root initialization.
/// It never authorizes replacing, deleting, or migrating an existing database.
struct SQLiteLibraryInitialization: Codable {
    static let filename = "initialization.json"
    let operationID: UUID
    let rootDevice: Int64
    let rootInode: Int64
    let schemaIdentity: Data
    let contentHash: Data

    init(rootIdentity: SQLiteFileIdentity) {
        operationID = UUID()
        rootDevice = rootIdentity.device
        rootInode = rootIdentity.inode
        schemaIdentity = SQLiteLibrarySchema.identity
        contentHash = Self.hash(operationID, rootDevice, rootInode, schemaIdentity)
    }

    func write(to rootURL: URL) throws {
        try AtomicFileStore(rootURL: rootURL).writeImmutable(
            CanonicalVaultJSON.encode(self), relativePath: Self.filename)
    }

    static func validate(at rootURL: URL, rootIdentity: SQLiteFileIdentity) throws {
        let url = rootURL.appendingPathComponent(filename)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SQLiteLibraryError.unsupportedFormat }
        defer { Darwin.close(descriptor) }
        _ = try SQLiteFileIdentity.regular(descriptor: descriptor)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_size > 0, metadata.st_size <= 4096 else {
            throw SQLiteLibraryError.unsupportedFormat
        }
        var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
        guard pread(descriptor, &bytes, bytes.count, 0) == bytes.count else { throw SQLiteLibraryError.unsupportedFormat }
        let receipt = try CanonicalVaultJSON.decode(Self.self, from: Data(bytes))
        guard receipt.rootDevice == rootIdentity.device, receipt.rootInode == rootIdentity.inode,
              receipt.schemaIdentity == SQLiteLibrarySchema.identity,
              receipt.contentHash == hash(receipt.operationID, receipt.rootDevice, receipt.rootInode, receipt.schemaIdentity) else {
            throw SQLiteLibraryError.unsupportedFormat
        }
    }

    private static func hash(_ id: UUID, _ device: Int64, _ inode: Int64, _ schema: Data) -> Data {
        SQLiteContentHash.hash(domain: "initialization:1", values: [
            .blob(id.sqliteBytes), .integer(device), .integer(inode), .blob(schema)
        ])
    }
}
