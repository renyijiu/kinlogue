import Foundation
import NIOCore
import Testing
@testable import KinlogueApp
@testable import KinlogueCore
@testable import KinloguePlatform

@Test
func sqliteLANServiceReceivesRefreshesAndKeepsMacQueueAfterReceiverStops() async throws {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("kinlogue-sqlite-lan-service-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("Library")
    let kernel = try SQLiteLibraryStore(rootURL: root)
    defer { try? kernel.close() }
    let address = LANNetworkAddress(interfaceName: "lo0", host: "127.0.0.1", networkPrefixLength: 8)
    let service = try LiveLANInboxService(store: kernel, lifecycle: LibraryLifecycleCoordinator(), dependencies: .init(receiverStart: { receiver, address in
        let presentation = try await receiver.start(at: address, port: 0, allowLoopbackForTesting: true,
            pipelineInstaller: { channel, _, _, _ in channel.eventLoop.makeSucceededFuture(()) })
        let peer = try LANPeerKey(socketDerivedBytes: [127, 0, 0, 1])
        guard case let .paired(credentials) = await receiver.pair(try LANPairRequest(code: presentation.pairingCode.value), from: peer),
              case let .authorized(authorization) = await receiver.authenticate(LANSessionProof(credentials: credentials), from: peer, operation: .nonBody) else { throw LANReceiverError.sessionEnded }
        let bytes = Data("synthetic unsupported inert source".utf8), remote = UUID()
        _ = try await receiver.reserveFile(LANReserveFileRequest(remoteFileID: remote, displayName: "synthetic.bin", declaredByteCount: Int64(bytes.count), mediaType: "application/octet-stream", attemptRevision: 0), authorizedBy: authorization)
        guard case let .receive(lease) = try await receiver.startFileUpload(remoteFileID: remote, attemptRevision: 0, declaredContentLength: Int64(bytes.count), authorizedBy: authorization) else { throw LANReceiverError.conflict }
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await lease.write(buffer).value
        _ = try await lease.finish()
        return presentation
    }))
    #expect(try await service.initialize().page.items.isEmpty)
    let before = await service.changeGeneration()
    #expect(await service.changeGeneration() == before)
    _ = try await service.startReceiving(at: address)
    #expect(await service.isReceiving())
    let item = try #require(try await service.refresh().page.items.first)
    #expect(await service.changeGeneration() > before)
    await service.stopReceiving()
    #expect(!(await service.isReceiving()))
    #expect(try await service.refresh().page.items.count == 1)
    #expect(try kernel.state().generation > 0)
    try await service.preprocess(itemID: item.id)
    let processed = try #require(try await service.refresh().page.items.first)
    guard case .unsupported = processed.state else { Issue.record("Mac queue must remain usable after receiver scope ends"); return }
    try await service.delete(itemID: item.id, expectedRevision: processed.revision)
    #expect(try await service.refresh().page.items.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
}

@Test @MainActor
func sqliteLANServiceModelPagesAndProcessesHiddenItemOnce() async throws {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("kinlogue-sqlite-lan-pages-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: parent) }
    let kernel = try SQLiteLibraryStore(rootURL: parent.appendingPathComponent("Library"))
    defer { try? kernel.close() }
    let inbox = try SQLiteLANInboxStore(store: kernel)
    for index in 0..<201 {
        let bytes = Data("synthetic inert source \(index)".utf8)
        let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "synthetic.bin"), declaredByteCount: bytes.count)
        guard case let .sink(sink) = try await inbox.startItemUpload(transport: LANInboxTransportIdentity(sessionID: UUID(), remoteFileID: UUID()),
            metadata: metadata, attemptRevision: 0) else { Issue.record("Expected a fresh upload"); return }
        try await sink.write(bytes).value
        _ = try await sink.finish()
    }
    let all = try await inbox.loadSnapshot().items
    for item in all.prefix(199) {
        _ = try await inbox.markItemPreprocessingIssue(itemID: item.id, expectedRevision: item.revision, issue: .unsupportedContent)
    }
    let selected = all[199]
    let document = try LANPreprocessedSourceDocument(source: ReportSource(attachmentID: selected.blobID, displayName: selected.displayName.rawValue, pageCount: 1),
        contentTypeIdentifier: "public.data", blocks: [])
    let reviewable = try await inbox.savePreprocessedDocument(itemID: selected.id, expectedRevision: selected.revision, document: document)
    let lifecycle = LibraryLifecycleCoordinator()
    let service = try LiveLANInboxService(store: kernel, lifecycle: lifecycle)
    let processing = AppProcessingCoordinator(lanService: service, lifecycle: lifecycle)
    let model = LANInboxModel(service: service, processing: processing)
    await model.start()
    #expect(model.items.count == 100)
    #expect(model.storage?.itemCount == 201)
    #expect(model.hasMore)
    for _ in 0..<400 {
        if try await inbox.loadItems(ids: [all[200].id]).first?.revision == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await inbox.loadItems(ids: [all[200].id]).first?.revision == 1)
    await model.refresh()
    await model.loadMore()
    #expect(model.items.count == 200)
    model.selectedItemIDs = [selected.id]
    model.reconcileSelectionOrder()
    await model.refresh()
    #expect(model.items.count == 100)
    #expect(model.orderedSelectedItems == [reviewable])
    await #expect(throws: LANInboxError.staleRevision) {
        _ = try await service.archive(itemIDs: [selected.id], expectedRevisions: [selected.revision], memberID: UUID(), canonicalReportDate: Date())
    }
    await model.refresh()
    await processing.cancelAndDrain()
    #expect(try await inbox.loadItems(ids: [all[200].id]).first?.revision == 1)
    model.beginDestructiveVaultLifecycle()
    await service.stopReceiving()
}

