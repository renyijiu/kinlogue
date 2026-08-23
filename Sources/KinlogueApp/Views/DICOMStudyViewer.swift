import AppKit
import KinlogueCore
import SwiftUI

enum DICOMViewerWindowScene {
    static let id = "dicom-viewer"
}

struct DICOMStudyViewerContainer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DICOMStudyViewerModel
    @StateObject private var memoryPressureMonitor = DICOMViewerMemoryPressureMonitor()

    init(model: DICOMStudyViewerModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        DICOMStudyViewer(model: model) {
            Task {
                await model.close()
                dismiss()
            }
        }
        .task {
            model.activateWindow { dismiss() }
            await model.load()
        }
        .onAppear {
            memoryPressureMonitor.start {
                Task { await model.handleMemoryPressure() }
            }
        }
        .onDisappear {
            memoryPressureMonitor.stop()
            Task { await model.close() }
        }
        .frame(minWidth: 760, minHeight: 620)
    }
}

@MainActor
private final class DICOMViewerMemoryPressureMonitor: ObservableObject {
    private var source: DispatchSourceMemoryPressure?

    func start(_ handler: @escaping @MainActor @Sendable () -> Void) {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }
}

struct DICOMStudyViewer: View {
    @ObservedObject var model: DICOMStudyViewerModel
    let onClose: () -> Void

    @AccessibilityFocusState private var retryIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            viewerBody
        }
        .background(KinlogueTheme.surface)
        .onChange(of: model.statusAnnouncement) { _, announcement in
            guard let announcement else { return }
            announce(announcement)
            if model.phase == .failed { retryIsFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.string("二维医学影像查看器"))
                    .font(.title2.weight(.semibold))
                Text(AppLocalization.string("仅供查看本机原始影像，不提供诊断、测量或医学解释。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let memberLabel = model.memberLabel {
                        Text(memberLabel)
                    }
                    if let effectiveDate = model.effectiveDate {
                        Text(ReportDateSemantics.formatted(
                            effectiveDate,
                            style: .medium
                        ))
                    }
                    if model.memberLabel == nil, model.effectiveDate == nil {
                        Text(AppLocalization.string("尚未确认家庭成员与检查日期"))
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.inertObjectCount > 0 {
                Label(
                    AppLocalization.string("另保留 \(model.inertObjectCount) 个暂不可查看对象"),
                    systemImage: "archivebox"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button(AppLocalization.string("关闭"), action: onClose)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("dicom-viewer-close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var viewerBody: some View {
        VStack(spacing: 0) {
            ZStack {
                DICOMImageCanvas(
                    image: model.image,
                    zoomScale: model.zoomScale,
                    panOffset: model.panOffset,
                    onWindow: { width, center in
                        Task {
                            await model.adjustWindow(
                                widthDelta: width,
                                centerDelta: center
                            )
                        }
                    },
                    onPan: { horizontal, vertical in
                        model.pan(horizontal: horizontal, vertical: vertical)
                    },
                    onZoom: { factor, x, y in
                        model.zoom(by: factor, anchorX: x, anchorY: y)
                    },
                    onSliceStep: { delta in
                        Task { await model.moveSlice(by: delta) }
                    }
                )

                switch model.phase {
                case .idle, .loading:
                    ProgressView(AppLocalization.string("正在加载影像切片…"))
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel(AppLocalization.string("正在加载影像切片"))
                case .empty:
                    ContentUnavailableView(
                        AppLocalization.string("这项检查没有可查看的影像序列"),
                        systemImage: "rectangle.slash"
                    )
                case .failed:
                    VStack(spacing: 12) {
                        Label(
                            model.errorMessage ?? AppLocalization.string("无法显示当前影像切片"),
                            systemImage: "exclamationmark.triangle"
                        )
                        if model.canRetry {
                            Button(AppLocalization.string("重试当前切片")) {
                                Task { await model.retry() }
                            }
                            .buttonStyle(.kinloguePrimary)
                            .accessibilityIdentifier("dicom-viewer-retry")
                            .accessibilityFocused($retryIsFocused)
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                case .ready, .closed:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            if model.hasFallbackOrderingWarning {
                Label(
                    AppLocalization.string("此序列缺少完整空间几何，当前使用持久化的回退顺序。"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .accessibilityLabel(AppLocalization.string("切片顺序警告：使用回退顺序"))
            }

            DICOMViewerControls(model: model)
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
