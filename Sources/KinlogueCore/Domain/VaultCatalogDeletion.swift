import Foundation

public enum CatalogDeletionError: Error, Equatable, Sendable {
    case recordNotFound
    case memberNotFound
    case memberStillReferenced(recordCount: Int, draftCount: Int)
    case memberStillReferencedByDICOMStudy(studyCount: Int)
    case dicomStudyNotFound
    case generationExhausted
}

public extension VaultCatalog {
    func deletingRecord(id: HealthRecord.ID) throws -> Self {
        guard records.contains(where: { $0.id == id }) else {
            throw CatalogDeletionError.recordNotFound
        }

        let remainingRecords = records.filter { $0.id != id }
        let remainingAttachmentIDs = Set(
            remainingRecords.flatMap { $0.sources.attachmentIDs }
                + importDrafts.flatMap { $0.sources.attachmentIDs }
                + dicomStudies.flatMap(\.attachmentIDs)
        )
        let remainingAttachments = attachments.filter {
            remainingAttachmentIDs.contains($0.id)
        }

        return try replacingForDeletion(
            records: remainingRecords,
            attachments: remainingAttachments
        )
    }

    func deletingMember(id: FamilyMember.ID) throws -> Self {
        guard members.contains(where: { $0.id == id }) else {
            throw CatalogDeletionError.memberNotFound
        }

        let recordCount = records.count { $0.memberID == id }
        let draftCount = importDrafts.count { $0.memberID == id }
        guard recordCount == 0, draftCount == 0 else {
            throw CatalogDeletionError.memberStillReferenced(
                recordCount: recordCount,
                draftCount: draftCount
            )
        }
        let dicomStudyCount = dicomStudies.count { study in
            study.state == .confirmed && study.confirmedMemberID == id
        }
        guard dicomStudyCount == 0 else {
            throw CatalogDeletionError.memberStillReferencedByDICOMStudy(
                studyCount: dicomStudyCount
            )
        }

        return try replacingForDeletion(
            members: members.filter { $0.id != id }
        )
    }

    func deletingDICOMStudy(id: DICOMStudy.ID) throws -> Self {
        guard let deletedStudy = dicomStudies.first(where: { $0.id == id }) else {
            throw CatalogDeletionError.dicomStudyNotFound
        }
        let remainingStudies = dicomStudies.filter { $0.id != id }
        let retainedDICOMAttachmentIDs = Set(remainingStudies.flatMap(\.attachmentIDs))
        let retainedReportAttachmentIDs = Set(
            records.flatMap { $0.sources.attachmentIDs }
                + importDrafts.flatMap { $0.sources.attachmentIDs }
        )
        let retainedAttachmentIDs = retainedDICOMAttachmentIDs.union(retainedReportAttachmentIDs)
        let reclaimableAttachmentIDs = Set(deletedStudy.attachmentIDs)
            .subtracting(retainedAttachmentIDs)
        return try replacingForDeletion(
            attachments: attachments.filter { !reclaimableAttachmentIDs.contains($0.id) },
            dicomStudies: remainingStudies
        )
    }

    private func replacingForDeletion(
        members: [FamilyMember]? = nil,
        records: [HealthRecord]? = nil,
        attachments: [Attachment]? = nil,
        dicomStudies: [DICOMStudy]? = nil
    ) throws -> Self {
        let (nextGeneration, overflow) = generation.addingReportingOverflow(1)
        guard !overflow else { throw CatalogDeletionError.generationExhausted }

        return try Self(
            formatVersion: formatVersion,
            vaultID: vaultID,
            generation: nextGeneration,
            members: members ?? self.members,
            records: records ?? self.records,
            attachments: attachments ?? self.attachments,
            importDrafts: importDrafts,
            dicomStudies: dicomStudies ?? self.dicomStudies
        )
    }
}