@Test @MainActor
func legacyLANModelAcceptsOtherWriterCommitsWithoutChangingQueryEpoch() async throws {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("kinlogue-legacy-lan-epoch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("Library")
    let vault = try PlaintextVault(rootURL: root)
    _ = try await vault.initialize()
    let service = LiveLANInboxService(rootURL: root, vault: vault, lifecycle: LibraryLifecycleCoordinator())
    let processing = AppProcessingCoordinator(lanService: service)
    let model = LANInboxModel(service: service, processing: processing)
    await model.start()
    await processing.cancelAndDrain()
    let epoch = try #require(model.page?.revision.openEpoch)
    var cursor: LANInboxPageCursor?
    for index in 0..<2 {
        let writer = try PlaintextLANInboxStore(rootURL: root)
        _ = try await writer.initialize()
        let bytes = Data("synthetic external writer \(index)".utf8)
        let metadata = try LANInboxTransportMetadata(displayName: LANInboxDisplayName(rawValue: "synthetic.bin"), declaredByteCount: bytes.count)
        guard case let .sink(sink) = try await writer.startItemUpload(transport: LANInboxTransportIdentity(sessionID: UUID(), remoteFileID: UUID()),
            metadata: metadata, attemptRevision: 0) else { Issue.record("Expected a fresh upload"); return }
        try await sink.write(bytes).value
        _ = try await sink.finish()
        let item = try #require(try await writer.loadSnapshot().items.last)
        _ = try await writer.markItemPreprocessingIssue(itemID: item.id, expectedRevision: item.revision, issue: .unsupportedContent)
        await model.refresh()
        #expect(model.items.count == index + 1)
        #expect(model.page?.revision.openEpoch == epoch)
        let work = try await service.processingPage(cursor: cursor)
        #expect(work.items.count == 1)
        cursor = LANInboxPageCursor(revision: work.revision, sequence: item.sequence, id: item.id, processing: true)
    }
    await processing.cancelAndDrain()
    model.beginDestructiveVaultLifecycle()
}
