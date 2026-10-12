import Foundation
import GRDB
import KinlogueCore

/// Typed rows are shared by live queries and strict per-study logical snapshots.
enum SQLiteDICOMRows {
    static let studyColumns = ["id", "state", "member_id", "effective_date", "operation_id", "fingerprint", "fingerprint_version", "study_uid_digest", "uid_domain", "uid_version", "content_revision", "index_version", "ordering_policy", "logical_byte_count", "object_count", "instance_count", "series_count", "objects_hash", "series_hash"]
    static let studyProjection = SQLiteHotProjection.sql(studyColumns, bounds: ["uid_domain": DICOMStudyIndex.UIDDigest.domain.utf8.count])
    static let objectColumns = ["study_id", "original_id", "retained_kind", "byte_count", "sha256"]
    static let seriesColumns = ["study_id", "series_id", "series_uid_digest", "ordinal", "ordering_provenance", "revision", "instance_count", "rows", "columns", "instances_hash"]
    static let instanceColumns = ["study_id", "series_id", "instance_id", "original_id", "sop_uid_digest", "ordinal", "sop_class", "transfer_syntax", "modality", "rows", "columns", "samples_per_pixel", "bits_allocated", "bits_stored", "high_bit", "pixel_representation", "photometric_interpretation", "position_x", "position_y", "position_z", "orientation_row_x", "orientation_row_y", "orientation_row_z", "orientation_column_x", "orientation_column_y", "orientation_column_z", "rescale_slope", "rescale_intercept", "window_center", "window_width"]

