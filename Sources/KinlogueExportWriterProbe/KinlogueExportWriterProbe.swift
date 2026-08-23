import Darwin
import Foundation
import ZIPFoundation

private let chunkSize = 64 * 1_024
private let cancellationPayloadBytes = 64 * 1_024 * 1_024

private enum Scenario: String, Codable, Sendable {
    case attachmentLimit = "attachment-limit"
    case manifestLimit = "manifest-limit"
}

private struct Configuration: Sendable {
    let entryCount: Int
    let scenario: Scenario
    let workingDirectory: URL

    static func parse(arguments: [String]) throws -> Self {
        var entryCount: Int?
        var scenario = Scenario.attachmentLimit
        var workingDirectory: URL?
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--entries":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]),
                      (1...100_000).contains(value) else {
                    throw ProbeError.invalidArguments
                }
                entryCount = value
            case "--scenario":
                index += 1
                guard index < arguments.count,
                      let value = Scenario(rawValue: arguments[index]) else {
                    throw ProbeError.invalidArguments
                }
                scenario = value
            case "--working-directory":
                index += 1
                guard index < arguments.count else {
                    throw ProbeError.invalidArguments
                }
                workingDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            default:
                throw ProbeError.invalidArguments
            }
            index += 1
        }

        guard let entryCount, let workingDirectory else {
            throw ProbeError.invalidArguments
        }
        return Self(
            entryCount: entryCount,
            scenario: scenario,
            workingDirectory: workingDirectory
        )
    }
}

private struct ProbeMetrics: Codable, Sendable {
    let scenario: Scenario
    let entryCount: Int
    let payloadBytes: Int
    let durationMilliseconds: Int
    let peakRSSDeltaBytes: UInt64
    let maximumProviderRequestBytes: Int
    let mainThreadHeartbeatCount: Int
    let maximumMainThreadHeartbeatGapMilliseconds: Int
    let cancellationPrefixEntries: Int
    let cancellationLatencyMilliseconds: Int
    let cancellationObserved: Bool
    let cleanupVerified: Bool
    let archiveIntegrityVerified: Bool
    let passed: Bool
}

private enum ProbeError: Error {
    case invalidArguments
    case invalidWorkingDirectory
    case cancellationNotObserved
    case inconsistentArchive
    case cleanupFailed
}

// SAFETY: Every read and write of `result` is serialized by the private lock,
// and neither the mutable storage nor the lock escapes this wrapper.
private final class WorkerState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<WorkerMetrics, Error>?

    func finish(_ result: Result<WorkerMetrics, Error>) {
        lock.withLock { self.result = result }
    }

    func snapshot() -> Result<WorkerMetrics, Error>? {
        lock.withLock { result }
    }
}

private struct WorkerMetrics: Sendable {
    let durationMilliseconds: Int
    let maximumProviderRequestBytes: Int
    let cancellationPrefixEntries: Int
    let cancellationLatencyMilliseconds: Int
    let cancellationObserved: Bool
    let cleanupVerified: Bool
    let archiveIntegrityVerified: Bool
}

// SAFETY: `value` is accessed only while holding the private lock, and the
// wrapper exposes snapshots rather than its mutable storage.
private final class IntegerMaximum: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record(_ candidate: Int) {
        lock.withLock { value = max(value, candidate) }
    }

    func snapshot() -> Int {
        lock.withLock { value }
    }
}

private func monotonicNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

private func milliseconds(from start: UInt64, to end: UInt64) -> Int {
    Int((end - start) / 1_000_000)
}

private func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

private func archivePath(index: Int, scenario: Scenario) -> String {
    switch scenario {
    case .attachmentLimit:
        return String(format: "m/r%05d/s.bin", index)
    case .manifestLimit:
        if index < 20_000 {
            return String(format: "m/r/s%05d.bin", index)
        }
        let dicomIndex = index - 20_000
        return String(
            format: "m/d%03d/o%04d.dcm",
            dicomIndex / 2_000,
            dicomIndex % 2_000
        )
    }
}

