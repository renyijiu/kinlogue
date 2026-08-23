import Foundation

public enum OriginalArchivePlanError: Error, Equatable, Sendable {
    case missingPreferredExtension
    case invalidPreferredExtension
    case invalidUndatedToken
    case invalidDate
    case maximumEntryCountExceeded
    case totalByteCountOverflow
    case unsafeArchivePath
}

/// One immutable original that an archive writer must copy.
///
/// This type intentionally is not `Codable`: the attachment identifier and
/// digest are vault-internal locators and must never be serialized into the
/// user-visible archive.
public struct OriginalArchiveEntry: Equatable, Sendable {
    public let archivePath: String
    public let attachmentID: Attachment.ID
    public let byteCount: Int
    public let sha256Digest: Data

    init(
        archivePath: String,
        attachmentID: Attachment.ID,
        byteCount: Int,
        sha256Digest: Data
    ) {
        self.archivePath = archivePath
        self.attachmentID = attachmentID
        self.byteCount = byteCount
        self.sha256Digest = sha256Digest
    }
}

/// A deterministic, identifier-free archive namespace projected from one
/// already validated catalog revision.
public struct OriginalArchivePlan: Equatable, Sendable {
    public static let maximumEntryCount = 30_000
    public static let maximumComponentByteCount = 120
    public static let maximumPathByteCount = 512

    public let entries: [OriginalArchiveEntry]
    public let totalByteCount: Int

    init(entries: [OriginalArchiveEntry], totalByteCount: Int) {
        self.entries = entries
        self.totalByteCount = totalByteCount
    }

    public static func make(
        catalog: VaultCatalog,
        preferredExtensions: [Attachment.ID: String],
        undatedToken: String
    ) throws -> Self {
        try catalog.validate()
        guard !undatedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OriginalArchivePlanError.invalidUndatedToken
        }

        let attachmentsByID = Dictionary(uniqueKeysWithValues: catalog.attachments.map { ($0.id, $0) })
        var pendingByMemberID: [FamilyMember.ID: [PendingItem]] = [:]
        var eligibleEntryCount = 0

        for record in catalog.records where record.importState == .confirmed {
            try reserveEntryCount(record.sources.count, total: &eligibleEntryCount)
            for (sourceOrdinal, source) in record.sources.elements.enumerated() {
                guard let attachment = attachmentsByID[source.attachmentID] else {
                    throw DomainValidationError.invalidCatalogReference
                }
                let preferredExtension = try validatedExtension(
                    for: attachment.id,
                    in: preferredExtensions,
                    requiresDICOM: false
                )
                pendingByMemberID[record.memberID, default: []].append(.report(
                    recordID: record.id,
                    sourceOrdinal: sourceOrdinal,
                    sourceName: source.displayName,
                    attachment: attachment,
                    preferredExtension: preferredExtension,
                    date: record.timelineDate
                ))
            }
        }

        for study in catalog.dicomStudies where study.state == .confirmed {
            guard let memberID = study.confirmedMemberID, let date = study.effectiveDate else {
                throw DomainValidationError.invalidCatalogReference
            }
            try reserveEntryCount(study.attachmentIDs.count, total: &eligibleEntryCount)
            var originals: [(attachment: Attachment, preferredExtension: String)] = []
            originals.reserveCapacity(study.attachmentIDs.count)
            for attachmentID in study.attachmentIDs.sorted(by: uuidPrecedes) {
                guard let attachment = attachmentsByID[attachmentID] else {
                    throw DomainValidationError.invalidCatalogReference
                }
                let preferredExtension = try validatedExtension(
                    for: attachment.id,
                    in: preferredExtensions,
                    requiresDICOM: true
                )
                originals.append((attachment, preferredExtension))
            }
            pendingByMemberID[memberID, default: []].append(.dicom(
                studyID: study.id,
                originals: originals,
                date: date
            ))
        }

        let orderedMembers = catalog.members
            .filter { pendingByMemberID[$0.id]?.isEmpty == false }
            .sorted(by: memberPrecedes)
        var memberNameAllocator = ComponentAllocator()
        var result: [OriginalArchiveEntry] = []
        var totalByteCount = 0

