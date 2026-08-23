import SwiftUI

struct DICOMViewerControls: View {
    @ObservedObject var model: DICOMStudyViewerModel

    var body: some View {
        VStack(spacing: 10) {
            seriesAndPlaybackControls

            HStack(spacing: 12) {
                Button {
                    Task { await model.moveSlice(by: -1) }
                } label: {
                    Label(AppLocalization.string("上一张"), systemImage: "chevron.left")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model.currentSliceIndex <= 0)

                Slider(
                    value: Binding(
                        get: { Double(model.currentSliceIndex) },
                        set: { value in
                            Task { await model.selectSlice(at: Int(value.rounded())) }
                        }
                    ),
                    in: 0...Double(max(1, model.totalSliceCount - 1)),
                    step: 1
                )
                .disabled(model.totalSliceCount <= 1)
                .accessibilityLabel(AppLocalization.string("切片位置"))
                .accessibilityValue(AppLocalization.string("第 \(model.currentSliceOrdinal) 张，共 \(model.totalSliceCount) 张"))
                .accessibilityIdentifier("dicom-viewer-slice-slider")

                Text("\(model.currentSliceOrdinal) / \(model.totalSliceCount)")
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 72, alignment: .trailing)
                    .accessibilityHidden(true)

                Button {
                    Task { await model.moveSlice(by: 1) }
                } label: {
                    Label(AppLocalization.string("下一张"), systemImage: "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(
                    model.totalSliceCount == 0
                        || model.currentSliceIndex >= model.totalSliceCount - 1
                )
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    displayStatus
                    Spacer()
                    viewerActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    displayStatus
                    viewerActions
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            Text(AppLocalization.string("拖动：窗宽窗位 · Space/辅助拖动：平移 · 捏合或 Command-滚动：缩放 · 滚动或左右方向键：切片"))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(AppLocalization.string("连续播放仅按顺序浏览空间切片，不代表真实时间动态影像。"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(KinlogueTheme.surface)
    }

    private var seriesAndPlaybackControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                seriesNavigation
                Spacer()
                playbackControls
            }
            VStack(alignment: .leading, spacing: 8) {
                seriesNavigation
                playbackControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var seriesNavigation: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.moveSeries(by: -1) }
            } label: {
                Label(AppLocalization.string("上一个序列"), systemImage: "chevron.backward.2")
            }
            .disabled(!model.canMoveToPreviousSeries)
            .accessibilityIdentifier("dicom-viewer-series-previous")

            Picker(
                AppLocalization.string("影像序列"),
                selection: Binding(
                    get: { model.selectedSeriesID },
                    set: { id in
                        guard let id, id != model.selectedSeriesID else { return }
                        Task { await model.selectSeries(id) }
                    }
                )
            ) {
                ForEach(model.series) { item in
                    Text(AppLocalization.string("序列 \(item.ordinal)，\(item.sliceCount) 张"))
                        .tag(Optional(item.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(model.series.isEmpty)
            .frame(minWidth: 170, idealWidth: 210, maxWidth: 260)
            .accessibilityLabel(AppLocalization.string("影像序列"))
            .accessibilityIdentifier("dicom-viewer-series-picker")

            Text(AppLocalization.string("共 \(model.series.count) 个序列，\(model.totalViewableSliceCount) 张可查看影像"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                Task { await model.moveSeries(by: 1) }
            } label: {
                Label(AppLocalization.string("下一个序列"), systemImage: "chevron.forward.2")
            }
            .disabled(!model.canMoveToNextSeries)
            .accessibilityIdentifier("dicom-viewer-series-next")
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlayback()
            } label: {
                Label(
                    model.isPlaying
                        ? AppLocalization.string("暂停播放")
                        : AppLocalization.string("连续播放"),
                    systemImage: model.isPlaying ? "pause.fill" : "play.fill"
                )
            }
            .disabled(!model.canPlay && !model.isPlaying)
            .keyboardShortcut("p", modifiers: [.command])
            .accessibilityIdentifier("dicom-viewer-playback")

            Menu(AppLocalization.string("每秒 \(model.playbackRate.rawValue) 张")) {
                ForEach(DICOMPlaybackRate.allCases) { rate in
                    Button {
                        model.setPlaybackRate(rate)
                    } label: {
                        if model.playbackRate == rate {
                            Label(
                                AppLocalization.string("每秒 \(rate.rawValue) 张"),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(AppLocalization.string("每秒 \(rate.rawValue) 张"))
                        }
                    }
                }
            }
            .disabled(model.totalSliceCount <= 1)
            .accessibilityLabel(AppLocalization.string("播放速度"))
        }
    }

    private var displayStatus: some View {
        HStack(spacing: 12) {
            if let center = model.windowCenter, let width = model.windowWidth {
                Text(AppLocalization.string("窗位 \(formatted(center)) · 窗宽 \(formatted(width))"))
            } else {
                Text(AppLocalization.string("窗宽窗位尚未加载"))
            }
            Text(AppLocalization.string("缩放 \(Int((model.zoomScale * 100).rounded()))%"))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var viewerActions: some View {
        HStack(spacing: 12) {
            Button {
                model.zoom(by: 0.8, anchorX: 0, anchorY: 0)
            } label: {
                Label(AppLocalization.string("缩小"), systemImage: "minus.magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("-", modifiers: [.command])

            Button {
                model.zoom(by: 1.25, anchorX: 0, anchorY: 0)
            } label: {
                Label(AppLocalization.string("放大"), systemImage: "plus.magnifyingglass")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("+", modifiers: [.command])

            Button(AppLocalization.string("适合窗口")) { model.fit() }
                .keyboardShortcut("0", modifiers: [.command])
                .accessibilityIdentifier("dicom-viewer-fit")

            Button(AppLocalization.string("重置")) {
                Task { await model.reset() }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityIdentifier("dicom-viewer-reset")

            Menu(AppLocalization.string("键盘调整")) {
                Button(AppLocalization.string("降低窗位")) {
                    Task { await model.adjustWindow(widthDelta: 0, centerDelta: -10) }
                }
                .disabled(model.windowCenter == nil || model.windowWidth == nil)
                Button(AppLocalization.string("提高窗位")) {
                    Task { await model.adjustWindow(widthDelta: 0, centerDelta: 10) }
                }
                .disabled(model.windowCenter == nil || model.windowWidth == nil)
                Button(AppLocalization.string("缩小窗宽")) {
                    Task { await model.adjustWindow(widthDelta: -10, centerDelta: 0) }
                }
                .disabled(model.windowCenter == nil || model.windowWidth == nil)
                Button(AppLocalization.string("扩大窗宽")) {
                    Task { await model.adjustWindow(widthDelta: 10, centerDelta: 0) }
                }
                .disabled(model.windowCenter == nil || model.windowWidth == nil)
                Divider()
                Button(AppLocalization.string("向左平移")) { model.pan(horizontal: -20, vertical: 0) }
                Button(AppLocalization.string("向右平移")) { model.pan(horizontal: 20, vertical: 0) }
                Button(AppLocalization.string("向上平移")) { model.pan(horizontal: 0, vertical: -20) }
                Button(AppLocalization.string("向下平移")) { model.pan(horizontal: 0, vertical: 20) }
            }
            .accessibilityHint(AppLocalization.string("提供窗宽窗位和平移的键盘操作"))
        }
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
