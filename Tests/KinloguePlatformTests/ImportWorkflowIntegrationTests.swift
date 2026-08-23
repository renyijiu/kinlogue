import Foundation
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func workflowStoresAttachmentAndReviewDocumentInThePlaintextVault() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    let store = VaultImportDraftStore(vault: vault)
    let workflow = ImportWorkflow(store: store, textExtractor: SyntheticTextExtractor())
    let plaintext = Data("SYNTHETIC-ATTACHMENT-BYTES".utf8)
    let file = try ValidatedImportedFile(
        data: plaintext,
        kind: .image,
        contentTypeIdentifier: "public.png",
        sha256Digest: ContentDigest.sha256(plaintext)
    )

    let outcome = try await workflow.importFile(file)
    guard case .needsReview(let draftID) = outcome else {
        Issue.record("Expected a review draft")
        return
    }

    let catalog = try await vault.loadCatalog()
    let draft = try #require(catalog.importDrafts.first { $0.id == draftID })
    #expect(draft.state == .needsReview)
    #expect(draft.memberID == nil)
    let attachmentID = try #require(draft.soleAttachmentID)
    let attachment = try #require(catalog.attachments.first { $0.id == attachmentID })
    #expect(try await vault.readObject(VaultObjectReference(
        id: attachment.id,
        kind: .attachment
    )) == plaintext)
    let document = try await store.loadDocument(draftID: draftID)
    #expect(document.candidates.memberName?.transcription == "合成成员")

    let duplicate = try await workflow.importFile(file)
    #expect(duplicate == .existingDraft(draftID))

    let layout = try PlaintextVaultLayout(rootURL: root)
    let attachmentURL = root.appendingPathComponent(layout.objectPath(
        VaultObjectReference(id: attachment.id, kind: .attachment)
    ))
    #expect(try Data(contentsOf: attachmentURL) == plaintext)

    let reopenedVault = try PlaintextVault(rootURL: root)
    let reopenedStore = VaultImportDraftStore(vault: reopenedVault)
    #expect(try await reopenedVault.readObject(VaultObjectReference(
        id: attachment.id,
        kind: .attachment
    )) == plaintext)
    #expect(try await reopenedStore.loadDocument(draftID: draftID) == document)
}

@Test
func reviewSnapshotReadsTheDocumentAndFirstSourceFromOneCatalogGeneration() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let firstBytes = Data("SYNTHETIC-FIRST-REVIEW-SOURCE".utf8)
    let secondBytes = Data("SYNTHETIC-SECOND-REVIEW-SOURCE".utf8)
    let firstAttachment = try Attachment(
        contentTypeIdentifier: "public.png",
        byteCount: firstBytes.count,
        sha256Digest: ContentDigest.sha256(firstBytes)
    )
    let secondAttachment = try Attachment(
        contentTypeIdentifier: "public.png",
        byteCount: secondBytes.count,
        sha256Digest: ContentDigest.sha256(secondBytes)
    )
    let firstSource = try ReportSource(
        attachmentID: firstAttachment.id,
        displayName: "synthetic-first.png",
        pageCount: 1
    )
    let secondSource = try ReportSource(
        attachmentID: secondAttachment.id,
        displayName: "synthetic-second.png",
        pageCount: 1
    )
    let documentObjectID = UUID()
    let draft = ImportDraft(
        sources: try ReportSources([firstSource, secondSource]),
        state: .needsReview,
        documentObjectID: documentObjectID
    )
    let document = ImportDraftDocument(blocks: [], candidates: ReportCandidates())
    let member = try FamilyMember(displayName: "Synthetic review member")
    let catalog = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        members: [member],
        attachments: [firstAttachment, secondAttachment],
        importDrafts: [draft]
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: catalog,
        writes: [
            VaultObjectWrite(
                reference: VaultObjectReference(id: firstAttachment.id, kind: .attachment),
                plaintext: firstBytes
            ),
            VaultObjectWrite(
                reference: VaultObjectReference(id: secondAttachment.id, kind: .attachment),
                plaintext: secondBytes
            ),
            VaultObjectWrite(
                reference: VaultObjectReference(id: documentObjectID, kind: .ocr),
                plaintext: try CanonicalVaultJSON.encode(document)
            ),
        ]
    ))

    let snapshot = try await VaultImportDraftStore(vault: vault).loadReviewSnapshot(
        draftID: draft.id
    )

    #expect(snapshot.draft == draft)
    #expect(snapshot.document == document)
    #expect(snapshot.members == [member])
    #expect(snapshot.attachment == firstAttachment)
    #expect(snapshot.originalData == firstBytes)
}

