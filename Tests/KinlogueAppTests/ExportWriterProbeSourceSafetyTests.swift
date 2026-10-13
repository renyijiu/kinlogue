import Foundation
import Testing

struct ExportWriterProbeSourceSafetyTests {
    @Test
    func fixtureUsesOnlyBoundedContentFreeSyntheticInputs() throws {
        let fixture = try contents(
            "Sources/KinlogueExportWriterProbe/KinlogueExportWriterProbe.swift"
        )

        for required in [
            "Data(count: requestedSize)",
            "compressionMethod: .none",
            "bufferSize: 64 * 1_024",
            "cleanupVerified",
            "maximumProviderRequestBytes",
            "mainThreadHeartbeatCount",
            "cancellationLatencyMilliseconds",
        ] {
            #expect(fixture.contains(required))
        }

        for forbidden in [
            "UUID(", "globallyUniqueString", "NSHomeDirectory", "Documents",
            "Downloads", "displayName", "patient", "memberName",
        ] {
            #expect(!fixture.contains(forbidden))
        }
    }

    @Test
    func runnerKeepsInputsBoundedAndUsesAnOwnedTemporaryDirectory() throws {
        let script = try contents("scripts/run-export-writer-probe.sh")

        for required in [
            "--entries", "--manifest-limit", "mktemp -d",
            "KinlogueExportWriterProbe", "umask 077", "trap cleanup",
        ] {
            #expect(script.contains(required))
        }
        #expect(!script.contains("$HOME"))
        #expect(!script.contains("~/"))
    }

    @Test
    func productionExportKeepsOneArchiveOpenAndReadsOnlyItsPinnedOriginals() throws {
        let exporter = try contents(
            "Sources/KinloguePlatform/Export/OriginalArchiveExporter.swift"
        )

        #expect(exporter.contains("func writeArchive("))
        #expect(exporter.contains("to archive: Archive"))
        #expect(!exporter.contains("accessMode: .update"))
        // Entries come from the originals pinned when the export was prepared, and the pins
        // are checked once more before the archive is committed.
        #expect(exporter.contains("try snapshot.pins.open(entry.attachmentID)"))
        #expect(exporter.contains("try snapshot.pins.validate()"))
    }

    private func contents(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
