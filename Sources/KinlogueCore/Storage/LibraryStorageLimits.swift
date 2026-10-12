/// The unpublished SQLite format's canonical JSON budget for one persisted entity.
/// This bounds storage encoding, not the text accepted by domain model constructors.
package enum LibraryStorageLimits {
    package static let maximumEntityJSONBytes = 16 * 1_024 * 1_024
}