private func addSyntheticEntry(
    to archive: Archive,
    path: String,
    payloadBytes: Int,
    progress: Progress? = nil,
    providerMaximum: IntegerMaximum,
    delayMicroseconds: useconds_t = 0
) throws {
    try archive.addEntry(
        with: path,
        type: .file,
        uncompressedSize: Int64(payloadBytes),
        modificationDate: Date(timeIntervalSince1970: 0),
        permissions: 0o600,
        compressionMethod: .none,
        bufferSize: 64 * 1_024,
        progress: progress
    ) { _, requestedSize in
        providerMaximum.record(requestedSize)
        if delayMicroseconds > 0 {
            usleep(delayMicroseconds)
        }
        return Data(count: requestedSize)
    }
}

private func writeCompletedArchive(
    configuration: Configuration,
    archiveURL: URL,
    providerMaximum: IntegerMaximum
) throws -> Int {
    let start = monotonicNanoseconds()
    do {
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for index in 0..<configuration.entryCount {
            try addSyntheticEntry(
                to: archive,
                path: archivePath(index: index, scenario: configuration.scenario),
                payloadBytes: 1,
                providerMaximum: providerMaximum
            )
        }
    }
    return milliseconds(from: start, to: monotonicNanoseconds())
}

private func verifyArchive(at archiveURL: URL, expectedEntries: Int) throws {
    let archive = try Archive(url: archiveURL, accessMode: .read)
    var observedEntries = 0
    for entry in archive {
        var extractedBytes = 0
        _ = try archive.extract(entry, bufferSize: chunkSize) { data in
            extractedBytes += data.count
        }
        guard extractedBytes == 1 else { throw ProbeError.inconsistentArchive }
        observedEntries += 1
    }
    guard observedEntries == expectedEntries else { throw ProbeError.inconsistentArchive }
}

private func exerciseCancellation(
    configuration: Configuration,
    archiveURL: URL,
    providerMaximum: IntegerMaximum
) throws -> (prefixEntries: Int, latencyMilliseconds: Int, observed: Bool) {
    let prefixEntries = min(max(configuration.entryCount / 2, 1), 10_000)
    let progress = Progress(totalUnitCount: Int64(cancellationPayloadBytes))
    let cancellationRequested = DispatchSemaphore(value: 0)
    let cancellationTimestamp = WorkerStateTimestamp()

    do {
        let archive = try Archive(url: archiveURL, accessMode: .create)
        for index in 0..<prefixEntries {
            try addSyntheticEntry(
                to: archive,
                path: archivePath(index: index, scenario: configuration.scenario),
                payloadBytes: 1,
                providerMaximum: providerMaximum
            )
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(10)) {
            cancellationTimestamp.store(monotonicNanoseconds())
            progress.cancel()
            cancellationRequested.signal()
        }

        do {
            try addSyntheticEntry(
                to: archive,
                path: "m/cancel.bin",
                payloadBytes: cancellationPayloadBytes,
                progress: progress,
                providerMaximum: providerMaximum,
                delayMicroseconds: 1_000
            )
            throw ProbeError.cancellationNotObserved
        } catch Archive.ArchiveError.cancelledOperation {
            cancellationRequested.wait()
            let requestedAt = cancellationTimestamp.snapshot()
            return (
                prefixEntries,
                milliseconds(from: requestedAt, to: monotonicNanoseconds()),
                true
            )
        }
    }
}

// SAFETY: All timestamp reads and writes hold the private lock; the stored
// integer is copied out and no mutable state escapes the wrapper.
private final class WorkerStateTimestamp: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func store(_ value: UInt64) {
        lock.withLock { self.value = value }
    }

    func snapshot() -> UInt64 {
        lock.withLock { value }
    }
}