@Test
func duplicateSkipVerifiesTheCurrentObjectBytesBeforeDiscardingTheNewSelection() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    let store = VaultImportDraftStore(vault: vault)
    let bytes = Data("SYNTHETIC-DUPLICATE-INTEGRITY".utf8)
    let file = try ValidatedImportedFile(
        data: bytes,
        kind: .image,
        contentTypeIdentifier: "public.png",
        sha256Digest: ContentDigest.sha256(bytes)
    )
    guard case .created(let draftID) = try await store.stage(file) else {
        Issue.record("Expected a draft")
        return
    }
    let lease = try await store.beginProcessing(draftID: draftID, attemptID: UUID())
    try await store.completeProcessing(
        lease: lease,
        document: ImportDraftDocument(blocks: [], candidates: ReportCandidates())
    )
    let catalog = try await vault.loadCatalog()
    let draft = try #require(catalog.importDrafts.first { $0.id == draftID })
    let attachmentID = try #require(draft.soleAttachmentID)
    let objectPath = try PlaintextVaultLayout(rootURL: root).objectPath(
        VaultObjectReference(id: attachmentID, kind: .attachment)
    )
    try AtomicFileStore(rootURL: root).replaceAtomically(
        Data(repeating: 0x7F, count: bytes.count),
        relativePath: objectPath
    )

    await #expect(throws: VaultError.invalidDigest) {
        _ = try await store.stage(file)
    }

    #expect(try await vault.loadCatalog().importDrafts.map(\.id) == [draftID])
}

@Test
func duplicateSkipVerifiesTheDraftOCRDocumentBeforeDiscardingTheNewSelection() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    let store = VaultImportDraftStore(vault: vault)
    let bytes = Data("SYNTHETIC-DUPLICATE-OCR-INTEGRITY".utf8)
    let file = try ValidatedImportedFile(
        data: bytes,
        kind: .image,
        contentTypeIdentifier: "public.png",
        sha256Digest: ContentDigest.sha256(bytes)
    )
    guard case .created(let draftID) = try await store.stage(file) else {
        Issue.record("Expected a draft")
        return
    }
    let lease = try await store.beginProcessing(draftID: draftID, attemptID: UUID())
    try await store.completeProcessing(
        lease: lease,
        document: ImportDraftDocument(blocks: [], candidates: ReportCandidates())
    )
    let draft = try #require(
        try await vault.loadCatalog().importDrafts.first { $0.id == draftID }
    )
    let documentID = try #require(draft.documentObjectID)
    let objectPath = try PlaintextVaultLayout(rootURL: root).objectPath(
        VaultObjectReference(id: documentID, kind: .ocr)
    )
    try AtomicFileStore(rootURL: root).replaceAtomically(
        Data("tampered-ocr".utf8),
        relativePath: objectPath
    )

    await #expect(throws: VaultError.invalidDigest) {
        _ = try await store.stage(file)
    }
}

@Test
func loadingAStagedMultiPageSourcePreservesItsPageCount() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    let store = VaultImportDraftStore(vault: vault)
    let bytes = Data("SYNTHETIC-MULTIPAGE".utf8)
    let file = try ValidatedImportedFile(
        data: bytes,
        kind: .pdf,
        contentTypeIdentifier: "com.adobe.pdf",
        sha256Digest: ContentDigest.sha256(bytes),
        pageCount: 3
    )
    guard case .created(let draftID) = try await store.stage(file) else {
        Issue.record("Expected a draft")
        return
    }

    #expect(try await store.loadSource(draftID: draftID).pageCount == 3)
}

