import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func stagedReportCommitRejectsGenerationExhaustionWithoutPublishing() async throws {
    let root = plaintextVaultTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let member = try FamilyMember(displayName: "Synthetic member")
    let withMember = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: try VaultGeneration.successor(of: initial.generation),
        members: [member]
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: withMember,
        writes: []
    ))
    let before = try replacePlaintextVaultCatalogGeneration(
        root: root,
        generation: UInt64.max
    )

    let bytes = Data("synthetic staged report".utf8)
    let attachmentID = UUID()
    let sourceID = UUID()
    let intent = try LANArchiveIntent(
        vaultID: initial.vaultID,
        orderedSources: [try LANArchiveSource(
            itemID: UUID(),
            itemRevision: 0,
            contentIdentity: try LANInboxContentIdentity(
                sha256Digest: ContentDigest.sha256(bytes),
                byteCount: bytes.count
            ),
            reportSourceID: sourceID,
            attachmentID: attachmentID
        )],
        memberID: member.id,
        canonicalReportDate: Date(timeIntervalSinceReferenceDate: 1),
        draftID: UUID(),
        documentObjectID: UUID()
    )
    let stagingPath = PlaintextVault.stagingPath(
        intentID: intent.id,
        attachmentID: attachmentID
    )
    try AtomicFileStore(rootURL: root).writeImmutable(bytes, relativePath: stagingPath)
    let staged = try VaultStagedReportSelection(
        intentID: intent.id,
        attachments: [try VaultStagedAttachment(
            reference: .init(id: attachmentID, kind: .attachment),
            relativePath: stagingPath,
            byteCount: bytes.count,
            sha256Digest: ContentDigest.sha256(bytes)
        )]
    )
    let sources = try ReportSources([try ReportSource(
        id: sourceID,
        attachmentID: attachmentID,
        displayName: "synthetic.txt",
        pageCount: 1
    )])
    let proposed = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: UInt64.max,
        members: [member],
        attachments: [try Attachment(
            id: attachmentID,
            contentTypeIdentifier: "public.data",
            byteCount: bytes.count,
            sha256Digest: ContentDigest.sha256(bytes)
        )],
        importDrafts: [ImportDraft(
            id: intent.draftID,
            sources: sources,
            state: .needsReview,
            documentObjectID: intent.documentObjectID,
            memberID: member.id
        )]
    )
    let documentWrite = VaultObjectWrite(
        reference: .init(id: intent.documentObjectID, kind: .ocr),
        plaintext: try CanonicalVaultJSON.encode(ImportDraftDocument(
            blocks: [],
            candidates: ReportCandidates()
        ))
    )

    await #expect(throws: VaultError.mutationConflict) {
        _ = try await vault.commitStagedReportSelection(
            staged,
            intent: intent,
            expectedGeneration: UInt64.max - 1,
            catalog: proposed,
            documentWrite: documentWrite
        )
    }
    await #expect(throws: VaultError.invalidGeneration) {
        _ = try await vault.commitStagedReportSelection(
            staged,
            intent: intent,
            expectedGeneration: UInt64.max,
            catalog: proposed,
            documentWrite: documentWrite
        )
    }

    #expect(try Data(contentsOf: root.appendingPathComponent("library.json")) == before)
    #expect((try await vault.loadCatalog()).generation == UInt64.max)
    let layout = try PlaintextVaultLayout(rootURL: root)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
        layout.objectPath(.init(id: attachmentID, kind: .attachment))
    ).path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
        layout.objectPath(documentWrite.reference)
    ).path))
}

private func replacePlaintextVaultCatalogGeneration(
    root: URL,
    generation: UInt64
) throws -> Data {
    let files = try AtomicFileStore(rootURL: root)
    let manifestPath = "library.json"
    let original = try Data(contentsOf: root.appendingPathComponent(manifestPath))
    let manifest = try CanonicalVaultJSON.decode(PlaintextVaultManifest.self, from: original)
    let catalog = try VaultCatalog(
        formatVersion: manifest.catalog.formatVersion,
        vaultID: manifest.catalog.vaultID,
        generation: generation,
        members: manifest.catalog.members,
        records: manifest.catalog.records,
        attachments: manifest.catalog.attachments,
        importDrafts: manifest.catalog.importDrafts,
        dicomStudies: manifest.catalog.dicomStudies
    )
    let replacement = PlaintextVaultManifest(
        magic: manifest.magic,
        formatVersion: manifest.formatVersion,
        commitID: UUID(),
        catalogSHA256: ContentDigest.sha256(try CanonicalVaultJSON.encode(catalog)),
        catalog: catalog,
        objects: manifest.objects
    )
    let data = try CanonicalVaultJSON.encode(replacement)
    try files.replaceAtomically(data, relativePath: manifestPath)
    return data
}
