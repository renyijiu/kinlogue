import Foundation
@testable import KinloguePlatform

/// A fresh library with its LAN inbox, in a private temporary directory.
struct LANInboxStoreTestFixture {
    let rootURL: URL
    let kernel: SQLiteLibraryStore
    let store: SQLiteLANInboxStore

    static func make() async throws -> Self {
        let root = try sqliteTestRoot()
        let kernel = try SQLiteLibraryStore(rootURL: root)
        return Self(rootURL: root, kernel: kernel, store: try SQLiteLANInboxStore(store: kernel))
    }

    func destroy() {
        try? kernel.close()
        try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
    }
}
