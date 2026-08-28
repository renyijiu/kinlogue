import Darwin
import Foundation
import XCTest
@testable import KinlogueCore
@testable import KinloguePlatform

func assertThrows<T>(
    _ expected: LANInboxError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () throws -> T
) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
        guard let actual = error as? LANInboxError else {
            XCTFail("unexpected error: \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

func assertThrows<T>(
    _ expected: LANInboxError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let actual as LANInboxError {
        XCTAssertEqual(actual, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

func assertThrows<T, Failure: Error>(
    _ expectedType: Failure.Type,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected \(expectedType)", file: file, line: line)
    } catch is Failure {
        return
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

final class DerivedDescriptorFixture: @unchecked Sendable {
    let parentURL: URL
    let fileURL: URL
    let attemptID = UUID()
    let rawDescriptor: Int32

    private let lock = NSLock()
    private var fixtureOwnsDescriptor = true

    init(
        mode: mode_t = S_IRUSR | S_IWUSR,
        addHardLink: Bool = false,
        minimumDescriptor: Int32? = nil
    ) throws {
        parentURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-derived-sink-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: false
        )
        fileURL = parentURL.appendingPathComponent("owned.partial")
        let openedDescriptor = Darwin.open(
            fileURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode
        )
        guard openedDescriptor >= 0 else {
            throw DerivedSinkPOSIXFailure(code: errno)
        }
        if let minimumDescriptor {
            let duplicatedDescriptor = fcntl(
                openedDescriptor,
                F_DUPFD_CLOEXEC,
                minimumDescriptor
            )
            guard duplicatedDescriptor >= 0 else {
                let code = errno
                _ = Darwin.close(openedDescriptor)
                throw DerivedSinkPOSIXFailure(code: code)
            }
            _ = Darwin.close(openedDescriptor)
            rawDescriptor = duplicatedDescriptor
        } else {
            rawDescriptor = openedDescriptor
        }
        if addHardLink {
            let secondURL = parentURL.appendingPathComponent("second-link.partial")
            guard Darwin.link(fileURL.path, secondURL.path) == 0 else {
                _ = Darwin.close(rawDescriptor)
                throw DerivedSinkPOSIXFailure(code: errno)
            }
        }
    }

    func transferDescriptor() -> Int32 {
        lock.withLock {
            precondition(fixtureOwnsDescriptor)
            fixtureOwnsDescriptor = false
            return rawDescriptor
        }
    }

    func canAcquireExclusiveLock() throws -> Bool {
        let descriptor = Darwin.open(
            fileURL.path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw DerivedSinkPOSIXFailure(code: errno)
        }
        defer { _ = Darwin.close(descriptor) }

        let result = flock(descriptor, LOCK_EX | LOCK_NB)
        if result == 0 {
            _ = flock(descriptor, LOCK_UN)
            return true
        }
        if errno == EWOULDBLOCK { return false }
        throw DerivedSinkPOSIXFailure(code: errno)
    }

    func destroy() {
        let shouldClose = lock.withLock { () -> Bool in
            guard fixtureOwnsDescriptor else { return false }
            fixtureOwnsDescriptor = false
            return true
        }
        if shouldClose { _ = Darwin.close(rawDescriptor) }
        try? FileManager.default.removeItem(at: parentURL)
    }
}

actor DerivedCallbackRecorder {
    private(set) var finalizedArtifacts: [LANDerivedArtifactSink.CompletedArtifact] = []
    private(set) var finalizedBytes: [Data] = []
    private(set) var abortCount = 0

    func recordFinalize(
        _ completed: LANDerivedArtifactSink.CompletedArtifact,
        descriptor: Int32
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw DerivedSinkPOSIXFailure(code: errno)
        }
        finalizedArtifacts.append(completed)
        finalizedBytes.append(try readDescriptor(
            descriptor,
            byteCount: completed.byteCount
        ))
    }

    func recordAbort(descriptor: Int32) {
        var metadata = stat()
        XCTAssertEqual(fstat(descriptor, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFREG)
        abortCount += 1
    }
}

final class DerivedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    var snapshot: [String] { lock.withLock { events } }
}

actor DerivedAsyncGate {
    private var paused = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPaused(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !paused {
            if clock.now >= deadline {
                release()
                throw DerivedSinkGateTimeout()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private func readDescriptor(_ descriptor: Int32, byteCount: Int) throws -> Data {
    var data = Data(count: byteCount)
    try data.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < byteCount {
            let count = pread(
                descriptor,
                baseAddress.advanced(by: offset),
                byteCount - offset,
                off_t(offset)
            )
            if count < 0 {
                if errno == EINTR { continue }
                throw DerivedSinkPOSIXFailure(code: errno)
            }
            guard count > 0 else { throw DerivedSinkPOSIXFailure(code: EIO) }
            offset += count
        }
    }
    return data
}

func makeDerivedAdmission(
    ownerBytes: Int,
    totalBytes: Int,
    ownerChunks: Int,
    totalChunks: Int
) throws -> LANPendingWriteAdmission {
    try LANPendingWriteAdmission(
        limits: .init(
            maximumPendingBytesPerOwner: ownerBytes,
            maximumTotalPendingBytes: totalBytes,
            maximumPendingChunksPerOwner: ownerChunks,
            maximumTotalPendingChunks: totalChunks
        )
    )
}

func waitForDerivedOccurrence(
    _ injector: LANDerivedArtifactSink.FailureInjector,
    point: LANDerivedArtifactSink.FaultPoint,
    expectedCount: Int,
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while injector.occurrenceCount(for: point) < expectedCount {
        if clock.now >= deadline { throw DerivedSinkGateTimeout() }
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// `write` deliberately performs admission before it returns its asynchronous
/// task. Fault-injection gates around that synchronous boundary must not block
/// Swift's cooperative executor or the test can starve its own release task.
func runDerivedSynchronousWriteOnDedicatedThread(
    _ write: @escaping @Sendable () -> Task<Void, Error>
) -> Task<Void, Error> {
    Task {
        let admittedWrite = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: write())
            }
        }
        try await admittedWrite.value
    }
}

final class DerivedBlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let expectedEntries: Int
    private var entries = 0
    private var released = false

    init(expectedEntries: Int = 1) {
        self.expectedEntries = expectedEntries
    }

    func enterAndWait() {
        condition.lock()
        entries += 1
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !hasExpectedEntries {
            if clock.now >= deadline {
                release()
                throw DerivedSinkGateTimeout()
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private var hasExpectedEntries: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entries >= expectedEntries
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class DerivedSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false

    func signal() {
        lock.withLock { signaled = true }
    }

    func wait(timeout: Duration = .seconds(5)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !isSignaled {
            if clock.now >= deadline { throw DerivedSinkGateTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private var isSignaled: Bool {
        lock.withLock { signaled }
    }
}

struct SyntheticDerivedSinkFailure: Error, Equatable, Sendable {}
struct DerivedSinkGateTimeout: Error, Equatable, Sendable {}

private struct DerivedSinkPOSIXFailure: Error, Equatable, Sendable {
    let code: Int32
}
