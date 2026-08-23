import Darwin
import Foundation
import KinlogueCore
import KinloguePlatform

enum DICOMInstalledAcceptanceFailureStep: String, Codable, Sendable {
    case phase
    case context
    case inputOwnership = "input-ownership"
    case environment
    case initialSnapshot = "initial-snapshot"
    case importOperation = "import-operation"
    case importOutcome = "import-outcome"
    case save
    case savedSnapshot = "saved-snapshot"
    case viewerMetadata = "viewer-metadata"
    case viewerContent = "viewer-content"
    case viewerRender = "viewer-render"
    case viewerLimits = "viewer-limits"
    case metrics
    case restart
    case delete
}

struct DICOMInstalledAcceptanceFailureMetrics: Equatable, Sendable {
    let cachedWindowP95Milliseconds: Int
    let foregroundP95Milliseconds: Int
    let importMetrics: DICOMImportMetricsSnapshot?
    let renderedSliceCount: Int
    let rssCloseWithinLimit: Bool
    let rssPeakDeltaBytes: UInt64
}

enum DICOMInstalledAcceptanceError: Error, Equatable, Sendable {
    case invariantFailed(
        DICOMInstalledAcceptanceFailureStep,
        DICOMInstalledAcceptanceFailureMetrics? = nil
    )

    var step: DICOMInstalledAcceptanceFailureStep {
        switch self {
        case let .invariantFailed(step, _): step
        }
    }

    var failureMetrics: DICOMInstalledAcceptanceFailureMetrics? {
        switch self {
        case let .invariantFailed(_, metrics): metrics
        }
    }
}

enum DICOMInstalledAcceptanceEventCode: String, Codable, Sendable {
    case importComplete = "KLA_DICOM_IMPORT_COMPLETE"
    case restartComplete = "KLA_DICOM_RESTART_COMPLETE"
    case deleteComplete = "KLA_DICOM_DELETE_COMPLETE"
    case failed = "KLA_DICOM_FAILED"
}

struct DICOMInstalledAcceptanceEvent: Codable, Equatable, Sendable {
    let cachedWindowP95Milliseconds: Int
    let code: DICOMInstalledAcceptanceEventCode
    let failureStep: DICOMInstalledAcceptanceFailureStep?
    let foregroundP95Milliseconds: Int
    let inertObjectCount: Int
    let liveDescriptorCount: Int
    let liveWorkerCount: Int
    let managedFullReadBytes: Int
    let maximumConcurrentWorkers: Int
    let maximumLiveDescriptors: Int
    let maximumManagedFullReadsPerObject: Int
    let maximumQueueDepth: Int
    let maximumWritesPerObject: Int
    let memberCount: Int
    let ok: Bool
    let peakAddedDiskBytes: Int
    let recordCount: Int
    let renderedSliceCount: Int
    let retainedObjectCount: Int
    let rssCloseWithinLimit: Bool
    let rssPeakDeltaBytes: UInt64
    let seriesCount: Int
    let sourceBytesRead: Int
    let stagingBytesWritten: Int
    let studyCount: Int
    let summarySHA256: String
    let viewableInstanceCount: Int

