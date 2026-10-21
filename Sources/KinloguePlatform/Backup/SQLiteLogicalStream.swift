import CryptoKit
import Foundation
import KinlogueCore

/// Fixed framing. A segment boundary may bisect a record; declared lengths are checked before allocation.
/// The header's version decides which kinds may appear and how many counts the footer carries.
enum SQLiteLogicalStream {
    /// Bytes from the footer tag to the end: tag, one count per kind, length, digest.
    static func footerByteCount(version: Int) -> Int { 1 + 4 * BackupLogicalKind.kinds(forVersion: version).count + 8 + 32 }
    static let magic = Data("KLGLOG01".utf8)
    static func integer<T: FixedWidthInteger>(_ value: T) -> Data { var value = value.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    static func number<T: FixedWidthInteger>(_ data: Data, _: T.Type) -> T { data.reduce(0) { ($0 << 8) | T($1) } }
    final class Writer {
        private let write: (Data) throws -> Void
        private var hash = SHA256()
        private let kinds: [BackupLogicalKind]
        private var counts: [UInt32]
        private var bytes: UInt64 = 0
        private var previous: (UInt8, Data)?
        private var finished = false
        init(header: BackupLogicalHeaderV1, write: @escaping (Data) throws -> Void) throws {
            self.write = write
            kinds = BackupLogicalKind.kinds(forVersion: header.version)
            counts = Array(repeating: 0, count: kinds.count)
            let encoded = try CanonicalVaultJSON.encode(header)
            guard BackupLogicalHeaderV1.supportedVersions.contains(header.version), encoded.count <= 1_024 else {
                throw SQLiteLogicalBackupError.unsupportedVersion
            }
            try appendBytes(SQLiteLogicalStream.magic + SQLiteLogicalStream.integer(UInt32(encoded.count)) + encoded)
        }
        private func appendBytes(_ data: Data) throws {
            guard UInt64(data.count) <= BackupFormatLimits.maximumPlaintextByteCount - bytes else { throw SQLiteLogicalBackupError.resourceLimit }
            try write(data); hash.update(data: data); bytes += UInt64(data.count)
        }
        func append(_ record: SQLiteLogicalRecord) throws {
            guard let index = kinds.firstIndex(of: record.kind) else { throw SQLiteLogicalBackupError.invalidStream }
            guard !finished, record.key.count == (record.kind == .archiveReceipt ? 32 : 16),
                  record.payload.count <= record.kind.maximumPayloadBytes else { throw SQLiteLogicalBackupError.resourceLimit }
            let tag = record.kind.rawValue
            if let previous { guard tag > previous.0 || (tag == previous.0 && previous.1.lexicographicallyPrecedes(record.key)) else { throw SQLiteLogicalBackupError.invalidStream } }
            guard counts[index] < record.kind.maximumCount else { throw SQLiteLogicalBackupError.resourceLimit }
            counts[index] += 1; previous = (tag, record.key)
            try appendBytes(Data([tag, UInt8(record.key.count)]) + record.key + SQLiteLogicalStream.integer(UInt32(record.payload.count)))
            try appendBytes(record.payload)
        }
        func finish() throws {
            guard !finished else { throw SQLiteLogicalBackupError.invalidStream }; finished = true
            var footer = Data([255])
            for count in counts { footer.append(SQLiteLogicalStream.integer(count)) }
            footer.append(SQLiteLogicalStream.integer(bytes)); footer.append(Data(hash.finalize()))
            try write(footer)
        }
    }
    static func read(byteCount: Int, read: (Int, Int) throws -> Data, receiveHeader: (BackupLogicalHeaderV1) throws -> Void = { _ in },
                     consume: (SQLiteLogicalRecord) throws -> Void) throws -> BackupLogicalHeaderV1 {
        var offset = 0, hash = SHA256()
        var previous: (UInt8, Data)?
        func take(_ count: Int, hashing: Bool = true) throws -> Data {
            guard count >= 0, offset <= byteCount, count <= byteCount - offset else { throw SQLiteLogicalBackupError.invalidStream }
            let data = try read(offset, count)
            guard data.count == count else { throw SQLiteLogicalBackupError.invalidStream }
            offset += count; if hashing { hash.update(data: data) }; return data
        }
        guard try take(8) == magic else { throw SQLiteLogicalBackupError.unsupportedVersion }
        let headerLength = Int(try number(take(4), UInt32.self))
        guard headerLength <= 1_024 else { throw SQLiteLogicalBackupError.resourceLimit }
        let headerBytes = try take(headerLength)
        let header = try CanonicalVaultJSON.decode(BackupLogicalHeaderV1.self, from: headerBytes)
        guard try CanonicalVaultJSON.encode(header) == headerBytes else { throw SQLiteLogicalBackupError.invalidStream }
        guard BackupLogicalHeaderV1.supportedVersions.contains(header.version), header.generation >= 0 else {
            throw SQLiteLogicalBackupError.unsupportedVersion
        }
        let kinds = BackupLogicalKind.kinds(forVersion: header.version)
        var counts = Array(repeating: UInt32(0), count: kinds.count)
        try receiveHeader(header)
        while true {
            try Task.checkCancellation()
            let start = offset
            let tag = try take(1, hashing: false)[0]
            if tag == 255 {
                var declared: [UInt32] = []
                for _ in counts { declared.append(try number(take(4, hashing: false), UInt32.self)) }
                let length = try number(take(8, hashing: false), UInt64.self)
                let digest = try take(32, hashing: false)
                guard counts == declared, length == UInt64(start), digest == Data(hash.finalize()), offset == byteCount else { throw SQLiteLogicalBackupError.invalidStream }
                return header
            }
            hash.update(data: Data([tag]))
            guard let kind = BackupLogicalKind(rawValue: tag), let index = kinds.firstIndex(of: kind) else {
                throw SQLiteLogicalBackupError.unsupportedVersion
            }
            let keyLength = Int(try take(1)[0])
            guard keyLength == (kind == .archiveReceipt ? 32 : 16) else { throw SQLiteLogicalBackupError.invalidStream }
            let key = try take(keyLength)
            if let previous { guard tag > previous.0 || (tag == previous.0 && previous.1.lexicographicallyPrecedes(key)) else { throw SQLiteLogicalBackupError.invalidStream } }
            let length = Int(try number(take(4), UInt32.self))
            guard length <= kind.maximumPayloadBytes, counts[index] < kind.maximumCount else { throw SQLiteLogicalBackupError.resourceLimit }
            counts[index] += 1; previous = (tag, key)
            try consume(SQLiteLogicalRecord(kind: kind, key: key, payload: take(length)))
        }
    }
}