private func runWorker(configuration: Configuration) throws -> WorkerMetrics {
    let fileManager = FileManager.default
    let completedArchive = configuration.workingDirectory.appendingPathComponent("completed.work")
    let cancelledArchive = configuration.workingDirectory.appendingPathComponent("cancelled.work")
    let providerMaximum = IntegerMaximum()
    var cleanupVerified = false

    defer {
        try? fileManager.removeItem(at: completedArchive)
        try? fileManager.removeItem(at: cancelledArchive)
    }

    let duration = try writeCompletedArchive(
        configuration: configuration,
        archiveURL: completedArchive,
        providerMaximum: providerMaximum
    )
    try verifyArchive(at: completedArchive, expectedEntries: configuration.entryCount)

    let cancellation = try exerciseCancellation(
        configuration: configuration,
        archiveURL: cancelledArchive,
        providerMaximum: providerMaximum
    )

    try fileManager.removeItem(at: completedArchive)
    try fileManager.removeItem(at: cancelledArchive)
    cleanupVerified = !fileManager.fileExists(atPath: completedArchive.path)
        && !fileManager.fileExists(atPath: cancelledArchive.path)
    guard cleanupVerified else { throw ProbeError.cleanupFailed }

    return WorkerMetrics(
        durationMilliseconds: duration,
        maximumProviderRequestBytes: providerMaximum.snapshot(),
        cancellationPrefixEntries: cancellation.prefixEntries,
        cancellationLatencyMilliseconds: cancellation.latencyMilliseconds,
        cancellationObserved: cancellation.observed,
        cleanupVerified: cleanupVerified,
        archiveIntegrityVerified: true
    )
}

private func run(configuration: Configuration) throws -> ProbeMetrics {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(
        atPath: configuration.workingDirectory.path,
        isDirectory: &isDirectory
    ), isDirectory.boolValue,
    !configuration.workingDirectory.isSymbolicLink else {
        throw ProbeError.invalidWorkingDirectory
    }

    let baselineRSS = residentMemoryBytes()
    var peakRSS = baselineRSS
    var heartbeatCount = 0
    var maximumHeartbeatGapMilliseconds = 0
    var previousHeartbeat = monotonicNanoseconds()
    let workerState = WorkerState()

    DispatchQueue.global(qos: .userInitiated).async {
        workerState.finish(Result { try runWorker(configuration: configuration) })
    }

    while workerState.snapshot() == nil {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        let now = monotonicNanoseconds()
        maximumHeartbeatGapMilliseconds = max(
            maximumHeartbeatGapMilliseconds,
            milliseconds(from: previousHeartbeat, to: now)
        )
        previousHeartbeat = now
        heartbeatCount += 1
        peakRSS = max(peakRSS, residentMemoryBytes())
    }

    let worker = try workerState.snapshot()!.get()
    let peakDelta = peakRSS >= baselineRSS ? peakRSS - baselineRSS : 0
    let passed = worker.cleanupVerified
        && worker.archiveIntegrityVerified
        && worker.cancellationObserved
        && worker.maximumProviderRequestBytes <= chunkSize
        && worker.cancellationLatencyMilliseconds <= 250
        && maximumHeartbeatGapMilliseconds <= 250
        && heartbeatCount > 0

    return ProbeMetrics(
        scenario: configuration.scenario,
        entryCount: configuration.entryCount,
        payloadBytes: configuration.entryCount,
        durationMilliseconds: worker.durationMilliseconds,
        peakRSSDeltaBytes: peakDelta,
        maximumProviderRequestBytes: worker.maximumProviderRequestBytes,
        mainThreadHeartbeatCount: heartbeatCount,
        maximumMainThreadHeartbeatGapMilliseconds: maximumHeartbeatGapMilliseconds,
        cancellationPrefixEntries: worker.cancellationPrefixEntries,
        cancellationLatencyMilliseconds: worker.cancellationLatencyMilliseconds,
        cancellationObserved: worker.cancellationObserved,
        cleanupVerified: worker.cleanupVerified,
        archiveIntegrityVerified: worker.archiveIntegrityVerified,
        passed: passed
    )
}

private extension URL {
    var isSymbolicLink: Bool {
        (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

do {
    let configuration = try Configuration.parse(arguments: Array(CommandLine.arguments.dropFirst()))
    let metrics = try run(configuration: configuration)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(metrics))
    FileHandle.standardOutput.write(Data([0x0a]))
    exit(metrics.passed ? 0 : 1)
} catch {
    let message = "Export writer probe failed with a non-content error.\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
