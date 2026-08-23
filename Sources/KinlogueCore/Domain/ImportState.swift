import Foundation

public enum ImportState: String, Codable, CaseIterable, Hashable, Sendable {
    case staging
    case processing
    case needsReview
    case confirmed
    case failed
    case discarded

    public func canTransition(to destination: Self) -> Bool {
        if self == destination {
            return true
        }
        switch (self, destination) {
        case (.staging, .processing),
             (.staging, .discarded),
             (.processing, .needsReview),
             (.processing, .failed),
             (.failed, .processing),
             (.failed, .discarded),
             (.needsReview, .confirmed),
             (.needsReview, .discarded):
            return true
        default:
            return false
        }
    }
}
