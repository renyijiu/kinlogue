import Foundation
import GRDB

/// GRDB 7.11.1's default String binding and Row copies stop at NUL.
enum SQLiteRows {
    static func placeholders(_ values: [DatabaseValue]) -> String {
        values.map { if case .string = $0.storage { "CAST(? AS TEXT)" } else { "?" } }.joined(separator: ",")
    }

    static func arguments(_ values: [DatabaseValue]) -> StatementArguments {
        StatementArguments(values.map { value in
            if case let .string(text) = value.storage { return Data(text.utf8).databaseValue }
            return value
        })
    }

    static func fetchOne(_ db: Database, sql: String, arguments: StatementArguments = StatementArguments()) throws -> Row? {
        let cursor = try fetchCursor(db, sql: sql, arguments: arguments)
        return try cursor.next()
    }

    static func fetchAll(_ db: Database, sql: String, arguments: StatementArguments = StatementArguments()) throws -> [Row] {
        try Array(fetchCursor(db, sql: sql, arguments: arguments))
    }

    static func fetchCursor(_ db: Database, sql: String, arguments: StatementArguments = StatementArguments()) throws -> AnyCursor<Row> {
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        return AnyCursor { try cursor.next().map(copy) }
    }

    private static func copy(_ row: Row) throws -> Row {
        var values: [String: (any DatabaseValueConvertible)?] = [:]
        values.reserveCapacity(row.count)
        for (index, (column, value)) in row.enumerated() {
            if case .string = value.storage {
                values[column] = try row.withUnsafeData(atIndex: index) { bytes -> DatabaseValue in
                    guard let bytes else { return .null }
                    // Invalid UTF-8 stays binary so the entity codec can reject only this row.
                    return String(data: bytes, encoding: .utf8)?.databaseValue ?? bytes.databaseValue
                }
            } else { values[column] = value }
        }
        return Row(values)
    }

    private static let textColumns: Set<String> = [
        "display_name", "disambiguation", "summary_name", "summary_label", "content_type", "lifecycle",
        "kind", "date_kind", "title", "report_type", "organization", "conclusion", "state", "failure_code",
        "media_type", "outcome", "uid_domain", "retained_kind", "ordering_provenance", "sop_class",
        "transfer_syntax", "modality", "pixel_representation", "photometric_interpretation"
    ]

    static func validateText(_ row: Row, table: String) throws {
        for (column, value) in row where textColumns.contains(column) {
            if table == "inbox_archive_receipts" && column == "outcome" { continue }
            switch value.storage {
            case .null, .string: break
            default: throw SQLiteLibraryError.damaged
            }
        }
    }
}
