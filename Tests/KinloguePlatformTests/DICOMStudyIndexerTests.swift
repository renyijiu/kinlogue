import Foundation
import KinlogueCore
import KinlogueDICOMIPC
import KinlogueDICOMTestSupport
import Testing
@testable import KinloguePlatform

struct DICOMStudyIndexerTests {
    @Test
    func indexerCollapsesExactDuplicatesAndRetainsExplicitSRAsInert() async throws {
        let fixture = try IndexerFixture()
        defer { fixture.cleanup() }
        let image = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        let inert = GeneratedDICOMFixture.explicitVRLittleEndianInertObject()
        let staged = try [image, image, inert].map { try fixture.stage($0) }
        let decoder = QueueFrameDecoder(frames: [fixture.frame()])

        let proposal = try await DICOMStudyIndexer(
            decoder: decoder,
            policy: .default
        ).index(stagedObjects: staged, vaultID: fixture.vaultID, staging: fixture.staging)

        #expect(proposal.study.state == .needsReview)
        #expect(proposal.study.attachmentIDs.count == 2)
        #expect(proposal.index.instances.count == 1)
        #expect(proposal.index.series.count == 1)
        #expect(proposal.index.series.first?.orderingProvenance == .geometryProjection)
        #expect(proposal.index.retainedObjects.filter { $0.kind == .inertAttachment }.count == 1)
        #expect(proposal.ignoredDuplicateCount == 1)
        #expect(await decoder.callCount == 1)
    }

    @Test
    func indexerRejectsMixedStudyAndSameSOPDifferentContentWithoutRawIdentifiers() async throws {
        let fixture = try IndexerFixture()
        defer { fixture.cleanup() }
        let first = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        let second = GeneratedDICOMFixture.explicitVRLittleEndianMR(pixels: [1, 2, 3, 4])
        let staged = try [first, second].map { try fixture.stage($0) }
        let decoder = QueueFrameDecoder(frames: [
            fixture.frame(),
            fixture.frame(sampleBytes: Data([1, 0, 2, 0, 3, 0, 4, 0])),
        ])

        do {
            _ = try await DICOMStudyIndexer(decoder: decoder).index(
                stagedObjects: staged,
                vaultID: fixture.vaultID,
                staging: fixture.staging
            )
            Issue.record("Expected SOP/content conflict")
        } catch let error as DICOMImportError {
            #expect(error == .sopInstanceConflict)
            #expect(!String(describing: error).contains("2.25"))
        }
    }

