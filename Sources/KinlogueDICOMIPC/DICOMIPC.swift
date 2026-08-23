@preconcurrency import Foundation

public enum KinlogueDICOMIPCLimits {
    public static let protocolVersion: UInt16 = 1
    public static let maximumObjectBytes = 100 * 1_024 * 1_024
    public static let maximumDecodedSampleBytes = 128 * 1_024 * 1_024
    public static let maximumRequestBytes = 4 * 1_024
    public static let maximumResponseBytes = maximumDecodedSampleBytes + 64 * 1_024
}

public enum KinlogueDICOMSupportedObject {
    public static let explicitVRLittleEndian = "1.2.840.10008.1.2.1"
    public static let mrImageStorage = "1.2.840.10008.5.1.4.1.1.4"
    public static let modality = "MR"
}

public enum KinlogueDICOMUID {
    /// Normalizes numeric DICOM UIDs and accepts bounded legacy identifiers used by
    /// otherwise valid vendor exports. Callers must not persist the returned value.
    public static func canonicalizing(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 64 else { return nil }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        if components.allSatisfy({ component in
            !component.isEmpty && component.utf8.allSatisfy { (0x30...0x39).contains($0) }
        }) {
            return components.map { component in
                let significant = component.drop(while: { $0 == "0" })
                return significant.isEmpty ? "0" : String(significant)
            }.joined(separator: ".")
        }

        let bytes = Array(value.utf8)
        guard let first = bytes.first, let last = bytes.last,
              isASCIIAlphanumeric(first), isASCIIAlphanumeric(last),
              bytes.allSatisfy({ byte in
                  isASCIIAlphanumeric(byte) || byte == 0x2e || byte == 0x2d || byte == 0x5f
              }),
              bytes.contains(where: { isASCIIAlpha($0) || $0 == 0x2d || $0 == 0x5f }) else {
            return nil
        }
        return value
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || isASCIIAlpha(byte)
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
    }
}

public enum KinlogueDICOMOperation: String, Codable, Sendable {
    case decodeSingleFrame
}

public struct KinlogueDICOMDecodeRequest: Codable, Equatable, Sendable {
    public let version: UInt16
    public let operation: KinlogueDICOMOperation
    public let declaredByteCount: Int

    public init(
        version: UInt16 = KinlogueDICOMIPCLimits.protocolVersion,
        operation: KinlogueDICOMOperation = .decodeSingleFrame,
        declaredByteCount: Int
    ) {
        self.version = version
        self.operation = operation
        self.declaredByteCount = declaredByteCount
    }

    public func validate() throws {
        guard version == KinlogueDICOMIPCLimits.protocolVersion else {
            throw KinlogueDICOMIPCValidationError.unsupportedVersion
        }
        guard operation == .decodeSingleFrame else {
            throw KinlogueDICOMIPCValidationError.unsupportedOperation
        }
        guard declaredByteCount > 0,
              declaredByteCount <= KinlogueDICOMIPCLimits.maximumObjectBytes else {
            throw KinlogueDICOMIPCValidationError.invalidLength
        }
    }
}

public struct KinlogueDICOMDecodedFrame: Codable, Equatable, Sendable {
    public let transferSyntaxUID: String
    public let sopClassUID: String
    public let studyInstanceUID: String
    public let seriesInstanceUID: String
    public let sopInstanceUID: String
    public let modality: String
    public let instanceNumber: Int?
    public let rows: Int
    public let columns: Int
    public let samplesPerPixel: Int
    public let bitsAllocated: Int
    public let bitsStored: Int
    public let highBit: Int
    public let pixelRepresentation: Int
    public let photometricInterpretation: String
    public let numberOfFrames: Int
    public let imagePositionPatient: [Double]?
    public let imageOrientationPatient: [Double]?
    public let windowCenter: Double?
    public let windowWidth: Double?
    public let rescaleIntercept: Double
    public let rescaleSlope: Double
    public let sampleBytes: Data

    public init(
        transferSyntaxUID: String,
        sopClassUID: String,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String,
        modality: String,
        instanceNumber: Int?,
        rows: Int,
        columns: Int,
        samplesPerPixel: Int,
        bitsAllocated: Int,
        bitsStored: Int,
        highBit: Int,
        pixelRepresentation: Int,
        photometricInterpretation: String,
        numberOfFrames: Int,
        imagePositionPatient: [Double]?,
        imageOrientationPatient: [Double]?,
        windowCenter: Double?,
        windowWidth: Double?,
        rescaleIntercept: Double,
        rescaleSlope: Double,
        sampleBytes: Data
    ) {
        self.transferSyntaxUID = transferSyntaxUID
        self.sopClassUID = sopClassUID
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.sopInstanceUID = sopInstanceUID
        self.modality = modality
        self.instanceNumber = instanceNumber
        self.rows = rows
        self.columns = columns
        self.samplesPerPixel = samplesPerPixel
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.pixelRepresentation = pixelRepresentation
        self.photometricInterpretation = photometricInterpretation
        self.numberOfFrames = numberOfFrames
        self.imagePositionPatient = imagePositionPatient
        self.imageOrientationPatient = imageOrientationPatient
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.rescaleIntercept = rescaleIntercept
        self.rescaleSlope = rescaleSlope
        self.sampleBytes = sampleBytes
    }

