import Foundation
import KinlogueCore

enum DICOMImportModelPhase: Equatable {
    case idle
    case selecting
    case importing
    case cancelling
    case cancelled
    case succeeded
    case failed
}

enum DICOMImportSelectionDisposition: Equatable {
    case cancelled
    case presentSheet
}

private enum DICOMImportUserError: Equatable {
    case accessDenied
    case noDICOMObjects
    case invalidDICOM
    case mixedStudy
    case unsupportedImage
    case resourceLimit
    case sourceChanged
    case unavailable
}

@MainActor
final class DICOMImportModel: ObservableObject {
    private let service: any DICOMAppServicing
    private var userError: DICOMImportUserError?
    private var cancellationRequested = false
    private var operationGeneration: UInt64 = 0

    @Published private(set) var phase: DICOMImportModelPhase = .idle
    @Published private(set) var result: DICOMAppImportOutcome?

    init(service: any DICOMAppServicing) {
        self.service = service
    }

    var userErrorMessage: String? {
        switch userError {
        case nil: nil
        case .accessDenied: AppLocalization.string("无法读取所选文件夹")
        case .noDICOMObjects: AppLocalization.string("所选文件夹中没有可导入的 DICOM 影像")
        case .invalidDICOM: AppLocalization.string("文件夹中包含无法读取或暂不支持的 DICOM 文件")
        case .mixedStudy: AppLocalization.string("一个文件夹只能导入一次检查")
        case .unsupportedImage: AppLocalization.string("这组影像超出当前支持范围")
        case .resourceLimit: AppLocalization.string("影像数量或大小超出当前支持范围")
        case .sourceChanged: AppLocalization.string("导入时源文件发生变化，请重试")
        case .unavailable: AppLocalization.string("影像导入未完成，可以稍后重试")
        }
    }

    func beginSelection() {
        guard phase != .importing, phase != .cancelling else { return }
        result = nil
        userError = nil
        cancellationRequested = false
        operationGeneration &+= 1
        phase = .selecting
    }

    func disposition(for selection: Result<[URL], Error>) -> DICOMImportSelectionDisposition {
        if case .failure(let error as CocoaError) = selection,
           error.code == .userCancelled {
            return .cancelled
        }
        return .presentSheet
    }

    func handleImporterResult(_ selection: Result<[URL], Error>) async {
        if phase == .idle, !cancellationRequested {
            operationGeneration &+= 1
        }
        let generation = operationGeneration
        let urls: [URL]
        switch selection {
        case .success(let selected):
            urls = selected
        case .failure(let error as CocoaError) where error.code == .userCancelled:
            phase = .idle
            return
        case .failure:
            phase = .failed
            userError = .accessDenied
            return
        }
        guard urls.count == 1, let url = urls.first else {
            phase = .failed
            userError = .accessDenied
            return
        }

        guard !cancellationRequested else {
            phase = .cancelled
            return
        }

        phase = .importing
        userError = nil
        do {
            let outcome = try await service.importDICOMDirectory(at: url)
            guard generation == operationGeneration, !cancellationRequested else { return }
            result = outcome
            phase = .succeeded
        } catch let error as DICOMImportError {
            guard generation == operationGeneration else { return }
            if error == .cancelled {
                phase = .cancelled
                return
            }
            userError = Self.userError(for: error)
            phase = .failed
        } catch {
            guard generation == operationGeneration else { return }
            userError = .unavailable
            phase = .failed
        }
    }

    func cancel() async {
        guard phase == .idle || phase == .selecting || phase == .importing else { return }
        let generation = operationGeneration
        cancellationRequested = true
        guard phase == .importing else {
            phase = .cancelled
            return
        }
        phase = .cancelling
        do {
            let committedOutcome = try await service.cancelDICOMImport()
            guard generation == operationGeneration else { return }
            if let committedOutcome {
                result = committedOutcome
                phase = .succeeded
            } else {
                phase = .cancelled
            }
        } catch let error as DICOMImportError {
            guard generation == operationGeneration else { return }
            if error == .cancelled {
                phase = .cancelled
            } else {
                userError = Self.userError(for: error)
                phase = .failed
            }
        } catch {
            guard generation == operationGeneration else { return }
            userError = .unavailable
            phase = .failed
        }
    }

    func takeResult() -> DICOMAppImportOutcome? {
        defer { result = nil }
        return result
    }

    func clear() {
        operationGeneration &+= 1
        cancellationRequested = true
        result = nil
        userError = nil
        phase = .idle
    }

    private static func userError(for error: DICOMImportError) -> DICOMImportUserError {
        switch error {
        case .accessDenied, .invalidDirectory: .accessDenied
        case .noDICOMObjects: .noDICOMObjects
        case .invalidPart10: .invalidDICOM
        case .mixedStudy, .sopInstanceConflict: .mixedStudy
        case .unsupportedImage, .corruptImage: .unsupportedImage
        case .resourceLimit, .insufficientCapacity: .resourceLimit
        case .sourceChanged, .integrityFailure: .sourceChanged
        case .decoderUnavailable, .publicationConflict, .cancelled: .unavailable
        }
    }
}