    @Test
    func indexerRejectsMixedStudiesAndUnsupportedImageClassesBeforePublication() async throws {
        let fixture = try IndexerFixture()
        defer { fixture.cleanup() }
        let first = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        let second = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            studyInstanceUID: "2.25.9922",
            seriesInstanceUID: "2.25.9923",
            sopInstanceUID: "2.25.9924"
        )
        let mixed = try [first, second].map { try fixture.stage($0) }
        let mixedDecoder = QueueFrameDecoder(frames: [
            fixture.frame(),
            fixture.frame(studyUID: "2.25.9922", seriesUID: "2.25.9923", sopUID: "2.25.9924"),
        ])
        await #expect(throws: DICOMImportError.mixedStudy) {
            _ = try await DICOMStudyIndexer(decoder: mixedDecoder).index(
                stagedObjects: mixed, vaultID: fixture.vaultID, staging: fixture.staging
            )
        }

        let unsupported = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            sopClassUID: "1.2.840.10008.5.1.4.1.1.2",
            modality: "CT"
        )
        let stagedUnsupported = try fixture.stage(unsupported)
        let unusedDecoder = QueueFrameDecoder(frames: [])
        await #expect(throws: DICOMImportError.unsupportedImage) {
            _ = try await DICOMStudyIndexer(decoder: unusedDecoder).index(
                stagedObjects: [stagedUnsupported],
                vaultID: fixture.vaultID,
                staging: fixture.staging
            )
        }
        #expect(await unusedDecoder.callCount == 0)
    }

    @Test
    func indexerEnforcesConfiguredFrameBudgets() async throws {
        let fixture = try IndexerFixture()
        defer { fixture.cleanup() }
        let staged = try fixture.stage(GeneratedDICOMFixture.explicitVRLittleEndianMR())

        let rowLimited = try policy(maximumRows: 1, maximumDecodedSampleBytes: 128 * 1_024 * 1_024)
        await #expect(throws: DICOMImportError.resourceLimit) {
            _ = try await DICOMStudyIndexer(
                decoder: QueueFrameDecoder(frames: [fixture.frame()]),
                policy: rowLimited
            ).index(stagedObjects: [staged], vaultID: fixture.vaultID, staging: fixture.staging)
        }

        let sampleLimited = try policy(maximumRows: 8_192, maximumDecodedSampleBytes: 4)
        await #expect(throws: DICOMImportError.resourceLimit) {
            _ = try await DICOMStudyIndexer(
                decoder: QueueFrameDecoder(frames: [fixture.frame()]),
                policy: sampleLimited
            ).index(stagedObjects: [staged], vaultID: fixture.vaultID, staging: fixture.staging)
        }
    }

    @Test
    func indexerRejectsInvalidUIDComponentsOnInertObjects() async throws {
        let fixture = try IndexerFixture()
        defer { fixture.cleanup() }
        var inert = GeneratedDICOMFixture.explicitVRLittleEndianInertObject()
        let valid = Data("2.25.8822".utf8)
        let invalid = Data("2.25/8822".utf8)
        let range = try #require(inert.range(of: valid))
        inert.replaceSubrange(range, with: invalid)
        let staged = try fixture.stage(inert)

        await #expect(throws: DICOMImportError.invalidPart10) {
            _ = try await DICOMStudyIndexer(
                decoder: QueueFrameDecoder(frames: [])
            ).index(stagedObjects: [staged], vaultID: fixture.vaultID, staging: fixture.staging)
        }
    }

    @Test
    func indexerSkipsUndefinedLengthSequenceBeforeRequiredTopLevelTags() async throws {
        let fixture = try IndexerFixture()
        defer { fixture.cleanup() }
        let object = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            preStudyUndefinedLengthSequence: true
        )
        let staged = try fixture.stage(object)

        let proposal = try await DICOMStudyIndexer(
            decoder: QueueFrameDecoder(frames: [fixture.frame()])
        ).index(stagedObjects: [staged], vaultID: fixture.vaultID, staging: fixture.staging)

        #expect(proposal.index.instances.count == 1)
        #expect(proposal.index.series.count == 1)
    }

    @Test
    func indexerCanonicalizesLeadingZeroUIDComponents() async throws {
        let fixture = try IndexerFixture()
        defer { fixture.cleanup() }
        let studyUID = "2.25.08822"
        let seriesUID = "2.25.08823"
        let sopUID = "2.25.08824"
        let object = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            studyInstanceUID: studyUID,
            seriesInstanceUID: seriesUID,
            sopInstanceUID: sopUID
        )
        let staged = try fixture.stage(object)
        let decoder = QueueFrameDecoder(frames: [fixture.frame(
            studyUID: studyUID,
            seriesUID: seriesUID,
            sopUID: sopUID
        )])

        let proposal = try await DICOMStudyIndexer(decoder: decoder).index(
            stagedObjects: [staged], vaultID: fixture.vaultID, staging: fixture.staging
        )

        #expect(proposal.index.instances.count == 1)
    }

    @Test
    func indexerAcceptsBoundedVendorStudyIdentifierWithoutPersistingIt() async throws {
        let fixture = try IndexerFixture()
        defer { fixture.cleanup() }
        let studyUID = "VENDOR_STUDY-01"
        let object = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            studyInstanceUID: studyUID,
            seriesInstanceUID: "2.25.08823",
            sopInstanceUID: "2.25.08824",
            preStudyUndefinedLengthSequence: true
        )
        let staged = try fixture.stage(object)
        let decoder = QueueFrameDecoder(frames: [fixture.frame(
            studyUID: studyUID,
            seriesUID: "2.25.08823",
            sopUID: "2.25.08824"
        )])

        let proposal = try await DICOMStudyIndexer(decoder: decoder).index(
            stagedObjects: [staged], vaultID: fixture.vaultID, staging: fixture.staging
        )

        #expect(proposal.index.instances.count == 1)
        #expect(!String(describing: proposal).contains(studyUID))
    }

    @Test
    func indexerPersistsObliqueGeometryOrderInsteadOfContentOrder() async throws {
        let fixture = try IndexerFixture()
        defer { fixture.cleanup() }
        let firstBytes = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            sopInstanceUID: "2.25.8831",
            pixels: [1, 2, 3, 4]
        )
        let secondBytes = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            sopInstanceUID: "2.25.8832",
            pixels: [5, 6, 7, 8]
        )
        let thirdBytes = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            sopInstanceUID: "2.25.8833",
            pixels: [9, 10, 11, 12]
        )
        let staged = try [firstBytes, secondBytes, thirdBytes].map(fixture.stage)
        let orientation = [
            1.0 / 2.0.squareRoot(), 1.0 / 2.0.squareRoot(), 0,
            0, 0, 1,
        ]
        let decoder = QueueFrameDecoder(frames: [
            fixture.frame(
                sopUID: "2.25.8831",
                instanceNumber: 30,
                position: [2, -2, 0],
                orientation: orientation,
                sampleBytes: Data([1, 0, 2, 0, 3, 0, 4, 0])
            ),
            fixture.frame(
                sopUID: "2.25.8832",
                instanceNumber: 10,
                position: [0, 0, 0],
                orientation: orientation,
                sampleBytes: Data([5, 0, 6, 0, 7, 0, 8, 0])
            ),
            fixture.frame(
                sopUID: "2.25.8833",
                instanceNumber: 20,
                position: [1, -1, 0],
                orientation: orientation,
                sampleBytes: Data([9, 0, 10, 0, 11, 0, 12, 0])
            ),
        ])

        let proposal = try await DICOMStudyIndexer(decoder: decoder).index(
            stagedObjects: staged,
            vaultID: fixture.vaultID,
            staging: fixture.staging
        )

        let series = try #require(proposal.index.series.first)
        #expect(series.orderingProvenance == .geometryProjection)
        let byID = Dictionary(uniqueKeysWithValues: proposal.index.instances.map { ($0.id, $0) })
        let orderedAttachmentIDs = try series.instanceIDs.map {
            try #require(byID[$0]).attachmentID
        }
        let attachmentByDigest = Dictionary(uniqueKeysWithValues: proposal.objects.map {
            ($0.staged.sha256Digest, $0.attachment.id)
        })
        #expect(orderedAttachmentIDs == [
            attachmentByDigest[staged[1].sha256Digest],
            attachmentByDigest[staged[2].sha256Digest],
            attachmentByDigest[staged[0].sha256Digest],
        ])
    }

    @Test
    func indexerUsesNonSpatialFallbackForInconsistentSeriesOrientation() async throws {
        let fixture = try IndexerFixture()
        defer { fixture.cleanup() }
        let first = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            sopInstanceUID: "2.25.8841"
        )
        let second = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            sopInstanceUID: "2.25.8842",
            pixels: [1, 2, 3, 4]
        )
        let staged = try [first, second].map(fixture.stage)
        let decoder = QueueFrameDecoder(frames: [
            fixture.frame(sopUID: "2.25.8841", position: [0, 0, 0]),
            fixture.frame(
                sopUID: "2.25.8842",
                position: [0, 0, 1],
                orientation: [0, 1, 0, 1, 0, 0],
                sampleBytes: Data([1, 0, 2, 0, 3, 0, 4, 0])
            ),
        ])

        let proposal = try await DICOMStudyIndexer(decoder: decoder).index(
            stagedObjects: staged,
            vaultID: fixture.vaultID,
            staging: fixture.staging
        )

        #expect(proposal.index.series.first?.orderingProvenance == .instanceNumberFallback)
        #expect(proposal.index.instances.map(\.canonicalOrder) == [0, 1])
    }
}

