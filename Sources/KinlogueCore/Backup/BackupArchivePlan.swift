import Foundation

/// Localized names a backup archive shows to people. A restore never reads them: it finds
/// every file through the index.
public struct BackupArchiveLabels: Equatable, Sendable {
    public let undated: String
    public let pendingFolder: String
    public let phoneFolder: String
    public let otherFolder: String

    public init(undated: String, pendingFolder: String, phoneFolder: String, otherFolder: String) {
        self.undated = undated
        self.pendingFolder = pendingFolder
        self.phoneFolder = phoneFolder
        self.otherFolder = otherFolder
    }
}

/// One original as the logical stream describes it.
public struct BackupArchiveOriginal: Equatable, Sendable {
    public let id: UUID
    public let byteCount: Int
    public let sha256: Data
    public let contentType: String

    public init(id: UUID, byteCount: Int, sha256: Data, contentType: String) {
        self.id = id
        self.byteCount = byteCount
        self.sha256 = sha256
        self.contentType = contentType
    }
}

/// Where one original is written in the archive.
public struct BackupArchiveFile: Equatable, Sendable {
    public let original: BackupArchiveOriginal
    public let path: String
}

/// The parts of the library that decide where originals go, read from the same logical
/// stream the archive carries so that names and data come from one commit.
package struct BackupArchiveCatalog: Sendable {
    package struct Report: Sendable {
        let id: UUID
        let memberID: UUID
        let confirmed: Bool
        let date: Date?
        let sources: [(attachmentID: UUID, stem: String)]
        package init(record: HealthRecord) {
            id = record.id
            memberID = record.memberID
            confirmed = record.importState == .confirmed
            date = record.timelineDate
            sources = record.sources.elements.map { ($0.attachmentID, BackupArchiveNaming.sourceStem($0.displayName)) }
        }
    }

    package struct Draft: Sendable {
        let id: UUID
        let sources: [(attachmentID: UUID, stem: String)]
        package init(draft: ImportDraft) {
            id = draft.id
            sources = draft.sources.elements.map { ($0.attachmentID, BackupArchiveNaming.sourceStem($0.displayName)) }
        }
    }

    package struct Study: Sendable {
        let id: UUID
        let memberID: UUID?
        let date: Date?
        let attachmentIDs: [UUID]
        package init(id: UUID, state: DICOMStudyState, memberID: UUID?, date: Date?, attachmentIDs: [UUID]) {
            self.id = id
            // Only a confirmed study has a person and a date to file it under.
            if state == .confirmed, let memberID, let date {
                self.memberID = memberID
                self.date = date
            } else {
                self.memberID = nil
                self.date = nil
            }
            self.attachmentIDs = attachmentIDs
        }
    }

    package struct InboxItem: Sendable {
        let attachmentID: UUID
        let sequence: UInt64
        let stem: String
        package init(item: LANInboxItem) {
            attachmentID = item.blobID
            sequence = item.sequence
            stem = BackupArchiveNaming.sourceStem(item.displayName.rawValue)
        }
    }

    package var members: [(id: UUID, stem: String)] = []
    package var originals: [BackupArchiveOriginal] = []
    package var reports: [Report] = []
    package var drafts: [Draft] = []
    package var studies: [Study] = []
    package var inbox: [InboxItem] = []

    package init() {}

    package mutating func add(member: FamilyMember) {
        let name = member.disambiguationLabel.map { "\(member.displayName) - \($0)" } ?? member.displayName
        members.append((member.id, BackupArchiveNaming.component(name, fallback: "Member")))
    }
}

/// Assigns every original of one backup exactly one readable path under `files/`.
///
/// Confirmed reports and confirmed DICOM studies are filed by person and date, using the
/// names the earlier original-file export used. Everything else that still holds an original
/// (drafts, studies awaiting review, phone uploads) goes into folders after the people, and an
/// original nothing names is kept under the "other" folder rather than left out. An original
/// several sources share is written once, at the first place it comes up.
public struct BackupArchivePlan: Equatable, Sendable {
    public let files: [BackupArchiveFile]