    static func failed(
        step: DICOMInstalledAcceptanceFailureStep,
        metrics: DICOMInstalledAcceptanceFailureMetrics? = nil
    ) -> DICOMInstalledAcceptanceEvent {
        let importMetrics = metrics?.importMetrics
        return DICOMInstalledAcceptanceEvent(
            cachedWindowP95Milliseconds: metrics?.cachedWindowP95Milliseconds ?? 0,
            code: .failed,
            failureStep: step,
            foregroundP95Milliseconds: metrics?.foregroundP95Milliseconds ?? 0,
            inertObjectCount: 0,
            liveDescriptorCount: importMetrics?.liveSourceAndStagingDescriptorCount ?? 0,
            liveWorkerCount: importMetrics?.liveWorkerCount ?? 0,
            managedFullReadBytes: importMetrics?.managedFullReadBytes ?? 0,
            maximumConcurrentWorkers: importMetrics?.maximumConcurrentWorkers ?? 0,
            maximumLiveDescriptors:
                importMetrics?.maximumLiveSourceAndStagingDescriptors ?? 0,
            maximumManagedFullReadsPerObject:
                importMetrics?.maximumManagedFullReadsPerObject ?? 0,
            maximumQueueDepth: importMetrics?.maximumQueueDepth ?? 0,
            maximumWritesPerObject: importMetrics?.maximumWritesPerObject ?? 0,
            memberCount: 0,
            ok: false,
            peakAddedDiskBytes: importMetrics?.peakAddedDiskBytes ?? 0,
            recordCount: 0,
            renderedSliceCount: metrics?.renderedSliceCount ?? 0,
            retainedObjectCount: 0,
            rssCloseWithinLimit: metrics?.rssCloseWithinLimit ?? false,
            rssPeakDeltaBytes: metrics?.rssPeakDeltaBytes ?? 0,
            seriesCount: 0,
            sourceBytesRead: importMetrics?.sourceBytesRead ?? 0,
            stagingBytesWritten: importMetrics?.stagingBytesWritten ?? 0,
            studyCount: 0,
            summarySHA256: String(repeating: "0", count: 64),
            viewableInstanceCount: 0
        )
    }

    func emit() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

struct DICOMInstalledAcceptanceRunner: Sendable {
    private static let expectedSeriesCount = 3
    private static let expectedViewableCount = 216
    private static let expectedInertCount = 1
    private static let expectedRetainedCount = 217

    let request: AcceptanceSmokeRequest

    func run() async throws {
        do {
            switch request.phase {
            case .dicomImport:
                try await runImport()
            case .dicomRestart:
                try await runRestart()
            case .dicomDelete:
                try await runDelete()
            default:
                throw DICOMInstalledAcceptanceError.invariantFailed(.phase)
            }
        } catch let error as DICOMInstalledAcceptanceError {
            throw error
        } catch {
            throw DICOMInstalledAcceptanceError.invariantFailed(.phase)
        }
    }