    public func validate() throws {
        guard rows > 0, columns > 0, rows <= 8_192, columns <= 8_192,
              samplesPerPixel == 1, numberOfFrames == 1,
              bitsAllocated == 8 || bitsAllocated == 16,
              bitsStored > 0, bitsStored <= bitsAllocated,
              highBit >= bitsStored - 1, highBit < bitsAllocated,
              pixelRepresentation == 0 || pixelRepresentation == 1,
              photometricInterpretation == "MONOCHROME1"
                || photometricInterpretation == "MONOCHROME2",
              transferSyntaxUID == KinlogueDICOMSupportedObject.explicitVRLittleEndian,
              sopClassUID == KinlogueDICOMSupportedObject.mrImageStorage,
              KinlogueDICOMUID.canonicalizing(studyInstanceUID) != nil,
              KinlogueDICOMUID.canonicalizing(seriesInstanceUID) != nil,
              KinlogueDICOMUID.canonicalizing(sopInstanceUID) != nil,
              modality == KinlogueDICOMSupportedObject.modality,
              imagePositionPatient.map({
                  $0.count == 3 && $0.allSatisfy { $0.isFinite }
              }) ?? true,
              imageOrientationPatient.map({
                  $0.count == 6 && $0.allSatisfy { $0.isFinite }
              }) ?? true,
              windowCenter.map(\.isFinite) ?? true,
              windowWidth.map({ $0.isFinite && $0 >= 1 }) ?? true,
              rescaleIntercept.isFinite,
              rescaleSlope.isFinite, rescaleSlope != 0,
              sampleBytes.count <= KinlogueDICOMIPCLimits.maximumDecodedSampleBytes else {
            throw KinlogueDICOMIPCValidationError.invalidPayload
        }
        let pixels = rows.multipliedReportingOverflow(by: columns)
        guard !pixels.overflow else {
            throw KinlogueDICOMIPCValidationError.invalidPayload
        }
        let expected = pixels.partialValue.multipliedReportingOverflow(by: bitsAllocated / 8)
        guard !expected.overflow, expected.partialValue == sampleBytes.count else {
            throw KinlogueDICOMIPCValidationError.invalidPayload
        }
    }

}

public enum KinlogueDICOMFailureCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case invalidDescriptor
    case invalidPart10
    case unsupportedObject
    case resourceLimit
    case decoderFailed
    case helperUnavailable
    case helperInterrupted
    case helperTimedOut
    case invalidResponse
}

public enum KinlogueDICOMDecodeResponse: Codable, Equatable, Sendable {
    case success(KinlogueDICOMDecodedFrame)
    case failure(KinlogueDICOMFailureCode)

    private enum CodingKeys: String, CodingKey { case kind, frame, code }
    private enum Kind: String, Codable { case success, failure }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .success:
            self = .success(try container.decode(KinlogueDICOMDecodedFrame.self, forKey: .frame))
        case .failure:
            self = .failure(try container.decode(KinlogueDICOMFailureCode.self, forKey: .code))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let frame):
            try container.encode(Kind.success, forKey: .kind)
            try container.encode(frame, forKey: .frame)
        case .failure(let code):
            try container.encode(Kind.failure, forKey: .kind)
            try container.encode(code, forKey: .code)
        }
    }
}

public enum KinlogueDICOMIPCValidationError: Error, Equatable, Sendable {
    case frameTooLarge
    case invalidEncoding
    case unsupportedVersion
    case unsupportedOperation
    case invalidLength
    case invalidPayload
}

public enum KinlogueDICOMIPCCodec {
    public static func encodeRequest(_ request: KinlogueDICOMDecodeRequest) throws -> Data {
        try request.validate()
        let data = try PropertyListEncoder().encode(request)
        guard data.count <= KinlogueDICOMIPCLimits.maximumRequestBytes else {
            throw KinlogueDICOMIPCValidationError.frameTooLarge
        }
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> KinlogueDICOMDecodeRequest {
        guard !data.isEmpty, data.count <= KinlogueDICOMIPCLimits.maximumRequestBytes else {
            throw KinlogueDICOMIPCValidationError.frameTooLarge
        }
        guard let request = try? PropertyListDecoder().decode(
            KinlogueDICOMDecodeRequest.self,
            from: data
        ) else {
            throw KinlogueDICOMIPCValidationError.invalidEncoding
        }
        try request.validate()
        return request
    }

    public static func encodeResponse(_ response: KinlogueDICOMDecodeResponse) throws -> Data {
        if case .success(let frame) = response { try frame.validate() }
        let data = try PropertyListEncoder().encode(response)
        guard data.count <= KinlogueDICOMIPCLimits.maximumResponseBytes else {
            throw KinlogueDICOMIPCValidationError.frameTooLarge
        }
        return data
    }

    public static func decodeResponse(_ data: Data) throws -> KinlogueDICOMDecodeResponse {
        guard !data.isEmpty, data.count <= KinlogueDICOMIPCLimits.maximumResponseBytes else {
            throw KinlogueDICOMIPCValidationError.frameTooLarge
        }
        guard let response = try? PropertyListDecoder().decode(
            KinlogueDICOMDecodeResponse.self,
            from: data
        ) else {
            throw KinlogueDICOMIPCValidationError.invalidEncoding
        }
        if case .success(let frame) = response { try frame.validate() }
        return response
    }
}

@objc public protocol KinlogueDICOMDecoderXPCProtocol {
    func decode(
        _ request: Data,
        descriptor: FileHandle,
        reply: @escaping (Data) -> Void
    )
}

public enum KinlogueDICOMXPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: KinlogueDICOMDecoderXPCProtocol.self)
        interface.setClasses(
            NSSet(object: FileHandle.self) as! Set<AnyHashable>,
            for: #selector(KinlogueDICOMDecoderXPCProtocol.decode(_:descriptor:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        return interface
    }
}