private func policy(
    maximumRows: Int,
    maximumDecodedSampleBytes: Int
) throws -> DICOMImportPolicy {
    try DICOMImportPolicy(
        maximumTraversalDepth: 16,
        maximumDirectoryEntries: 10_000,
        maximumDICOMObjectCount: 2_000,
        maximumUniqueSourceBytes: 2 * 1_024 * 1_024 * 1_024,
        maximumObjectBytes: 100 * 1_024 * 1_024,
        maximumRows: maximumRows,
        maximumColumns: 8_192,
        maximumDecodedSampleBytes: maximumDecodedSampleBytes,
        maximumWorkers: 2,
        maximumSourceAndStagingDescriptors: 8,
        requiredFreeSpaceHeadroom: 256 * 1_024 * 1_024
    )
}

private struct IndexerFixture {
    let base: URL
    let vault: URL
    let staging: VaultDICOMStudyStaging
    let operationID = UUID()
    let vaultID = UUID()
    let ownership: VaultDICOMStagingOwnership

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        vault = base.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        staging = try VaultDICOMStudyStaging(rootURL: vault)
        ownership = try staging.prepare(operationID: operationID)
    }

    func stage(_ data: Data) throws -> VaultDICOMStagedObject {
        let url = base.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        let stagedByteCount = try staging.list(ownership: ownership).reduce(0) {
            $0 + $1.byteCount
        }
        return try staging.stage(
            sourceDescriptor: descriptor,
            declaredByteCount: data.count,
            ownership: ownership,
            stagedByteCountBeforeCopy: stagedByteCount
        )
    }

    func frame(
        studyUID: String = "2.25.8822",
        seriesUID: String = "2.25.8823",
        sopUID: String = "2.25.8824",
        instanceNumber: Int? = 1,
        position: [Double]? = [0, 0, 0],
        orientation: [Double]? = [1, 0, 0, 0, 1, 0],
        sampleBytes: Data = Data([0, 0, 64, 0, 128, 0, 255, 0])
    ) -> KinlogueDICOMDecodedFrame {
        KinlogueDICOMDecodedFrame(
            transferSyntaxUID: KinlogueDICOMSupportedObject.explicitVRLittleEndian,
            sopClassUID: KinlogueDICOMSupportedObject.mrImageStorage,
            studyInstanceUID: studyUID,
            seriesInstanceUID: seriesUID,
            sopInstanceUID: sopUID,
            modality: "MR", instanceNumber: instanceNumber, rows: 2, columns: 2,
            samplesPerPixel: 1, bitsAllocated: 16, bitsStored: 12, highBit: 11,
            pixelRepresentation: 0, photometricInterpretation: "MONOCHROME2",
            numberOfFrames: 1, imagePositionPatient: position,
            imageOrientationPatient: orientation, windowCenter: 128,
            windowWidth: 256, rescaleIntercept: 0, rescaleSlope: 1,
            sampleBytes: sampleBytes
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private actor QueueFrameDecoder: DICOMFrameDecoding {
    private var frames: [KinlogueDICOMDecodedFrame]
    private(set) var callCount = 0

    init(frames: [KinlogueDICOMDecodedFrame]) { self.frames = frames }

    func decode(descriptor: FileHandle, declaredByteCount: Int) async throws -> KinlogueDICOMDecodedFrame {
        callCount += 1
        guard !frames.isEmpty else { throw DICOMDecoderAdapterError.decoderFailed }
        return frames.removeFirst()
    }
}
