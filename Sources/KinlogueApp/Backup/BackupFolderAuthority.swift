import AppKit
import Darwin
import Foundation
import KinlogueCore
import KinloguePlatform

enum BackupFolderError: Error, Equatable, Sendable {
    case invalidDirectory
    case symbolicLink
    case volumeRoot
    case forbiddenVaultRelationship
    case ubiquitousContainer
    case readOnly
    /// The stored access grant no longer resolves; the folder has to be chosen again.
    case bookmarkInvalid
    case securityScopeUnavailable
    /// The bookmark now leads to a different folder than the one chosen.
    case identityChanged
    /// The folder is not reachable right now: a disk is unplugged or a share is offline.
    case folderUnavailable
}

struct BackupResolvedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

protocol BackupBookmarkAccessing: Sendable {
    func createBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> BackupResolvedBookmark
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct SystemBackupBookmarkAccess: BackupBookmarkAccessing {
    func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolveBookmark(_ data: Data) throws -> BackupResolvedBookmark {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return .init(url: url, isStale: stale)
    }

    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

struct BackupResolvedFolder<Value> {
    let value: Value
    /// A fresh bookmark when the stored one was stale; the caller persists it.
    let refreshedBookmarkData: Data?
}

/// Turns the folder the person picked into a durable grant, and every later use of that grant
/// back into the same folder. Writing, listing and deleting happen only inside `withFolder`,
/// which keeps the security scope open until the work ends.
// SAFETY: every stored collaborator is an immutable Sendable value.
final class BackupFolderAuthority: @unchecked Sendable {
    private let bookmarks: any BackupBookmarkAccessing
    private let ubiquitousItemDetector: @Sendable (URL) -> Bool

    init(
        bookmarks: any BackupBookmarkAccessing = SystemBackupBookmarkAccess(),
        ubiquitousItemDetector: @escaping @Sendable (URL) -> Bool = { url in
            (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
        }
    ) {
        self.bookmarks = bookmarks
        self.ubiquitousItemDetector = ubiquitousItemDetector
    }

    /// Validates a folder from the open panel and records it. The caller holds the panel's
    /// access to `url` for the duration of the call.
    func select(_ url: URL, activeVaultURL: URL) throws -> BackupFolderSelection {
        let folder = url.standardizedFileURL
        if folder.path == folder.deletingLastPathComponent().path { throw BackupFolderError.volumeRoot }
        var metadata = stat()
        guard lstat(folder.path, &metadata) == 0 else { throw BackupFolderError.invalidDirectory }
        guard (metadata.st_mode & S_IFMT) != S_IFLNK else { throw BackupFolderError.symbolicLink }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else { throw BackupFolderError.invalidDirectory }
        let chosen = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let vault = activeVaultURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if vault.starts(with: chosen) || chosen.starts(with: vault) { throw BackupFolderError.forbiddenVaultRelationship }
        guard !ubiquitousItemDetector(folder) else { throw BackupFolderError.ubiquitousContainer }
        guard access(folder.path, W_OK) == 0 else { throw BackupFolderError.readOnly }
        let identity = try Self.identity(of: folder)
        let bookmark: Data
        do { bookmark = try bookmarks.createBookmark(for: folder) } catch { throw BackupFolderError.bookmarkInvalid }
        guard try Self.identity(of: folder) == identity else { throw BackupFolderError.identityChanged }
        do {
            return try BackupFolderSelection(bookmarkData: bookmark, identity: identity)
        } catch {
            throw BackupFolderError.bookmarkInvalid
        }
    }

    func withFolder<Value>(
        _ selection: BackupFolderSelection, _ body: (URL) throws -> Value
    ) throws -> BackupResolvedFolder<Value> {
        let (url, refreshed) = try begin(selection)
        defer { bookmarks.stopAccessing(url) }
        return .init(value: try body(url), refreshedBookmarkData: refreshed)
    }

    func withFolder<Value: Sendable>(
        _ selection: BackupFolderSelection, _ body: @Sendable (URL) async throws -> Value
    ) async throws -> BackupResolvedFolder<Value> {
        let (url, refreshed) = try begin(selection)
        defer { bookmarks.stopAccessing(url) }
        return .init(value: try await body(url), refreshedBookmarkData: refreshed)
    }

    private func begin(_ selection: BackupFolderSelection) throws -> (URL, Data?) {
        let resolved: BackupResolvedBookmark
        do {
            resolved = try bookmarks.resolveBookmark(selection.bookmarkData)
        } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            throw BackupFolderError.folderUnavailable
        } catch {
            throw BackupFolderError.bookmarkInvalid
        }
        guard bookmarks.startAccessing(resolved.url) else { throw BackupFolderError.securityScopeUnavailable }
        do {
            guard try Self.identity(of: resolved.url) == selection.identity else { throw BackupFolderError.identityChanged }
            var refreshed: Data?
            if resolved.isStale {
                guard let data = try? bookmarks.createBookmark(for: resolved.url), !data.isEmpty,
                      data.count <= BackupFolderSelection.maximumBookmarkByteCount else {
                    throw BackupFolderError.bookmarkInvalid
                }
                refreshed = data
            }
            return (resolved.url, refreshed)
        } catch {
            bookmarks.stopAccessing(resolved.url)
            throw error
        }
    }

    private static func identity(of url: URL) throws -> BackupFolderIdentity {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ENOTDIR || errno == ELOOP ? BackupFolderError.identityChanged : BackupFolderError.folderUnavailable
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw BackupFolderError.identityChanged
        }
        return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
    }
}