    private func runImport() async throws {
        var step = DICOMInstalledAcceptanceFailureStep.context
        do {
            let context = try context()
            step = .inputOwnership
            try verifyOwnedInput(context.inputDirectory)
            step = .environment
            let environment = try LiveAppServiceEnvironment.makeDefault(
                identity: request.identity
            )
            let baselineRSS = try residentMemoryByteCount()
            step = .initialSnapshot
            let initial = try await environment.dataService.bootstrap()
            guard initial.members.count == 4,
                  initial.records.count == 96,
                  initial.dicomStudies.isEmpty,
                  let member = initial.members.first(where: { !$0.isArchived }) else {
                throw DICOMInstalledAcceptanceError.invariantFailed(step)
            }

            step = .importOperation
            let outcome = try await environment.dataService.importDICOMDirectory(
                at: context.inputDirectory
            )
            step = .importOutcome
            guard outcome.destination == .review,
                  !outcome.wasExisting,
                  outcome.viewableInstanceCount == Self.expectedViewableCount,
                  outcome.inertObjectCount == Self.expectedInertCount else {
                throw DICOMInstalledAcceptanceError.invariantFailed(step)
            }
            step = .save
            let saved = try await environment.dataService.saveDICOMStudy(
                SaveDICOMStudyCommand(
                    studyID: outcome.studyID,
                    memberID: member.id,
                    effectiveDate: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
            step = .savedSnapshot
            guard saved.members.count == 4,
                  saved.records.count == 96,
                  saved.dicomStudies.count == 1,
                  saved.dicomStudies[0].state == .confirmed else {
                throw DICOMInstalledAcceptanceError.invariantFailed(step)
            }
            step = .viewerMetadata
            let viewer = try await environment.dataService.loadDICOMStudyViewer(
                studyID: outcome.studyID
            )
            step = .viewerContent
            try validate(viewer)

            step = .viewerRender
            let sliceService = environment.dicomSliceServiceFactory()
            let rendered = try await exerciseViewer(
                sliceService,
                content: viewer,
                baselineRSS: baselineRSS,
                fullScrollPasses: 3
            )
            await sliceService.close()
            let closeWithinLimit = await waitForRSS(
                atMost: baselineRSS + 32 * 1_024 * 1_024,
                timeout: .seconds(5)
            )
            step = .viewerLimits
            guard closeWithinLimit,
                  rendered.foregroundP95Milliseconds < 150,
                  rendered.cachedP95Milliseconds < 16,
                  rendered.peakRSSDeltaBytes <= 320 * 1_024 * 1_024 else {
                throw DICOMInstalledAcceptanceError.invariantFailed(
                    step,
                    failureMetrics(
                        rendered: rendered,
                        closeWithinLimit: closeWithinLimit
                    )
                )
            }
            step = .metrics
            guard let metricsRecorder = environment.dicomImportMetrics else {
                throw DICOMInstalledAcceptanceError.invariantFailed(step)
            }
            let metrics = await metricsRecorder.snapshot()
            guard metrics.uniqueObjectCount == Self.expectedRetainedCount,
                  metrics.maximumConcurrentWorkers <= 2,
                  metrics.maximumQueueDepth <= 2,
                  metrics.maximumLiveSourceAndStagingDescriptors <= 8,
                  metrics.liveSourceAndStagingDescriptorCount == 0,
                  metrics.liveWorkerCount == 0,
                  metrics.sourceBytesRead == metrics.stagingBytesWritten,
                  metrics.maximumManagedFullReadsPerObject <= 3,
                  metrics.maximumWritesPerObject <= 2,
                  metrics.peakAddedDiskBytes <= metrics.sourceBytesRead * 2
                    + 256 * 1_024 * 1_024 else {
                throw DICOMInstalledAcceptanceError.invariantFailed(
                    step,
                    failureMetrics(
                        rendered: rendered,
                        closeWithinLimit: closeWithinLimit,
                        importMetrics: metrics
                    )
                )
            }
            event(
                code: .importComplete,
                metrics: metrics,
                rendered: rendered,
                closeWithinLimit: closeWithinLimit,
                memberCount: saved.members.count,
                recordCount: saved.records.count,
                studyCount: saved.dicomStudies.count
            ).emit()
        } catch let error as DICOMInstalledAcceptanceError {
            throw error
        } catch {
            throw DICOMInstalledAcceptanceError.invariantFailed(step)
        }
    }

    private func runRestart() async throws {
        let environment = try LiveAppServiceEnvironment.makeDefault(identity: request.identity)
        let snapshot = try await environment.dataService.bootstrap()
        guard snapshot.members.count == 4,
              snapshot.records.count == 96,
              snapshot.dicomStudies.count == 1,
              let study = snapshot.dicomStudies.first,
              study.state == .confirmed else {
            throw DICOMInstalledAcceptanceError.invariantFailed(.restart)
        }
        let viewer = try await environment.dataService.loadDICOMStudyViewer(studyID: study.id)
        try validate(viewer)
        let sliceService = environment.dicomSliceServiceFactory()
        var rendered = 0
        for series in viewer.series {
            let session = try await sliceService.openSeries(
                studyID: study.id,
                seriesID: series.id
            )
            guard let instance = session.instances.first else {
                throw DICOMInstalledAcceptanceError.invariantFailed(.restart)
            }
            _ = try await sliceService.render(
                session: session,
                instanceID: instance.id,
                windowCenter: nil,
                windowWidth: nil
            )
            rendered += 1
        }
        await sliceService.close()
        event(
            code: .restartComplete,
            metrics: nil,
            rendered: .init(
                cachedP95Milliseconds: 0,
                foregroundP95Milliseconds: 0,
                peakRSSDeltaBytes: 0,
                renderedSliceCount: rendered
            ),
            closeWithinLimit: true,
            memberCount: snapshot.members.count,
            recordCount: snapshot.records.count,
            studyCount: snapshot.dicomStudies.count
        ).emit()
    }

    private func runDelete() async throws {
        let environment = try LiveAppServiceEnvironment.makeDefault(identity: request.identity)
        let before = try await environment.dataService.bootstrap()
        guard before.members.count == 4,
              before.records.count == 96,
              before.dicomStudies.count == 1,
              let study = before.dicomStudies.first else {
            throw DICOMInstalledAcceptanceError.invariantFailed(.delete)
        }
        let after = try await environment.dataService.deleteDICOMStudy(id: study.id)
        guard after.members == before.members,
              after.records == before.records,
              after.dicomStudies.isEmpty else {
            throw DICOMInstalledAcceptanceError.invariantFailed(.delete)
        }
        event(
            code: .deleteComplete,
            metrics: nil,
            rendered: .zero,
            closeWithinLimit: true,
            memberCount: after.members.count,
            recordCount: after.records.count,
            studyCount: 0
        ).emit()
    }

    private func context() throws -> DICOMInstalledAcceptanceContext {
        guard case let .acceptance(runID) = request.identity.mode else {
            throw DICOMInstalledAcceptanceError.invariantFailed(.context)
        }
        let context = try DICOMInstalledAcceptanceContext(
            runID: runID,
            sourceVault: request.identity.sourceVault
        )
        let applicationSupport = context.inputDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        _ = try AcceptanceRunOwnership.load(
            applicationSupportURL: applicationSupport,
            runID: runID
        )
        return context
    }

    private func verifyOwnedInput(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              (metadata.st_mode & 0o777) == 0o700 else {
            throw DICOMInstalledAcceptanceError.invariantFailed(.inputOwnership)
        }
    }

    private func validate(_ content: DICOMStudyViewerContent) throws {
        guard content.study.state == .confirmed,
              content.seriesCount == Self.expectedSeriesCount,
              content.viewableInstanceCount == Self.expectedViewableCount,
              content.inertObjectCount == Self.expectedInertCount,
              content.series.allSatisfy({ $0.sliceCount == 72 }) else {
            throw DICOMInstalledAcceptanceError.invariantFailed(.viewerContent)
        }
    }

    private struct RenderSummary: Sendable {
        let cachedP95Milliseconds: Int
        let foregroundP95Milliseconds: Int
        let peakRSSDeltaBytes: UInt64
        let renderedSliceCount: Int

        static let zero = RenderSummary(
            cachedP95Milliseconds: 0,
            foregroundP95Milliseconds: 0,
            peakRSSDeltaBytes: 0,
            renderedSliceCount: 0
        )
    }

    private func failureMetrics(
        rendered: RenderSummary,
        closeWithinLimit: Bool,
        importMetrics: DICOMImportMetricsSnapshot? = nil
    ) -> DICOMInstalledAcceptanceFailureMetrics {
        DICOMInstalledAcceptanceFailureMetrics(
            cachedWindowP95Milliseconds: rendered.cachedP95Milliseconds,
            foregroundP95Milliseconds: rendered.foregroundP95Milliseconds,
            importMetrics: importMetrics,
            renderedSliceCount: rendered.renderedSliceCount,
            rssCloseWithinLimit: closeWithinLimit,
            rssPeakDeltaBytes: rendered.peakRSSDeltaBytes
        )
    }

    private func exerciseViewer(
        _ service: any DICOMSliceViewing,
        content: DICOMStudyViewerContent,
        baselineRSS: UInt64,
        fullScrollPasses: Int
    ) async throws -> RenderSummary {
        var foreground: [UInt64] = []
        var cached: [UInt64] = []
        var renderedCount = 0
        var peakRSS = baselineRSS
        for pass in 0..<fullScrollPasses {
            for series in content.series {
                let session = try await service.openSeries(
                    studyID: content.study.id,
                    seriesID: series.id
                )
                for instance in session.instances {
                    let started = DispatchTime.now().uptimeNanoseconds
                    _ = try await service.render(
                        session: session,
                        instanceID: instance.id,
                        windowCenter: nil,
                        windowWidth: nil
                    )
                    if pass == 0 {
                        foreground.append(DispatchTime.now().uptimeNanoseconds - started)
                    }
                    renderedCount += 1
                    peakRSS = max(peakRSS, try residentMemoryByteCount())
                }
                if pass == 0, let first = session.instances.first {
                    for offset in 0..<20 {
                        let started = DispatchTime.now().uptimeNanoseconds
                        _ = try await service.render(
                            session: session,
                            instanceID: first.id,
                            windowCenter: 128 + Double(offset),
                            windowWidth: 256
                        )
                        cached.append(DispatchTime.now().uptimeNanoseconds - started)
                    }
                }
            }
        }
        return RenderSummary(
            cachedP95Milliseconds: percentile95Milliseconds(cached),
            foregroundP95Milliseconds: percentile95Milliseconds(foreground),
            peakRSSDeltaBytes: peakRSS >= baselineRSS ? peakRSS - baselineRSS : 0,
            renderedSliceCount: renderedCount
        )
    }

    private func percentile95Milliseconds(_ values: [UInt64]) -> Int {
        guard !values.isEmpty else { return .max }
        let sorted = values.sorted()
        let rank = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        let nanoseconds = sorted[min(rank, sorted.count - 1)]
        return Int((nanoseconds + 999_999) / 1_000_000)
    }

    private func residentMemoryByteCount() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw DICOMInstalledAcceptanceError.invariantFailed(.viewerRender)
        }
        return info.resident_size
    }

