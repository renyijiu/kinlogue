import Foundation
import KinlogueCore

public typealias LANReportArchiveResult = LANArchiveOutcome

enum LANReportArchiveCoordinatorFault: Equatable, Sendable {
    case beforeTerminalCleanup
}

/// Turns one ordered Mac selection into at most one review draft. The inbox
/// intent survives cross-store work, and selected items leave the queue only
/// after the Vault has a durable new or pre-existing destination.
public actor LANReportArchiveCoordinator {
    public typealias IDGenerator = @Sendable () -> UUID

    private let inbox: PlaintextLANInboxStore
    private let vault: PlaintextVault
    private let preprocessor: LANItemPreprocessor
    private let stager: VaultReportSelectionStaging
    private let makeID: IDGenerator
    private let failureInjector: (@Sendable (LANReportArchiveCoordinatorFault) -> Bool)?

    public init(
        rootURL: URL,
        inbox: PlaintextLANInboxStore,
        vault: PlaintextVault,
        preprocessor: LANItemPreprocessor,
        makeID: @escaping IDGenerator = { UUID() }
    ) throws {
        try self.init(
            rootURL: rootURL,
            inbox: inbox,
            vault: vault,
            preprocessor: preprocessor,
            makeID: makeID,
            failureInjector: nil
        )
    }

    init(
        rootURL: URL,
        inbox: PlaintextLANInboxStore,
        vault: PlaintextVault,
        preprocessor: LANItemPreprocessor,
        makeID: @escaping IDGenerator = { UUID() },
        failureInjector: (@Sendable (LANReportArchiveCoordinatorFault) -> Bool)?
    ) throws {
        self.inbox = inbox
        self.vault = vault
        self.preprocessor = preprocessor
        stager = try VaultReportSelectionStaging(rootURL: rootURL, inbox: inbox)
        self.makeID = makeID
        self.failureInjector = failureInjector
    }

    public func archive(
        itemIDs: [LANInboxItem.ID],
        memberID: FamilyMember.ID,
        canonicalReportDate: Date,
        activeSessionID: UUID? = nil
    ) async throws -> LANReportArchiveResult {
        guard !itemIDs.isEmpty,
              itemIDs.count <= LANArchiveIntent.maximumSourceCount,
              Set(itemIDs).count == itemIDs.count,
              canonicalReportDate.timeIntervalSinceReferenceDate.isFinite else {
            throw LANInboxError.invalidModel
        }
        let persistenceStableDate = CanonicalVaultJSON.persistenceStableDate(
            canonicalReportDate
        )
        _ = try await preprocessor.preprocess(itemIDs: itemIDs)
        let prepared = try await preprocessor.preparedSelection(
            itemIDs: itemIDs,
            canonicalReportDate: persistenceStableDate
        )
        var snapshot = try await inbox.loadSnapshot()
        var intent = try existingOrNewIntent(
            snapshot: snapshot,
            prepared: prepared,
            memberID: memberID,
            canonicalReportDate: persistenceStableDate
        )

        switch try await inbox.prepareArchive(intent) {
        case let .completed(terminal):
            await cleanupAndAcknowledge(terminal)
            return terminal.receipt.outcome
        case let .active(active):
            intent = active
        }

        snapshot = try await inbox.loadSnapshot()
        try validate(intent: intent, prepared: prepared, snapshot: snapshot)
        let staged: VaultStagedReportSelection
        do {
            staged = try await stager.stage(intent)
        } catch {
            if (try? await stager.cleanup(intent)) != nil {
                try? await inbox.cancelArchive(intentID: intent.id)
            }
            throw error
        }

        do {
            let documentWrite = VaultObjectWrite(
                reference: VaultObjectReference(
                    id: intent.documentObjectID,
                    kind: .ocr
                ),
                plaintext: try CanonicalVaultJSON.encode(prepared.document)
            )
            var lastConflict: Error?
            for _ in 0..<4 {
                do {
                    let catalog = try await vault.loadCatalog()
                    let proposed = try proposedCatalog(
                        from: catalog,
                        intent: intent,
                        prepared: prepared
                    )
                    let outcome = try await vault.commitStagedReportSelection(
                        staged,
                        intent: intent,
                        expectedGeneration: catalog.generation,
                        catalog: proposed,
                        documentWrite: documentWrite
                    )
                    let terminal: LANArchiveTerminal
                    switch outcome {
                    case let .accepted(_, revision):
                        terminal = try await inbox.recordArchiveOutcome(
                            intentID: intent.id,
                            outcome: .accepted(draftID: intent.draftID),
                            vaultRevision: revision,
                            activeSessionID: activeSessionID
                        )
                    case let .duplicateSkipped(destination, revision):
                        terminal = try await inbox.recordArchiveOutcome(
                            intentID: intent.id,
                            outcome: .duplicateSkipped(destination),
                            vaultRevision: revision,
                            activeSessionID: activeSessionID
                        )
                    }
                    let result = terminal.receipt.outcome
                    await cleanupAndAcknowledge(terminal, staged: staged)
                    return result
                } catch VaultError.mutationConflict {
                    lastConflict = VaultError.mutationConflict
                }
            }
            throw lastConflict ?? VaultError.mutationConflict
        } catch {
            if let reconciled = try? await reconcileDurableResult(
                intent: intent,
                activeSessionID: activeSessionID
            ) {
                await cleanupAndAcknowledge(reconciled, staged: staged)
                return reconciled.receipt.outcome
            }
            if (try? await stager.cleanup(staged)) != nil {
                try? await inbox.cancelArchive(intentID: intent.id)
            }
            throw error
        }
    }

    public func reconcileTerminalStaging(in snapshot: LANInboxSnapshot) async {
        var completed: [LANArchiveTerminal] = []
        for terminal in snapshot.archiveTerminals {
            do {
                try await stager.cleanup(terminal.intent)
                completed.append(terminal)
            } catch {
                continue
            }
        }
        try? await inbox.acknowledgeArchiveTerminals(completed)
    }

    private func cleanupAndAcknowledge(
        _ terminal: LANArchiveTerminal,
        staged: VaultStagedReportSelection? = nil
    ) async {
        guard failureInjector?(.beforeTerminalCleanup) != true else { return }
        do {
            if let staged {
                try await stager.cleanup(staged)
            } else {
                try await stager.cleanup(terminal.intent)
            }
            try await inbox.acknowledgeArchiveTerminals([terminal])
        } catch {
            // If acknowledgement did not commit, the terminal remains the
            // restart authority; a lost ack response is already converged.
        }
    }

    private func existingOrNewIntent(
        snapshot: LANInboxSnapshot,
        prepared: LANPreparedItemSelection,
        memberID: FamilyMember.ID,
        canonicalReportDate: Date
    ) throws -> LANArchiveIntent {
        let itemIDs = prepared.items.map(\.id)
        if let existing = snapshot.archiveIntents.first(where: {
            $0.orderedSources.map(\.itemID) == itemIDs
                && $0.memberID == memberID
                && $0.canonicalReportDate == canonicalReportDate
        }) {
            try validate(intent: existing, prepared: prepared, snapshot: snapshot)
            return existing
        }
        let sources = try zip(prepared.items, prepared.sourceDocuments).map {
            item, document in
            try LANArchiveSource(
                itemID: item.id,
                itemRevision: item.revision,
                contentIdentity: item.contentIdentity,
                reportSourceID: document.source.id,
                attachmentID: document.source.attachmentID
            )
        }
        return try LANArchiveIntent(
            id: makeID(),
            vaultID: snapshot.vaultID,
            orderedSources: sources,
            memberID: memberID,
            canonicalReportDate: canonicalReportDate,
            draftID: makeID(),
            documentObjectID: makeID()
        )
    }

    private func validate(
        intent: LANArchiveIntent,
        prepared: LANPreparedItemSelection,
        snapshot: LANInboxSnapshot
    ) throws {
        guard intent.vaultID == snapshot.vaultID,
              intent.orderedSources.map(\.itemID) == prepared.items.map(\.id),
              intent.orderedSources.map(\.itemRevision) == prepared.items.map(\.revision),
              intent.orderedSources.map(\.contentIdentity)
                == prepared.items.map(\.contentIdentity),
              intent.orderedSources.map(\.reportSourceID)
                == prepared.sourceDocuments.map(\.source.id),
              intent.orderedSources.map(\.attachmentID)
                == prepared.sourceDocuments.map(\.source.attachmentID) else {
            throw LANInboxError.receiptConflict
        }
    }

    private func proposedCatalog(
        from catalog: VaultCatalog,
        intent: LANArchiveIntent,
        prepared: LANPreparedItemSelection
    ) throws -> VaultCatalog {
        if catalog.importDrafts.contains(where: { $0.id == intent.draftID }) {
            return catalog
        }
        guard catalog.members.contains(where: {
            $0.id == intent.memberID && !$0.isArchived
        }) else {
            throw LANInboxError.invalidReference
        }
        var attachments = catalog.attachments
        for (source, document) in zip(
            intent.orderedSources,
            prepared.sourceDocuments
        ) {
            if let existing = attachments.first(where: {
                $0.id == source.attachmentID
            }) {
                guard existing.byteCount == source.contentIdentity.byteCount,
                      existing.sha256Digest == source.contentIdentity.sha256Digest,
                      existing.contentTypeIdentifier == document.contentTypeIdentifier else {
                    throw VaultError.objectAlreadyExists
                }
            } else {
                attachments.append(try Attachment(
                    id: source.attachmentID,
                    contentTypeIdentifier: document.contentTypeIdentifier,
                    byteCount: source.contentIdentity.byteCount,
                    sha256Digest: source.contentIdentity.sha256Digest
                ))
            }
        }
        var drafts = catalog.importDrafts
        drafts.append(ImportDraft(
            id: intent.draftID,
            sources: prepared.sources,
            state: .needsReview,
            revision: 0,
            attemptID: nil,
            documentObjectID: intent.documentObjectID,
            failureCode: nil,
            memberID: intent.memberID
        ))
        return try VaultCatalog(
            formatVersion: catalog.formatVersion,
            vaultID: catalog.vaultID,
            generation: try VaultGeneration.successor(of: catalog.generation),
            members: catalog.members,
            records: catalog.records,
            attachments: attachments,
            importDrafts: drafts,
            dicomStudies: catalog.dicomStudies
        )
    }

    private func reconcileDurableResult(
        intent: LANArchiveIntent,
        activeSessionID: UUID?
    ) async throws -> LANArchiveTerminal {
        let (catalog, revision) = try await vault.loadCatalogHead()
        if let draft = catalog.importDrafts.first(where: { $0.id == intent.draftID }),
           draft.state == .needsReview,
           (try ReportFingerprint(
                sources: draft.sources,
                attachments: catalog.attachments
           )) == intent.fingerprint {
            let terminal = try await inbox.recordArchiveOutcome(
                intentID: intent.id,
                outcome: .accepted(draftID: intent.draftID),
                vaultRevision: revision,
                activeSessionID: activeSessionID
            )
            return terminal
        }
        guard let duplicate = DuplicateDetector.find(
            fingerprint: intent.fingerprint,
            attachments: catalog.attachments,
            records: catalog.records,
            drafts: catalog.importDrafts
        ) else {
            throw LANInboxError.invalidReference
        }
        let destination = switch duplicate {
        case let .record(id): LANReportDuplicateDestination(
            kind: .healthRecord,
            id: id
        )
        case let .draft(id): LANReportDuplicateDestination(
            kind: .importDraft,
            id: id
        )
        }
        let terminal = try await inbox.recordArchiveOutcome(
            intentID: intent.id,
            outcome: .duplicateSkipped(destination),
            vaultRevision: revision,
            activeSessionID: activeSessionID
        )
        return terminal
    }
}
