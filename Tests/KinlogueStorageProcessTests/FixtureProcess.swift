import Darwin
import Foundation

struct StorageProcessFixtureCommand: Codable, Sendable {
    let operation: String
    let rootPath: String?
    let variant: Int?
    let protocolVersion: Int?

    init(
        operation: String,
        rootURL: URL? = nil,
        variant: Int? = nil,
        protocolVersion: Int? = nil
    ) {
        self.operation = operation
        rootPath = rootURL?.path
        self.variant = variant
        self.protocolVersion = protocolVersion
    }
}

struct StorageProcessFixtureResponse: Codable, Equatable, Sendable {
    let event: String
    let ok: Bool
    let code: String?
    let variant: Int?
    let generation: UInt64?
    let protocolVersion: Int?
}

enum StorageProcessHarnessError: Error, Equatable, Sendable {
    case executableUnavailable
    case malformedResponse
    case responseTooLarge
    case streamClosed
    case timedOut
    case processFailed(Int32)
}

final class StorageProcessFixture: @unchecked Sendable {
    private static let maximumLineByteCount = 16 * 1024
    private static let protocolVersion = 2

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let eventQueue = StorageProcessEventQueue()
    private let readerQueue = DispatchQueue(
        label: "app.kinlogue.storage-process-fixture-reader"
    )
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var acceptedTerminationStatus: Int32?

    init() throws {
        process.executableURL = try Self.fixtureExecutableURL()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
    }

    var isRunning: Bool { process.isRunning }

    func start() throws {
        try process.run()
        inputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()
        let handle = outputPipe.fileHandleForReading
        let queue = eventQueue
        readerQueue.async {
            Self.readResponses(from: handle, into: queue)
        }
    }

    func validateHandshake() async throws {
        try send(.init(
            operation: "handshake",
            protocolVersion: Self.protocolVersion
        ))
        let response = try await nextResponse()
        guard response.event == "handshake",
              response.ok,
              response.protocolVersion == Self.protocolVersion else {
            throw StorageProcessHarnessError.malformedResponse
        }
    }

    func send(_ command: StorageProcessFixtureCommand) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(command)
        data.append(0x0a)
        guard data.count <= Self.maximumLineByteCount else {
            throw StorageProcessHarnessError.responseTooLarge
        }
        try writeLock.withLock {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func nextResponse(
        timeout: Duration = .seconds(10)
    ) async throws -> StorageProcessFixtureResponse {
        try await withThrowingTaskGroup(of: StorageProcessFixtureResponse.self) { group in
            group.addTask { try await self.eventQueue.next() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw StorageProcessHarnessError.timedOut
            }
            guard let response = try await group.next() else {
                throw StorageProcessHarnessError.streamClosed
            }
            group.cancelAll()
            return response
        }
    }

    func shutdown() async throws {
        if process.isRunning {
            try send(.init(operation: "exit"))
            let response = try await nextResponse()
            guard response.event == "exiting", response.ok else {
                throw StorageProcessHarnessError.malformedResponse
            }
        }
        inputPipe.fileHandleForWriting.closeFile()
        let status = await waitForExit()
        await waitForReader()
        let acceptedStatus = stateLock.withLock { acceptedTerminationStatus ?? 0 }
        guard status == acceptedStatus else {
            throw StorageProcessHarnessError.processFailed(status)
        }
    }

    func terminateForCleanup() {
        inputPipe.fileHandleForWriting.closeFile()
        if process.isRunning { process.terminate() }
    }

    func crash() async throws {
        let identifier = process.processIdentifier
        guard process.isRunning, identifier > 1 else {
            throw StorageProcessHarnessError.streamClosed
        }
        guard Darwin.kill(identifier, SIGKILL) == 0 else {
            throw StorageProcessHarnessError.streamClosed
        }
        inputPipe.fileHandleForWriting.closeFile()
        let status = await waitForExit()
        await waitForReader()
        guard status == SIGKILL else {
            throw StorageProcessHarnessError.processFailed(status)
        }
        stateLock.withLock { acceptedTerminationStatus = SIGKILL }
    }

    @discardableResult
    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                self.process.waitUntilExit()
                continuation.resume(returning: self.process.terminationStatus)
            }
        }
    }

    func waitForReader() async {
        await withCheckedContinuation { continuation in
            readerQueue.async {
                continuation.resume()
            }
        }
    }

    private static func readResponses(
        from handle: FileHandle,
        into queue: StorageProcessEventQueue
    ) {
        var pending = Data()
        do {
            while true {
                // `read(upToCount:)` may wait for the requested byte count on
                // a pipe even after a complete short JSON line is available.
                // `availableData` wakes for the current pipe payload, which is
                // the framing barrier this harness needs.
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                guard pending.count <= maximumLineByteCount else {
                    throw StorageProcessHarnessError.responseTooLarge
                }
                while let newline = pending.firstIndex(of: 0x0a) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard !line.isEmpty,
                          line.count <= maximumLineByteCount,
                          let response = try? JSONDecoder().decode(
                            StorageProcessFixtureResponse.self,
                            from: line
                          ) else {
                        throw StorageProcessHarnessError.malformedResponse
                    }
                    queue.append(response)
                }
            }
            guard pending.isEmpty else {
                throw StorageProcessHarnessError.malformedResponse
            }
            queue.finish(with: .streamClosed)
        } catch let error as StorageProcessHarnessError {
            queue.finish(with: error)
        } catch {
            queue.finish(with: .streamClosed)
        }
    }

    private static func fixtureExecutableURL() throws -> URL {
        try fixtureExecutableURL(
            testBundleURL: Bundle(for: StorageProcessFixture.self).bundleURL
        )
    }

    static func fixtureExecutableURL(testBundleURL: URL) throws -> URL {
        let testBundleURL = testBundleURL.standardizedFileURL
        guard testBundleURL.pathExtension == "xctest" else {
            throw StorageProcessHarnessError.executableUnavailable
        }

        let buildDirectory = testBundleURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = buildDirectory.appendingPathComponent(
            "KinlogueStorageProcessFixture",
            isDirectory: false
        )
        guard candidate.deletingLastPathComponent().standardizedFileURL == buildDirectory,
              isOwnedExecutable(candidate) else {
            throw StorageProcessHarnessError.executableUnavailable
        }
        return candidate
    }

    private static func isOwnedExecutable(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == geteuid()
            && access(url.path, X_OK) == 0
    }
}

