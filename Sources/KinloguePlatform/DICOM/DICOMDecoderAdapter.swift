@preconcurrency import Foundation
#if canImport(KinlogueDICOMIPC)
import KinlogueDICOMIPC
#endif

public struct DICOMPart10Envelope: Equatable, Sendable {
    public let transferSyntaxUID: String

    public static func validate(
        descriptor: FileHandle,
        declaredByteCount: Int
    ) throws -> DICOMPart10Envelope {
        guard declaredByteCount > 0,
              declaredByteCount <= KinlogueDICOMIPCLimits.maximumObjectBytes else {
            throw DICOMDecoderAdapterError.resourceLimit
        }
        do {
            try descriptor.seek(toOffset: 0)
            let prefix = try descriptor.read(
                upToCount: min(declaredByteCount, 132 + 12 + 64 * 1_024)
            ) ?? Data()
            try descriptor.seek(toOffset: 0)
            guard prefix.count >= 144,
                  prefix[128..<132].elementsEqual([0x44, 0x49, 0x43, 0x4d]) else {
                throw DICOMDecoderAdapterError.invalidPart10
            }
            var cursor = 132
            var transferSyntax: String?
            var groupLength: Int?
            var groupBodyStart: Int?
            while cursor < prefix.count {
                guard let group = uint16(prefix, cursor),
                      let element = uint16(prefix, cursor + 2) else {
                    throw DICOMDecoderAdapterError.invalidPart10
                }
                if group != 0x0002 { break }
                guard cursor <= prefix.count - 8 else {
                    throw DICOMDecoderAdapterError.invalidPart10
                }
                let vr = String(decoding: prefix[(cursor + 4)..<(cursor + 6)], as: UTF8.self)
                let longVR = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT"]
                    .contains(vr)
                let headerLength = longVR ? 12 : 8
                let valueLength: Int
                if longVR {
                    guard prefix[cursor + 6] == 0, prefix[cursor + 7] == 0,
                          let length = uint32(prefix, cursor + 8) else {
                        throw DICOMDecoderAdapterError.invalidPart10
                    }
                    valueLength = Int(length)
                } else {
                    guard let length = uint16(prefix, cursor + 6) else {
                        throw DICOMDecoderAdapterError.invalidPart10
                    }
                    valueLength = Int(length)
                }
                guard valueLength >= 0,
                      valueLength <= 64 * 1_024,
                      valueLength.isMultiple(of: 2),
                      cursor <= prefix.count - headerLength,
                      valueLength <= prefix.count - cursor - headerLength else {
                    throw DICOMDecoderAdapterError.invalidPart10
                }
                let valueStart = cursor + headerLength
                let valueEnd = valueStart + valueLength
                if element == 0x0000 {
                    guard vr == "UL", valueLength == 4,
                          let length = uint32(prefix, valueStart) else {
                        throw DICOMDecoderAdapterError.invalidPart10
                    }
                    groupLength = Int(length)
                    groupBodyStart = valueEnd
                } else if element == 0x0010 {
                    guard vr == "UI" else { throw DICOMDecoderAdapterError.invalidPart10 }
                    transferSyntax = String(decoding: prefix[valueStart..<valueEnd], as: UTF8.self)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
                }
                cursor = valueEnd
            }
            guard let groupLength,
                  let groupBodyStart,
                  groupLength >= 0, groupLength <= 64 * 1_024,
                  groupBodyStart <= declaredByteCount,
                  groupLength <= declaredByteCount - groupBodyStart,
                  cursor == groupBodyStart + groupLength,
                  let transferSyntax,
                  transferSyntax
                    == KinlogueDICOMSupportedObject.explicitVRLittleEndian else {
                throw DICOMDecoderAdapterError.invalidPart10
            }
            return DICOMPart10Envelope(transferSyntaxUID: transferSyntax)
        } catch let error as DICOMDecoderAdapterError {
            throw error
        } catch {
            throw DICOMDecoderAdapterError.invalidDescriptor
        }
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

public enum DICOMDecoderAdapterError: Error, Equatable, Sendable {
    case invalidDescriptor
    case invalidPart10
    case resourceLimit
    case helperUnavailable
    case helperInterrupted
    case helperTimedOut
    case invalidResponse
    case unsupportedObject
    case decoderFailed
}

public protocol DICOMDecoderTransport: Sendable {
    func decode(request: Data, descriptor: FileHandle) async throws -> Data
}

public struct DICOMDecoderAdapter: Sendable {
    private let transport: any DICOMDecoderTransport

    public init(transport: any DICOMDecoderTransport = XPCDICOMDecoderTransport()) {
        self.transport = transport
    }

    public func decode(
        descriptor: FileHandle,
        declaredByteCount: Int
    ) async throws -> KinlogueDICOMDecodedFrame {
        _ = try DICOMPart10Envelope.validate(
            descriptor: descriptor,
            declaredByteCount: declaredByteCount
        )
        let request = try KinlogueDICOMIPCCodec.encodeRequest(
            KinlogueDICOMDecodeRequest(declaredByteCount: declaredByteCount)
        )
        let reply: Data
        do {
            reply = try await transport.decode(request: request, descriptor: descriptor)
        } catch let error as DICOMDecoderAdapterError {
            throw error
        } catch {
            throw DICOMDecoderAdapterError.helperUnavailable
        }
        let response: KinlogueDICOMDecodeResponse
        do {
            response = try KinlogueDICOMIPCCodec.decodeResponse(reply)
        } catch {
            throw DICOMDecoderAdapterError.invalidResponse
        }
        switch response {
        case .success(let frame): return frame
        case .failure(let code): throw map(code)
        }
    }

    private func map(_ code: KinlogueDICOMFailureCode) -> DICOMDecoderAdapterError {
        switch code {
        case .invalidRequest, .invalidDescriptor: .invalidDescriptor
        case .invalidPart10: .invalidPart10
        case .unsupportedObject: .unsupportedObject
        case .resourceLimit: .resourceLimit
        case .decoderFailed: .decoderFailed
        case .helperUnavailable: .helperUnavailable
        case .helperInterrupted: .helperInterrupted
        case .helperTimedOut: .helperTimedOut
        case .invalidResponse: .invalidResponse
        }
    }
}

// SAFETY: Production transports store immutable configuration and every decode
// owns its connection and lock-protected reply state. The conditionally
// compiled probe transport reuses one connection only from its serial
// standalone crash scenario; `requestLock` protects its submission count and
// that initializer is not part of the public API.
public final class XPCDICOMDecoderTransport: DICOMDecoderTransport, @unchecked Sendable {
    public static let serviceName = "com.kinlogue.mac.dicom-decoder"
    private let timeoutNanoseconds: UInt64
#if KINLOGUE_DICOM_XPC_CRASH_PROBE
    private let requestSubmitted: (@Sendable (_ occurrence: Int) -> Void)?
    private let reusableConnection: NSXPCConnection?
    private let requestLock = NSLock()
    private var requestSubmissionCount = 0
#endif

    public init(timeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
#if KINLOGUE_DICOM_XPC_CRASH_PROBE
        requestSubmitted = nil
        reusableConnection = nil
#endif
    }

#if KINLOGUE_DICOM_XPC_CRASH_PROBE
    init(
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        requestSubmitted: @escaping @Sendable (_ occurrence: Int) -> Void
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.requestSubmitted = requestSubmitted
        let connection = Self.makeConnection()
        connection.resume()
        reusableConnection = connection
    }

    deinit { reusableConnection?.invalidate() }
#endif

    public func decode(request: Data, descriptor: FileHandle) async throws -> Data {
#if KINLOGUE_DICOM_XPC_CRASH_PROBE
        let connection = reusableConnection
            ?? Self.makeConnection()
        let invalidatesConnectionOnFinish = reusableConnection == nil
#else
        let connection = Self.makeConnection()
        let invalidatesConnectionOnFinish = true
#endif
        let state = XPCReplyState(
            connection: connection,
            invalidatesConnectionOnFinish: invalidatesConnectionOnFinish
        )
        connection.interruptionHandler = { state.fail(.helperInterrupted) }
        connection.invalidationHandler = { state.fail(.helperUnavailable) }
#if KINLOGUE_DICOM_XPC_CRASH_PROBE
        if invalidatesConnectionOnFinish { connection.resume() }
#else
        connection.resume()
#endif

        return try await withTaskCancellationHandler {
            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                state.fail(.helperTimedOut)
            }
            defer { timeoutTask.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    state.fail(.helperUnavailable)
                }) as? KinlogueDICOMDecoderXPCProtocol else {
                    state.fail(.helperUnavailable)
                    return
                }
                proxy.decode(request, descriptor: descriptor) { data in
                    state.succeed(data)
                }
#if KINLOGUE_DICOM_XPC_CRASH_PROBE
                let occurrence = requestLock.withLock {
                    requestSubmissionCount += 1
                    return requestSubmissionCount
                }
                requestSubmitted?(occurrence)
#endif
            }
        } onCancel: {
            state.fail(.helperInterrupted)
        }
    }

    private static func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = KinlogueDICOMXPCInterface.make()
        return connection
    }
}

// SAFETY: `lock` serializes continuation/result installation and completion;
// `finish` resumes at most once and invalidates every production-owned
// connection. Only the serial standalone crash probe retains its connection.
private final class XPCReplyState: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NSXPCConnection
    private let invalidatesConnectionOnFinish: Bool
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?

    init(
        connection: NSXPCConnection,
        invalidatesConnectionOnFinish: Bool
    ) {
        self.connection = connection
        self.invalidatesConnectionOnFinish = invalidatesConnectionOnFinish
    }

    func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func succeed(_ data: Data) { finish(.success(data)) }
    func fail(_ error: DICOMDecoderAdapterError) { finish(.failure(error)) }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if invalidatesConnectionOnFinish { connection.invalidate() }
        continuation?.resume(with: result)
    }
}