    public var totalByteCount: UInt64 { files.reduce(0) { $0 + UInt64($1.original.byteCount) } }

    package static func make(
        catalog: BackupArchiveCatalog,
        preferredExtensions: [UUID: String],
        labels: BackupArchiveLabels
    ) throws -> Self {
        typealias Naming = BackupArchiveNaming
        guard catalog.originals.count <= BackupArchiveLimits.maximumOriginalCount else {
            throw BackupArchiveError.resourceLimit
        }
        let originals = try Dictionary(catalog.originals.map { ($0.id, $0) }) { _, _ in
            throw BackupArchiveError.invalidArchive
        }
        let memberIDs = Set(catalog.members.map(\.id))
        let referenced = catalog.reports.flatMap { $0.sources.map(\.attachmentID) }
            + catalog.drafts.flatMap { $0.sources.map(\.attachmentID) }
            + catalog.studies.flatMap(\.attachmentIDs) + catalog.inbox.map(\.attachmentID)
        guard memberIDs.count == catalog.members.count,
              referenced.allSatisfy({ originals[$0] != nil }),
              catalog.reports.allSatisfy({ memberIDs.contains($0.memberID) }),
              catalog.studies.allSatisfy({ $0.memberID.map(memberIDs.contains) ?? true }) else {
            throw BackupArchiveError.invalidArchive
        }

        var placed: Set<UUID> = []
        var files: [BackupArchiveFile] = []
        var topLevel = Naming.Allocator()
        func place(_ id: UUID, _ components: [String]) throws {
            guard let original = originals[id], placed.insert(id).inserted else { throw BackupArchiveError.invalidArchive }
            files.append(.init(original: original, path: try Naming.path([BackupArchiveIndex.originalsDirectory] + components)))
        }
        func fileExtension(_ id: UUID) throws -> String {
            guard let value = preferredExtensions[id] else { throw BackupArchiveError.invalidArchive }
            return try Naming.validatedExtension(value)
        }
        func placeSources(_ sources: [(attachmentID: UUID, stem: String)], in folder: String,
                          names: inout Naming.Allocator, title: (Int) -> String) throws {
            for (offset, source) in sources.enumerated() where !placed.contains(source.attachmentID) {
                let stem = Naming.component("\(title(offset + 1)) - \(source.stem)", fallback: "Report")
                try place(source.attachmentID, [folder, names.allocate(stem: stem, extension: try fileExtension(source.attachmentID))])
            }
        }
        func placeStudy(_ study: BackupArchiveCatalog.Study, under folder: [String]) throws {
            var names = Naming.Allocator()
            var ordinal = 0
            for id in study.attachmentIDs.sorted(by: Naming.precedes) where !placed.contains(id) {
                ordinal += 1
                try place(id, folder + [names.allocate(stem: String(format: "%04d", ordinal), extension: try fileExtension(id))])
            }
        }

        // People: confirmed reports and confirmed studies, by date.
        enum Item {
            case report(BackupArchiveCatalog.Report)
            case study(BackupArchiveCatalog.Study)
            var date: Date? { switch self { case .report(let value): value.date; case .study(let value): value.date } }
            var kindOrder: Int { if case .report = self { 0 } else { 1 } }
            var id: UUID { switch self { case .report(let value): value.id; case .study(let value): value.id } }
        }
        var itemsByMember: [UUID: [Item]] = [:]
        for report in catalog.reports where report.confirmed {
            itemsByMember[report.memberID, default: []].append(.report(report))
        }
        for study in catalog.studies {
            if let memberID = study.memberID { itemsByMember[memberID, default: []].append(.study(study)) }
        }
        let people = catalog.members
            .filter { itemsByMember[$0.id]?.isEmpty == false }
            .sorted { lhs, rhs in
                let left = Naming.collisionKey(lhs.stem), right = Naming.collisionKey(rhs.stem)
                return left != right ? left < right : Naming.precedes(lhs.id, rhs.id)
            }
        for person in people {
            let directory = topLevel.allocate(stem: person.stem)
            var names = Naming.Allocator()
            let items = itemsByMember[person.id, default: []].sorted { lhs, rhs in
                switch (lhs.date, rhs.date) {
                case let (left?, right?) where left != right: return left < right
                case (nil, _?): return false
                case (_?, nil): return true
                default: break
                }
                if lhs.kindOrder != rhs.kindOrder { return lhs.kindOrder < rhs.kindOrder }
                return Naming.precedes(lhs.id, rhs.id)
            }
            var reportOrdinal = 0, studyOrdinal = 0
            for item in items {
                let date = try item.date.map(Naming.dateString) ?? Naming.component(labels.undated, fallback: "Undated")
                switch item {
                case .report(let report):
                    reportOrdinal += 1
                    let ordinal = reportOrdinal
                    try placeSources(report.sources, in: directory, names: &names) {
                        String(format: "%@ - Report %04d - Source %04d", date, ordinal, $0)
                    }
                case .study(let study):
                    guard study.attachmentIDs.contains(where: { !placed.contains($0) }) else { continue }
                    studyOrdinal += 1
                    let folder = names.allocate(stem: Naming.component(String(format: "%@ - DICOM %04d", date, studyOrdinal), fallback: "DICOM"))
                    try placeStudy(study, under: [directory, folder])
                }
            }
        }

        // Drafts, reports not yet confirmed and studies awaiting review.
        let pendingReports = catalog.reports.filter { !$0.confirmed }.sorted { Naming.precedes($0.id, $1.id) }
        let pendingDrafts = catalog.drafts.sorted { Naming.precedes($0.id, $1.id) }
        let pendingStudies = catalog.studies.filter { $0.memberID == nil }.sorted { Naming.precedes($0.id, $1.id) }
        let pendingIDs = pendingReports.flatMap { $0.sources.map(\.attachmentID) }
            + pendingDrafts.flatMap { $0.sources.map(\.attachmentID) } + pendingStudies.flatMap(\.attachmentIDs)
        if pendingIDs.contains(where: { !placed.contains($0) }) {
            let folder = topLevel.allocate(stem: Naming.component("_" + labels.pendingFolder, fallback: "_Pending"))
            var names = Naming.Allocator()
            for (offset, report) in pendingReports.enumerated() {
                try placeSources(report.sources, in: folder, names: &names) {
                    String(format: "Report %04d - Source %04d", offset + 1, $0)
                }
            }
            for (offset, draft) in pendingDrafts.enumerated() {
                try placeSources(draft.sources, in: folder, names: &names) {
                    String(format: "Draft %04d - Source %04d", offset + 1, $0)
                }
            }
            var studyOrdinal = 0
            for study in pendingStudies where study.attachmentIDs.contains(where: { !placed.contains($0) }) {
                studyOrdinal += 1
                try placeStudy(study, under: [folder, names.allocate(stem: String(format: "DICOM %04d", studyOrdinal))])
            }
        }

        // Phone uploads, in the order they arrived.
        let inbox = catalog.inbox.sorted { $0.sequence < $1.sequence }.filter { !placed.contains($0.attachmentID) }
        if !inbox.isEmpty {
            let folder = topLevel.allocate(stem: Naming.component("_" + labels.phoneFolder, fallback: "_Phone"))
            var names = Naming.Allocator()
            for (offset, item) in inbox.enumerated() where !placed.contains(item.attachmentID) {
                let stem = Naming.component(String(format: "%04d - %@", offset + 1, item.stem), fallback: "Upload")
                try place(item.attachmentID, [folder, names.allocate(stem: stem, extension: try fileExtension(item.attachmentID))])
            }
        }

        // Anything left is still part of the library and goes into the backup.
        let rest = catalog.originals.map(\.id).filter { !placed.contains($0) }.sorted(by: Naming.precedes)
        if !rest.isEmpty {
            let folder = topLevel.allocate(stem: Naming.component("_" + labels.otherFolder, fallback: "_Other"))
            var names = Naming.Allocator()
            for (offset, id) in rest.enumerated() {
                try place(id, [folder, names.allocate(stem: String(format: "%04d", offset + 1), extension: try fileExtension(id))])
            }
        }
        return Self(files: files)
    }
}