@Test
func deferredReviewEditsSurviveReopeningThePlaintextVault() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let member = try FamilyMember(displayName: "Synthetic member")
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: try VaultCatalog(
            vaultID: initial.vaultID,
            generation: initial.generation + 1,
            members: [member]
        ),
        writes: []
    ))
    let store = VaultImportDraftStore(vault: vault)
    let bytes = Data("SYNTHETIC-DEFERRED-REVIEW".utf8)
    let file = try ValidatedImportedFile(
        data: bytes,
        kind: .image,
        contentTypeIdentifier: "public.png",
        sha256Digest: ContentDigest.sha256(bytes)
    )
    guard case .created(let draftID) = try await store.stage(file) else {
        Issue.record("Expected a new draft")
        return
    }
    let lease = try await store.beginProcessing(draftID: draftID, attemptID: UUID())
    try await store.completeProcessing(
        lease: lease,
        document: ImportDraftDocument(blocks: [], candidates: ReportCandidates())
    )
    let beforeDeferral = try await vault.loadCatalog()
    let originalRevision = try #require(
        beforeDeferral.importDrafts.first { $0.id == draftID }?.revision
    )
    let originalDocumentObjectID = try #require(
        beforeDeferral.importDrafts.first { $0.id == draftID }?.documentObjectID
    )
    let reviewState = ImportDraftReviewState(
        timelineDateSelection: .manual(Date(timeIntervalSince1970: 1_784_419_200)),
        title: "Synthetic title",
        organization: "Synthetic organization",
        department: "Synthetic department",
        reportType: "Synthetic type",
        reportedResults: "Synthetic results",
        conclusion: "Synthetic conclusion",
        abnormalItems: ["Synthetic abnormal item"],
        userNote: "Synthetic note"
    )

    try await store.saveReview(
        draftID: draftID,
        expectedRevision: originalRevision,
        memberID: member.id,
        document: ImportDraftDocument(
            blocks: [],
            candidates: ReportCandidates(),
            reviewState: reviewState
        )
    )

    let reopenedVault = try PlaintextVault(rootURL: root)
    let reopenedCatalog = try await reopenedVault.loadCatalog()
    let reopenedDraft = try #require(reopenedCatalog.importDrafts.first { $0.id == draftID })
    #expect(reopenedCatalog.generation == beforeDeferral.generation + 1)
    #expect(reopenedDraft.revision == originalRevision + 1)
    #expect(reopenedDraft.memberID == member.id)
    #expect(reopenedDraft.documentObjectID != originalDocumentObjectID)
    let reopenedStore = VaultImportDraftStore(vault: reopenedVault)
    #expect(try await reopenedStore.loadDocument(draftID: draftID).reviewState == reviewState)
    await #expect(throws: VaultError.objectMissing) {
        _ = try await reopenedVault.readObject(VaultObjectReference(
            id: originalDocumentObjectID,
            kind: .ocr
        ))
    }
    let layout = try PlaintextVaultLayout(rootURL: root)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
        layout.objectPath(VaultObjectReference(id: originalDocumentObjectID, kind: .ocr))
    ).path))
    let manifestData = try Data(contentsOf: root.appendingPathComponent("library.json"))
    #expect(!manifestData.contains(Data("reviewState".utf8)))

    let reconciledState = ImportDraftReviewState(
        timelineDateSelection: .unknown,
        title: "Synthetic title after response loss",
        organization: "",
        department: "",
        reportType: "",
        reportedResults: "",
        conclusion: "",
        abnormalItems: [],
        userNote: ""
    )
    let responseLostVault = try PlaintextVault(
        rootURL: root,
        transactionFailureInjector: { $0 == .afterManifestCommit }
    )
    let responseLostStore = VaultImportDraftStore(vault: responseLostVault)
    try await responseLostStore.saveReview(
        draftID: draftID,
        expectedRevision: reopenedDraft.revision,
        memberID: member.id,
        document: ImportDraftDocument(
            blocks: [],
            candidates: ReportCandidates(),
            reviewState: reconciledState
        )
    )

    let afterResponseLoss = try PlaintextVault(rootURL: root)
    let afterResponseLossStore = VaultImportDraftStore(vault: afterResponseLoss)
    #expect(
        try await afterResponseLossStore.loadDocument(draftID: draftID).reviewState
            == reconciledState
    )
    await #expect(throws: ImportDraftError.staleAttempt) {
        try await reopenedStore.saveReview(
            draftID: draftID,
            expectedRevision: reopenedDraft.revision,
            memberID: member.id,
            document: ImportDraftDocument(
                blocks: [],
                candidates: ReportCandidates(),
                reviewState: reviewState
            )
        )
    }
}

