import Darwin
import DicomCore
@preconcurrency import Foundation
#if canImport(KinlogueDICOMIPC)
import KinlogueDICOMIPC
#endif

private final class DICOMDecoderService: NSObject, KinlogueDICOMDecoderXPCProtocol {
    func decode(
        _ requestData: Data,
        descriptor: FileHandle,
        reply: @escaping (Data) -> Void
    ) {
        let requestTicket = DICOMDecoderProcessLifecycle.beginRequest()
#if KINLOGUE_DICOM_XPC_TEST_HANG
        while true { _ = Darwin.pause() }
#endif
        let response = autoreleasepool {
            decodeRequest(requestData, descriptor: descriptor)
        }
        let encoded = (try? KinlogueDICOMIPCCodec.encodeResponse(response))
            ?? fallback(.invalidResponse)
        reply(encoded)
        DICOMDecoderProcessLifecycle.completeRequest(requestTicket)
    }

    private func decodeRequest(
        _ requestData: Data,
        descriptor: FileHandle
    ) -> KinlogueDICOMDecodeResponse {
        guard let request = try? KinlogueDICOMIPCCodec.decodeRequest(requestData) else {
            return .failure(.invalidRequest)
        }
        guard fcntl(descriptor.fileDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY else {
            return .failure(.invalidDescriptor)
        }

        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: directory) }
            guard fileManager.createFile(
                atPath: file.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                return .failure(.helperUnavailable)
            }
            do {
                let output = try FileHandle(forWritingTo: file)
                defer { try? output.close() }
                try descriptor.seek(toOffset: 0)
                var copied = 0
                while copied < request.declaredByteCount {
                    let remaining = request.declaredByteCount - copied
                    let chunk = try descriptor.read(
                        upToCount: min(remaining, 1_024 * 1_024)
                    ) ?? Data()
                    guard !chunk.isEmpty else { return .failure(.invalidDescriptor) }
                    copied += chunk.count
                    guard copied <= request.declaredByteCount else {
                        return .failure(.invalidDescriptor)
                    }
                    try output.write(contentsOf: chunk)
                }
                guard (try descriptor.read(upToCount: 1) ?? Data()).isEmpty else {
                    return .failure(.invalidDescriptor)
                }
            }

