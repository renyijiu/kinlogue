import Darwin
import Foundation
import KinlogueCore
import KinlogueDICOMTestSupport
import Testing
@testable import KinloguePlatform

struct DICOMFolderScannerTests {
    @Test
    func committedStagingCapacityCountsExistingBytesOnlyOnceAtTheExactBoundary() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kinlogue-dicom-capacity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let stagedBytes = 101
        let headroom = 17
        let policy = try DICOMImportPolicy(
            maximumTraversalDepth: 1,
            maximumDirectoryEntries: 2,
            maximumDICOMObjectCount: 2,
            maximumUniqueSourceBytes: 1_024,
            maximumObjectBytes: 1_024,
            maximumRows: 8_192,
            maximumColumns: 8_192,
            maximumDecodedSampleBytes: 128 * 1_024 * 1_024,
            maximumWorkers: 2,
            maximumSourceAndStagingDescriptors: 8,
            requiredFreeSpaceHeadroom: headroom
        )
        let exactBoundary = try VaultDICOMStudyStaging(
            rootURL: base,
            policy: policy,
            availableCapacityProvider: { _ in Int64(stagedBytes + headroom) }
        )

        try exactBoundary.validateCapacity(uniqueStagedBytes: stagedBytes)

        let belowBoundary = try VaultDICOMStudyStaging(
            rootURL: base,
            policy: policy,
            availableCapacityProvider: { _ in Int64(stagedBytes + headroom - 1) }
        )
        #expect(throws: DICOMImportError.insufficientCapacity) {
            try belowBoundary.validateCapacity(uniqueStagedBytes: stagedBytes)
        }
    }

    @Test
    func descriptorRelativeScanStagesOnlyPart10RegularFilesWithOpaqueNames() async throws {
        let fixture = try ScannerFixture()
        defer { fixture.cleanup() }
        let nested = fixture.source.appendingPathComponent("visible-name", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let dicom = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        try dicom.write(to: nested.appendingPathComponent("identity-bearing-name.bin"))
        try Data("ordinary".utf8).write(to: fixture.source.appendingPathComponent("note.txt"))
        let outside = fixture.base.appendingPathComponent("outside.bin")
        try dicom.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("escape.bin"),
            withDestinationURL: outside
        )

        let result = try await fixture.scanner.scan(
            directoryURL: fixture.source,
            operationID: fixture.operationID,
            securityScope: .notRequiredForTesting,
            staging: fixture.staging,
            ownership: fixture.ownership
        )

        #expect(result.stagedObjects.count == 1)
        #expect(result.ignoredNonDICOMCount == 1)
        #expect(result.ignoredNonRegularCount == 1)
        let staged = try #require(result.stagedObjects.first)
        #expect(!staged.relativePath.contains("visible-name"))
        #expect(!staged.relativePath.contains("identity-bearing-name"))
        #expect(try fixture.staging.read(staged) == dicom)
        let mode = try fixture.mode(of: staged.relativePath)
        #expect(mode & 0o777 == 0o400)
    }

    @Test
    func scannerRejectsDepthAndEntryOverflowWithoutLeavingStagedBytes() async throws {
        let policy = try DICOMImportPolicy(
            maximumTraversalDepth: 1,
            maximumDirectoryEntries: 2,
            maximumDICOMObjectCount: 2,
            maximumUniqueSourceBytes: 1_024 * 1_024,
            maximumObjectBytes: 1_024 * 1_024,
            maximumRows: 8_192,
            maximumColumns: 8_192,
            maximumDecodedSampleBytes: 128 * 1_024 * 1_024,
            maximumWorkers: 2,
            maximumSourceAndStagingDescriptors: 8,
            requiredFreeSpaceHeadroom: 0
        )
        let fixture = try ScannerFixture(policy: policy)
        defer { fixture.cleanup() }
        let one = fixture.source.appendingPathComponent("one", isDirectory: true)
        let two = one.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: two.appendingPathComponent("object.bin")
        )

        await #expect(throws: DICOMImportError.resourceLimit) {
            try await fixture.scanner.scan(
                directoryURL: fixture.source,
                operationID: fixture.operationID,
                securityScope: .notRequiredForTesting,
                staging: fixture.staging,
                ownership: fixture.ownership
            )
        }
        #expect(try fixture.staging.list(ownership: fixture.ownership).isEmpty)
    }

    @Test
    func scannerPromptlyRemovesExactDuplicateStagingCopies() async throws {
        let object = GeneratedDICOMFixture.explicitVRLittleEndianMR()
        let policy = try DICOMImportPolicy(
            maximumTraversalDepth: 16,
            maximumDirectoryEntries: 10_000,
            maximumDICOMObjectCount: 2_000,
            maximumUniqueSourceBytes: object.count,
            maximumObjectBytes: object.count,
            maximumRows: 8_192,
            maximumColumns: 8_192,
            maximumDecodedSampleBytes: 128 * 1_024 * 1_024,
            maximumWorkers: 2,
            maximumSourceAndStagingDescriptors: 8,
            requiredFreeSpaceHeadroom: 0
        )
        let fixture = try ScannerFixture(policy: policy)
        defer { fixture.cleanup() }
        for ordinal in 0..<24 {
            try object.write(to: fixture.source.appendingPathComponent("generated-\(ordinal).bin"))
        }

        let result = try await fixture.scanner.scan(
            directoryURL: fixture.source,
            operationID: fixture.operationID,
            securityScope: .notRequiredForTesting,
            staging: fixture.staging,
            ownership: fixture.ownership
        )

        #expect(result.stagedObjects.count == 1)
        #expect(result.ignoredDuplicateCount == 23)
        #expect(result.stagedByteCount == object.count)
        #expect(try fixture.staging.list(ownership: fixture.ownership).count == 1)
    }

    @Test(arguments: SourceMutation.allCases)
    func admittedSourceMutationFailsWithoutPublishingSkew(mutation: SourceMutation) async throws {
        let control = SourceMutationControl(mutation: mutation)
        let fixture = try ScannerFixture(control: control)
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("generated.bin")
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(to: source)
        await control.configure(
            source: source,
            replacement: GeneratedDICOMFixture.explicitVRLittleEndianMR(
                sopInstanceUID: "2.25.9924"
            )
        )

        await #expect(throws: DICOMImportError.sourceChanged) {
            _ = try await fixture.scanner.scan(
                directoryURL: fixture.source,
                operationID: fixture.operationID,
                securityScope: .notRequiredForTesting,
                staging: fixture.staging,
                ownership: fixture.ownership
            )
        }
        #expect(try fixture.staging.list(ownership: fixture.ownership).isEmpty)
    }

    @Test
    func requiredScopeLossFailsBeforeAdmissionOrStaging() async throws {
        let fixture = try ScannerFixture(securityScopeAccess: DeniedSecurityScopeAccess())
        defer { fixture.cleanup() }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR().write(
            to: fixture.source.appendingPathComponent("generated.bin")
        )

        await #expect(throws: DICOMImportError.accessDenied) {
            _ = try await fixture.scanner.scan(
                directoryURL: fixture.source,
                operationID: fixture.operationID,
                securityScope: .required,
                staging: fixture.staging,
                ownership: fixture.ownership
            )
        }
        #expect(try fixture.staging.list(ownership: fixture.ownership).isEmpty)
    }

    @Test
    func securityScopedRootRenameAndReplacementCannotEscapeHeldDescriptor() async throws {
        let control = RootReplacementControl()
        let fixture = try ScannerFixture(
            control: control,
            securityScopeAccess: PermissiveSecurityScopeAccess()
        )
        defer { fixture.cleanup() }
        let admitted = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            sopInstanceUID: "2.25.77801"
        )
        let outside = GeneratedDICOMFixture.explicitVRLittleEndianMR(
            sopInstanceUID: "2.25.77802",
            pixels: [1, 2, 3, 4]
        )
        try admitted.write(to: fixture.source.appendingPathComponent("generated.bin"))
        await control.configure(root: fixture.source, outsideBytes: outside)

        let result = try await fixture.scanner.scan(
            directoryURL: fixture.source,
            operationID: fixture.operationID,
            securityScope: .required,
            staging: fixture.staging,
            ownership: fixture.ownership
        )

        let staged = try #require(result.stagedObjects.first)
        #expect(result.stagedObjects.count == 1)
        #expect(try fixture.staging.read(staged) == admitted)
        #expect(try fixture.staging.read(staged) != outside)
    }

    @Test
    func depthSixteenTraversalKeepsEveryImportOwnedDescriptorInsideFrozenBudget() async throws {
        let metrics = DICOMImportMetricsRecorder()
        let fixture = try ScannerFixture(
            metrics: metrics,
            control: ScannerTwoWorkerBarrierControl()
        )
        defer { fixture.cleanup() }
        var deepest = fixture.source
        for ordinal in 0..<16 {
            deepest.appendPathComponent("generated-directory-\(ordinal)", isDirectory: true)
            try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: false)
        }
        try GeneratedDICOMFixture.explicitVRLittleEndianMR(
            sopInstanceUID: "2.25.77601"
        ).write(to: deepest.appendingPathComponent("generated-a.bin"))
        try GeneratedDICOMFixture.explicitVRLittleEndianMR(
            sopInstanceUID: "2.25.77602"
        ).write(to: deepest.appendingPathComponent("generated-b.bin"))

        let result = try await fixture.scanner.scan(
            directoryURL: fixture.source,
            operationID: fixture.operationID,
            securityScope: .notRequiredForTesting,
            staging: fixture.staging,
            ownership: fixture.ownership
        )
        let snapshot = await metrics.snapshot()

        #expect(result.stagedObjects.count == 2)
        #expect(snapshot.maximumConcurrentWorkers == 2)
        #expect(snapshot.maximumQueueDepth == 2)
        #expect(snapshot.maximumLiveSourceDescriptors <= 8)
        #expect(snapshot.maximumLiveSourceAndStagingDescriptors <= 8)
        #expect(snapshot.liveSourceAndStagingDescriptorCount == 0)
        #expect(snapshot.liveWorkerCount == 0)
    }
}