    static func hash(_ table: String, _ values: [DatabaseValue]) throws -> Data {
        // UID roles are implicit in the table, but remain part of the hash domain.
        do { return try SQLiteReportRows.hash(table: table + ":uid-v1:" + DICOMStudyIndex.UIDDigest.domain, values: values) }
        catch SQLiteLibraryError.damaged {
            // This pure value codec rejects nonfinite numbers, not database damage.
            throw DICOMSliceServiceError.integrityFailure
        }
    }
    static func verify(_ row: Row, _ table: String, _ columns: [String]) throws {
        do { try SQLiteRows.validateText(row, table: table) }
        catch { throw DICOMSliceServiceError.integrityFailure }
        guard try hash(table, columns.map { row[$0] }) == row["content_hash"] as Data else { throw DICOMSliceServiceError.integrityFailure }
    }
    @discardableResult
    static func insert(_ db: Database, _ table: String, _ columns: [String], _ values: [DatabaseValue]) throws -> Data {
        let digest = try hash(table, values)
        try db.execute(sql: "INSERT INTO \(table)(\((columns + ["content_hash"]).joined(separator: ","))) VALUES (\(Array(repeating: "?", count: columns.count + 1).joined(separator: ",")))", arguments: StatementArguments(values + [digest.databaseValue]))
        return digest
    }
    static func collectionHash(_ domain: String, _ hashes: [Data]) -> Data {
        SQLiteContentHash.hash(domain: domain + ":1", values: [.integer(Int64(hashes.count))] + hashes.map(SQLiteContentHash.Value.blob))
    }
    static func validateSeriesOrdinals(_ ordinals: [Int]) throws {
        guard ordinals.enumerated().allSatisfy({ $0.element == $0.offset + 1 }) else { throw DICOMSliceServiceError.integrityFailure }
    }
    static func studyRow(_ id: UUID, _ db: Database) throws -> Row {
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT \(SQLiteDICOMRows.studyProjection) FROM dicom_studies WHERE id = ?", arguments: [id.sqliteBytes]) else { throw DICOMSliceServiceError.studyUnavailable }
        _ = try summary(row)
        return row
    }
    static func summary(_ row: Row) throws -> LibraryDICOMStudySummary {
        guard !(row["oversized"] as Bool) else { throw DICOMSliceServiceError.integrityFailure }
        try verify(row, "dicom_studies", studyColumns)
        guard let state = DICOMStudyState(rawValue: row["state"]),
              row["fingerprint_version"] as Int == DICOMStudyFingerprint.currentVersion,
              row["uid_domain"] as String == DICOMStudyIndex.UIDDigest.domain,
              row["uid_version"] as Int == DICOMStudyIndex.UIDDigest.currentVersion,
              row["index_version"] as Int == DICOMStudyIndex.currentVersion,
              row["ordering_policy"] as Int == DICOMStudyIndex.currentOrderingPolicyVersion else { throw DICOMSliceServiceError.integrityFailure }
        let date: Double? = row["effective_date"]
        let member = try SQLiteReportRows.optionalUUID(row, "member_id")
        let revision: Int64 = row["content_revision"], count: Int = row["object_count"], instances: Int = row["instance_count"], series: Int = row["series_count"]
        guard revision >= 0, (1...2_000).contains(count), (0...count).contains(instances), (0...4_096).contains(series),
              (state == .confirmed ? (member != nil && date?.isFinite == true) : (member == nil && date == nil)) else { throw DICOMSliceServiceError.integrityFailure }
        return LibraryDICOMStudySummary(id: try SQLiteReportRows.uuid(row, "id"), state: state, confirmedMemberID: member,
            effectiveDate: date.map(Date.init(timeIntervalSince1970:)), contentRevision: UInt64(revision),
            retainedObjectCount: count, viewableInstanceCount: instances, seriesCount: series)
    }
    static func seriesSummary(_ row: Row) throws -> LibraryDICOMSeriesSummary {
        try verify(row, "dicom_series", seriesColumns)
        guard let provenance = DICOMStudyIndex.OrderingProvenance(rawValue: row["ordering_provenance"]) else { throw DICOMSliceServiceError.integrityFailure }
        return LibraryDICOMSeriesSummary(id: try SQLiteReportRows.uuid(row, "series_id"), ordinal: row["ordinal"],
            sliceCount: row["instance_count"], rows: row["rows"], columns: row["columns"], orderingProvenance: provenance)
    }
    static func object(_ row: Row, _ db: Database) throws -> (DICOMStudyIndex.RetainedObject, SQLiteOriginal) {
        try verify(row, "dicom_objects", objectColumns)
        let id = try SQLiteReportRows.uuid(row, "original_id")
        let original = try SQLiteOriginal.read(id, from: db)
        guard original.lifecycle == "live", original.byteCount == row["byte_count"] as Int,
              original.sha256 == row["sha256"] as Data,
              let kind = DICOMStudyIndex.RetainedObjectKind(rawValue: row["retained_kind"]) else { throw DICOMSliceServiceError.integrityFailure }
        return (DICOMStudyIndex.RetainedObject(attachmentID: id, kind: kind), original)
    }
    static func instance(_ row: Row) throws -> DICOMStudyIndex.Instance {
        try verify(row, "dicom_instances", instanceColumns)
        func vector(_ prefix: String) throws -> DICOMStudyIndex.Vector3? {
            let x: Double? = row[prefix + "_x"], y: Double? = row[prefix + "_y"], z: Double? = row[prefix + "_z"]
            guard let x, let y, let z else {
                guard x == nil, y == nil, z == nil else { throw DICOMSliceServiceError.integrityFailure }
                return nil
            }
            return try .init(x: x, y: y, z: z)
        }
        guard let representation = DICOMStudyIndex.PixelRepresentation(rawValue: row["pixel_representation"]),
              let interpretation = DICOMStudyIndex.PhotometricInterpretation(rawValue: row["photometric_interpretation"]),
              row["sop_class"] as String == "mrImageStorage", row["transfer_syntax"] as String == "explicitVRLittleEndian",
              row["modality"] as String == "mr" else { throw DICOMSliceServiceError.integrityFailure }
        let attributes = try DICOMStudyIndex.ImageAttributes(rows: row["rows"], columns: row["columns"], samplesPerPixel: row["samples_per_pixel"],
            bitsAllocated: row["bits_allocated"], bitsStored: row["bits_stored"], highBit: row["high_bit"],
            pixelRepresentation: representation, photometricInterpretation: interpretation,
            imagePositionPatient: vector("position"), imageOrientationPatientRow: vector("orientation_row"),
            imageOrientationPatientColumn: vector("orientation_column"), rescaleSlope: row["rescale_slope"],
            rescaleIntercept: row["rescale_intercept"], windowCenter: row["window_center"], windowWidth: row["window_width"])
        return try DICOMStudyIndex.Instance(id: SQLiteReportRows.uuid(row, "instance_id"), attachmentID: SQLiteReportRows.uuid(row, "original_id"),
            seriesID: SQLiteReportRows.uuid(row, "series_id"), sopInstanceUIDDigest: .init(scope: .sopInstance, digest: row["sop_uid_digest"]),
            canonicalOrder: row["ordinal"], sopClass: .mrImageStorage, transferSyntax: .explicitVRLittleEndian, modality: .mr, attributes: attributes)
    }

