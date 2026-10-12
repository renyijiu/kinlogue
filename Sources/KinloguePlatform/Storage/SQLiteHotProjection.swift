import Foundation

/// Small verified UI columns shared by each domain; full entity readers remain strict.
enum SQLiteHotProjection {
    // SQL checks byte lengths before copying untrusted text into the hot projection.
    // Oversized rows are explicitly marked damaged; the placeholder is never trusted as content.
    static func sql(_ columns: [String], bounds: [String: Int], qualifier: String = "") -> String {
        let prefix = qualifier.isEmpty ? "" : qualifier + "."
        let fields = (columns + ["content_hash"]).map { column in
            guard let limit = bounds[column] else { return prefix + column }
            return "CASE WHEN octet_length(\(prefix)\(column)) > \(limit) THEN '' ELSE \(prefix)\(column) END AS \(column)"
        }
        let oversized = bounds.sorted { $0.key < $1.key }.map {
            "coalesce(octet_length(\(prefix)\($0.key)), 0) > \($0.value)"
        }.joined(separator: " OR ")
        return (fields + ["(\(oversized)) AS oversized"]).joined(separator: ",")
    }

}