            let decoder = try DCMDecoder(contentsOf: file)
            let transferSyntaxUID = decoder.info(for: .transferSyntaxUID)
            let sopClassUID = decoder.info(for: .sopClassUID)
            let studyInstanceUID = decoder.info(for: .studyInstanceUID)
            let seriesInstanceUID = decoder.info(for: .seriesInstanceUID)
            let sopInstanceUID = decoder.info(for: .sopInstanceUID)
            let modality = decoder.info(for: .modality)
            let voiLUTFunction = decoder.info(for: 0x00281056)
            guard transferSyntaxUID == KinlogueDICOMSupportedObject.explicitVRLittleEndian,
                  sopClassUID == KinlogueDICOMSupportedObject.mrImageStorage,
                  !studyInstanceUID.isEmpty,
                  !seriesInstanceUID.isEmpty,
                  !sopInstanceUID.isEmpty,
                  modality == KinlogueDICOMSupportedObject.modality,
                  supportsLinearVOILUTFunction(voiLUTFunction),
                  decoder.nImages == 1,
                  decoder.samplesPerPixel == 1,
                  decoder.photometricInterpretation == "MONOCHROME1"
                    || decoder.photometricInterpretation == "MONOCHROME2" else {
                return .failure(.unsupportedObject)
            }
            let bitsAllocated = decoder.intValue(for: .bitsAllocated) ?? decoder.bitDepth
            let bitsStored = decoder.intValue(for: .bitsStored) ?? bitsAllocated
            let highBit = decoder.intValue(for: .highBit) ?? (bitsStored - 1)
            guard decoder.height > 0, decoder.width > 0,
                  decoder.height <= 8_192, decoder.width <= 8_192,
                  bitsAllocated == 8 || bitsAllocated == 16,
                  bitsStored > 0, bitsStored <= bitsAllocated,
                  highBit >= bitsStored - 1, highBit < bitsAllocated else {
                return .failure(.unsupportedObject)
            }
            let pixelCount = decoder.height.multipliedReportingOverflow(by: decoder.width)
            guard !pixelCount.overflow else { return .failure(.resourceLimit) }
            let expectedBytes = pixelCount.partialValue.multipliedReportingOverflow(
                by: bitsAllocated / 8
            )
            guard !expectedBytes.overflow,
                  expectedBytes.partialValue
                    <= KinlogueDICOMIPCLimits.maximumDecodedSampleBytes else {
                return .failure(.resourceLimit)
            }
            // getPixels8/getPixels16 perform presentation work for signed and
            // MONOCHROME1 images. Kinlogue owns those transforms, so preserve
            // the native Explicit-VR-LE frame bytes instead.
            guard validateNativePixelElement(
                      in: file,
                      valueOffset: decoder.offset,
                      expectedByteCount: expectedBytes.partialValue,
                      bitsAllocated: bitsAllocated
                  ),
                  let nativeFrame = decoder.getFrame(0),
                  nativeFrame.descriptor.rows == decoder.height,
                  nativeFrame.descriptor.columns == decoder.width,
                  nativeFrame.descriptor.numberOfFrames == 1,
                  nativeFrame.descriptor.bitsAllocated == bitsAllocated,
                  nativeFrame.descriptor.bitsStored == bitsStored,
                  nativeFrame.descriptor.highBit == highBit,
                  nativeFrame.descriptor.pixelRepresentation
                    == decoder.pixelRepresentationTagValue,
                  nativeFrame.descriptor.samplesPerPixel == 1,
                  nativeFrame.descriptor.photometricInterpretation
                    == decoder.photometricInterpretation,
                  nativeFrame.data.count == expectedBytes.partialValue else {
                return .failure(.decoderFailed)
            }
            let samples = nativeFrame.data
            let frame = KinlogueDICOMDecodedFrame(
                transferSyntaxUID: transferSyntaxUID,
                sopClassUID: sopClassUID,
                studyInstanceUID: studyInstanceUID,
                seriesInstanceUID: seriesInstanceUID,
                sopInstanceUID: sopInstanceUID,
                modality: modality,
                instanceNumber: decoder.intValue(for: .instanceNumber),
                rows: decoder.height,
                columns: decoder.width,
                samplesPerPixel: decoder.samplesPerPixel,
                bitsAllocated: bitsAllocated,
                bitsStored: bitsStored,
                highBit: highBit,
                pixelRepresentation: decoder.pixelRepresentationTagValue,
                photometricInterpretation: decoder.photometricInterpretation,
                numberOfFrames: decoder.nImages,
                imagePositionPatient: decimalValues(decoder.info(for: .imagePositionPatient)),
                imageOrientationPatient: decimalValues(decoder.info(for: .imageOrientationPatient)),
                windowCenter: decoder.doubleValue(for: .windowCenter),
                windowWidth: decoder.doubleValue(for: .windowWidth),
                rescaleIntercept: decoder.doubleValue(for: .rescaleIntercept) ?? 0,
                rescaleSlope: decoder.doubleValue(for: .rescaleSlope) ?? 1,
                sampleBytes: samples
            )
            try frame.validate()
            return .success(frame)
        } catch {
            return .failure(.decoderFailed)
        }
    }

    private func decimalValues(_ value: String) -> [Double]? {
        let values = value.split(separator: "\\").compactMap { Double($0) }
        return values.isEmpty ? nil : values
    }

    private func supportsLinearVOILUTFunction(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return normalized.isEmpty || normalized == "LINEAR"
    }

    private func validateNativePixelElement(
        in file: URL,
        valueOffset: Int,
        expectedByteCount: Int,
        bitsAllocated: Int
    ) -> Bool {
        guard valueOffset >= 12 else { return false }
        do {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(valueOffset - 12))
            let header = try input.read(upToCount: 12) ?? Data()
            guard header.count == 12,
                  header[0..<4].elementsEqual([0xe0, 0x7f, 0x10, 0x00]),
                  header[6] == 0, header[7] == 0,
                  (header[4..<6].elementsEqual([0x4f, 0x57])
                    || (bitsAllocated == 8
                      && header[4..<6].elementsEqual([0x4f, 0x42]))) else {
                return false
            }
            let declaredLength = UInt32(header[8])
                | UInt32(header[9]) << 8
                | UInt32(header[10]) << 16
                | UInt32(header[11]) << 24
            return declaredLength == UInt32(expectedByteCount)
        } catch {
            return false
        }
    }

    private func fallback(_ code: KinlogueDICOMFailureCode) -> Data {
        (try? KinlogueDICOMIPCCodec.encodeResponse(.failure(code)))
            ?? Data([0])
    }
}

/// A decoder call is synchronous inside exact upstream code, so cancellation
/// cannot unwind a parser that has stopped making progress. Keep that failure
/// inside the XPC boundary by terminating the Helper at a fixed hard deadline.
/// Successful requests leave normal XPC process lifetime management to macOS;
/// manually exiting an idle service causes launchd to throttle rapid relaunches.
private enum DICOMDecoderProcessLifecycle {
    struct Ticket: Hashable { fileprivate let id = UUID() }

    private static let lock = NSLock()
    // SAFETY: `lock` protects both static collections; every read and mutation
    // in request/watchdog lifecycle methods occurs while holding it.
    nonisolated(unsafe) private static var activeTickets: Set<Ticket> = []
    nonisolated(unsafe) private static var watchdogs: [Ticket: DispatchWorkItem] = [:]

#if KINLOGUE_DICOM_XPC_TEST_HANG
    private static let hardDeadline: DispatchTimeInterval = .milliseconds(750)
#else
    private static let hardDeadline: DispatchTimeInterval = .seconds(9)
#endif

    static func beginRequest() -> Ticket {
        let ticket = Ticket()
        let watchdog = DispatchWorkItem {
            lock.lock()
            let exceededDeadline = activeTickets.contains(ticket)
            lock.unlock()
            if exceededDeadline { Darwin._exit(124) }
        }
        lock.lock()
        activeTickets.insert(ticket)
        watchdogs[ticket] = watchdog
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + hardDeadline,
            execute: watchdog
        )
        return ticket
    }

    static func completeRequest(_ ticket: Ticket) {
        lock.lock()
        activeTickets.remove(ticket)
        let watchdog = watchdogs.removeValue(forKey: ticket)
        lock.unlock()
        watchdog?.cancel()
    }
}

private final class DICOMDecoderServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = KinlogueDICOMXPCInterface.make()
        connection.exportedObject = DICOMDecoderService()
        connection.resume()
        return true
    }
}

@main
private enum KinlogueDICOMDecoderHelperMain {
    static func main() {
        let delegate = DICOMDecoderServiceDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
