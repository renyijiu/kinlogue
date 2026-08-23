import Darwin
import Foundation
import KinlogueCore

enum BoundedRegularFileReader {
    static func read<OversizeError: Error>(
        descriptor: Int32,
        maximumByteCount: Int,
        oversizeError: @autoclosure () -> OversizeError,
        checksCancellation: Bool = false
    ) throws -> Data {
        if checksCancellation {
            try Task.checkCancellation()
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            throw LANInboxError.storageFailure
        }
        guard metadata.st_size <= maximumByteCount else {
            throw oversizeError()
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while offset < metadata.st_size {
            if checksCancellation {
                try Task.checkCancellation()
            }
            let requested = min(buffer.count, Int(metadata.st_size - offset))
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(descriptor, bytes.baseAddress, requested, offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw LANInboxError.storageFailure
            }
            guard count > 0 else { throw LANInboxError.storageFailure }
            data.append(contentsOf: buffer.prefix(count))
            offset += off_t(count)
        }
        return data
    }
}
