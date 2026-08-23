import AppKit
import Darwin
import Foundation
import KinlogueCore
import KinloguePlatform

enum BackupDestinationAuthorityError: Error, Equatable, Sendable {
    case selectionCancelled
    case invalidDirectory
    case symbolicLink
    case volumeRoot
    case forbiddenVaultRelationship
    case ubiquitousContainer
    case readOnly
    case bookmarkInvalid
    case securityScopeUnavailable
    case identityChanged
    case repositoryIdentityConflict
    case repositoryOffline
    case ioFailure
}

struct BackupResolvedBookmark: Sendable {
    let url: URL
    let isStale: Bool
}

protocol BackupBookmarkAccessing: Sendable {
    func createBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> BackupResolvedBookmark
    func refreshBookmark(for url: URL) throws -> Data
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct SystemBackupBookmarkAccess: BackupBookmarkAccessing {
    func createBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> BackupResolvedBookmark {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return .init(url: url, isStale: stale)
    }

    func refreshBookmark(for url: URL) throws -> Data {
        try createBookmark(for: url)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

struct BackupDestinationSelection: Hashable, Sendable {
    let repositoryURL: URL
    let bookmarkData: Data
    let selectedDirectoryIdentity: BackupFilesystemIdentity
    let repositoryDirectoryIdentity: BackupFilesystemIdentity
}

struct BackupResolvedDestinationResult<Value> {
    let value: Value
    let refreshedBookmarkData: Data?
}

protocol BackupEnrollmentPublishing: Sendable {
    func publish(
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        selection: BackupDestinationSelection
    ) throws -> Data?

    func publish(configuration: BackupLocalConfiguration) throws -> Data?
}

// SAFETY: All stored collaborators are immutable Sendable values; the
// enrollment repository is stateless and each call owns its descriptors.
final class BackupDestinationAuthority: BackupEnrollmentPublishing, @unchecked Sendable {
    static let repositoryDirectoryName = ".kinlogue-backup-v1"
    static let descriptorFileName = "backup-set-descriptor.bin"
    static let authorizationFileName = "writer-authorization.bin"

    private let bookmarks: any BackupBookmarkAccessing
    private let ubiquitousItemDetector: @Sendable (URL) -> Bool
    private let enrollmentRepository = BackupEnrollmentRepository()

    init(
        bookmarks: any BackupBookmarkAccessing = SystemBackupBookmarkAccess(),
        ubiquitousItemDetector: @escaping @Sendable (URL) -> Bool = { url in
            (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
        }
    ) {
        self.bookmarks = bookmarks
        self.ubiquitousItemDetector = ubiquitousItemDetector
    }

    @MainActor
    func chooseParentDirectory() throws -> URL {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url else {
            throw BackupDestinationAuthorityError.selectionCancelled
        }
        return url
    }

    func prepareSelectedParent(
        _ selectedParent: URL,
        activeVaultURL: URL
    ) throws -> BackupDestinationSelection {
        let selected = selectedParent.standardizedFileURL
        try validateSelectedParent(selected, activeVaultURL: activeVaultURL)
        let selectedIdentity = try directoryIdentity(selected, expectedMode: nil)
        let bookmark: Data
        do {
            bookmark = try bookmarks.createBookmark(for: selected)
        } catch {
            throw BackupDestinationAuthorityError.bookmarkInvalid
        }
        guard !bookmark.isEmpty,
              bookmark.count <= BackupPendingEnrollment.maximumBookmarkByteCount else {
            throw BackupDestinationAuthorityError.bookmarkInvalid
        }

        let selectedDescriptor = Darwin.open(
            selected.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard selectedDescriptor >= 0 else {
            throw BackupDestinationAuthorityError.repositoryOffline
        }
        defer { Darwin.close(selectedDescriptor) }
        guard try directoryIdentity(selectedDescriptor, expectedMode: nil) == selectedIdentity else {
            throw BackupDestinationAuthorityError.identityChanged
        }
        if mkdirat(selectedDescriptor, Self.repositoryDirectoryName, 0o700) != 0,
           errno != EEXIST {
            throw errno == EROFS || errno == EACCES
                ? BackupDestinationAuthorityError.readOnly
                : BackupDestinationAuthorityError.ioFailure
        }
        let repositoryDescriptor = openat(
            selectedDescriptor,
            Self.repositoryDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard repositoryDescriptor >= 0 else {
            throw BackupDestinationAuthorityError.repositoryIdentityConflict
        }
        defer { Darwin.close(repositoryDescriptor) }
        let repositoryIdentity = try directoryIdentity(repositoryDescriptor, expectedMode: 0o700)
        guard repositoryIdentity.device == selectedIdentity.device,
              repositoryIdentity != selectedIdentity,
              try directoryIdentity(selectedDescriptor, expectedMode: nil) == selectedIdentity else {
            throw BackupDestinationAuthorityError.identityChanged
        }
        try synchronize(selectedDescriptor)
        return .init(
            repositoryURL: selected.appendingPathComponent(
                Self.repositoryDirectoryName,
                isDirectory: true
            ),
            bookmarkData: bookmark,
            selectedDirectoryIdentity: selectedIdentity,
            repositoryDirectoryIdentity: repositoryIdentity
        )
    }

    func withResolvedDestination<Value>(
        _ selection: BackupDestinationSelection,
        _ body: (URL) throws -> Value
    ) throws -> BackupResolvedDestinationResult<Value> {
        let resolved: BackupResolvedBookmark
        do {
            resolved = try bookmarks.resolveBookmark(selection.bookmarkData)
        } catch {
            throw BackupDestinationAuthorityError.bookmarkInvalid
        }
        guard bookmarks.startAccessing(resolved.url) else {
            throw BackupDestinationAuthorityError.securityScopeUnavailable
        }
        defer { bookmarks.stopAccessing(resolved.url) }

        let parentIdentity = try directoryIdentity(resolved.url, expectedMode: nil)
        guard parentIdentity == selection.selectedDirectoryIdentity else {
            throw BackupDestinationAuthorityError.identityChanged
        }
        let repositoryURL = resolved.url.appendingPathComponent(
            Self.repositoryDirectoryName,
            isDirectory: true
        )
        guard try directoryIdentity(repositoryURL, expectedMode: 0o700)
                == selection.repositoryDirectoryIdentity else {
            throw BackupDestinationAuthorityError.identityChanged
        }
        let refreshed: Data?
        if resolved.isStale {
            do {
                refreshed = try bookmarks.refreshBookmark(for: resolved.url)
            } catch {
                throw BackupDestinationAuthorityError.bookmarkInvalid
            }
            guard let refreshed, !refreshed.isEmpty,
                  refreshed.count <= BackupPendingEnrollment.maximumBookmarkByteCount else {
                throw BackupDestinationAuthorityError.bookmarkInvalid
            }
        } else {
            refreshed = nil
        }
        return try .init(value: body(repositoryURL), refreshedBookmarkData: refreshed)
    }

    /// Keeps the Powerbox security scope alive for the full asynchronous
    /// operation. Backup publication, final read-back, repository scans and
    /// retention must not outlive the scope that authorizes their directory.
    func withResolvedDestination<Value: Sendable>(
        _ selection: BackupDestinationSelection,
        _ body: @Sendable (URL) async throws -> Value
    ) async throws -> BackupResolvedDestinationResult<Value> {
        let resolved: BackupResolvedBookmark
        do {
            resolved = try bookmarks.resolveBookmark(selection.bookmarkData)
        } catch {
            throw BackupDestinationAuthorityError.bookmarkInvalid
        }
        guard bookmarks.startAccessing(resolved.url) else {
            throw BackupDestinationAuthorityError.securityScopeUnavailable
        }
        defer { bookmarks.stopAccessing(resolved.url) }

        let parentIdentity = try directoryIdentity(resolved.url, expectedMode: nil)
        guard parentIdentity == selection.selectedDirectoryIdentity else {
            throw BackupDestinationAuthorityError.identityChanged
        }
        let repositoryURL = resolved.url.appendingPathComponent(
            Self.repositoryDirectoryName,
            isDirectory: true
        )
        guard try directoryIdentity(repositoryURL, expectedMode: 0o700)
                == selection.repositoryDirectoryIdentity else {
            throw BackupDestinationAuthorityError.identityChanged
        }
        let refreshed: Data?
        if resolved.isStale {
            do {
                refreshed = try bookmarks.refreshBookmark(for: resolved.url)
            } catch {
                throw BackupDestinationAuthorityError.bookmarkInvalid
            }
            guard let refreshed, !refreshed.isEmpty,
                  refreshed.count <= BackupPendingEnrollment.maximumBookmarkByteCount else {
                throw BackupDestinationAuthorityError.bookmarkInvalid
            }
        } else {
            refreshed = nil
        }
        let value = try await body(repositoryURL)
        return .init(value: value, refreshedBookmarkData: refreshed)
    }

    func publish(
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        selection: BackupDestinationSelection
    ) throws -> Data? {
        let result = try withResolvedDestination(selection) { repositoryURL in
            try publishEnrollmentRecords(
                descriptor: descriptor,
                authorization: authorization,
                repositoryURL: repositoryURL,
                expectedIdentity: selection.repositoryDirectoryIdentity
            )
        }
        return result.refreshedBookmarkData
    }

    func publish(configuration: BackupLocalConfiguration) throws -> Data? {
        try publishStoredEnrollment(configuration)
    }

    func publishEnrollment(
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        to selection: BackupDestinationSelection
    ) throws {
        try publishEnrollmentRecords(
            descriptor: descriptor,
            authorization: authorization,
            repositoryURL: selection.repositoryURL,
            expectedIdentity: selection.repositoryDirectoryIdentity
        )
    }

    func publishStoredEnrollment(_ configuration: BackupLocalConfiguration) throws -> Data? {
        let selection = BackupDestinationSelection(
            repositoryURL: URL(fileURLWithPath: "/", isDirectory: true),
            bookmarkData: configuration.bookmarkData,
            selectedDirectoryIdentity: configuration.selectedDirectoryIdentity,
            repositoryDirectoryIdentity: configuration.repositoryDirectoryIdentity
        )
        let result = try withResolvedDestination(selection) { repositoryURL in
            try publishEnrollmentRecords(
                descriptor: configuration.descriptor,
                authorization: configuration.authorization,
                repositoryURL: repositoryURL,
                expectedIdentity: configuration.repositoryDirectoryIdentity
            )
        }
        return result.refreshedBookmarkData
    }

    private func publishEnrollmentRecords(
        descriptor: BackupSetDescriptor,
        authorization: BackupDeviceAuthorization,
        repositoryURL: URL,
        expectedIdentity: BackupFilesystemIdentity
    ) throws {
        do {
            try enrollmentRepository.publish(
                descriptor: descriptor,
                authorization: authorization,
                repositoryURL: repositoryURL,
                expectedIdentity: expectedIdentity
            )
        } catch let error as BackupEnrollmentRepositoryError {
            switch error {
            case .offline:
                throw BackupDestinationAuthorityError.repositoryOffline
            case .identityChanged:
                throw BackupDestinationAuthorityError.identityChanged
            case .identityConflict:
                throw BackupDestinationAuthorityError.repositoryIdentityConflict
            case .ioFailure:
                throw BackupDestinationAuthorityError.ioFailure
            }
        }
    }

    private func validateSelectedParent(_ selected: URL, activeVaultURL: URL) throws {
        if selected.path == selected.deletingLastPathComponent().path {
            throw BackupDestinationAuthorityError.volumeRoot
        }
        var metadata = stat()
        guard lstat(selected.path, &metadata) == 0 else {
            throw BackupDestinationAuthorityError.invalidDirectory
        }
        guard (metadata.st_mode & S_IFMT) != S_IFLNK else {
            throw BackupDestinationAuthorityError.symbolicLink
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw BackupDestinationAuthorityError.invalidDirectory
        }
        let selectedComponents = selected.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let vaultComponents = activeVaultURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if vaultComponents.starts(with: selectedComponents)
            || selectedComponents.starts(with: vaultComponents) {
            throw BackupDestinationAuthorityError.forbiddenVaultRelationship
        }
        guard !ubiquitousItemDetector(selected) else {
            throw BackupDestinationAuthorityError.ubiquitousContainer
        }
        guard access(selected.path, W_OK) == 0 else {
            throw BackupDestinationAuthorityError.readOnly
        }
    }
}

private func directoryIdentity(
    _ url: URL,
    expectedMode: mode_t?
) throws -> BackupFilesystemIdentity {
    let descriptor = Darwin.open(
        url.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw BackupDestinationAuthorityError.repositoryOffline }
    defer { Darwin.close(descriptor) }
    return try directoryIdentity(descriptor, expectedMode: expectedMode)
}

private func directoryIdentity(
    _ descriptor: Int32,
    expectedMode: mode_t?
) throws -> BackupFilesystemIdentity {
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFDIR,
          metadata.st_uid == geteuid(),
          metadata.st_nlink >= 2,
          expectedMode.map({ metadata.st_mode & 0o777 == $0 }) ?? true else {
        throw BackupDestinationAuthorityError.identityChanged
    }
    return .init(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino))
}

private func synchronize(_ descriptor: Int32) throws {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    guard fsync(descriptor) == 0 else { throw BackupDestinationAuthorityError.ioFailure }
}
