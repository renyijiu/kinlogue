import Darwin
import Foundation
import KinlogueCore
import NIOCore
import NIOPosix

enum LANFileWriteSupport {
    enum Chunk: Sendable {
        case data(Data)
        case byteBuffer(ByteBuffer)

        var byteCount: Int {
            switch self {
            case .data(let data):
                data.count
            case .byteBuffer(let buffer):
                buffer.readableBytes
            }
        }

        func withUnsafeReadableBytes<Result>(
            _ body: (UnsafeRawBufferPointer) throws -> Result
        ) rethrows -> Result {
            switch self {
            case .data(let data):
                try data.withUnsafeBytes(body)
            case .byteBuffer(let buffer):
                try buffer.withUnsafeReadableBytes(body)
            }
        }
    }

    struct POSIXFailure: Error, Sendable {
        let code: Int32
    }

    static func validateEmptyOwnedDescriptor(_ descriptor: Int32) throws {
        guard descriptor >= 0 else { throw LANInboxError.invalidState }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              (metadata.st_mode & 0o777) == (S_IRUSR | S_IWUSR),
              metadata.st_size == 0,
              lseek(descriptor, 0, SEEK_CUR) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw LANInboxError.invalidState
        }

        let statusFlags = fcntl(descriptor, F_GETFL)
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard statusFlags >= 0,
              descriptorFlags >= 0,
              (statusFlags & O_ACCMODE) != O_RDONLY,
              (statusFlags & O_APPEND) == 0,
              (descriptorFlags & FD_CLOEXEC) != 0 else {
            throw LANInboxError.invalidState
        }
    }

    static func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw LANInboxError.arithmeticOverflow }
        return sum
    }

    static func writeAll(
        _ chunk: Chunk,
        to descriptor: Int32,
        maximumWriteByteCount: Int,
        beforeWrite: () throws -> Void,
        afterWrite: () throws -> Void
    ) throws {
        try chunk.withUnsafeReadableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                try beforeWrite()
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    min(rawBuffer.count - written, maximumWriteByteCount)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXFailure(code: errno)
                }
                guard count > 0 else { throw POSIXFailure(code: EIO) }
                written += count
                try afterWrite()
            }
        }
    }

    static func mappedStorageError(_ error: Error) -> Error {
        if error is POSIXFailure || error is NIOThreadPoolError.ThreadPoolInactive {
            return LANInboxError.storageFailure
        }
        return error
    }
}
