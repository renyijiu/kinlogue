import Foundation
#if canImport(KinlogueDICOMIPC)
import KinlogueDICOMIPC
#endif

public enum GeneratedDICOMFixture {
    public static func explicitVRLittleEndianMR(
        rows: UInt16 = 2,
        columns: UInt16 = 2,
        photometricInterpretation: String = "MONOCHROME2",
        bitsStored: UInt16 = 12,
        highBit: UInt16 = 11,
        pixelRepresentation: UInt16 = 0,
        auditCanary: String? = nil,
        studyInstanceUID: String = "2.25.8822",
        seriesInstanceUID: String = "2.25.8823",
        sopInstanceUID: String = "2.25.8824",
        sopClassUID: String = KinlogueDICOMSupportedObject.mrImageStorage,
        modality: String = KinlogueDICOMSupportedObject.modality,
        numberOfFrames: Int = 1,
        voiLUTFunction: String? = nil,
        instanceNumber: Int = 1,
        preStudyUndefinedLengthSequence: Bool = false,
        imagePositionPatient: String? = "0\\0\\0",
        imageOrientationPatient: String? = "1\\0\\0\\0\\1\\0",
        pixels: [UInt16] = [0, 64, 128, 255]
    ) -> Data {
        precondition(pixels.count == Int(rows) * Int(columns))
        precondition(
            photometricInterpretation == "MONOCHROME1"
                || photometricInterpretation == "MONOCHROME2"
        )
        precondition(bitsStored > 0 && highBit >= bitsStored - 1 && highBit < 16)
        let sopClass = sopClassUID
        let transferSyntax = KinlogueDICOMSupportedObject.explicitVRLittleEndian
        let implementation = uid([2, 25, 8_821])
        let study = studyInstanceUID
        let series = seriesInstanceUID
        let instance = sopInstanceUID

        var metaBody = Data()
        metaBody.append(element(0x0002, 0x0001, "OB", Data([0, 1])))
        metaBody.append(element(0x0002, 0x0002, "UI", text(sopClass, nul: true)))
        metaBody.append(element(0x0002, 0x0003, "UI", text(instance, nul: true)))
        metaBody.append(element(0x0002, 0x0010, "UI", text(transferSyntax, nul: true)))
        metaBody.append(element(0x0002, 0x0012, "UI", text(implementation, nul: true)))

        var output = Data(repeating: 0, count: 128)
        output.append(contentsOf: [0x44, 0x49, 0x43, 0x4d])
        output.append(element(0x0002, 0x0000, "UL", littleEndian(UInt32(metaBody.count))))
        output.append(metaBody)
        output.append(element(0x0008, 0x0016, "UI", text(sopClass, nul: true)))
        output.append(element(0x0008, 0x0018, "UI", text(instance, nul: true)))
        output.append(element(
            0x0008,
            0x0060,
            "CS",
            text(modality)
        ))
        if preStudyUndefinedLengthSequence {
            output.append(undefinedLengthSequence())
        }
        if let auditCanary {
            output.append(element(0x0008, 0x103e, "LO", text(auditCanary)))
            output.append(element(
                0x0028,
                0x7fe0,
                "UR",
                text("http://127.0.0.1:9/\(auditCanary)")
            ))
        }
        output.append(element(0x0020, 0x000d, "UI", text(study, nul: true)))
        output.append(element(0x0020, 0x000e, "UI", text(series, nul: true)))
        output.append(element(0x0020, 0x0013, "IS", text(String(instanceNumber))))
        if let imagePositionPatient {
            output.append(element(0x0020, 0x0032, "DS", text(imagePositionPatient)))
        }
        if let imageOrientationPatient {
            output.append(element(0x0020, 0x0037, "DS", text(imageOrientationPatient)))
        }
        output.append(element(0x0028, 0x0002, "US", littleEndian(UInt16(1))))
        output.append(element(0x0028, 0x0004, "CS", text(photometricInterpretation)))
        output.append(element(0x0028, 0x0008, "IS", text(String(numberOfFrames))))
        output.append(element(0x0028, 0x0010, "US", littleEndian(rows)))
        output.append(element(0x0028, 0x0011, "US", littleEndian(columns)))
        output.append(element(0x0028, 0x0100, "US", littleEndian(UInt16(16))))
        output.append(element(0x0028, 0x0101, "US", littleEndian(bitsStored)))
        output.append(element(0x0028, 0x0102, "US", littleEndian(highBit)))
        output.append(element(0x0028, 0x0103, "US", littleEndian(pixelRepresentation)))
        output.append(element(0x0028, 0x1050, "DS", text("128")))
        output.append(element(0x0028, 0x1051, "DS", text("256")))
        output.append(element(0x0028, 0x1052, "DS", text("0")))
        output.append(element(0x0028, 0x1053, "DS", text("1")))
        if let voiLUTFunction {
            output.append(element(0x0028, 0x1056, "CS", text(voiLUTFunction)))
        }
        output.append(element(
            0x7fe0,
            0x0010,
            "OW",
            Data(pixels.flatMap {
                Array(littleEndian($0 << (highBit - (bitsStored - 1))))
            })
        ))
        return output
    }

