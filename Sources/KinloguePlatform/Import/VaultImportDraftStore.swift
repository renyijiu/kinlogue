import Foundation
import KinlogueCore
import UniformTypeIdentifiers

public enum VaultImportDraftStoreError: Error, Equatable, Sendable {
    case draftNotFound
    case attachmentNotFound
    case documentNotFound
    case invalidDraftDocument
}

public actor VaultImportDraftStore: ImportDraftStore {
    private let vault: any VaultStore

    public init(vault: any VaultStore) {
        self.vault = vault
    }

    public func stage(_ file: ValidatedImportedFile) async throws -> ImportStageOutcome {
        let fingerprint = try ReportFingerprint(sources: [
            .init(sha256Digest: file.sha256Digest, byteCount: file.data.count),
        ])
        let snapshot = try await vault.readSnapshot { catalog in
            Self.duplicateVerificationReferences(
                fingerprint: fingerprint,
                catalog: catalog
            )
        }
        let catalog = snapshot.catalog
        if let duplicate = try await verifiedDuplicate(fingerprint: fingerprint, snapshot: snapshot) {
            switch duplicate {
            case .record(let id): return .existingRecord(id)
            case .draft(let id): return .existingDraft(id)
            }
        }

        let attachment = try Attachment(
            contentTypeIdentifier: file.contentTypeIdentifier,
            byteCount: file.data.count,
            sha256Digest: file.sha256Digest
        )
        let draft = ImportDraft(sources: try ReportSources([try ReportSource(
            attachmentID: attachment.id,
            displayName: nil,
            pageCount: file.pageCount
        )]))
        var attachments = catalog.attachments
        attachments.append(attachment)
        var drafts = catalog.importDrafts
        drafts.append(draft)
        let next = try nextCatalog(catalog, attachments: attachments, drafts: drafts)
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: next,
            writes: [VaultObjectWrite(
                reference: VaultObjectReference(id: attachment.id, kind: .attachment),
                plaintext: file.data
            )]
        ))
        return .created(draft.id)
    }

    public func beginProcessing(
        draftID: ImportDraft.ID,
        attemptID: UUID
    ) async throws -> ImportProcessingLease {
        let catalog = try await vault.loadCatalog()
        guard let index = catalog.importDrafts.firstIndex(where: { $0.id == draftID }) else {
            throw VaultImportDraftStoreError.draftNotFound
        }
        var drafts = catalog.importDrafts
        drafts[index] = try drafts[index].startingProcessing(attemptID: attemptID)
        let next = try nextCatalog(catalog, drafts: drafts)
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: next,
            writes: []
        ))
        return ImportProcessingLease(
            draftID: draftID,
            revision: drafts[index].revision,
            attemptID: attemptID
        )
    }

    public func loadSource(draftID: ImportDraft.ID) async throws -> ValidatedImportedFile {
        let snapshot = try await vault.readSnapshot { catalog in
            guard let draft = catalog.importDrafts.first(where: { $0.id == draftID }) else {
                throw VaultImportDraftStoreError.draftNotFound
            }
            guard let source = draft.sources.soleSource,
                  catalog.attachments.contains(where: { $0.id == source.attachmentID }) else {
                throw VaultImportDraftStoreError.attachmentNotFound
            }
            return [VaultObjectReference(id: source.attachmentID, kind: .attachment)]
        }
        let catalog = snapshot.catalog
        guard let draft = catalog.importDrafts.first(where: { $0.id == draftID }) else {
            throw VaultImportDraftStoreError.draftNotFound
        }
        guard let source = draft.sources.soleSource,
              let attachment = catalog.attachments.first(where: {
                  $0.id == source.attachmentID
              }) else { throw VaultImportDraftStoreError.attachmentNotFound }
        let data = try snapshot.data(for: VaultObjectReference(
            id: attachment.id,
            kind: .attachment
        ))
        let kind: ImportedContentKind = attachment.contentTypeIdentifier == UTType.pdf.identifier
            ? .pdf
            : .image
        return try ValidatedImportedFile(
            data: data,
            kind: kind,
            contentTypeIdentifier: attachment.contentTypeIdentifier,
            sha256Digest: attachment.sha256Digest,
            pageCount: source.pageCount
        )
    }

    public func completeProcessing(
        lease: ImportProcessingLease,
        document: ImportDraftDocument
    ) async throws {
        let catalog = try await vault.loadCatalog()
        guard let index = catalog.importDrafts.firstIndex(where: { $0.id == lease.draftID }) else {
            throw VaultImportDraftStoreError.draftNotFound
        }
        let documentObjectID = UUID()
        var drafts = catalog.importDrafts
        drafts[index] = try drafts[index].completingProcessing(
            expectedRevision: lease.revision,
            attemptID: lease.attemptID,
            documentObjectID: documentObjectID
        )
        let persistedDocument = try document.attributedAndValidated(for: drafts[index].sources)
        let next = try nextCatalog(catalog, drafts: drafts)
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: next,
            writes: [VaultObjectWrite(
                reference: VaultObjectReference(id: documentObjectID, kind: .ocr),
                plaintext: try encode(persistedDocument)
            )]
        ))
    }

    public func failProcessing(
        lease: ImportProcessingLease,
        failureCode: ImportFailureCode
    ) async throws {
        let catalog = try await vault.loadCatalog()
        guard let index = catalog.importDrafts.firstIndex(where: { $0.id == lease.draftID }) else {
            throw VaultImportDraftStoreError.draftNotFound
        }
        var drafts = catalog.importDrafts
        drafts[index] = try drafts[index].failingProcessing(
            expectedRevision: lease.revision,
            attemptID: lease.attemptID,
            failureCode: failureCode
        )
        let next = try nextCatalog(catalog, drafts: drafts)
        _ = try await vault.commit(try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: next,
            writes: []
        ))
    }

    public func resumableDraftIDs() async throws -> [ImportDraft.ID] {
        try await vault.loadCatalog().importDrafts
            .filter(\.isResumableAfterInterruption)
            .map(\.id)
    }

    public func loadDocument(draftID: ImportDraft.ID) async throws -> ImportDraftDocument {
        let snapshot = try await vault.readSnapshot { catalog in
            guard let draft = catalog.importDrafts.first(where: { $0.id == draftID }) else {
                throw VaultImportDraftStoreError.draftNotFound
            }
            guard let objectID = draft.documentObjectID else {
                throw VaultImportDraftStoreError.documentNotFound
            }
            return [VaultObjectReference(id: objectID, kind: .ocr)]
        }
        guard let draft = snapshot.catalog.importDrafts.first(where: { $0.id == draftID }) else {
            throw VaultImportDraftStoreError.draftNotFound
        }
        return try document(for: draft, in: snapshot)
    }

    public func loadReviewSnapshot(
        draftID: ImportDraft.ID
    ) async throws -> ImportDraftReviewSnapshot {
        let snapshot = try await vault.readSnapshot { catalog in
            guard let draft = catalog.importDrafts.first(where: {
                $0.id == draftID && $0.state == .needsReview
            }) else {
                throw VaultImportDraftStoreError.draftNotFound
            }
            guard let documentObjectID = draft.documentObjectID else {
                throw VaultImportDraftStoreError.documentNotFound
            }
            let source = draft.sources.first
            guard catalog.attachments.contains(where: { $0.id == source.attachmentID }) else {
                throw VaultImportDraftStoreError.attachmentNotFound
            }
            return [
                VaultObjectReference(id: documentObjectID, kind: .ocr),
                VaultObjectReference(id: source.attachmentID, kind: .attachment),
            ]
        }
        let catalog = snapshot.catalog
        guard let draft = catalog.importDrafts.first(where: {
            $0.id == draftID && $0.state == .needsReview
        }) else {
            throw VaultImportDraftStoreError.draftNotFound
        }
        let source = draft.sources.first
        guard let attachment = catalog.attachments.first(where: {
            $0.id == source.attachmentID
        }) else {
            throw VaultImportDraftStoreError.attachmentNotFound
        }
        return ImportDraftReviewSnapshot(
            draft: draft,
            document: try document(for: draft, in: snapshot),
            members: catalog.members,
            attachment: attachment,
            originalData: try snapshot.data(for: VaultObjectReference(
                id: attachment.id,
                kind: .attachment
            ))
        )
    }

    public func saveReview(
        draftID: ImportDraft.ID,
        expectedRevision: UInt64,
        memberID: FamilyMember.ID?,
        document: ImportDraftDocument
    ) async throws {
        let catalog = try await vault.loadCatalog()
        guard let index = catalog.importDrafts.firstIndex(where: { $0.id == draftID }) else {
            throw VaultImportDraftStoreError.draftNotFound
        }
        guard memberID == nil || catalog.members.contains(where: {
            $0.id == memberID && !$0.isArchived
        }) else {
            throw VaultImportDraftStoreError.invalidDraftDocument
        }
        guard document.reviewState != nil else {
            throw VaultImportDraftStoreError.invalidDraftDocument
        }
        let savedDocumentObjectID = UUID()
        var drafts = catalog.importDrafts
        drafts[index] = try drafts[index].savingReview(
            expectedRevision: expectedRevision,
            memberID: memberID,
            documentObjectID: savedDocumentObjectID
        )
        let next = try nextCatalog(catalog, drafts: drafts)
        let reference = VaultObjectReference(id: savedDocumentObjectID, kind: .ocr)
        let documentData = try encode(try document.attributedAndValidated(for: drafts[index].sources))
        let request = try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: next,
            writes: [VaultObjectWrite(
                reference: reference,
                plaintext: documentData
            )]
        )
        do {
            _ = try await vault.commit(request)
        } catch {
            if let reconciled = try? await vault.loadCatalog(),
               reconciled.importDrafts.contains(drafts[index]),
               let persistedData = try? await vault.readObject(reference),
               persistedData == documentData {
                return
            }
            throw error
        }
    }

    public func confirm(
        draftID: ImportDraft.ID,
        expectedRevision: UInt64,
        record: HealthRecord
    ) async throws -> VaultCatalog {
        let catalog = try await vault.loadCatalog()
        guard let draft = catalog.importDrafts.first(where: { $0.id == draftID }) else {
            throw VaultImportDraftStoreError.draftNotFound
        }
        guard draft.state == .needsReview else {
            throw VaultImportDraftStoreError.invalidDraftDocument
        }
        guard draft.revision == expectedRevision else {
            throw ImportDraftError.staleAttempt
        }
        guard record.importState == .confirmed,
              record.sources == draft.sources,
              record.ocrDocumentObjectID == draft.documentObjectID,
              catalog.members.contains(where: { $0.id == record.memberID && !$0.isArchived }),
              !catalog.records.contains(where: { $0.id == record.id }) else {
            throw VaultImportDraftStoreError.invalidDraftDocument
        }
        var records = catalog.records
        records.append(record)
        let drafts = catalog.importDrafts.filter { $0.id != draftID }
        let next = try nextCatalog(catalog, records: records, drafts: drafts)
        return try await vault.commit(try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: next,
            writes: []
        ))
    }

    public func discard(
        draftID: ImportDraft.ID,
        expectedRevision: UInt64
    ) async throws -> VaultCatalog {
        let catalog = try await vault.loadCatalog()
        guard let draft = catalog.importDrafts.first(where: { $0.id == draftID }) else {
            throw VaultImportDraftStoreError.draftNotFound
        }
        guard draft.revision == expectedRevision else {
            throw ImportDraftError.staleAttempt
        }
        let drafts = catalog.importDrafts.filter { $0.id != draftID }
        let retainedAttachmentIDs = Set(
            catalog.records.flatMap { $0.sources.attachmentIDs }
                + drafts.flatMap { $0.sources.attachmentIDs }
                + catalog.dicomStudies.flatMap(\.attachmentIDs)
        )
        let attachments = catalog.attachments.filter {
            retainedAttachmentIDs.contains($0.id)
        }
        let next = try nextCatalog(catalog, attachments: attachments, drafts: drafts)
        return try await vault.commit(try VaultCommitRequest(
            expectedGeneration: catalog.generation,
            catalog: next,
            writes: []
        ))
    }

    private func nextCatalog(
        _ catalog: VaultCatalog,
        records: [HealthRecord]? = nil,
        attachments: [Attachment]? = nil,
        drafts: [ImportDraft]? = nil
    ) throws -> VaultCatalog {
        try VaultCatalog(
            formatVersion: catalog.formatVersion,
            vaultID: catalog.vaultID,
            generation: try VaultGeneration.successor(of: catalog.generation),
            members: catalog.members,
            records: records ?? catalog.records,
            attachments: attachments ?? catalog.attachments,
            importDrafts: drafts ?? catalog.importDrafts,
            dicomStudies: catalog.dicomStudies
        )
    }

    /// Metadata is only a lookup hint. Before discarding a newly selected
    /// source as an exact duplicate, read every candidate object in the same
    /// coherent vault snapshot, then reload and repeat the authoritative lookup.
    /// This protects the existing local-file staging path; it is not the U5
    /// transaction that will atomically skip and delete a destructive
    /// phone-upload inbox candidate under one mutation lease.
    private func verifiedDuplicate(
        fingerprint: ReportFingerprint,
        snapshot: VaultReadSnapshot
    ) async throws -> DuplicateImport? {
        let initialCatalog = snapshot.catalog
        guard let verification = Self.duplicateVerification(
            fingerprint: fingerprint,
            catalog: initialCatalog
        ) else { return nil }
        let attachments = Dictionary(
            uniqueKeysWithValues: initialCatalog.attachments.map { ($0.id, $0) }
        )
        for attachmentID in Set(verification.sources.attachmentIDs) {
            guard let attachment = attachments[attachmentID] else { return nil }
            let data = try snapshot.data(for: VaultObjectReference(
                id: attachmentID,
                kind: .attachment
            ))
            guard data.count == attachment.byteCount,
                  ContentDigest.sha256(data) == attachment.sha256Digest else {
                return nil
            }
        }
        if let documentObjectID = verification.documentObjectID {
            let data = try snapshot.data(for: VaultObjectReference(
                id: documentObjectID,
                kind: .ocr
            ))
            _ = try decode(ImportDraftDocument.self, from: data)
                .attributedAndValidated(for: verification.sources)
        }

        let current = try await vault.loadCatalog()
        let currentMatch = DuplicateDetector.find(
            fingerprint: fingerprint,
            attachments: current.attachments,
            records: current.records,
            drafts: current.importDrafts
        )
        return currentMatch == verification.match ? currentMatch : nil
    }

    private static func duplicateVerificationReferences(
        fingerprint: ReportFingerprint,
        catalog: VaultCatalog
    ) -> [VaultObjectReference] {
        guard let verification = duplicateVerification(
            fingerprint: fingerprint,
            catalog: catalog
        ) else { return [] }
        var references = Set(verification.sources.attachmentIDs).map {
            VaultObjectReference(id: $0, kind: .attachment)
        }
        if let documentObjectID = verification.documentObjectID {
            references.append(VaultObjectReference(id: documentObjectID, kind: .ocr))
        }
        return references.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func duplicateVerification(
        fingerprint: ReportFingerprint,
        catalog: VaultCatalog
    ) -> (match: DuplicateImport, sources: ReportSources, documentObjectID: UUID?)? {
        guard let match = DuplicateDetector.find(
            fingerprint: fingerprint,
            attachments: catalog.attachments,
            records: catalog.records,
            drafts: catalog.importDrafts
        ) else { return nil }
        let sources: ReportSources
        let documentObjectID: UUID?
        switch match {
        case .record(let id):
            guard let record = catalog.records.first(where: { $0.id == id }) else { return nil }
            sources = record.sources
            documentObjectID = record.ocrDocumentObjectID
        case .draft(let id):
            guard let draft = catalog.importDrafts.first(where: { $0.id == id }) else { return nil }
            sources = draft.sources
            documentObjectID = draft.documentObjectID
        }
        return (match, sources, documentObjectID)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try CanonicalVaultJSON.encode(value)
    }

    private func document(
        for draft: ImportDraft,
        in snapshot: VaultReadSnapshot
    ) throws -> ImportDraftDocument {
        guard let objectID = draft.documentObjectID else {
            throw VaultImportDraftStoreError.documentNotFound
        }
        let data = try snapshot.data(for: VaultObjectReference(id: objectID, kind: .ocr))
        return try decode(ImportDraftDocument.self, from: data)
            .attributedAndValidated(for: draft.sources)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try CanonicalVaultJSON.decode(type, from: data)
        } catch { throw VaultImportDraftStoreError.invalidDraftDocument }
    }
}