/// File and folder names that open on macOS, Windows and common unzip tools.
enum BackupArchiveNaming {
    static let maximumComponentByteCount = 120
    static let maximumPathByteCount = 512

    static func sourceStem(_ displayName: String?) -> String {
        guard let displayName else { return "Report" }
        // The type comes from the stored content type; a display-name suffix must not spoof it.
        let stem = (displayName.precomposedStringWithCanonicalMapping as NSString).deletingPathExtension
        return component(stem, fallback: "Report")
    }

    static func component(_ rawValue: String, fallback: String) -> String {
        let invalidPunctuation = CharacterSet(charactersIn: "<>:\"/\\|?*")
        var scalars = String.UnicodeScalarView()
        for scalar in rawValue.precomposedStringWithCanonicalMapping.unicodeScalars {
            let replace = scalar.value == 0 || CharacterSet.controlCharacters.contains(scalar)
                || invalidPunctuation.contains(scalar)
            scalars.append(replace ? "_" : scalar)
        }
        var edges = CharacterSet.whitespacesAndNewlines
        edges.insert(charactersIn: ".")
        var value = String(scalars).trimmingCharacters(in: edges)
        if value.isEmpty { value = fallback }
        if isWindowsReservedName(value) { value = "_" + value }
        return truncated(value, maximumByteCount: maximumComponentByteCount)
    }