@Test
func staleConfirmationCannotRemoveANewerReviewSavedByAnotherVaultInstance() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try await prepareReviewDraft(at: root)
    let staleVault = try PlaintextVault(rootURL: root)
    let staleStore = VaultImportDraftStore(vault: staleVault)
    let newerVault = try PlaintextVault(rootURL: root)
    let newerStore = VaultImportDraftStore(vault: newerVault)
    let newerState = syntheticReviewState(title: "Newer title")

    try await newerStore.saveReview(
        draftID: prepared.draft.id,
        expectedRevision: prepared.draft.revision,
        memberID: prepared.member.id,
        document: ImportDraftDocument(
            blocks: [],
            candidates: ReportCandidates(),
            reviewState: newerState
        )
    )
    let staleRecord = try HealthRecord(
        id: prepared.draft.id,
        memberID: prepared.member.id,
        sources: prepared.draft.sources,
        ocrDocumentObjectID: prepared.draft.documentObjectID,
        importState: .confirmed
    )

    await #expect(throws: ImportDraftError.staleAttempt) {
        _ = try await staleStore.confirm(
            draftID: prepared.draft.id,
            expectedRevision: prepared.draft.revision,
            record: staleRecord
        )
    }

    let current = try await staleVault.loadCatalog()
    let currentDraft = try #require(current.importDrafts.first {
        $0.id == prepared.draft.id
    })
    #expect(currentDraft.revision == prepared.draft.revision + 1)
    #expect(current.records.isEmpty)
    #expect(try await staleStore.loadDocument(draftID: prepared.draft.id).reviewState == newerState)
}

@Test
func staleDiscardCannotRemoveANewerReviewSavedByAnotherVaultInstance() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try await prepareReviewDraft(at: root)
    let staleVault = try PlaintextVault(rootURL: root)
    let staleStore = VaultImportDraftStore(vault: staleVault)
    let newerVault = try PlaintextVault(rootURL: root)
    let newerStore = VaultImportDraftStore(vault: newerVault)
    let newerState = syntheticReviewState(title: "Newer title")

    try await newerStore.saveReview(
        draftID: prepared.draft.id,
        expectedRevision: prepared.draft.revision,
        memberID: prepared.member.id,
        document: ImportDraftDocument(
            blocks: [],
            candidates: ReportCandidates(),
            reviewState: newerState
        )
    )

    await #expect(throws: ImportDraftError.staleAttempt) {
        _ = try await staleStore.discard(
            draftID: prepared.draft.id,
            expectedRevision: prepared.draft.revision
        )
    }

    let current = try await staleVault.loadCatalog()
    let currentDraft = try #require(current.importDrafts.first {
        $0.id == prepared.draft.id
    })
    #expect(currentDraft.revision == prepared.draft.revision + 1)
    #expect(try await staleStore.loadDocument(draftID: prepared.draft.id).reviewState == newerState)
}