    private func waitForRSS(atMost limit: UInt64, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if let rss = try? residentMemoryByteCount(), rss <= limit { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        return false
    }

    private func event(
        code: DICOMInstalledAcceptanceEventCode,
        metrics: DICOMImportMetricsSnapshot?,
        rendered: RenderSummary,
        closeWithinLimit: Bool,
        memberCount: Int,
        recordCount: Int,
        studyCount: Int
    ) -> DICOMInstalledAcceptanceEvent {
        let summary = [
            code.rawValue,
            String(memberCount),
            String(recordCount),
            String(studyCount),
            String(rendered.renderedSliceCount),
        ].joined(separator: ":")
        return DICOMInstalledAcceptanceEvent(
            cachedWindowP95Milliseconds: rendered.cachedP95Milliseconds,
            code: code,
            failureStep: nil,
            foregroundP95Milliseconds: rendered.foregroundP95Milliseconds,
            inertObjectCount: code == .deleteComplete ? 0 : Self.expectedInertCount,
            liveDescriptorCount: metrics?.liveSourceAndStagingDescriptorCount ?? 0,
            liveWorkerCount: metrics?.liveWorkerCount ?? 0,
            managedFullReadBytes: metrics?.managedFullReadBytes ?? 0,
            maximumConcurrentWorkers: metrics?.maximumConcurrentWorkers ?? 0,
            maximumLiveDescriptors: metrics?.maximumLiveSourceAndStagingDescriptors ?? 0,
            maximumManagedFullReadsPerObject: metrics?.maximumManagedFullReadsPerObject ?? 0,
            maximumQueueDepth: metrics?.maximumQueueDepth ?? 0,
            maximumWritesPerObject: metrics?.maximumWritesPerObject ?? 0,
            memberCount: memberCount,
            ok: true,
            peakAddedDiskBytes: metrics?.peakAddedDiskBytes ?? 0,
            recordCount: recordCount,
            renderedSliceCount: rendered.renderedSliceCount,
            retainedObjectCount: code == .deleteComplete ? 0 : Self.expectedRetainedCount,
            rssCloseWithinLimit: closeWithinLimit,
            rssPeakDeltaBytes: rendered.peakRSSDeltaBytes,
            seriesCount: code == .deleteComplete ? 0 : Self.expectedSeriesCount,
            sourceBytesRead: metrics?.sourceBytesRead ?? 0,
            stagingBytesWritten: metrics?.stagingBytesWritten ?? 0,
            studyCount: studyCount,
            summarySHA256: ContentDigest.sha256(Data(summary.utf8)).hexadecimalString,
            viewableInstanceCount: code == .deleteComplete ? 0 : Self.expectedViewableCount
        )
    }
}