    static func targetSeries(_ studyID: UUID, _ seriesID: UUID, _ db: Database) throws -> (DICOMStudyIndex, [SQLiteOriginal]) {
        let study = try studyRow(studyID, db)
        guard let row = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM dicom_series WHERE study_id = ? AND series_id = ?", arguments: [studyID.sqliteBytes, seriesID.sqliteBytes]) else { throw DICOMSliceServiceError.seriesUnavailable }
        let summary = try seriesSummary(row)
        guard summary.ordinal > 0, summary.ordinal <= study["series_count"] as Int else { throw DICOMSliceServiceError.integrityFailure }
        let rows = try SQLiteRows.fetchAll(db, sql: "SELECT * FROM dicom_instances WHERE study_id = ? AND series_id = ? ORDER BY ordinal LIMIT 2001", arguments: [studyID.sqliteBytes, seriesID.sqliteBytes])
        guard rows.count == summary.sliceCount, rows.count <= 2_000,
              collectionHash("dicom-series-instances", rows.map { $0["content_hash"] }) == row["instances_hash"] as Data else { throw DICOMSliceServiceError.integrityFailure }
        let instances = try rows.map(instance)
        var retained: [DICOMStudyIndex.RetainedObject] = [], originals: [SQLiteOriginal] = []
        for instance in instances {
            guard let objectRow = try SQLiteRows.fetchOne(db, sql: "SELECT * FROM dicom_objects WHERE study_id = ? AND original_id = ?", arguments: [studyID.sqliteBytes, instance.attachmentID.sqliteBytes]) else { throw DICOMSliceServiceError.integrityFailure }
            let value = try object(objectRow, db)
            retained.append(value.0); originals.append(value.1)
        }
        let series = try DICOMStudyIndex.Series(id: seriesID, ordinal: summary.ordinal, instanceIDs: instances.map(\.id),
            seriesUIDDigest: .init(scope: .series, digest: row["series_uid_digest"]), orderingProvenance: summary.orderingProvenance)
        let index = try DICOMStudyIndex(studyID: studyID, studyUIDDigest: .init(scope: .study, digest: study["study_uid_digest"]),
            retainedObjects: retained, instances: instances, series: [series])
        guard instances.first?.attributes.rows == summary.rows, instances.first?.attributes.columns == summary.columns else { throw DICOMSliceServiceError.integrityFailure }
        try DICOMSeriesGeometry.validatePersistedGeometryOrder(index)
        return (index, originals)
    }