        for member in orderedMembers {
            let visibleMemberName = member.disambiguationLabel.map {
                "\(member.displayName) - \($0)"
            } ?? member.displayName
            let memberStem = sanitizedComponent(visibleMemberName, fallback: "Member")
            let memberDirectory = memberNameAllocator.allocate(stem: memberStem)
            var childNameAllocator = ComponentAllocator()
            let items = pendingByMemberID[member.id, default: []].sorted(by: pendingItemPrecedes)
            let reportOrdinals = stableOrdinals(
                items.compactMap { item in
                    if case let .report(recordID, _, _, _, _, _) = item { recordID } else { nil }
                }
            )
            let studyOrdinals = stableOrdinals(
                items.compactMap { item in
                    if case let .dicom(studyID, _, _) = item { studyID } else { nil }
                }
            )

            for item in items {
                switch item {
                case let .report(recordID, sourceOrdinal, sourceName, attachment, preferredExtension, date):
                    guard let reportOrdinal = reportOrdinals[recordID] else {
                        throw OriginalArchivePlanError.unsafeArchivePath
                    }
                    let datePrefix = try date.map(dateString) ?? sanitizedComponent(undatedToken, fallback: "Undated")
                    let sourceStem = sanitizedSourceStem(sourceName)
                    let fileStem = sanitizedComponent(
                        String(
                            format: "%@ - Report %04d - Source %04d - %@",
                            datePrefix,
                            reportOrdinal,
                            sourceOrdinal + 1,
                            sourceStem
                        ),
                        fallback: "Report"
                    )
                    let filename = childNameAllocator.allocate(stem: fileStem, extension: preferredExtension)
                    let path = try checkedPath([memberDirectory, filename])
                    try appendEntry(
                        OriginalArchiveEntry(
                            archivePath: path,
                            attachmentID: attachment.id,
                            byteCount: attachment.byteCount,
                            sha256Digest: attachment.sha256Digest
                        ),
                        to: &result,
                        totalByteCount: &totalByteCount
                    )

                case let .dicom(studyID, originals, date):
                    guard let studyOrdinal = studyOrdinals[studyID] else {
                        throw OriginalArchivePlanError.unsafeArchivePath
                    }
                    let datePrefix = try dateString(date)
                    let studyStem = sanitizedComponent(
                        String(format: "%@ - DICOM %04d", datePrefix, studyOrdinal),
                        fallback: "DICOM"
                    )
                    let studyDirectory = childNameAllocator.allocate(stem: studyStem)
                    var objectNameAllocator = ComponentAllocator()
                    for (offset, original) in originals.enumerated() {
                        let ordinal = String(format: "%04d", offset + 1)
                        let filename = objectNameAllocator.allocate(
                            stem: ordinal,
                            extension: original.preferredExtension
                        )
                        let path = try checkedPath([memberDirectory, studyDirectory, filename])
                        try appendEntry(
                            OriginalArchiveEntry(
                                archivePath: path,
                                attachmentID: original.attachment.id,
                                byteCount: original.attachment.byteCount,
                                sha256Digest: original.attachment.sha256Digest
                            ),
                            to: &result,
                            totalByteCount: &totalByteCount
                        )
                    }
                }
            }
        }

        return Self(entries: result, totalByteCount: totalByteCount)
    }
}

private extension OriginalArchivePlan {
    enum PendingItem {
        case report(
            recordID: HealthRecord.ID,
            sourceOrdinal: Int,
            sourceName: String?,
            attachment: Attachment,
            preferredExtension: String,
            date: Date?
        )
        case dicom(
            studyID: DICOMStudy.ID,
            originals: [(attachment: Attachment, preferredExtension: String)],
            date: Date
        )

        var date: Date? {
            switch self {
            case let .report(_, _, _, _, _, date): date
            case let .dicom(_, _, date): date
            }
        }

        var kindOrder: Int {
            switch self {
            case .report: 0
            case .dicom: 1
            }
        }

        var hiddenID: UUID {
            switch self {
            case let .report(recordID, _, _, _, _, _): recordID
            case let .dicom(studyID, _, _): studyID
            }
        }

        var sourceOrdinal: Int {
            switch self {
            case let .report(_, sourceOrdinal, _, _, _, _): sourceOrdinal
            case .dicom: 0
            }
        }

    }

    static func appendEntry(
        _ entry: OriginalArchiveEntry,
        to entries: inout [OriginalArchiveEntry],
        totalByteCount: inout Int
    ) throws {
        guard entries.count < maximumEntryCount else {
            throw OriginalArchivePlanError.maximumEntryCountExceeded
        }
        let addition = totalByteCount.addingReportingOverflow(entry.byteCount)
        guard !addition.overflow else {
            throw OriginalArchivePlanError.totalByteCountOverflow
        }
        totalByteCount = addition.partialValue
        entries.append(entry)
    }

    static func reserveEntryCount(_ count: Int, total: inout Int) throws {
        guard count <= maximumEntryCount - total else {
            throw OriginalArchivePlanError.maximumEntryCountExceeded
        }
        total += count
    }

