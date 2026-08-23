import Foundation

public enum ReportDateKind: String, Codable, CaseIterable, Hashable, Sendable {
    case report
    case examination
    case collection
    case admission
    case discharge
    case other
}

public struct ReportDateCandidate: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let date: Date
    public let kind: ReportDateKind
    public let source: SourceField

    public init(
        id: UUID = UUID(),
        date: Date,
        kind: ReportDateKind,
        source: SourceField
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.source = source
    }
}
