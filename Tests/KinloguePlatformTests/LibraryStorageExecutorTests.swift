import Foundation
import os
import Testing
@testable import KinlogueCore
@testable import KinloguePlatform

@Suite(.serialized)
struct LibraryStorageExecutorTests {
    @Test
    func readsWaitingForAdmissionLeaveTheCooperativePoolFree() async throws {
        let root = try sqliteTestRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try SQLiteLibraryStore(rootURL: root)
        defer { try? store.close() }
        let reports = SQLiteReportRepository(store: store)
        // The detection below is only meaningful if a plain task is seen as being on the pool.
        #expect(await Task.detached { LibraryStorageExecutor.callerIsOnCooperativePool }.value)

        // Admission is held the way a long capture holds it. The holder lets go on its own after
        // a deadline, so a starved pool fails this test instead of hanging it.
        let release = DispatchSemaphore(value: 0)
        let probeRan = OSAllocatedUnfairLock(initialState: false)
        let poolWasFree = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (holding: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                store.admission.withLock {
                    holding.resume()
                    _ = release.wait(timeout: .now() + 5)
                    poolWasFree.withLock { $0 = probeRan.withLock { $0 } }
                }
            }
        }
        // Several times more waiting reads than the pool has threads.
        let reads = (0..<(4 * ProcessInfo.processInfo.activeProcessorCount)).map { _ in
            Task { try await reports.members() }
        }
        let probe = Task.detached { probeRan.withLock { $0 = true } }
        await probe.value
        release.signal()
        for read in reads { #expect(try await read.value.isEmpty) }
        #expect(poolWasFree.withLock { $0 })
    }

    @Test
    func repositoryCallsTakeAdmissionOnlyOffTheCooperativePool() async throws {
        let root = try sqliteTestRoot()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = try SQLiteLibraryStore(rootURL: root)
        defer { try? store.close() }
        let reports = SQLiteReportRepository(store: store)
        let studies = try SQLiteDICOMRepository(store: store)
        let inbox = try SQLiteLANInboxStore(store: store)
        let entries = OSAllocatedUnfairLock(initialState: 0)
        store.admission.onCooperativePoolEntry = { entries.withLock { $0 += 1 } }
        defer { store.admission.onCooperativePoolEntry = nil }

        let member = try FamilyMember(displayName: "Synthetic executor member")
        try await reports.saveMember(member, replacing: nil)
        #expect(try await reports.member(member.id) == member)
        let bytes = Data("synthetic executor original".utf8)
        let file = try ValidatedImportedFile(data: bytes, kind: .image, contentTypeIdentifier: "public.png",
                                             sha256Digest: ContentDigest.sha256(bytes))
        guard case .created(let draftID) = try await reports.stage(file) else {
            Issue.record("Expected a new draft"); return
        }
        let lease = try await reports.beginProcessing(draftID: draftID, attemptID: UUID())
        try await reports.completeProcessing(lease: lease, document: ImportDraftDocument(blocks: [], candidates: ReportCandidates()))
        let draft = try await reports.draft(draftID)
        let record = try HealthRecord(id: draftID, memberID: member.id, sources: draft.sources,
            ocrDocumentObjectID: draft.documentObjectID, importState: .confirmed,
            conclusion: SourceField.manualEntry("Synthetic executor conclusion"))
        try await reports.confirm(draftID: draftID, expectedRevision: draft.revision, record: record)
        #expect(try await reports.record(draftID) == record)
        #expect(try await reports.header().reportCount == 1)
        #expect(try await reports.timelinePage(memberID: nil, limit: 100, cursor: nil).items.count == 1)
        #expect(try await reports.reportPage(query: "executor").items.count == 1)
        #expect(try await reports.draftPage(states: [.needsReview], limit: 100, cursor: nil).items.isEmpty)
        #expect(try await studies.summaries().items.isEmpty)
        #expect(try await inbox.loadSnapshot().items.isEmpty)
        #expect(try await SQLiteLibraryIntegrityScrubber(store: store).run().completed)

        // An upload reaches storage from the sink's own callbacks as well: one that is
        // published and one that is cancelled after its first bytes.
        func upload(_ text: String) async throws -> LANUploadSink {
            let bytes = Data(text.utf8)
            let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "synthetic.png"),
                                                         declaredByteCount: bytes.count)
            guard case let .sink(sink) = try await inbox.startItemUpload(
                transport: LANInboxTransportIdentity(sessionID: UUID(), remoteFileID: UUID()),
                metadata: metadata, attemptRevision: 0) else { throw LANInboxError.invalidState }
            try await sink.write(bytes).value
            return sink
        }
        _ = try await upload("synthetic executor upload").finish()
        try await upload("synthetic cancelled upload").cancel()
        #expect(try await inbox.loadSnapshot().items.count == 1)

        #expect(entries.withLock { $0 } == 0)
        // The observer does fire for a caller that stays on the pool, so a zero above is not vacuous.
        _ = try await Task.detached { try store.state() }.value
        #expect(entries.withLock { $0 } == 1)
    }

    @Test
    func everyConcurrentStorageEntryPointMovesOntoTheStorageExecutor() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var checked = 0
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            var search = text.startIndex..<text.endIndex
            while let attribute = text.range(of: "@concurrent", range: search) {
                search = attribute.upperBound..<text.endIndex
                // Prose that mentions the attribute is not a declaration.
                let line = text[text.lineRange(for: attribute)]
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let next = text.range(of: "@concurrent", range: search)?.lowerBound ?? text.endIndex
                let declaration = text[attribute.upperBound..<next].prefix(900)
                checked += 1
                #expect(declaration.contains("LibraryStorageExecutor.run"),
                        "\(url.lastPathComponent): a @concurrent function does not move onto the storage executor")
            }
        }
        #expect(checked >= 70)
    }
}
