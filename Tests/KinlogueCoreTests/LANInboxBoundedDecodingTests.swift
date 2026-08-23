import Foundation
import Testing
@testable import KinlogueCore

@Suite("LAN inbox bounded decoding")
struct LANInboxBoundedDecodingTests {
    @Test
    func snapshotRejectsEveryOversizedTopLevelArrayBeforeDecodingElements() throws {
        let snapshot = try LANInboxSnapshot(
            vaultID: uuid(1),
            generation: 1,
            commitID: uuid(2),
            lastWriterRuntimeGeneration: uuid(3)
        )
        let validWire = try jsonObject(snapshot)
        let limits = [
            ("items", LANInboxSnapshot.maximumItemCount),
            ("transportReceipts", LANInboxSnapshot.maximumTransportReceiptCount),
            ("contentTerminals", LANInboxSnapshot.maximumContentTerminalCount),
            ("archiveIntents", LANInboxSnapshot.maximumArchiveIntentCount),
            ("archiveTerminals", LANInboxSnapshot.maximumArchiveTerminalCount),
            ("blobs", LANInboxSnapshot.maximumBlobCount),
        ]

        for (key, limit) in limits {
            var oversizedWire = validWire
            oversizedWire[key] = invalidElements(count: limit + 1)
            try expectImmediateLimitRejection(
                LANInboxSnapshot.self,
                wire: oversizedWire,
                arrayKey: key,
                maximumCount: limit
            )
        }
    }

    @Test
    func archiveIntentAndFingerprintRejectOversizedSourcesBeforeDecodingElements() throws {
        let source = try LANArchiveSource(
            itemID: uuid(10),
            itemRevision: 0,
            contentIdentity: LANInboxContentIdentity(
                sha256Digest: Data(repeating: 1, count: 32),
                byteCount: 1
            ),
            reportSourceID: uuid(11),
            attachmentID: uuid(12)
        )
        let intent = try LANArchiveIntent(
            id: uuid(13),
            vaultID: uuid(14),
            orderedSources: [source],
            memberID: uuid(15),
            canonicalReportDate: Date(timeIntervalSinceReferenceDate: 1_000),
            draftID: uuid(16),
            documentObjectID: uuid(17)
        )

        var oversizedSources = try jsonObject(intent)
        oversizedSources["orderedSources"] = invalidElements(
            count: LANArchiveIntent.maximumSourceCount + 1
        )
        try expectImmediateLimitRejection(
            LANArchiveIntent.self,
            wire: oversizedSources,
            arrayKey: "orderedSources",
            maximumCount: LANArchiveIntent.maximumSourceCount
        )

        var oversizedFingerprint = try jsonObject(intent)
        oversizedFingerprint["fingerprint"] = fingerprintWire(
            sourceCount: LANArchiveIntent.maximumSourceCount + 1
        )
        try expectImmediateLimitRejection(
            LANArchiveIntent.self,
            wire: oversizedFingerprint,
            arrayKey: "sources",
            maximumCount: LANArchiveIntent.maximumSourceCount
        )

        try expectImmediateLimitRejection(
            ReportFingerprint.self,
            wire: fingerprintWire(
                sourceCount: ReportFingerprint.maximumDecodedSourceCount + 1
            ),
            arrayKey: "sources",
            maximumCount: ReportFingerprint.maximumDecodedSourceCount
        )
    }
}

private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func fingerprintWire(sourceCount: Int) -> [String: Any] {
    [
        "version": ReportFingerprint.currentVersion,
        "sources": invalidElements(count: sourceCount),
    ]
}

private func invalidElements(count: Int) -> [Any] {
    Array(repeating: NSNull(), count: count)
}

private func expectImmediateLimitRejection<Value: Decodable>(
    _ type: Value.Type,
    wire: [String: Any],
    arrayKey: String,
    maximumCount: Int
) throws {
    let data = try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys])
    do {
        _ = try JSONDecoder().decode(type, from: data)
        Issue.record("Oversized \(arrayKey) array decoded successfully")
    } catch let DecodingError.dataCorrupted(context) {
        #expect(context.debugDescription == "Array exceeds maximum allowed count of \(maximumCount)")
        #expect(context.codingPath.last?.stringValue == arrayKey)
    } catch {
        Issue.record("Oversized \(arrayKey) array decoded an element before rejection: \(error)")
    }
}
