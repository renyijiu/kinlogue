import Darwin
import Foundation
import KinlogueCore
import KinloguePlatform
import Testing
@testable import KinlogueApp

@Test
func destinationPreparationCreatesOneOwnedChildAndPreservesUnknownSiblings() throws {
    try withDestinationFixture { fixture in
        let unknown = fixture.parent.appendingPathComponent("do-not-touch.txt")
        try Data("foreign".utf8).write(to: unknown)
        let bookmarks = FakeBookmarkAccess()
        let authority = BackupDestinationAuthority(bookmarks: bookmarks)

        let selection = try authority.prepareSelectedParent(
            fixture.parent,
            activeVaultURL: fixture.vault
        )

        #expect(selection.repositoryURL.lastPathComponent
            == BackupDestinationAuthority.repositoryDirectoryName)
        #expect(selection.bookmarkData == Data("bookmark".utf8))
        #expect(selection.selectedDirectoryIdentity.device
            == selection.repositoryDirectoryIdentity.device)
        #expect(selection.selectedDirectoryIdentity != selection.repositoryDirectoryIdentity)
        #expect(try Data(contentsOf: unknown) == Data("foreign".utf8))
    }
}

@Test
func destinationRejectsVaultRelationsSymlinksVolumeRootAndUbiquity() throws {
    try withDestinationFixture { fixture in
        let authority = BackupDestinationAuthority(bookmarks: FakeBookmarkAccess())
        for forbidden in [fixture.vault, fixture.vault.deletingLastPathComponent()] {
            #expect(throws: BackupDestinationAuthorityError.forbiddenVaultRelationship) {
                _ = try authority.prepareSelectedParent(forbidden, activeVaultURL: fixture.vault)
            }
        }

        let symlink = fixture.base.appendingPathComponent("selected-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.parent)
        #expect(throws: BackupDestinationAuthorityError.symbolicLink) {
            _ = try authority.prepareSelectedParent(symlink, activeVaultURL: fixture.vault)
        }
    }

    let root = URL(fileURLWithPath: "/", isDirectory: true)
    #expect(throws: BackupDestinationAuthorityError.volumeRoot) {
        _ = try BackupDestinationAuthority(bookmarks: FakeBookmarkAccess())
            .prepareSelectedParent(root, activeVaultURL: URL(fileURLWithPath: "/tmp/vault"))
    }

    try withDestinationFixture { fixture in
        let authority = BackupDestinationAuthority(
            bookmarks: FakeBookmarkAccess(),
            ubiquitousItemDetector: { _ in true }
        )
        #expect(throws: BackupDestinationAuthorityError.ubiquitousContainer) {
            _ = try authority.prepareSelectedParent(fixture.parent, activeVaultURL: fixture.vault)
        }
    }
}

@Test
func resolvedDestinationBalancesSecurityScopeRefreshesStaleBookmarkAndPinsIdentity() throws {
    try withDestinationFixture { fixture in
        let bookmarks = FakeBookmarkAccess(resolvedURL: fixture.parent, stale: true)
        let authority = BackupDestinationAuthority(bookmarks: bookmarks)
        let selection = try authority.prepareSelectedParent(fixture.parent, activeVaultURL: fixture.vault)

        let result = try authority.withResolvedDestination(selection) { repositoryURL in
            repositoryURL.lastPathComponent
        }

        #expect(result.value == BackupDestinationAuthority.repositoryDirectoryName)
        #expect(result.refreshedBookmarkData == Data("refreshed-bookmark".utf8))
        #expect(bookmarks.startCount == 1)
        #expect(bookmarks.stopCount == 1)

        let moved = fixture.base.appendingPathComponent("moved-parent")
        try FileManager.default.moveItem(at: fixture.parent, to: moved)
        try FileManager.default.createDirectory(at: fixture.parent, withIntermediateDirectories: false)
        #expect(throws: BackupDestinationAuthorityError.identityChanged) {
            _ = try authority.withResolvedDestination(selection) { _ in () }
        }
        #expect(bookmarks.startCount == 2)
        #expect(bookmarks.stopCount == 2)
    }
}

@Test
func enrollmentPublicationIsExclusiveIdempotentForSameBytesAndRejectsSubstitution() throws {
    try withDestinationFixture { fixture in
        let authority = BackupDestinationAuthority(bookmarks: FakeBookmarkAccess())
        let selection = try authority.prepareSelectedParent(fixture.parent, activeVaultURL: fixture.vault)
        let first = try BackupKeyHierarchy.makeEnrollment()
        let second = try BackupKeyHierarchy.makeEnrollment()

        try authority.publishEnrollment(
            descriptor: first.descriptor,
            authorization: first.authorization,
            to: selection
        )
        try authority.publishEnrollment(
            descriptor: first.descriptor,
            authorization: first.authorization,
            to: selection
        )
        #expect(throws: BackupDestinationAuthorityError.repositoryIdentityConflict) {
            try authority.publishEnrollment(
                descriptor: second.descriptor,
                authorization: second.authorization,
                to: selection
            )
        }

        let descriptorURL = selection.repositoryURL
            .appendingPathComponent(BackupDestinationAuthority.descriptorFileName)
        #expect(try Data(contentsOf: descriptorURL) == first.descriptor.canonicalBytes)
    }
}

private struct DestinationFixture {
    let base: URL
    let parent: URL
    let vault: URL
}

private func withDestinationFixture(_ body: (DestinationFixture) throws -> Void) throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("KinlogueDestination-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let parent = base.appendingPathComponent("selected", isDirectory: true)
    let vault = base.appendingPathComponent("app-support/Kinlogue/Vault", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    try body(.init(base: base, parent: parent, vault: vault))
}

private final class FakeBookmarkAccess: BackupBookmarkAccessing, @unchecked Sendable {
    private let resolvedURL: URL?
    private let stale: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(resolvedURL: URL? = nil, stale: Bool = false) {
        self.resolvedURL = resolvedURL
        self.stale = stale
    }

    func createBookmark(for url: URL) throws -> Data { Data("bookmark".utf8) }

    func resolveBookmark(_ data: Data) throws -> BackupResolvedBookmark {
        guard let resolvedURL else { throw BackupDestinationAuthorityError.bookmarkInvalid }
        return .init(url: resolvedURL, isStale: stale)
    }

    func refreshBookmark(for url: URL) throws -> Data { Data("refreshed-bookmark".utf8) }

    func startAccessing(_ url: URL) -> Bool {
        startCount += 1
        return true
    }

    func stopAccessing(_ url: URL) { stopCount += 1 }
}
