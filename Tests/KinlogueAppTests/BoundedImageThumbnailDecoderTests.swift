import Darwin
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import KinlogueApp

struct BoundedImageThumbnailDecoderTests {
    @Test
    func boundsLongestEdgeWithoutChangingAspectRatio() async throws {
        let data = try syntheticPNG(width: 80, height: 20)

        let thumbnail = try #require(await BoundedImageThumbnailDecoder.decode(
            data: data,
            maximumPixelSize: 40
        ))

        #expect(thumbnail.cgImage.width == 40)
        #expect(thumbnail.cgImage.height == 10)
    }

    @Test
    func invalidImageReturnsNil() async {
        let thumbnail = await BoundedImageThumbnailDecoder.decode(
            data: Data("not an image".utf8),
            maximumPixelSize: 40
        )

        #expect(thumbnail == nil)
    }

    @Test
    func requestCancelledBeforeDecodeReturnsNil() async throws {
        let data = try syntheticPNG(width: 8, height: 8)
        let task = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return await BoundedImageThumbnailDecoder.decode(
                data: data,
                maximumPixelSize: 40
            )
        }

        #expect(await task.value == nil)
    }

    @Test
    func decoderAllowsOnlyOneImageOperationAtATime() async {
        let requestCount = 32
        let probe = DecodeConcurrencyProbe()
        let decoder = BoundedImageThumbnailDecoder(operation: probe.decode)
        let startGate = AsyncStartGate(expectedWaiterCount: requestCount)
        let tasks = (0..<requestCount).map { _ in
            Task {
                await startGate.wait()
                return await decoder.decode(data: Data(), maximumPixelSize: 40)
            }
        }

        await startGate.waitUntilReady()
        await startGate.open()
        for task in tasks { _ = await task.value }

        #expect(probe.operationCount == requestCount)
        #expect(probe.maximumConcurrentCount == 1)
    }

    @Test
    func cancellationDuringImageOperationDiscardsItsResult() async throws {
        let thumbnail = try syntheticThumbnail()
        let decoder = BoundedImageThumbnailDecoder { _, _ in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return thumbnail
        }

        let task = Task {
            await decoder.decode(data: Data(), maximumPixelSize: 40)
        }
        let result = await task.value

        #expect(result == nil)
    }

    private func syntheticPNG(width: Int, height: Int) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw TestImageError.creationFailed
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw TestImageError.creationFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.creationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.creationFailed
        }
        return output as Data
    }

    private func syntheticThumbnail() throws -> BoundedImageThumbnail {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let image = context.makeImage() else {
            throw TestImageError.creationFailed
        }
        return BoundedImageThumbnail(cgImage: image)
    }
}

private actor AsyncStartGate {
    private let expectedWaiterCount: Int
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var readinessWaiters: [CheckedContinuation<Void, Never>] = []

    init(expectedWaiterCount: Int) {
        self.expectedWaiterCount = expectedWaiterCount
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            guard !isOpen else {
                continuation.resume()
                return
            }
            waiters.append(continuation)
            if waiters.count == expectedWaiterCount {
                let continuations = readinessWaiters
                readinessWaiters.removeAll()
                continuations.forEach { $0.resume() }
            }
        }
    }

    func waitUntilReady() async {
        guard waiters.count < expectedWaiterCount else { return }
        await withCheckedContinuation { continuation in
            readinessWaiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private final class DecodeConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var maximumCount = 0
    private var count = 0

    func decode(data _: Data, maximumPixelSize _: Int) -> BoundedImageThumbnail? {
        lock.lock()
        activeCount += 1
        count += 1
        maximumCount = max(maximumCount, activeCount)
        lock.unlock()
        for _ in 0..<64 { Darwin.sched_yield() }
        lock.lock()
        activeCount -= 1
        lock.unlock()
        return nil
    }

    var maximumConcurrentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumCount
    }

    var operationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private enum TestImageError: Error {
    case creationFailed
}