    public static func explicitVRLittleEndianInertObject(
        studyInstanceUID: String = "2.25.8822",
        seriesInstanceUID: String = "2.25.8825",
        sopInstanceUID: String = "2.25.8826"
    ) -> Data {
        let sopClass = "1.2.840.10008.5.1.4.1.1.88.33"
        let transferSyntax = KinlogueDICOMSupportedObject.explicitVRLittleEndian
        let implementation = uid([2, 25, 8_821])
        let study = studyInstanceUID
        let series = seriesInstanceUID
        let instance = sopInstanceUID

        var metaBody = Data()
        metaBody.append(element(0x0002, 0x0001, "OB", Data([0, 1])))
        metaBody.append(element(0x0002, 0x0002, "UI", text(sopClass, nul: true)))
        metaBody.append(element(0x0002, 0x0003, "UI", text(instance, nul: true)))
        metaBody.append(element(0x0002, 0x0010, "UI", text(transferSyntax, nul: true)))
        metaBody.append(element(0x0002, 0x0012, "UI", text(implementation, nul: true)))

        var output = Data(repeating: 0, count: 128)
        output.append(contentsOf: [0x44, 0x49, 0x43, 0x4d])
        output.append(element(0x0002, 0x0000, "UL", littleEndian(UInt32(metaBody.count))))
        output.append(metaBody)
        output.append(element(0x0008, 0x0016, "UI", text(sopClass, nul: true)))
        output.append(element(0x0008, 0x0018, "UI", text(instance, nul: true)))
        output.append(element(0x0008, 0x0060, "CS", text("SR")))
        output.append(element(0x0020, 0x000d, "UI", text(study, nul: true)))
        output.append(element(0x0020, 0x000e, "UI", text(series, nul: true)))
        output.append(contentsOf: [
            0x40, 0x00, 0x30, 0xa7, 0x53, 0x51, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff,
            0xfe, 0xff, 0xdd, 0xe0, 0x00, 0x00, 0x00, 0x00,
        ])
        return output
    }

    private static func uid(_ components: [Int]) -> String {
        components.map(String.init).joined(separator: ".")
    }

    private static func undefinedLengthSequence() -> Data {
        var data = Data([
            0x08, 0x00, 0x50, 0x12, 0x53, 0x51, 0x00, 0x00,
            0xff, 0xff, 0xff, 0xff,
            0xfe, 0xff, 0x00, 0xe0, 0xff, 0xff, 0xff, 0xff,
        ])
        data.append(element(0x0008, 0x1150, "UI", text("1.2.3", nul: true)))
        data.append(contentsOf: [
            0xfe, 0xff, 0x0d, 0xe0, 0x00, 0x00, 0x00, 0x00,
            0xfe, 0xff, 0xdd, 0xe0, 0x00, 0x00, 0x00, 0x00,
        ])
        return data
    }

    private static func text(_ value: String, nul: Bool = false) -> Data {
        var data = Data(value.utf8)
        if data.count.isMultiple(of: 2) { return data }
        data.append(nul ? 0 : 0x20)
        return data
    }

    private static func element(
        _ group: UInt16,
        _ tag: UInt16,
        _ vr: String,
        _ value: Data
    ) -> Data {
        var data = Data()
        data.append(littleEndian(group))
        data.append(littleEndian(tag))
        data.append(contentsOf: vr.utf8)
        if ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UN", "UR", "UT"].contains(vr) {
            data.append(contentsOf: [0, 0])
            data.append(littleEndian(UInt32(value.count)))
        } else {
            data.append(littleEndian(UInt16(value.count)))
        }
        data.append(value)
        return data
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
