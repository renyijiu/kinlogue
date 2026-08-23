import Foundation
import Testing
@testable import KinloguePlatform

@Suite("LAN inbox change monitor", .serialized)
struct LANInboxChangeMonitorTests {
    @Test
    func observesAtomicManifestReplacementAndPartialProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-lan-change-monitor-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = try PlaintextVault(rootURL: root)
        _ = try await vault.initialize()
        let inbox = try PlaintextLANInboxStore(rootURL: root)
        _ = try await inbox.initialize()
        let monitor = try LANInboxChangeMonitor(rootURL: root)
        defer { monitor.stop() }

        let manifestURL = root.appendingPathComponent("lan-inbox/inbox.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let initial = monitor.currentGeneration()
        try manifestData.write(to: manifestURL, options: .atomic)
        let afterManifest = try await waitForChange(after: initial, monitor: monitor)

        let partialURL = root.appendingPathComponent(
            "lan-inbox/partials/\(UUID().uuidString.lowercased()).partial"
        )
        try Data([0x31]).write(to: partialURL)
        let afterCreate = try await waitForChange(after: afterManifest, monitor: monitor)

        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x32]))
        try handle.synchronize()
        try handle.close()
        _ = try await waitForChange(after: afterCreate, monitor: monitor)
    }

    private func waitForChange(
        after generation: UInt64,
        monitor: LANInboxChangeMonitor
    ) async throws -> UInt64 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            let current = monitor.currentGeneration()
            if current != generation { return current }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Expected a content-free LAN inbox change notification")
        return monitor.currentGeneration()
    }
}