    static func strictStudy(_ id: UUID, _ db: Database) throws -> (DICOMStudyHeader, DICOMStudyIndex) {
        let row = try studyRow(id, db), summary = try summary(row)
        let objectRows = try SQLiteRows.fetchAll(db, sql: "SELECT * FROM dicom_objects WHERE study_id = ? ORDER BY original_id LIMIT 2001", arguments: [id.sqliteBytes])
        let seriesRows = try SQLiteRows.fetchAll(db, sql: "SELECT * FROM dicom_series WHERE study_id = ? ORDER BY ordinal LIMIT 4097", arguments: [id.sqliteBytes])
        guard objectRows.count == summary.retainedObjectCount, seriesRows.count == summary.seriesCount,
              collectionHash("dicom-study-objects", objectRows.map { $0["content_hash"] }) == row["objects_hash"] as Data,
              collectionHash("dicom-study-series", seriesRows.map { $0["content_hash"] }) == row["series_hash"] as Data else { throw DICOMSliceServiceError.integrityFailure }
        try validateSeriesOrdinals(seriesRows.map { $0["ordinal"] })
        let objects = try objectRows.map { try object($0, db) }
        let fingerprint = try DICOMStudyFingerprint(objects: objects.map { try .init(sha256Digest: $0.1.sha256, byteCount: $0.1.byteCount) })
        guard ContentDigest.sha256(fingerprint.canonicalIdentityBytes) == row["fingerprint"] as Data else { throw DICOMSliceServiceError.integrityFailure }
        var instances: [DICOMStudyIndex.Instance] = [], series: [DICOMStudyIndex.Series] = []
        for seriesRow in seriesRows {
            let target = try targetSeries(id, SQLiteReportRows.uuid(seriesRow, "series_id"), db).0
            instances += target.instances; series += target.series
        }
        let index = try DICOMStudyIndex(studyID: id, studyUIDDigest: .init(scope: .study, digest: row["study_uid_digest"]),
            retainedObjects: objects.map(\.0), instances: instances, series: series)
        guard instances.count == summary.viewableInstanceCount,
              try CanonicalVaultJSON.encode(index).count == row["logical_byte_count"] as Int else { throw DICOMSliceServiceError.integrityFailure }
        let header = try DICOMStudyHeader(id: id, state: summary.state, fingerprint: fingerprint,
            attachmentIDs: objects.map { $0.1.id }, confirmedMemberID: summary.confirmedMemberID,
            effectiveDate: summary.effectiveDate, contentRevision: summary.contentRevision)
        return (header, index)
    }

