import Darwin
import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func parentPreparationCreatesOnlyPrivateParent() throws {
    let ancestor = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("kinlogue-parent-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: ancestor) }
    try FileManager.default.createDirectory(at: ancestor, withIntermediateDirectories: false)
    let parent = ancestor.appendingPathComponent("Kinlogue", isDirectory: true)
    let active = parent.appendingPathComponent("Vault", isDirectory: true)

    #expect(try VaultParentDirectoryPreparation.ensureParentDirectory(for: active) == parent)
    #expect(!FileManager.default.fileExists(atPath: active.path))
    var metadata = stat()
    #expect(lstat(parent.path, &metadata) == 0)
    #expect(metadata.st_mode & 0o777 == 0o700)
}

@Test
func parentPreparationRejectsSymlinkWithoutTouchingItsTarget() throws {
    let ancestor = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("kinlogue-parent-link-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: ancestor) }
    try FileManager.default.createDirectory(at: ancestor, withIntermediateDirectories: false)
    let external = ancestor.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
    let parent = ancestor.appendingPathComponent("Kinlogue", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: external)
    let active = parent.appendingPathComponent("Vault", isDirectory: true)

    #expect(throws: VaultError.invalidPath) {
        try VaultParentDirectoryPreparation.ensureParentDirectory(for: active)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
}

@Test
func parentPreparationRejectsRegularFileAtParentName() throws {
    let ancestor = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("kinlogue-parent-file-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: ancestor) }
    try FileManager.default.createDirectory(at: ancestor, withIntermediateDirectories: false)
    let parent = ancestor.appendingPathComponent("Kinlogue")
    try Data("synthetic".utf8).write(to: parent)

    #expect(throws: VaultError.invalidPath) {
        try VaultParentDirectoryPreparation.ensureParentDirectory(
            for: parent.appendingPathComponent("Vault")
        )
    }
    #expect(try Data(contentsOf: parent) == Data("synthetic".utf8))
}
