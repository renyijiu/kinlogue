import Darwin
@preconcurrency import Dispatch
import Foundation
import KinlogueCore

/// A content-free dirty signal for the LAN inbox projection.
///
/// Directory sources cover manifest replacement and object publication.
/// Individual partial sources cover byte progress without parsing the inbox
/// manifest or enumerating its full physical inventory on every UI heartbeat.
// SAFETY: The private serial queue confines generation, source ownership, and
// stop state; every public access synchronizes on that queue. Event handlers
// run on the same queue and capture the monitor weakly. `deinit` has exclusive
// ownership and only cancels the remaining sources.
public final class LANInboxChangeMonitor: @unchecked Sendable {
    private static let partialPrefix = "partial:"
    private let layout: LANInboxLayout
    private let queue = DispatchQueue(label: "com.kinlogue.lan-inbox-change-monitor")
    private var generation: UInt64 = 0
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var isStopped = false

    public init(rootURL: URL) throws {
        layout = try LANInboxLayout(rootURL: rootURL)
        try queue.sync {
            try installDirectorySource(key: "inbox", url: layout.inboxDirectoryURL)
            try installDirectorySource(key: "blobs", url: layout.blobsDirectoryURL)
            try installDirectorySource(
                key: "partials",
                url: layout.partialsDirectoryURL,
                rebuildPartials: true
            )
            try installDirectorySource(key: "derived", url: layout.derivedDirectoryURL)
            try rebuildPartialSources()
        }
    }

    deinit {
        sources.values.forEach { $0.cancel() }
    }

    public func currentGeneration() -> UInt64 {
        queue.sync { generation }
    }

    public func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            sources.values.forEach { $0.cancel() }
            sources.removeAll()
        }
    }

    private func installDirectorySource(
        key: String,
        url: URL,
        rebuildPartials: Bool = false
    ) throws {
        try installSource(key: key, url: url, directory: true) { [weak self] in
            self?.recordChange(rebuildPartials: rebuildPartials)
        }
    }

    private func installSource(
        key: String,
        url: URL,
        directory: Bool,
        handler: @escaping @Sendable () -> Void
    ) throws {
        let flags = O_EVTONLY | O_CLOEXEC | O_NOFOLLOW | (directory ? O_DIRECTORY : 0)
        let descriptor = Darwin.open(url.path, flags)
        guard descriptor >= 0 else { throw VaultError.ioFailure(errno) }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.attrib, .delete, .extend, .link, .rename, .revoke, .write],
            queue: queue
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { Darwin.close(descriptor) }
        sources[key]?.cancel()
        sources[key] = source
        source.resume()
    }

    private func recordChange(rebuildPartials: Bool) {
        guard !isStopped else { return }
        generation &+= 1
        if rebuildPartials { try? rebuildPartialSources() }
    }

    private func rebuildPartialSources() throws {
        let existingKeys = sources.keys.filter { $0.hasPrefix(Self.partialPrefix) }
        for key in existingKeys {
            sources.removeValue(forKey: key)?.cancel()
        }
        let names = try FileManager.default.contentsOfDirectory(
            atPath: layout.partialsDirectoryURL.path
        )
        for name in names.sorted() {
            let relativePath = "lan-inbox/partials/\(name)"
            guard layout.partialID(at: relativePath) != nil else { continue }
            let url = layout.partialsDirectoryURL.appendingPathComponent(name)
            try installSource(
                key: "\(Self.partialPrefix)\(name)",
                url: url,
                directory: false
            ) { [weak self] in
                self?.recordChange(rebuildPartials: false)
            }
        }
    }
}