@Test
func processingDraftCanBeReacquiredAfterAStoreRestartAndRejectsTheOldLease() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    let firstStore = VaultImportDraftStore(vault: vault)
    let bytes = Data("SYNTHETIC-RESTART".utf8)
    let file = try ValidatedImportedFile(
        data: bytes,
        kind: .image,
        contentTypeIdentifier: "public.png",
        sha256Digest: ContentDigest.sha256(bytes)
    )
    let stage = try await firstStore.stage(file)
    guard case .created(let draftID) = stage else {
        Issue.record("Expected a new draft")
        return
    }
    let oldLease = try await firstStore.beginProcessing(draftID: draftID, attemptID: UUID())

    let restartedStore = VaultImportDraftStore(vault: vault)
    #expect(try await restartedStore.resumableDraftIDs() == [draftID])
    let newLease = try await restartedStore.beginProcessing(draftID: draftID, attemptID: UUID())
    #expect(newLease.revision > oldLease.revision)
    let document = ImportDraftDocument(blocks: [], candidates: ReportCandidates())
    await #expect(throws: ImportDraftError.staleAttempt) {
        try await restartedStore.completeProcessing(lease: oldLease, document: document)
    }
    try await restartedStore.completeProcessing(lease: newLease, document: document)
    #expect(try await restartedStore.loadDocument(draftID: draftID) == document)
}

@Test
func failedDraftIsNotAutomaticallyResumedButExplicitRetryStillProcessesIt() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    let store = VaultImportDraftStore(vault: vault)
    let bytes = Data("SYNTHETIC-FAILED-RETRY".utf8)
    let file = try ValidatedImportedFile(
        data: bytes,
        kind: .image,
        contentTypeIdentifier: "public.png",
        sha256Digest: ContentDigest.sha256(bytes)
    )
    guard case .created(let draftID) = try await store.stage(file) else {
        Issue.record("Expected a new draft")
        return
    }
    let lease = try await store.beginProcessing(draftID: draftID, attemptID: UUID())
    try await store.failProcessing(
        lease: lease,
        failureCode: .textExtractionFailed
    )
    let failed = try #require(
        try await vault.loadCatalog().importDrafts.first { $0.id == draftID }
    )

    let restartedStore = VaultImportDraftStore(vault: try PlaintextVault(rootURL: root))
    let restartedWorkflow = ImportWorkflow(
        store: restartedStore,
        textExtractor: SyntheticTextExtractor()
    )
    #expect(try await restartedStore.resumableDraftIDs().isEmpty)
    #expect(try await restartedWorkflow.resumeInterruptedImports().isEmpty)
    let afterBootstrapRecovery = try #require(
        try await vault.loadCatalog().importDrafts.first { $0.id == draftID }
    )
    #expect(afterBootstrapRecovery == failed)

    #expect(try await restartedWorkflow.retry(draftID: draftID) == .needsReview(draftID))
    let retried = try #require(
        try await vault.loadCatalog().importDrafts.first { $0.id == draftID }
    )
    #expect(retried.state == .needsReview)
    #expect(retried.revision == failed.revision + 2)
    #expect(retried.failureCode == nil)
}

