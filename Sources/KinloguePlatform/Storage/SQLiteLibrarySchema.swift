import Foundation
import GRDB
import KinlogueCore

/// Development format; no migration from a JSON vault or another SQLite schema.
enum SQLiteLibrarySchema {
    static let applicationID = 0x4B4C4753 // KLGS
    static let version = 1
    static let maximumPayloadBytes = LibraryStorageLimits.maximumEntityJSONBytes

    static let statements: [(name: String, sql: String)] = [
        ("library_state", """
        CREATE TABLE library_state (
            singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
            library_id BLOB NOT NULL CHECK(length(library_id) = 16),
            generation INTEGER NOT NULL CHECK(generation >= 0),
            commit_id BLOB NOT NULL CHECK(length(commit_id) = 16),
            schema_identity BLOB NOT NULL CHECK(length(schema_identity) = 32),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32)
        ) STRICT
        """),
        ("members", """
        CREATE TABLE members (
            id BLOB PRIMARY KEY NOT NULL CHECK(length(id) = 16),
            display_name TEXT NOT NULL,
            disambiguation TEXT,
            summary_name TEXT NOT NULL CHECK(length(CAST(summary_name AS BLOB)) <= 640),
            summary_label TEXT CHECK(summary_label IS NULL OR length(CAST(summary_label AS BLOB)) <= 640),
            summary_hash BLOB NOT NULL CHECK(length(summary_hash) = 32),
            archived INTEGER NOT NULL CHECK(archived IN (0,1)),
            revision INTEGER NOT NULL CHECK(revision >= 0),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32)
        ) STRICT
        """),
        ("originals", """
        CREATE TABLE originals (
            id BLOB PRIMARY KEY NOT NULL CHECK(length(id) = 16),
            byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
            sha256 BLOB NOT NULL CHECK(length(sha256) = 32),
            content_type TEXT NOT NULL,
            lifecycle TEXT NOT NULL CHECK(lifecycle IN ('staged','live','deleting')),
            operation_id BLOB NOT NULL CHECK(length(operation_id) = 16),
            file_device INTEGER,
            file_inode INTEGER,
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            CHECK((file_device IS NULL) = (file_inode IS NULL)),
            CHECK(file_device IS NULL OR (file_device > 0 AND file_inode > 0)),
            CHECK(lifecycle = 'staged' OR file_device IS NOT NULL)
        ) STRICT
        """),
        ("original_digest", "CREATE INDEX original_digest ON originals(sha256, byte_count)"),
        ("ocr_documents", """
        CREATE TABLE ocr_documents (
            id BLOB PRIMARY KEY NOT NULL CHECK(length(id) = 16),
            kind TEXT NOT NULL CHECK(kind IN ('report','lanSource')),
            document_version INTEGER NOT NULL CHECK(document_version = 1),
            extraction_version INTEGER CHECK(extraction_version IS NULL OR extraction_version > 0),
            revision INTEGER NOT NULL CHECK(revision >= 0),
            payload BLOB NOT NULL CHECK((kind = 'report' AND length(payload) <= 16777216) OR (kind = 'lanSource' AND length(payload) <= 33554432)),
            sha256 BLOB NOT NULL CHECK(length(sha256) = 32),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32)
        ) STRICT
        """),
        ("reports", """
        CREATE TABLE reports (
            record_id BLOB PRIMARY KEY NOT NULL CHECK(length(record_id) = 16),
            member_id BLOB NOT NULL REFERENCES members(id),
            document_id BLOB REFERENCES ocr_documents(id),
            revision INTEGER NOT NULL CHECK(revision >= 0),
            timeline_date REAL,
            date_kind TEXT CHECK(date_kind IS NULL OR date_kind IN ('report','examination','collection','admission','discharge','other')),
            title TEXT,
            report_type TEXT,
            organization TEXT,
            conclusion TEXT,
            search_hash BLOB NOT NULL CHECK(length(search_hash) = 32),
            detail_hash BLOB NOT NULL CHECK(length(detail_hash) = 32),
            sources_hash BLOB NOT NULL CHECK(length(sources_hash) = 32),
            source_count INTEGER NOT NULL CHECK(source_count > 0 AND source_count <= 20000),
            document_hash BLOB CHECK(document_hash IS NULL OR length(document_hash) = 32),
            fingerprint BLOB CHECK(fingerprint IS NULL OR length(fingerprint) = 32),
            fingerprint_version INTEGER CHECK(fingerprint_version IS NULL OR fingerprint_version > 0),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            CHECK((fingerprint IS NULL) = (fingerprint_version IS NULL))
        ) STRICT
        """),
        ("report_member_date", "CREATE INDEX report_member_date ON reports(member_id, timeline_date, record_id)"),
        ("report_date", "CREATE INDEX report_date ON reports(timeline_date, record_id)"),
        ("report_document", "CREATE UNIQUE INDEX report_document ON reports(document_id) WHERE document_id IS NOT NULL"),
        ("report_fingerprint", "CREATE INDEX report_fingerprint ON reports(fingerprint_version, fingerprint)"),
        ("report_search", """
        CREATE TABLE report_search (
            record_id BLOB PRIMARY KEY NOT NULL REFERENCES reports(record_id),
            fields BLOB NOT NULL CHECK(length(fields) <= 16777216),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32)
        ) STRICT
        """),
        ("report_details", """
        CREATE TABLE report_details (
            record_id BLOB PRIMARY KEY NOT NULL REFERENCES reports(record_id),
            payload BLOB NOT NULL CHECK(length(payload) <= 16777216),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32)
        ) STRICT
        """),
        ("import_drafts", """
        CREATE TABLE import_drafts (
            draft_id BLOB PRIMARY KEY NOT NULL CHECK(length(draft_id) = 16),
            member_id BLOB REFERENCES members(id),
            state TEXT NOT NULL CHECK(state IN ('staging','processing','needsReview','failed')),
            revision INTEGER NOT NULL CHECK(revision >= 0),
            attempt_id BLOB CHECK(attempt_id IS NULL OR length(attempt_id) = 16),
            failure_code TEXT,
            document_id BLOB REFERENCES ocr_documents(id),
            sources_hash BLOB NOT NULL CHECK(length(sources_hash) = 32),
            source_count INTEGER NOT NULL CHECK(source_count > 0 AND source_count <= 20000),
            document_hash BLOB CHECK(document_hash IS NULL OR length(document_hash) = 32),
            fingerprint BLOB CHECK(fingerprint IS NULL OR length(fingerprint) = 32),
            fingerprint_version INTEGER CHECK(fingerprint_version IS NULL OR fingerprint_version > 0),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            CHECK((fingerprint IS NULL) = (fingerprint_version IS NULL)),
            CHECK((state = 'staging' AND attempt_id IS NULL AND document_id IS NULL AND failure_code IS NULL)
                OR (state = 'processing' AND attempt_id IS NOT NULL AND document_id IS NULL AND failure_code IS NULL)
                OR (state = 'needsReview' AND attempt_id IS NULL AND document_id IS NOT NULL AND failure_code IS NULL)
                OR (state = 'failed' AND attempt_id IS NULL AND document_id IS NULL AND failure_code IS NOT NULL))
        ) STRICT
        """),
        ("draft_document", "CREATE UNIQUE INDEX draft_document ON import_drafts(document_id) WHERE document_id IS NOT NULL"),
        ("draft_member", "CREATE INDEX draft_member ON import_drafts(member_id)"),
        ("draft_fingerprint", "CREATE INDEX draft_fingerprint ON import_drafts(fingerprint_version, fingerprint) WHERE state = 'needsReview'"),
        ("report_sources", """
        CREATE TABLE report_sources (
            row_id BLOB PRIMARY KEY NOT NULL CHECK(length(row_id) = 16),
            source_id BLOB NOT NULL CHECK(length(source_id) = 16),
            report_id BLOB REFERENCES reports(record_id),
            draft_id BLOB REFERENCES import_drafts(draft_id),
            position INTEGER NOT NULL CHECK(position >= 0),
            original_id BLOB NOT NULL REFERENCES originals(id),
            page_count INTEGER NOT NULL CHECK(page_count > 0),
            display_name TEXT,
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            CHECK((report_id IS NULL) != (draft_id IS NULL)),
            UNIQUE(report_id, source_id), UNIQUE(draft_id, source_id),
            UNIQUE(report_id, position), UNIQUE(draft_id, position)
        ) STRICT
        """),
        ("source_original", "CREATE INDEX source_original ON report_sources(original_id)"),
        ("inbox_items", """
        CREATE TABLE inbox_items (
            id BLOB PRIMARY KEY NOT NULL CHECK(length(id) = 16),
            originating_session_id BLOB NOT NULL CHECK(length(originating_session_id) = 16),
            sequence INTEGER NOT NULL UNIQUE CHECK(sequence >= 0),
            revision INTEGER NOT NULL CHECK(revision >= 0),
            state TEXT NOT NULL CHECK(state IN ('stored','preprocessing','reviewable','unsupported','failed','integrityFailed')),
            original_id BLOB NOT NULL REFERENCES originals(id),
            content_sha256 BLOB NOT NULL CHECK(length(content_sha256) = 32),
            content_byte_count INTEGER NOT NULL CHECK(content_byte_count >= 0),
            derived_document_id BLOB REFERENCES ocr_documents(id),
            derived_sha256 BLOB CHECK(derived_sha256 IS NULL OR length(derived_sha256) = 32),
            derived_byte_count INTEGER CHECK(derived_byte_count IS NULL OR derived_byte_count >= 0),
            attempt_id BLOB CHECK(attempt_id IS NULL OR length(attempt_id) = 16),
            display_name TEXT NOT NULL,
            received_at REAL NOT NULL,
            failure_code TEXT,
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            CHECK(state != 'preprocessing' OR attempt_id IS NOT NULL),
            CHECK(state != 'reviewable' OR derived_document_id IS NOT NULL)
        ) STRICT
        """),
        ("inbox_content", "CREATE UNIQUE INDEX inbox_content ON inbox_items(content_sha256, content_byte_count)"),
        ("inbox_state_sequence", "CREATE INDEX inbox_state_sequence ON inbox_items(state, sequence)"),
        ("inbox_original", "CREATE UNIQUE INDEX inbox_original ON inbox_items(original_id)"),
        ("inbox_document", "CREATE UNIQUE INDEX inbox_document ON inbox_items(derived_document_id) WHERE derived_document_id IS NOT NULL"),
        ("inbox_content_terminals", """
        CREATE TABLE inbox_content_terminals (
            id BLOB NOT NULL UNIQUE CHECK(length(id) = 16),
            created_at REAL NOT NULL,
            session_id BLOB NOT NULL CHECK(length(session_id) = 16),
            sha256 BLOB NOT NULL CHECK(length(sha256) = 32),
            byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
            kind TEXT NOT NULL CHECK(kind IN ('archived','deleted')),
            revision INTEGER NOT NULL CHECK(revision >= 0),
            admission_generation_cutoff INTEGER CHECK(admission_generation_cutoff IS NULL OR admission_generation_cutoff >= 0),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            PRIMARY KEY(session_id, sha256, byte_count),
            CHECK(kind != 'deleted' OR admission_generation_cutoff IS NOT NULL)
        ) STRICT
        """),
        ("inbox_transport_receipts", """
        CREATE TABLE inbox_transport_receipts (
            id BLOB NOT NULL UNIQUE CHECK(length(id) = 16),
            display_name TEXT NOT NULL,
            declared_byte_count INTEGER NOT NULL CHECK(declared_byte_count >= 0),
            media_type TEXT,
            attempt_revision INTEGER NOT NULL CHECK(attempt_revision >= 0),
            completed_at REAL NOT NULL,
            content_sha256 BLOB CHECK(content_sha256 IS NULL OR length(content_sha256) = 32),
            content_byte_count INTEGER CHECK(content_byte_count IS NULL OR content_byte_count >= 0),
            session_id BLOB NOT NULL CHECK(length(session_id) = 16),
            remote_file_id BLOB NOT NULL CHECK(length(remote_file_id) = 16),
            outcome TEXT NOT NULL CHECK(outcome IN ('published','merged','archived','deleted','cancelled')),
            item_id BLOB REFERENCES inbox_items(id),
            terminal_sha256 BLOB CHECK(terminal_sha256 IS NULL OR length(terminal_sha256) = 32),
            terminal_byte_count INTEGER,
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            PRIMARY KEY(session_id, remote_file_id),
            FOREIGN KEY(session_id, terminal_sha256, terminal_byte_count)
                REFERENCES inbox_content_terminals(session_id, sha256, byte_count),
            CHECK((terminal_sha256 IS NULL) = (terminal_byte_count IS NULL)),
            CHECK((content_sha256 IS NULL) = (content_byte_count IS NULL)),
            CHECK((outcome = 'cancelled') = (content_sha256 IS NULL)),
            CHECK((outcome IN ('published','merged') AND item_id IS NOT NULL AND terminal_sha256 IS NULL)
               OR (outcome IN ('archived','deleted') AND item_id IS NULL AND terminal_sha256 IS NOT NULL)
               OR (outcome = 'cancelled' AND item_id IS NULL AND terminal_sha256 IS NULL))
        ) STRICT
        """),
        ("inbox_receipt_content", "CREATE INDEX inbox_receipt_content ON inbox_transport_receipts(content_sha256, content_byte_count)"),
        ("inbox_uploads", """
        CREATE TABLE inbox_uploads (
            id BLOB PRIMARY KEY NOT NULL CHECK(length(id) = 16),
            scope_id BLOB NOT NULL CHECK(length(scope_id) = 16),
            session_id BLOB NOT NULL CHECK(length(session_id) = 16),
            remote_file_id BLOB NOT NULL CHECK(length(remote_file_id) = 16),
            display_name TEXT NOT NULL,
            declared_byte_count INTEGER NOT NULL CHECK(declared_byte_count >= 0),
            media_type TEXT,
            attempt_revision INTEGER NOT NULL CHECK(attempt_revision >= 0),
            admission_generation INTEGER NOT NULL CHECK(admission_generation >= 0),
            file_device INTEGER,
            file_inode INTEGER,
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            UNIQUE(session_id, remote_file_id),
            CHECK((file_device IS NULL) = (file_inode IS NULL)),
            CHECK(file_device IS NULL OR (file_device > 0 AND file_inode > 0))
        ) STRICT
        """),
        ("inbox_archive_receipts", """
        CREATE TABLE inbox_archive_receipts (
            command_hash BLOB PRIMARY KEY NOT NULL CHECK(length(command_hash) = 32),
            command BLOB NOT NULL CHECK(length(command) <= 65536),
            intent BLOB NOT NULL CHECK(length(intent) <= 65536),
            outcome BLOB NOT NULL CHECK(length(outcome) <= 4096),
            generation INTEGER NOT NULL UNIQUE CHECK(generation > 0),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32)
        ) STRICT
        """),
        ("dicom_studies", """
        CREATE TABLE dicom_studies (
            id BLOB PRIMARY KEY NOT NULL CHECK(length(id) = 16),
            state TEXT NOT NULL CHECK(state IN ('needsReview','confirmed')),
            member_id BLOB REFERENCES members(id),
            effective_date REAL,
            operation_id BLOB NOT NULL CHECK(length(operation_id) = 16),
            fingerprint BLOB NOT NULL CHECK(length(fingerprint) = 32),
            fingerprint_version INTEGER NOT NULL CHECK(fingerprint_version > 0),
            study_uid_digest BLOB NOT NULL CHECK(length(study_uid_digest) = 32),
            uid_domain TEXT NOT NULL,
            uid_version INTEGER NOT NULL CHECK(uid_version > 0),
            content_revision INTEGER NOT NULL CHECK(content_revision >= 0),
            index_version INTEGER NOT NULL CHECK(index_version > 0),
            ordering_policy INTEGER NOT NULL CHECK(ordering_policy = 2),
            logical_byte_count INTEGER NOT NULL CHECK(logical_byte_count >= 0 AND logical_byte_count <= 16777216),
            object_count INTEGER NOT NULL CHECK(object_count > 0 AND object_count <= 2000),
            instance_count INTEGER NOT NULL CHECK(instance_count >= 0 AND instance_count <= object_count),
            series_count INTEGER NOT NULL CHECK(series_count >= 0 AND series_count <= 4096),
            objects_hash BLOB NOT NULL CHECK(length(objects_hash) = 32),
            series_hash BLOB NOT NULL CHECK(length(series_hash) = 32),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            CHECK((state = 'needsReview' AND member_id IS NULL AND effective_date IS NULL)
                OR (state = 'confirmed' AND member_id IS NOT NULL AND effective_date IS NOT NULL))
        ) STRICT
        """),
        ("dicom_member_date", "CREATE INDEX dicom_member_date ON dicom_studies(member_id, effective_date, id)"),
        ("dicom_study_uid", "CREATE UNIQUE INDEX dicom_study_uid ON dicom_studies(study_uid_digest)"),
        ("dicom_fingerprint", "CREATE INDEX dicom_fingerprint ON dicom_studies(fingerprint_version, fingerprint)"),
        ("dicom_objects", """
        CREATE TABLE dicom_objects (
            study_id BLOB NOT NULL REFERENCES dicom_studies(id),
            original_id BLOB NOT NULL REFERENCES originals(id),
            retained_kind TEXT NOT NULL CHECK(retained_kind IN ('viewableImage','inertAttachment')),
            byte_count INTEGER NOT NULL CHECK(byte_count > 0 AND byte_count <= 104857600),
            sha256 BLOB NOT NULL CHECK(length(sha256) = 32),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            PRIMARY KEY(study_id, original_id)
        ) STRICT
        """),
        ("dicom_original", "CREATE INDEX dicom_original ON dicom_objects(original_id)"),
        ("dicom_series", """
        CREATE TABLE dicom_series (
            study_id BLOB NOT NULL REFERENCES dicom_studies(id),
            series_id BLOB NOT NULL CHECK(length(series_id) = 16),
            series_uid_digest BLOB NOT NULL CHECK(length(series_uid_digest) = 32),
            ordinal INTEGER NOT NULL CHECK(ordinal > 0),
            ordering_provenance TEXT NOT NULL CHECK(ordering_provenance IN ('geometryProjection','instanceNumberFallback','stableContentFallback')),
            revision INTEGER NOT NULL CHECK(revision >= 0),
            instance_count INTEGER NOT NULL CHECK(instance_count > 0 AND instance_count <= 2000),
            rows INTEGER NOT NULL CHECK(rows > 0 AND rows <= 8192),
            columns INTEGER NOT NULL CHECK(columns > 0 AND columns <= 8192),
            instances_hash BLOB NOT NULL CHECK(length(instances_hash) = 32),
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            PRIMARY KEY(study_id, series_id),
            UNIQUE(study_id, series_uid_digest), UNIQUE(study_id, ordinal)
        ) STRICT
        """),
        ("dicom_instances", """
        CREATE TABLE dicom_instances (
            study_id BLOB NOT NULL,
            series_id BLOB NOT NULL,
            instance_id BLOB NOT NULL CHECK(length(instance_id) = 16),
            original_id BLOB NOT NULL,
            sop_uid_digest BLOB NOT NULL CHECK(length(sop_uid_digest) = 32),
            ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
            sop_class TEXT NOT NULL CHECK(sop_class = 'mrImageStorage'),
            transfer_syntax TEXT NOT NULL CHECK(transfer_syntax = 'explicitVRLittleEndian'),
            modality TEXT NOT NULL CHECK(modality = 'mr'),
            rows INTEGER NOT NULL CHECK(rows > 0 AND rows <= 8192),
            columns INTEGER NOT NULL CHECK(columns > 0 AND columns <= 8192),
            samples_per_pixel INTEGER NOT NULL CHECK(samples_per_pixel = 1),
            bits_allocated INTEGER NOT NULL CHECK(bits_allocated IN (8,16)),
            bits_stored INTEGER NOT NULL CHECK(bits_stored > 0 AND bits_stored <= bits_allocated),
            high_bit INTEGER NOT NULL CHECK(high_bit >= bits_stored - 1 AND high_bit < bits_allocated),
            pixel_representation TEXT NOT NULL CHECK(pixel_representation IN ('unsigned','signed')),
            photometric_interpretation TEXT NOT NULL CHECK(photometric_interpretation IN ('monochrome1','monochrome2')),
            position_x REAL, position_y REAL, position_z REAL,
            orientation_row_x REAL, orientation_row_y REAL, orientation_row_z REAL,
            orientation_column_x REAL, orientation_column_y REAL, orientation_column_z REAL,
            rescale_slope REAL NOT NULL CHECK(rescale_slope != 0), rescale_intercept REAL NOT NULL,
            window_center REAL, window_width REAL,
            content_hash BLOB NOT NULL CHECK(length(content_hash) = 32),
            PRIMARY KEY(study_id, series_id, instance_id),
            FOREIGN KEY(study_id, series_id) REFERENCES dicom_series(study_id, series_id),
            FOREIGN KEY(study_id, original_id) REFERENCES dicom_objects(study_id, original_id),
            UNIQUE(study_id, instance_id), UNIQUE(study_id, original_id),
            UNIQUE(study_id, sop_uid_digest), UNIQUE(study_id, series_id, ordinal),
            CHECK((position_x IS NULL) = (position_y IS NULL) AND (position_x IS NULL) = (position_z IS NULL)),
            CHECK((orientation_row_x IS NULL) = (orientation_row_y IS NULL) AND (orientation_row_x IS NULL) = (orientation_row_z IS NULL)
                AND (orientation_row_x IS NULL) = (orientation_column_x IS NULL) AND (orientation_row_x IS NULL) = (orientation_column_y IS NULL)
                AND (orientation_row_x IS NULL) = (orientation_column_z IS NULL)),
            CHECK((window_center IS NULL) = (window_width IS NULL)),
            CHECK(window_width IS NULL OR window_width >= 1)
        ) STRICT
        """)
    ]