    static func validatedExtension(
        for attachmentID: Attachment.ID,
        in preferredExtensions: [Attachment.ID: String],
        requiresDICOM: Bool
    ) throws -> String {
        guard let rawExtension = preferredExtensions[attachmentID] else {
            throw OriginalArchivePlanError.missingPreferredExtension
        }
        let value = rawExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !value.isEmpty,
              value.utf8.count <= 16,
              value.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
              }),
              !requiresDICOM || value == "dcm" else {
            throw OriginalArchivePlanError.invalidPreferredExtension
        }
        return value
    }

    static func memberPrecedes(_ lhs: FamilyMember, _ rhs: FamilyMember) -> Bool {
        let lhsVisible = sanitizedComponent(
            lhs.disambiguationLabel.map { "\(lhs.displayName) - \($0)" } ?? lhs.displayName,
            fallback: "Member"
        )
        let rhsVisible = sanitizedComponent(
            rhs.disambiguationLabel.map { "\(rhs.displayName) - \($0)" } ?? rhs.displayName,
            fallback: "Member"
        )
        let lhsKey = collisionKey(lhsVisible)
        let rhsKey = collisionKey(rhsVisible)
        if lhsKey != rhsKey { return lhsKey < rhsKey }
        return uuidPrecedes(lhs.id, rhs.id)
    }

    static func pendingItemPrecedes(_ lhs: PendingItem, _ rhs: PendingItem) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            break
        }
        if lhs.kindOrder != rhs.kindOrder { return lhs.kindOrder < rhs.kindOrder }
        if lhs.hiddenID != rhs.hiddenID { return uuidPrecedes(lhs.hiddenID, rhs.hiddenID) }
        return lhs.sourceOrdinal < rhs.sourceOrdinal
    }

    static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    static func dateString(_ date: Date) throws -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw OriginalArchivePlanError.invalidDate
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              (1...9_999).contains(year),
              let month = components.month,
              let day = components.day else {
            throw OriginalArchivePlanError.invalidDate
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func stableOrdinals(_ identifiers: [UUID]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for identifier in identifiers where result[identifier] == nil {
            result[identifier] = result.count + 1
        }
        return result
    }

    static func sanitizedSourceStem(_ displayName: String?) -> String {
        guard let displayName else { return "Report" }
        let normalized = displayName.precomposedStringWithCanonicalMapping
        // Keep the visible text on both sides of hostile separators, but never
        // allow either separator to become archive structure. The extension is
        // removed only to prevent a display-name suffix from impersonating the
        // caller-provided type mapping.
        let sourceStem = (normalized as NSString).deletingPathExtension
        return sanitizedComponent(sourceStem, fallback: "Report")
    }

    static func sanitizedComponent(_ rawValue: String, fallback: String) -> String {
        let normalized = rawValue.precomposedStringWithCanonicalMapping
        let invalidPunctuation = CharacterSet(charactersIn: "<>:\"/\\|?*")
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(normalized.unicodeScalars.count)
        for scalar in normalized.unicodeScalars {
            if scalar.value == 0
                || CharacterSet.controlCharacters.contains(scalar)
                || invalidPunctuation.contains(scalar) {
                scalars.append("_")
            } else {
                scalars.append(scalar)
            }
        }
        var edgeCharacters = CharacterSet.whitespacesAndNewlines
        edgeCharacters.insert(charactersIn: ".")
        var value = String(scalars).trimmingCharacters(in: edgeCharacters)
        if value == "." || value == ".." || value.isEmpty {
            value = fallback
        }
        if isWindowsReservedName(value) {
            value = "_" + value
        }
        return truncated(value, maximumByteCount: maximumComponentByteCount)
    }

    static func isWindowsReservedName(_ value: String) -> Bool {
        let stem = value.split(separator: ".", maxSplits: 1).first.map(String.init) ?? value
        let upper = stem.uppercased()
        if ["CON", "PRN", "AUX", "NUL"].contains(upper) { return true }
        if upper.count == 4,
           (upper.hasPrefix("COM") || upper.hasPrefix("LPT")),
           let digit = upper.last,
           ("1"..."9").contains(String(digit)) {
            return true
        }
        return false
    }

    static func checkedPath(_ components: [String]) throws -> String {
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && component.utf8.count <= maximumComponentByteCount
                      && !component.contains("/")
                      && !component.contains("\\")
                      && !component.unicodeScalars.contains(where: { $0.value == 0 })
              }) else {
            throw OriginalArchivePlanError.unsafeArchivePath
        }
        let path = components.joined(separator: "/")
        guard path.utf8.count <= maximumPathByteCount else {
            throw OriginalArchivePlanError.unsafeArchivePath
        }
        return path
    }

    static func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    static func truncated(_ value: String, maximumByteCount: Int) -> String {
        guard value.utf8.count > maximumByteCount else { return value }
        var result = ""
        result.reserveCapacity(maximumByteCount)
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumByteCount else { break }
            result = candidate
        }
        return result
    }

    struct ComponentAllocator {
        private var usedKeys: Set<String> = []

        mutating func allocate(stem: String, extension fileExtension: String? = nil) -> String {
            var ordinal = 1
            while true {
                let suffix = ordinal == 1 ? "" : " (\(ordinal))"
                let extensionSuffix = fileExtension.map { ".\($0)" } ?? ""
                let stemBudget = maximumComponentByteCount - suffix.utf8.count - extensionSuffix.utf8.count
                let boundedStem = truncated(stem, maximumByteCount: max(1, stemBudget))
                let candidate = boundedStem + suffix + extensionSuffix
                let key = collisionKey(candidate)
                if usedKeys.insert(key).inserted {
                    return candidate
                }
                ordinal += 1
            }
        }
    }
}
