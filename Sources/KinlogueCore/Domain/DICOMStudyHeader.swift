import Foundation

/// A study graph identity independent of its persistence representation.
public struct DICOMStudyHeader: Equatable, Sendable {
    public let id: UUID
    public let state: DICOMStudyState
    public let fingerprint: DICOMStudyFingerprint
    public let attachmentIDs: [UUID]
    public let confirmedMemberID: UUID?
    public let effectiveDate: Date?
    public let contentRevision: UInt64

    public init(id: UUID, state: DICOMStudyState, fingerprint: DICOMStudyFingerprint,
                attachmentIDs: [UUID], confirmedMemberID: UUID? = nil,
                effectiveDate: Date? = nil, contentRevision: UInt64 = 0) throws {
        guard !attachmentIDs.isEmpty, attachmentIDs.count <= DICOMStudyFingerprint.maximumObjectCount,
              Set(attachmentIDs).count == attachmentIDs.count,
              attachmentIDs.count == fingerprint.objects.count else { throw DomainValidationError.invalidCatalogReference }
        switch state {
        case .needsReview:
            guard confirmedMemberID == nil, effectiveDate == nil else { throw DomainValidationError.invalidStateTransition }
        case .confirmed:
            guard confirmedMemberID != nil, let effectiveDate,
                  effectiveDate.timeIntervalSinceReferenceDate.isFinite else { throw DomainValidationError.invalidStateTransition }
        }
        self.id = id; self.state = state; self.fingerprint = fingerprint
        self.attachmentIDs = attachmentIDs.sorted { $0.uuidString < $1.uuidString }
        self.confirmedMemberID = confirmedMemberID; self.effectiveDate = effectiveDate
        self.contentRevision = contentRevision
    }
}

package struct LibraryDICOMStudySummary: Equatable, Sendable, Identifiable {
    package let id: UUID
    package let state: DICOMStudyState
    package let confirmedMemberID: UUID?
    package let effectiveDate: Date?
    package let contentRevision: UInt64
    package let retainedObjectCount: Int
    package let viewableInstanceCount: Int
    package let seriesCount: Int
    package var inertObjectCount: Int { retainedObjectCount - viewableInstanceCount }

    package init(id: UUID, state: DICOMStudyState, confirmedMemberID: UUID?, effectiveDate: Date?,
                contentRevision: UInt64, retainedObjectCount: Int, viewableInstanceCount: Int, seriesCount: Int) {
        self.id = id; self.state = state; self.confirmedMemberID = confirmedMemberID; self.effectiveDate = effectiveDate
        self.contentRevision = contentRevision; self.retainedObjectCount = retainedObjectCount
        self.viewableInstanceCount = viewableInstanceCount; self.seriesCount = seriesCount
    }
}

package struct LibraryDICOMSeriesSummary: Equatable, Sendable, Identifiable {
    package let id: UUID
    package let ordinal: Int
    package let sliceCount: Int
    package let rows: Int
    package let columns: Int
    package let orderingProvenance: DICOMStudyIndex.OrderingProvenance

    package init(id: UUID, ordinal: Int, sliceCount: Int, rows: Int, columns: Int,
                orderingProvenance: DICOMStudyIndex.OrderingProvenance) {
        self.id = id; self.ordinal = ordinal; self.sliceCount = sliceCount; self.rows = rows
        self.columns = columns; self.orderingProvenance = orderingProvenance
    }
}

package struct LibraryDICOMStudyDetails: Equatable, Sendable {
    package let study: LibraryDICOMStudySummary
    package let series: [LibraryDICOMSeriesSummary]
    package init(study: LibraryDICOMStudySummary, series: [LibraryDICOMSeriesSummary]) {
        self.study = study; self.series = series
    }
}

package struct LibraryDICOMStudyListing: Sendable {
    package let revision: LibraryRevision
    package let items: [LibraryDICOMStudySummary]
    package let damagedIDs: [UUID]
    package init(revision: LibraryRevision, items: [LibraryDICOMStudySummary], damagedIDs: [UUID]) {
        self.revision = revision; self.items = items; self.damagedIDs = damagedIDs
    }
}
