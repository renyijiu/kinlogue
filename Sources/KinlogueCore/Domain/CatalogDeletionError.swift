import Foundation

public enum CatalogDeletionError: Error, Equatable, Sendable {
    case recordNotFound
    case memberNotFound
    case memberStillReferenced(recordCount: Int, draftCount: Int)
    case memberStillReferencedByDICOMStudy(studyCount: Int)
    case dicomStudyNotFound
    case generationExhausted
}