enum SourceMutation: String, CaseIterable, Sendable {
    case rename, delete, growth, truncation, replacement
}

private actor SourceMutationControl: DICOMFolderScannerControl {
    private let mutation: SourceMutation
    private var source: URL?
    private var replacement = Data()
    private var didMutate = false

    init(mutation: SourceMutation) { self.mutation = mutation }

    func configure(source: URL, replacement: Data) {
        self.source = source
        self.replacement = replacement
    }

    func sourceAdmitted(ordinal: Int) async throws {
        guard ordinal == 0, !didMutate, let source else { return }
        didMutate = true
        switch mutation {
        case .rename:
            try FileManager.default.moveItem(
                at: source,
                to: source.deletingLastPathComponent().appendingPathComponent("renamed.bin")
            )
        case .delete:
            try FileManager.default.removeItem(at: source)
        case .growth:
            let handle = try FileHandle(forWritingTo: source)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0, 0]))
            try handle.close()
        case .truncation:
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: 132)
            try handle.close()
        case .replacement:
            try FileManager.default.removeItem(at: source)
            try replacement.write(to: source)
        }
    }

    func workerStarted() async throws {}
}

private struct DeniedSecurityScopeAccess: DICOMSecurityScopeAccess {
    func start(_ url: URL) -> Bool { false }
    func stop(_ url: URL) {}
}

