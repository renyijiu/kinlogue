import Foundation
import KinlogueDICOMIPC
import KinlogueDICOMTestSupport
import Testing
@testable import KinloguePlatform

struct DICOMDecoderAdapterTests {
    @Test
    func ipcCodecRoundTripsBoundedTypedFrames() throws {
        let request = KinlogueDICOMDecodeRequest(declaredByteCount: 512)
        let requestData = try KinlogueDICOMIPCCodec.encodeRequest(request)
        #expect(try KinlogueDICOMIPCCodec.decodeRequest(requestData) == request)

        let response = KinlogueDICOMDecodeResponse.success(frame())
        let responseData = try KinlogueDICOMIPCCodec.encodeResponse(response)
        #expect(try KinlogueDICOMIPCCodec.decodeResponse(responseData) == response)
    }

    @Test
    func ipcCodecRejectsInvalidVersionLengthTypeAndFraming() throws {
        #expect(throws: KinlogueDICOMIPCValidationError.unsupportedVersion) {
            try KinlogueDICOMIPCCodec.encodeRequest(
                KinlogueDICOMDecodeRequest(version: 2, declaredByteCount: 512)
            )
        }
        #expect(throws: KinlogueDICOMIPCValidationError.invalidLength) {
            try KinlogueDICOMIPCCodec.encodeRequest(
                KinlogueDICOMDecodeRequest(declaredByteCount: 0)
            )
        }
        #expect(throws: KinlogueDICOMIPCValidationError.frameTooLarge) {
            try KinlogueDICOMIPCCodec.decodeRequest(
                Data(count: KinlogueDICOMIPCLimits.maximumRequestBytes + 1)
            )
        }
        #expect(throws: KinlogueDICOMIPCValidationError.invalidEncoding) {
            try KinlogueDICOMIPCCodec.decodeResponse(Data([0xde, 0xad]))
        }
        #expect(throws: KinlogueDICOMIPCValidationError.frameTooLarge) {
            try KinlogueDICOMIPCCodec.decodeResponse(
                Data(count: KinlogueDICOMIPCLimits.maximumResponseBytes + 1)
            )
        }

        let shiftedHighBit = frame(highBit: 14)
        #expect(try KinlogueDICOMIPCCodec.decodeResponse(
            KinlogueDICOMIPCCodec.encodeResponse(.success(shiftedHighBit))
        ) == .success(shiftedHighBit))

        let invalidHighBit = frame(highBit: 16)
        #expect(throws: KinlogueDICOMIPCValidationError.invalidPayload) {
            try KinlogueDICOMIPCCodec.encodeResponse(.success(invalidHighBit))
        }

        let oversizedUID = frame(
            highBit: 11,
            studyInstanceUID: String(repeating: "1", count: 65)
        )
        #expect(throws: KinlogueDICOMIPCValidationError.invalidPayload) {
            try KinlogueDICOMIPCCodec.encodeResponse(.success(oversizedUID))
        }
        let malformedUID = frame(studyInstanceUID: "2.025/invalid")
        #expect(throws: KinlogueDICOMIPCValidationError.invalidPayload) {
            try KinlogueDICOMIPCCodec.encodeResponse(.success(malformedUID))
        }
        #expect(throws: KinlogueDICOMIPCValidationError.invalidPayload) {
            try KinlogueDICOMIPCCodec.encodeResponse(
                .success(frame(windowWidth: 0.5))
            )
        }
    }

    @Test
    func ipcCodecAcceptsCanonicalizableLeadingZeroUIDComponents() throws {
        let leadingZeroUID = frame(studyInstanceUID: "2.25.01001")

        let encoded = try KinlogueDICOMIPCCodec.encodeResponse(.success(leadingZeroUID))

        #expect(try KinlogueDICOMIPCCodec.decodeResponse(encoded) == .success(leadingZeroUID))
    }

    @Test
    func ipcCodecAcceptsBoundedVendorStudyIdentifiers() throws {
        let vendorIdentifier = frame(studyInstanceUID: "VENDOR_STUDY-01")

        let encoded = try KinlogueDICOMIPCCodec.encodeResponse(.success(vendorIdentifier))

        #expect(try KinlogueDICOMIPCCodec.decodeResponse(encoded) == .success(vendorIdentifier))
    }

    @Test
    func part10EnvelopeAcceptsGeneratedExplicitVRLittleEndianMR() throws {
        let fixture = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        try withReadOnlyDescriptor(fixture) { descriptor in
            let envelope = try DICOMPart10Envelope.validate(
                descriptor: descriptor,
                declaredByteCount: fixture.count
            )
            #expect(!envelope.transferSyntaxUID.isEmpty)
            #expect(try descriptor.offset() == 0)
        }
    }

    @Test
    func part10EnvelopeRejectsCorruptTruncatedAndOversizedObjects() throws {
        var corrupt = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        corrupt[128] = 0
        _ = try withReadOnlyDescriptor(corrupt) { descriptor in
            #expect(throws: DICOMDecoderAdapterError.invalidPart10) {
                try DICOMPart10Envelope.validate(
                    descriptor: descriptor,
                    declaredByteCount: corrupt.count
                )
            }
        }

        let truncated = Data(GeneratedDICOMFixture.explicitVRLittleEndianMR().prefix(140))
        _ = try withReadOnlyDescriptor(truncated) { descriptor in
            #expect(throws: DICOMDecoderAdapterError.invalidPart10) {
                try DICOMPart10Envelope.validate(
                    descriptor: descriptor,
                    declaredByteCount: truncated.count
                )
            }
        }

        var inconsistentGroupLength = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        inconsistentGroupLength.replaceSubrange(140..<144, with: [0, 0, 0, 0])
        _ = try withReadOnlyDescriptor(inconsistentGroupLength) { descriptor in
            #expect(throws: DICOMDecoderAdapterError.invalidPart10) {
                try DICOMPart10Envelope.validate(
                    descriptor: descriptor,
                    declaredByteCount: inconsistentGroupLength.count
                )
            }
        }

        let empty = Data()
        _ = try withReadOnlyDescriptor(empty) { descriptor in
            #expect(throws: DICOMDecoderAdapterError.resourceLimit) {
                try DICOMPart10Envelope.validate(
                    descriptor: descriptor,
                    declaredByteCount: KinlogueDICOMIPCLimits.maximumObjectBytes + 1
                )
            }
        }
    }

    @Test
    func adapterReturnsOnlyValidatedKinlogueFrame() async throws {
        let fixture = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        let transport = StubTransport(result: .success(
            try KinlogueDICOMIPCCodec.encodeResponse(.success(frame()))
        ))
        let adapter = DICOMDecoderAdapter(transport: transport)
        let decoded = try await withReadOnlyDescriptor(fixture) { descriptor in
            try await adapter.decode(
                descriptor: descriptor,
                declaredByteCount: fixture.count
            )
        }

        #expect(decoded.rows == 2)
        #expect(decoded.columns == 2)
        #expect(decoded.sampleBytes.count == 8)
        #expect(await transport.callCount == 1)
    }

    @Test(arguments: [
        DICOMDecoderAdapterError.helperInterrupted,
        .helperTimedOut,
        .helperUnavailable,
    ])
    func helperFailureNeverFallsBackInProcess(
        expected: DICOMDecoderAdapterError
    ) async throws {
        let fixture = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        let transport = StubTransport(result: .failure(expected))
        let adapter = DICOMDecoderAdapter(transport: transport)

        await #expect(throws: expected) {
            try await withReadOnlyDescriptor(fixture) { descriptor in
                try await adapter.decode(
                    descriptor: descriptor,
                    declaredByteCount: fixture.count
                )
            }
        }
        #expect(await transport.callCount == 1)
    }

    @Test
    func malformedHelperReplyFailsClosed() async throws {
        let fixture = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        let transport = StubTransport(result: .success(Data([0xde, 0xad])))
        let adapter = DICOMDecoderAdapter(transport: transport)

        await #expect(throws: DICOMDecoderAdapterError.invalidResponse) {
            try await withReadOnlyDescriptor(fixture) { descriptor in
                try await adapter.decode(
                    descriptor: descriptor,
                    declaredByteCount: fixture.count
                )
            }
        }
    }

    @Test
    func subUnitWindowWidthFromHelperIsAnInvalidResponse() async throws {
        let fixture = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        let invalidReply = try PropertyListEncoder().encode(
            KinlogueDICOMDecodeResponse.success(frame(windowWidth: 0.5))
        )
        let adapter = DICOMDecoderAdapter(
            transport: StubTransport(result: .success(invalidReply))
        )

        await #expect(throws: DICOMDecoderAdapterError.invalidResponse) {
            try await withReadOnlyDescriptor(fixture) { descriptor in
                try await adapter.decode(
                    descriptor: descriptor,
                    declaredByteCount: fixture.count
                )
            }
        }
    }

    private func frame(
        highBit: Int = 11,
        studyInstanceUID: String = "2.25.1001",
        windowWidth: Double = 256
    ) -> KinlogueDICOMDecodedFrame {
        KinlogueDICOMDecodedFrame(
            transferSyntaxUID: KinlogueDICOMSupportedObject.explicitVRLittleEndian,
            sopClassUID: KinlogueDICOMSupportedObject.mrImageStorage,
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: "2.25.1002",
            sopInstanceUID: "2.25.1003",
            modality: KinlogueDICOMSupportedObject.modality,
            instanceNumber: 1,
            rows: 2,
            columns: 2,
            samplesPerPixel: 1,
            bitsAllocated: 16,
            bitsStored: 12,
            highBit: highBit,
            pixelRepresentation: 0,
            photometricInterpretation: "MONOCHROME2",
            numberOfFrames: 1,
            imagePositionPatient: [0, 0, 0],
            imageOrientationPatient: [1, 0, 0, 0, 1, 0],
            windowCenter: 128,
            windowWidth: windowWidth,
            rescaleIntercept: 0,
            rescaleSlope: 1,
            sampleBytes: Data([0, 0, 64, 0, 128, 0, 255, 0])
        )
    }

    private func withReadOnlyDescriptor<T>(
        _ data: Data,
        operation: (FileHandle) async throws -> T
    ) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = try FileHandle(forReadingFrom: url)
        defer { try? descriptor.close() }
        return try await operation(descriptor)
    }

    private func withReadOnlyDescriptor<T>(
        _ data: Data,
        operation: (FileHandle) throws -> T
    ) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = try FileHandle(forReadingFrom: url)
        defer { try? descriptor.close() }
        return try operation(descriptor)
    }
}

private actor StubTransport: DICOMDecoderTransport {
    private let result: Result<Data, DICOMDecoderAdapterError>
    private(set) var callCount = 0

    init(result: Result<Data, DICOMDecoderAdapterError>) { self.result = result }

    func decode(request: Data, descriptor: FileHandle) async throws -> Data {
        callCount += 1
        return try result.get()
    }
}
