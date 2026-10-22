import Darwin
import Foundation
import KinlogueCore
import KinloguePlatform
import Testing
@testable import KinlogueApp

@Suite("Backup folder authority")
struct BackupFolderAuthorityTests {
    @Test
    func choosingAFolderRecordsItWithoutCreatingAnythingInIt() throws {
        try withFolderFixture { fixture in
            let unknown = fixture.folder.appendingPathComponent("do-not-touch.txt")
            try Data("foreign".utf8).write(to: unknown)
            let selection = try BackupFolderAuthority(bookmarks: FolderBookmarks(resolvedURL: fixture.folder))
                .select(fixture.folder, activeVaultURL: fixture.vault)

            #expect(selection.bookmarkData == Data("bookmark".utf8))
            var metadata = stat()
            #expect(lstat(fixture.folder.path, &metadata) == 0)
            #expect(selection.identity.inode == UInt64(metadata.st_ino))
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path) == ["do-not-touch.txt"])
        }
    }

    @Test
    func refusesTheLibraryItsParentSymlinksTheVolumeRootAndICloud() throws {
        try withFolderFixture { fixture in
            let authority = BackupFolderAuthority(bookmarks: FolderBookmarks(resolvedURL: fixture.folder))
            for forbidden in [fixture.vault, fixture.vault.deletingLastPathComponent()] {
                #expect(throws: BackupFolderError.forbiddenVaultRelationship) {
                    _ = try authority.select(forbidden, activeVaultURL: fixture.vault)
                }
            }
            let symlink = fixture.base.appendingPathComponent("folder-link")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.folder)
            #expect(throws: BackupFolderError.symbolicLink) { _ = try authority.select(symlink, activeVaultURL: fixture.vault) }
            let ubiquitous = BackupFolderAuthority(bookmarks: FolderBookmarks(resolvedURL: fixture.folder), ubiquitousItemDetector: { _ in true })
            #expect(throws: BackupFolderError.ubiquitousContainer) {
                _ = try ubiquitous.select(fixture.folder, activeVaultURL: fixture.vault)
            }
        }
        #expect(throws: BackupFolderError.volumeRoot) {
            _ = try BackupFolderAuthority(bookmarks: FolderBookmarks(resolvedURL: URL(fileURLWithPath: "/")))
                .select(URL(fileURLWithPath: "/", isDirectory: true), activeVaultURL: URL(fileURLWithPath: "/tmp/vault"))
        }
    }

    @Test
    func usingTheFolderBalancesScopeRefreshesAStaleBookmarkAndPinsTheFolder() throws {
        try withFolderFixture { fixture in
            let bookmarks = FolderBookmarks(resolvedURL: fixture.folder)
            let authority = BackupFolderAuthority(bookmarks: bookmarks)
            let selection = try authority.select(fixture.folder, activeVaultURL: fixture.vault)
            bookmarks.stale = true
            bookmarks.created = Data("refreshed-bookmark".utf8)

            let result = try authority.withFolder(selection) { $0.lastPathComponent }
            #expect(result.value == fixture.folder.lastPathComponent)
            #expect(result.refreshedBookmarkData == Data("refreshed-bookmark".utf8))
            #expect(bookmarks.counts == (1, 1))

            let moved = fixture.base.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: fixture.folder, to: moved)
            #expect(throws: BackupFolderError.folderUnavailable) { _ = try authority.withFolder(selection) { _ in () } }
            try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: false)
            #expect(throws: BackupFolderError.identityChanged) { _ = try authority.withFolder(selection) { _ in () } }
            #expect(bookmarks.counts == (3, 3))
        }
    }

    @Test
    func aBookmarkThatNoLongerResolvesNeedsReselectionUnlessTheFileIsMissing() throws {
        try withFolderFixture { fixture in
            let bookmarks = FolderBookmarks(resolvedURL: fixture.folder)
            let authority = BackupFolderAuthority(bookmarks: bookmarks)
            let selection = try authority.select(fixture.folder, activeVaultURL: fixture.vault)
            bookmarks.resolutionError = CocoaError(.fileReadCorruptFile)
            #expect(throws: BackupFolderError.bookmarkInvalid) { _ = try authority.withFolder(selection) { _ in () } }
            bookmarks.resolutionError = CocoaError(.fileNoSuchFile)
            #expect(throws: BackupFolderError.folderUnavailable) { _ = try authority.withFolder(selection) { _ in () } }
            #expect(bookmarks.counts == (0, 0))
        }
    }
}

private struct FolderFixture {
    let base: URL
    let folder: URL
    let vault: URL
}

private func withFolderFixture(_ body: (FolderFixture) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("KinlogueFolderAuthority-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let folder = base.appendingPathComponent("chosen", isDirectory: true)
    let vault = base.appendingPathComponent("support/Kinlogue/Vault", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    try body(FolderFixture(base: base, folder: folder, vault: vault))
}

private final class FolderBookmarks: BackupBookmarkAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let resolvedURL: URL
    private var _stale = false
    private var _created = Data("bookmark".utf8)
    private var _resolutionError: Error?
    private var starts = 0, stops = 0

    init(resolvedURL: URL) { self.resolvedURL = resolvedURL }

    var stale: Bool {
        get { lock.withLock { _stale } }
        set { lock.withLock { _stale = newValue } }
    }
    var created: Data {
        get { lock.withLock { _created } }
        set { lock.withLock { _created = newValue } }
    }
    var resolutionError: Error? {
        get { lock.withLock { _resolutionError } }
        set { lock.withLock { _resolutionError = newValue } }
    }
    var counts: (Int, Int) { lock.withLock { (starts, stops) } }

    func createBookmark(for url: URL) throws -> Data { created }
    func resolveBookmark(_ data: Data) throws -> BackupResolvedBookmark {
        if let error = resolutionError { throw error }
        return .init(url: resolvedURL, isStale: stale)
    }
    func startAccessing(_ url: URL) -> Bool { lock.withLock { starts += 1 }; return true }
    func stopAccessing(_ url: URL) { lock.withLock { stops += 1 } }
}