    static func isWindowsReservedName(_ value: String) -> Bool {
        let stem = (value.split(separator: ".", maxSplits: 1).first.map(String.init) ?? value).uppercased()
        if ["CON", "PRN", "AUX", "NUL"].contains(stem) { return true }
        if stem.count == 4, stem.hasPrefix("COM") || stem.hasPrefix("LPT"), let digit = stem.last {
            return ("1"..."9").contains(String(digit))
        }
        return false
    }

    static func validatedExtension(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !value.isEmpty, value.utf8.count <= 16, value.utf8.allSatisfy({ byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }) else { throw BackupArchiveError.invalidArchive }
        return value
    }

    static func path(_ components: [String]) throws -> String {
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
                && $0.utf8.count <= maximumComponentByteCount }) else { throw BackupArchiveError.invalidArchive }
        let value = components.joined(separator: "/")
        guard value.utf8.count <= maximumPathByteCount, BackupArchiveIndex.isSafePath(value) else {
            throw BackupArchiveError.invalidArchive
        }
        return value
    }

    static func dateString(_ date: Date) throws -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw BackupArchiveError.invalidArchive }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, (1...9_999).contains(year), let month = parts.month, let day = parts.day else {
            throw BackupArchiveError.invalidArchive
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func precedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    static func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func truncated(_ value: String, maximumByteCount: Int) -> String {
        guard value.utf8.count > maximumByteCount else { return value }
        var result = ""
        for character in value {
            guard (result + String(character)).utf8.count <= maximumByteCount else { break }
            result.append(character)
        }
        return result
    }

    /// Hands out names that differ even on a case-insensitive file system.
    struct Allocator {
        private var used: Set<String> = []

        mutating func allocate(stem: String, extension fileExtension: String? = nil) -> String {
            var ordinal = 1
            while true {
                let suffix = ordinal == 1 ? "" : " (\(ordinal))"
                let extensionSuffix = fileExtension.map { ".\($0)" } ?? ""
                let budget = maximumComponentByteCount - suffix.utf8.count - extensionSuffix.utf8.count
                let candidate = truncated(stem, maximumByteCount: max(1, budget)) + suffix + extensionSuffix
                if used.insert(collisionKey(candidate)).inserted { return candidate }
                ordinal += 1
            }
        }
    }
}