@Test
func confirmingDraftAtomicallyAddsAConfirmedRecordAndRemovesTheDraft() async throws {
    let root = temporaryImportVaultRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let member = try FamilyMember(displayName: "Synthetic member")
    let withMember = try VaultCatalog(
        vaultID: initial.vaultID,
        generation: initial.generation + 1,
        members: [member]
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: withMember,
        writes: []
    ))
    let store = VaultImportDraftStore(vault: vault)
    let bytes = Data("SYNTHETIC-CONFIRM".utf8)
    let file = try ValidatedImportedFile(
        data: bytes,
        kind: .image,
        contentTypeIdentifier: "public.png",
        sha256Digest: ContentDigest.sha256(bytes)
    )
    guard case .created(let draftID) = try await store.stage(file) else {
        Issue.record("Expected a new draft")
        return
    }
    let lease = try await store.beginProcessing(draftID: draftID, attemptID: UUID())
    try await store.completeProcessing(
        lease: lease,
        document: ImportDraftDocument(blocks: [], candidates: ReportCandidates())
    )
    let staged = try await vault.loadCatalog()
    let draft = try #require(staged.importDrafts.first { $0.id == draftID })
    let record = try HealthRecord(
        memberID: member.id,
        sources: draft.sources,
        ocrDocumentObjectID: draft.documentObjectID,
        importState: .confirmed
    )

    var archivedMember = member
    archivedMember.isArchived = true
    let beforeArchive = try await vault.loadCatalog()
    let archivedCatalog = try VaultCatalog(
        formatVersion: beforeArchive.formatVersion,
        vaultID: beforeArchive.vaultID,
        generation: beforeArchive.generation + 1,
        members: [archivedMember],
        records: beforeArchive.records,
        attachments: beforeArchive.attachments,
        importDrafts: beforeArchive.importDrafts
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: beforeArchive.generation,
        catalog: archivedCatalog,
        writes: []
    ))
    await #expect(throws: VaultImportDraftStoreError.invalidDraftDocument) {
        _ = try await store.confirm(
            draftID: draftID,
            expectedRevision: draft.revision,
            record: record
        )
    }

    let beforeUnarchive = try await vault.loadCatalog()
    let activeCatalog = try VaultCatalog(
        formatVersion: beforeUnarchive.formatVersion,
        vaultID: beforeUnarchive.vaultID,
        generation: beforeUnarchive.generation + 1,
        members: [member],
        records: beforeUnarchive.records,
        attachments: beforeUnarchive.attachments,
        importDrafts: beforeUnarchive.importDrafts
    )
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: beforeUnarchive.generation,
        catalog: activeCatalog,
        writes: []
    ))

    _ = try await store.confirm(
        draftID: draftID,
        expectedRevision: draft.revision,
        record: record
    )

    let committed = try await vault.loadCatalog()
    #expect(committed.records == [record])
    #expect(committed.importDrafts.isEmpty)
    #expect(committed.attachments.contains { $0.id == record.soleAttachmentID })
    #expect(committed.records.first?.ocrDocumentObjectID == draft.documentObjectID)
    if let documentObjectID = draft.documentObjectID {
        #expect(try await vault.readObject(VaultObjectReference(
            id: documentObjectID,
            kind: .ocr
        )).isEmpty == false)
    }
}

private actor SyntheticTextExtractor: TextExtractionService {
    func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        [try OCRBlock(
            pageNumber: 1,
            text: "姓名：合成成员",
            boundingBox: NormalizedRect(x: 0.1, y: 0.8, width: 0.4, height: 0.1),
            confidence: 1,
            method: .vision,
            engineVersion: "synthetic"
        )]
    }
}

private func prepareReviewDraft(
    at root: URL
) async throws -> (member: FamilyMember, draft: ImportDraft) {
    let vault = try PlaintextVault(rootURL: root)
    let initial = try await vault.initialize()
    let member = try FamilyMember(displayName: "Synthetic member")
    _ = try await vault.commit(try VaultCommitRequest(
        expectedGeneration: initial.generation,
        catalog: try VaultCatalog(
            vaultID: initial.vaultID,
            generation: initial.generation + 1,
            members: [member]
        ),
        writes: []
    ))
    let store = VaultImportDraftStore(vault: vault)
    let bytes = Data("SYNTHETIC-STALE-TERMINAL-ACTION".utf8)
    let file = try ValidatedImportedFile(
        data: bytes,
        kind: .image,
        contentTypeIdentifier: "public.png",
        sha256Digest: ContentDigest.sha256(bytes)
    )
    guard case .created(let draftID) = try await store.stage(file) else {
        throw VaultImportDraftStoreError.invalidDraftDocument
    }
    let lease = try await store.beginProcessing(draftID: draftID, attemptID: UUID())
    try await store.completeProcessing(
        lease: lease,
        document: ImportDraftDocument(blocks: [], candidates: ReportCandidates())
    )
    let draft = try #require(
        try await vault.loadCatalog().importDrafts.first { $0.id == draftID }
    )
    return (member, draft)
}

private func syntheticReviewState(title: String) -> ImportDraftReviewState {
    ImportDraftReviewState(
        timelineDateSelection: .unknown,
        title: title,
        organization: "",
        department: "",
        reportType: "",
        reportedResults: "",
        conclusion: "",
        abnormalItems: [],
        userNote: ""
    )
}

private func temporaryImportVaultRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("kinlogue-import-\(UUID().uuidString)", isDirectory: true)
}