    static func insertStudy(_ header: DICOMStudyHeader, index: DICOMStudyIndex, operationID: UUID, _ db: Database) throws {
        try index.validate(studyID: header.id, attachmentIDs: Set(header.attachmentIDs))
        try DICOMSeriesGeometry.validatePersistedGeometryOrder(index)
        let byteCount = try CanonicalVaultJSON.encode(index).count
        guard byteCount <= 16 * 1_024 * 1_024, header.contentRevision <= UInt64(Int64.max) else { throw DICOMImportError.resourceLimit }
        try SQLiteReportRows.requireMember(header.confirmedMemberID, in: db)
        var objectHashes: [Data] = []
        for object in index.retainedObjects.sorted(by: { $0.attachmentID.uuidString < $1.attachmentID.uuidString }) {
            let original = try SQLiteOriginal.read(object.attachmentID, from: db)
            guard original.lifecycle == "live", (1...104_857_600).contains(original.byteCount) else { throw DICOMImportError.integrityFailure }
            objectHashes.append(try hash("dicom_objects", objectValues(header.id, object, original)))
        }
        let originals = try header.attachmentIDs.map { try SQLiteOriginal.read($0, from: db) }
        guard try DICOMStudyFingerprint(objects: originals.map { try .init(sha256Digest: $0.sha256, byteCount: $0.byteCount) }) == header.fingerprint else { throw DICOMImportError.integrityFailure }
        let instancesByID = Dictionary(uniqueKeysWithValues: index.instances.map { ($0.id, $0) })
        let orderedSeries = index.series.sorted { $0.ordinal < $1.ordinal }
        try validateSeriesOrdinals(orderedSeries.map(\.ordinal))
        let seriesValues = try orderedSeries.map { series -> [DatabaseValue] in
            let instances = try series.instanceIDs.map { id -> DICOMStudyIndex.Instance in
                guard let value = instancesByID[id] else { throw DICOMImportError.integrityFailure }; return value
            }
            guard let first = instances.first else { throw DICOMImportError.integrityFailure }
            let hashes = try instances.map { try hash("dicom_instances", instanceValues(header.id, $0)) }
            return [header.id.sqliteBytes.databaseValue, series.id.sqliteBytes.databaseValue, series.seriesUIDDigest.digest.databaseValue,
                series.ordinal.databaseValue, series.orderingProvenance.rawValue.databaseValue, 0.databaseValue,
                instances.count.databaseValue, first.attributes.rows.databaseValue, first.attributes.columns.databaseValue,
                collectionHash("dicom-series-instances", hashes).databaseValue]
        }
        let seriesHashes = try seriesValues.map { try hash("dicom_series", $0) }
        try insert(db, "dicom_studies", studyColumns, [header.id.sqliteBytes.databaseValue, header.state.rawValue.databaseValue,
            header.confirmedMemberID?.sqliteBytes.databaseValue ?? .null, header.effectiveDate?.timeIntervalSince1970.databaseValue ?? .null,
            operationID.sqliteBytes.databaseValue, ContentDigest.sha256(header.fingerprint.canonicalIdentityBytes).databaseValue,
            header.fingerprint.version.databaseValue, index.studyUIDDigest.digest.databaseValue, index.studyUIDDigest.domain.databaseValue,
            index.studyUIDDigest.version.databaseValue, Int64(header.contentRevision).databaseValue, index.version.databaseValue,
            index.orderingPolicyVersion.databaseValue, byteCount.databaseValue, index.retainedObjects.count.databaseValue,
            index.instances.count.databaseValue, index.series.count.databaseValue, collectionHash("dicom-study-objects", objectHashes).databaseValue,
            collectionHash("dicom-study-series", seriesHashes).databaseValue])
        for object in index.retainedObjects { try insert(db, "dicom_objects", objectColumns, objectValues(header.id, object, SQLiteOriginal.read(object.attachmentID, from: db))) }
        for values in seriesValues { try insert(db, "dicom_series", seriesColumns, values) }
        for instance in index.instances { try insert(db, "dicom_instances", instanceColumns, instanceValues(header.id, instance)) }
    }
    static func objectValues(_ studyID: UUID, _ object: DICOMStudyIndex.RetainedObject, _ original: SQLiteOriginal) -> [DatabaseValue] {
        [studyID.sqliteBytes.databaseValue, original.id.sqliteBytes.databaseValue, object.kind.rawValue.databaseValue,
         original.byteCount.databaseValue, original.sha256.databaseValue]
    }
    static func instanceValues(_ studyID: UUID, _ instance: DICOMStudyIndex.Instance) -> [DatabaseValue] {
        let a = instance.attributes
        return [studyID.sqliteBytes.databaseValue, instance.seriesID.sqliteBytes.databaseValue, instance.id.sqliteBytes.databaseValue,
            instance.attachmentID.sqliteBytes.databaseValue, instance.sopInstanceUIDDigest.digest.databaseValue, instance.canonicalOrder.databaseValue,
            instance.sopClass.rawValue.databaseValue, instance.transferSyntax.rawValue.databaseValue, instance.modality.rawValue.databaseValue,
            a.rows.databaseValue, a.columns.databaseValue, a.samplesPerPixel.databaseValue, a.bitsAllocated.databaseValue,
            a.bitsStored.databaseValue, a.highBit.databaseValue, a.pixelRepresentation.rawValue.databaseValue, a.photometricInterpretation.rawValue.databaseValue,
            a.imagePositionPatient?.x.databaseValue ?? .null, a.imagePositionPatient?.y.databaseValue ?? .null, a.imagePositionPatient?.z.databaseValue ?? .null,
            a.imageOrientationPatientRow?.x.databaseValue ?? .null, a.imageOrientationPatientRow?.y.databaseValue ?? .null, a.imageOrientationPatientRow?.z.databaseValue ?? .null,
            a.imageOrientationPatientColumn?.x.databaseValue ?? .null, a.imageOrientationPatientColumn?.y.databaseValue ?? .null, a.imageOrientationPatientColumn?.z.databaseValue ?? .null,
            a.rescaleSlope.databaseValue, a.rescaleIntercept.databaseValue, a.windowCenter.databaseValue, a.windowWidth.databaseValue]
    }
}