    static let identity = ContentDigest.sha256(Data(statements.map(\.sql).joined(separator: "\n").utf8))

    static func create(in db: Database) throws {
        for statement in statements { try db.execute(sql: statement.sql) }
        let state = SQLiteLibraryState(libraryID: UUID(), generation: 0, commitID: UUID())
        try db.execute(sql: "INSERT INTO library_state VALUES (1, ?, ?, ?, ?, ?)", arguments: [
            state.libraryID.sqliteBytes, state.generation, state.commitID.sqliteBytes,
            identity, state.contentHash
        ])
        try db.execute(sql: "PRAGMA application_id = \(applicationID)")
        try db.execute(sql: "PRAGMA user_version = \(version)")
    }

    static func validate(in db: Database) throws {
        guard try Int.fetchOne(db, sql: "PRAGMA application_id") == applicationID,
              try Int.fetchOne(db, sql: "PRAGMA user_version") == version else {
            throw SQLiteLibraryError.unsupportedFormat
        }
        let rows = try Row.fetchAll(db, sql: "SELECT name, sql FROM sqlite_schema WHERE sql IS NOT NULL ORDER BY name")
        let expected = Dictionary(uniqueKeysWithValues: statements)
        guard rows.count == expected.count,
              rows.allSatisfy({ row in expected[row["name"] as String] == row["sql"] as String }) else {
            throw SQLiteLibraryError.damaged
        }
        guard try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"],
              try Row.fetchOne(db, sql: "PRAGMA foreign_key_check") == nil else {
            throw SQLiteLibraryError.damaged
        }
        _ = try SQLiteLibraryState.read(from: db)
        guard try Int.fetchOne(db, sql: "SELECT count(*) FROM members") ?? 0 <= 256,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM reports") ?? 0 <= 20_000,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM import_drafts") ?? 0 <= 20_000,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_items") ?? 0 <= 5_000,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_transport_receipts") ?? 0 <= 5_000,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM inbox_content_terminals") ?? 0 <= 5_000,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM (SELECT original_id FROM report_sources UNION SELECT original_id FROM dicom_objects)") ?? 0 <= 20_000,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM dicom_studies") ?? 0 <= 256,
              try Int.fetchOne(db, sql: "SELECT count(*) FROM dicom_series") ?? 0 <= 4_096,
              try Int.fetchOne(db, sql: "SELECT count(DISTINCT original_id) FROM dicom_objects") ?? 0 <= 10_000,
              try Row.fetchOne(db, sql: "SELECT study_id FROM dicom_objects GROUP BY study_id HAVING count(*) > 2000 LIMIT 1") == nil,
              try Row.fetchOne(db, sql: """
                  SELECT original_id FROM (
                    SELECT original_id FROM report_sources UNION SELECT original_id FROM inbox_items UNION SELECT original_id FROM dicom_objects
                  ) JOIN originals ON originals.id = original_id WHERE lifecycle != 'live' LIMIT 1
                  """) == nil else { throw SQLiteLibraryError.damaged }
    }
}