private struct PermissiveSecurityScopeAccess: DICOMSecurityScopeAccess {
    func start(_ url: URL) -> Bool { true }
    func stop(_ url: URL) {}
}

private actor RootReplacementControl: DICOMFolderScannerControl {
    private var root: URL?
    private var outsideBytes = Data()
    private var didReplace = false

    func configure(root: URL, outsideBytes: Data) {
        self.root = root
        self.outsideBytes = outsideBytes
    }

    func sourceAdmitted(ordinal: Int) async throws {
        guard ordinal == 0, !didReplace, let root else { return }
        didReplace = true
        let parent = root.deletingLastPathComponent()
        let moved = parent.appendingPathComponent("moved-selected-root", isDirectory: true)
        let outside = parent.appendingPathComponent("outside-root", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try outsideBytes.write(to: outside.appendingPathComponent("generated.bin"))
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
    }

    func workerStarted() async throws {}
}

private actor ScannerTwoWorkerBarrierControl: DICOMFolderScannerControl {
    private var started = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sourceAdmitted(ordinal: Int) async throws {}

    func workerStarted() async throws {
        started += 1
        if started >= 2 {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct ScannerFixture {
    let base: URL
    let source: URL
    let vault: URL
    let operationID = UUID()
    let staging: VaultDICOMStudyStaging
    let ownership: VaultDICOMStagingOwnership
    let scanner: DICOMFolderScanner

    init(
        policy: DICOMImportPolicy = .default,
        metrics: DICOMImportMetricsRecorder? = nil,
        control: (any DICOMFolderScannerControl)? = nil,
        securityScopeAccess: any DICOMSecurityScopeAccess = SystemDICOMSecurityScopeAccess()
    ) throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = base.appendingPathComponent("source", isDirectory: true)
        vault = base.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        staging = try VaultDICOMStudyStaging(rootURL: vault, policy: policy)
        ownership = try staging.prepare(operationID: operationID)
        scanner = DICOMFolderScanner(
            policy: policy,
            metrics: metrics,
            control: control,
            securityScopeAccess: securityScopeAccess
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func mode(of relativePath: String) throws -> mode_t {
        var metadata = stat()
        let url = vault.appendingPathComponent(relativePath)
        guard lstat(url.path, &metadata) == 0 else { throw POSIXError(.ENOENT) }
        return metadata.st_mode
    }
}
