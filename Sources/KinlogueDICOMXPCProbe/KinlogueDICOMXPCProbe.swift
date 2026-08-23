import Darwin
import Foundation
#if canImport(KinlogueDICOMTestSupport)
import KinlogueDICOMTestSupport
#endif
#if canImport(KinloguePlatform)
import KinloguePlatform
#endif

@main
struct KinlogueDICOMXPCProbe {
    private enum CrashControlMarker: String {
        case ready = "crash-ready"
        case armed = "crash-armed"
        case requestStarted = "crash-request-started"
    }

    private struct RoundTripCase {
        let fixture: Data
        let expectedSamples: Data
        let pixelRepresentation: Int
        let highBit: Int
        let photometricInterpretation: String
    }

    static func main() async {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: directory) }
            let mode = ProbeMode(
                rawValue: Bundle.main.object(forInfoDictionaryKey: "KLDProbeMode") as? String
                    ?? "roundTrip"
            ) ?? .roundTrip
            switch mode {
            case .roundTrip:
                try await verifyRoundTrips(in: directory)
                try await verifyWarmHelperAcrossIdleGap(in: directory)
                try await verifyUnsupportedVOIFunctionFailsClosed(in: directory)
                try await verifyMalformedObjectsFailClosed(in: directory)
                print("KLD_DICOM_XPC_OK")
            case .expectCrash:
                try await verifyExternalCrashIsContained(in: directory)
            case .expectWatchdog:
                try await verifyWatchdogContainsHang(in: directory)
            }
        } catch let error as DICOMDecoderAdapterError {
            print("KLD_DICOM_XPC_FAILED:\(error)")
            exit(1)
        } catch let error as ProbeFailure {
            print("KLD_DICOM_XPC_PROBE_FAILED:\(error.rawValue)")
            exit(1)
        } catch {
            print("KLD_DICOM_XPC_FAILED:unexpected")
            exit(1)
        }
    }

    private static func verifyRoundTrips(in directory: URL) async throws {
        let canary = Bundle.main.object(forInfoDictionaryKey: "KLDProbeCanary") as? String
        let cases = [
            RoundTripCase(
                fixture: GeneratedDICOMFixture.explicitVRLittleEndianMR(
                    auditCanary: canary
                ),
                expectedSamples: Data([0, 0, 64, 0, 128, 0, 255, 0]),
                pixelRepresentation: 0,
                highBit: 11,
                photometricInterpretation: "MONOCHROME2"
            ),
            RoundTripCase(
                fixture: GeneratedDICOMFixture.explicitVRLittleEndianMR(
                    photometricInterpretation: "MONOCHROME1",
                    pixelRepresentation: 1,
                    auditCanary: canary,
                    pixels: [0x0800, 0x0fff, 0x0000, 0x07ff]
                ),
                expectedSamples: Data([
                    0x00, 0x08, 0xff, 0x0f, 0x00, 0x00, 0xff, 0x07,
                ]),
                pixelRepresentation: 1,
                highBit: 11,
                photometricInterpretation: "MONOCHROME1"
            ),
            RoundTripCase(
                fixture: GeneratedDICOMFixture.explicitVRLittleEndianMR(
                    highBit: 14,
                    auditCanary: canary
                ),
                expectedSamples: Data([
                    0x00, 0x00, 0x00, 0x02, 0x00, 0x04, 0xf8, 0x07,
                ]),
                pixelRepresentation: 0,
                highBit: 14,
                photometricInterpretation: "MONOCHROME2"
            ),
            RoundTripCase(
                fixture: GeneratedDICOMFixture.explicitVRLittleEndianMR(
                    voiLUTFunction: " linear "
                ),
                expectedSamples: Data([0, 0, 64, 0, 128, 0, 255, 0]),
                pixelRepresentation: 0,
                highBit: 11,
                photometricInterpretation: "MONOCHROME2"
            ),
        ]
        for _ in 0..<12 {
            for testCase in cases {
                let frame = try await decode(testCase.fixture, in: directory)
                guard frame.rows == 2,
                      frame.columns == 2,
                      frame.pixelRepresentation == testCase.pixelRepresentation,
                      frame.highBit == testCase.highBit,
                      frame.photometricInterpretation == testCase.photometricInterpretation,
                      frame.sampleBytes == testCase.expectedSamples else {
                    throw ProbeFailure.unexpectedFrame
                }
            }
        }
    }

    private static func verifyWarmHelperAcrossIdleGap(in directory: URL) async throws {
        let fixture = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        _ = try await decode(fixture, in: directory)
        try await Task.sleep(for: .milliseconds(600))

        let start = ContinuousClock.now
        _ = try await decode(fixture, in: directory)
        guard start.duration(to: .now) < .seconds(2) else {
            throw ProbeFailure.helperRelaunchWasThrottled
        }
    }

    private static func verifyUnsupportedVOIFunctionFailsClosed(
        in directory: URL
    ) async throws {
        do {
            _ = try await decode(
                GeneratedDICOMFixture.explicitVRLittleEndianMR(
                    voiLUTFunction: "SIGMOID"
                ),
                in: directory
            )
            throw ProbeFailure.malformedObjectAccepted
        } catch let error as DICOMDecoderAdapterError {
            guard error == .unsupportedObject else {
                throw ProbeFailure.unexpectedFailureCode
            }
        }
    }

    private static func verifyMalformedObjectsFailClosed(in directory: URL) async throws {
        let original = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        var truncatedPixelData = original
        truncatedPixelData.removeLast()

        var oversizedPixelLength = original
        let pixelTag = Data([0xe0, 0x7f, 0x10, 0x00, 0x4f, 0x57, 0x00, 0x00])
        guard let tagRange = oversizedPixelLength.range(of: pixelTag),
              tagRange.upperBound <= oversizedPixelLength.count - 4 else {
            throw ProbeFailure.fixtureMutationFailed
        }
        oversizedPixelLength.replaceSubrange(
            tagRange.upperBound..<(tagRange.upperBound + 4),
            with: [0xfc, 0xff, 0xff, 0x7f]
        )

        for fixture in [truncatedPixelData, oversizedPixelLength] {
            do {
                _ = try await decode(fixture, in: directory)
                throw ProbeFailure.malformedObjectAccepted
            } catch let error as DICOMDecoderAdapterError {
                guard error == .decoderFailed || error == .unsupportedObject else {
                    throw ProbeFailure.unexpectedFailureCode
                }
            }
        }
    }

    private static func verifyExternalCrashIsContained(in directory: URL) async throws {
        let fixture = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        let controlDirectory = try crashControlDirectory()
#if KINLOGUE_DICOM_XPC_CRASH_PROBE
        let crashTransport = XPCDICOMDecoderTransport(requestSubmitted: { occurrence in
            guard occurrence == 2 else { return }
            try? createCrashControlMarker(.requestStarted, in: controlDirectory)
        })
        _ = try await decode(fixture, in: directory, transport: crashTransport)
#else
        _ = try await decode(fixture, in: directory)
#endif
        try createCrashControlMarker(.ready, in: controlDirectory)
        try await waitForCrashControlMarker(.armed, in: controlDirectory)

        let start = ContinuousClock.now
        do {
#if KINLOGUE_DICOM_XPC_CRASH_PROBE
            _ = try await decode(
                fixture,
                in: directory,
                transport: crashTransport
            )
            throw ProbeFailure.expectedFaultDidNotOccur
#else
            throw ProbeFailure.crashProbeUnavailable
#endif
        } catch let error as DICOMDecoderAdapterError {
            guard error == .helperInterrupted || error == .helperUnavailable else {
                throw ProbeFailure.unexpectedFailureCode
            }
            guard start.duration(to: .now) < .seconds(2) else {
                throw ProbeFailure.crashContainmentTimedOut
            }
        }

        let recovered = try await decode(fixture, in: directory)
        guard recovered.rows == 2,
              recovered.columns == 2,
              recovered.sampleBytes == Data([0, 0, 64, 0, 128, 0, 255, 0]) else {
            throw ProbeFailure.helperDidNotRecover
        }
        print("KLD_DICOM_XPC_CRASH_CONTAINED")
    }

    private static func crashControlDirectory() throws -> URL {
        guard let path = Bundle.main.object(
            forInfoDictionaryKey: "KLDProbeCrashControlDirectory"
        ) as? String else {
            throw ProbeFailure.invalidCrashControlDirectory
        }
        let components = (path as NSString).pathComponents
        guard components.count == 5,
              components[0] == "/",
              components[1] == "private",
              components[2] == "tmp",
              components[3].hasPrefix("kinlogue-dicom-xpc-probe."),
              components[4] == "crash-control" else {
            throw ProbeFailure.invalidCrashControlDirectory
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw ProbeFailure.invalidCrashControlDirectory
        }
        return directory
    }

    private static func createCrashControlMarker(
        _ marker: CrashControlMarker,
        in directory: URL
    ) throws {
        let path = directory.appendingPathComponent(marker.rawValue).path
        let descriptor = Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw ProbeFailure.invalidCrashControlMarker }
        guard Darwin.close(descriptor) == 0 else {
            throw ProbeFailure.invalidCrashControlMarker
        }
    }

    private static func waitForCrashControlMarker(
        _ marker: CrashControlMarker,
        in directory: URL
    ) async throws {
        let path = directory.appendingPathComponent(marker.rawValue).path
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            var metadata = stat()
            if lstat(path, &metadata) == 0 {
                guard (metadata.st_mode & S_IFMT) == S_IFREG,
                      metadata.st_uid == geteuid(),
                      metadata.st_nlink == 1,
                      metadata.st_mode & 0o077 == 0 else {
                    throw ProbeFailure.invalidCrashControlMarker
                }
                return
            }
            guard errno == ENOENT else { throw ProbeFailure.invalidCrashControlMarker }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ProbeFailure.crashControlTimedOut
    }

    private static func verifyWatchdogContainsHang(in directory: URL) async throws {
        let fixture = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        let start = ContinuousClock.now
        do {
            _ = try await decode(
                fixture,
                in: directory,
                transport: XPCDICOMDecoderTransport(timeoutNanoseconds: 3_000_000_000)
            )
            throw ProbeFailure.expectedFaultDidNotOccur
        } catch let error as DICOMDecoderAdapterError {
            guard error == .helperInterrupted || error == .helperUnavailable,
                  start.duration(to: .now) < .seconds(2) else {
                throw ProbeFailure.unexpectedFailureCode
            }
            print("KLD_DICOM_XPC_WATCHDOG_CONTAINED")
        }
    }

    private static func decode(
        _ fixture: Data,
        in directory: URL,
        transport: XPCDICOMDecoderTransport = XPCDICOMDecoderTransport()
    ) async throws -> ProbeFrame {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try fixture.write(to: file, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: file) }
        let descriptor = try FileHandle(forReadingFrom: file)
        defer { try? descriptor.close() }
        let frame = try await DICOMDecoderAdapter(transport: transport).decode(
            descriptor: descriptor,
            declaredByteCount: fixture.count
        )
        return ProbeFrame(
            rows: frame.rows,
            columns: frame.columns,
            pixelRepresentation: frame.pixelRepresentation,
            highBit: frame.highBit,
            photometricInterpretation: frame.photometricInterpretation,
            sampleBytes: frame.sampleBytes
        )
    }
}

private enum ProbeMode: String {
    case roundTrip
    case expectCrash
    case expectWatchdog
}

private enum ProbeFailure: String, Error {
    case crashContainmentTimedOut
    case crashControlTimedOut
    case crashProbeUnavailable
    case expectedFaultDidNotOccur
    case fixtureMutationFailed
    case helperDidNotRecover
    case helperRelaunchWasThrottled
    case invalidCrashControlDirectory
    case invalidCrashControlMarker
    case malformedObjectAccepted
    case unexpectedFailureCode
    case unexpectedFrame
}

private struct ProbeFrame {
    let rows: Int
    let columns: Int
    let pixelRepresentation: Int
    let highBit: Int
    let photometricInterpretation: String
    let sampleBytes: Data
}