private final class StorageProcessEventQueue: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<StorageProcessFixtureResponse, Error>
    }

    private let lock = NSLock()
    private var responses: [StorageProcessFixtureResponse] = []
    private var waiters: [Waiter] = []
    private var terminalError: StorageProcessHarnessError?

    func append(_ response: StorageProcessFixtureResponse) {
        let waiter: Waiter? = lock.withLock {
            guard terminalError == nil else { return nil }
            guard !waiters.isEmpty else {
                responses.append(response)
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.continuation.resume(returning: response)
    }

    func finish(with error: StorageProcessHarnessError) {
        let pending: [Waiter] = lock.withLock {
            guard terminalError == nil else { return [] }
            terminalError = error
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            return pending
        }
        for waiter in pending {
            waiter.continuation.resume(throwing: error)
        }
    }

    func next() async throws -> StorageProcessFixtureResponse {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum Resolution {
                    case response(StorageProcessFixtureResponse)
                    case failure(any Error)
                    case waiting
                }

                let resolution: Resolution = lock.withLock {
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    if !responses.isEmpty {
                        return .response(responses.removeFirst())
                    }
                    if let terminalError {
                        return .failure(terminalError)
                    }
                    waiters.append(.init(id: id, continuation: continuation))
                    return .waiting
                }
                switch resolution {
                case let .response(response):
                    continuation.resume(returning: response)
                case let .failure(error):
                    continuation.resume(throwing: error)
                case .waiting:
                    break
                }
            }
        } onCancel: {
            self.cancelWaiter(id: id)
        }
    }

    private func cancelWaiter(id: UUID) {
        let waiter: Waiter? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return waiters.remove(at: index)
        }
        waiter?.continuation.resume(throwing: CancellationError())
    }
}

struct StorageProcessVaultFixture: Sendable {
    let parentURL: URL
    let rootURL: URL

    init() throws {
        let parentURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "kinlogue-storage-process-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        self.parentURL = parentURL
        rootURL = parentURL.appendingPathComponent("Vault", isDirectory: true)
    }

    func removeOwnedParent() throws {
        var metadata = stat()
        guard parentURL.lastPathComponent.hasPrefix("kinlogue-storage-process-"),
              lstat(parentURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              parentURL.resolvingSymlinksInPath().standardizedFileURL == parentURL else {
            throw StorageProcessHarnessError.malformedResponse
        }
        try FileManager.default.removeItem(at: parentURL)
    }
}

func withStorageProcessFixture<R: Sendable>(
    processCount: Int,
    _ body: ([StorageProcessFixture]) async throws -> R
) async throws -> R {
    let processes = try (0..<processCount).map { _ in try StorageProcessFixture() }
    do {
        for process in processes {
            try process.start()
            try await process.validateHandshake()
        }
        let result = try await body(processes)
        for process in processes { try await process.shutdown() }
        return result
    } catch {
        for process in processes { process.terminateForCleanup() }
        for process in processes {
            _ = await process.waitForExit()
            await process.waitForReader()
        }
        throw error
    }
}

func withOwnedVaultFixture<R: Sendable>(
    _ body: (StorageProcessVaultFixture) async throws -> R
) async throws -> R {
    let fixture = try StorageProcessVaultFixture()
    do {
        let result = try await body(fixture)
        try fixture.removeOwnedParent()
        return result
    } catch {
        try? fixture.removeOwnedParent()
        throw error
    }
}
