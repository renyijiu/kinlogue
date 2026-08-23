import AppKit
import KinlogueCore
import SwiftUI
import UniformTypeIdentifiers

enum OriginalDocumentPresentation {
    case inline(onOpenOriginal: (() -> Void)?)
    case viewer
}

enum OriginalDocumentLayout {
    static func fittedSize(content: CGSize, container: CGSize) -> CGSize {
        guard content.width.isFinite,
              content.height.isFinite,
              container.width.isFinite,
              container.height.isFinite,
              content.width > 0,
              content.height > 0,
              container.width > 0,
              container.height > 0 else {
            return .zero
        }
        let scale = min(
            1,
            min(container.width / content.width, container.height / content.height)
        )
        guard scale.isFinite, scale > 0 else { return .zero }
        return CGSize(width: content.width * scale, height: content.height * scale)
    }

    static func widthFittedSize(
        content: CGSize,
        containerWidth: CGFloat,
        zoom: CGFloat = 1
    ) -> CGSize {
        guard content.width.isFinite,
              content.height.isFinite,
              containerWidth.isFinite,
              zoom.isFinite,
              content.width > 0,
              content.height > 0,
              containerWidth > 0,
              zoom > 0 else {
            return .zero
        }
        let scale = containerWidth / content.width * zoom
        guard scale.isFinite, scale > 0 else { return .zero }
        return CGSize(width: content.width * scale, height: content.height * scale)
    }

    static func zoomedSize(content: CGSize, container: CGSize, zoom: Double) -> CGSize {
        guard zoom.isFinite, zoom > 0 else { return .zero }
        let fitted = fittedSize(content: content, container: container)
        guard fitted != .zero else { return .zero }
        return CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
    }

    static func maximumZoom(content: CGSize, container: CGSize) -> Double {
        let fitted = fittedSize(content: content, container: container)
        guard fitted != .zero else { return 2.4 }
        let actualSizeZoom = max(
            content.width / fitted.width,
            content.height / fitted.height
        )
        guard actualSizeZoom.isFinite else { return 2.4 }
        return max(2.4, actualSizeZoom)
    }
}

enum OriginalDocumentRotation: Int, Equatable {
    case zero = 0
    case clockwise90 = 90
    case clockwise180 = 180
    case clockwise270 = 270

    var angle: Angle {
        .degrees(Double(rawValue))
    }

    mutating func rotateLeft() {
        self = switch self {
        case .zero: .clockwise270
        case .clockwise90: .zero
        case .clockwise180: .clockwise90
        case .clockwise270: .clockwise180
        }
    }

    mutating func rotateRight() {
        self = switch self {
        case .zero: .clockwise90
        case .clockwise90: .clockwise180
        case .clockwise180: .clockwise270
        case .clockwise270: .zero
        }
    }

    func orientedSize(_ size: CGSize) -> CGSize {
        swapsDimensions
            ? CGSize(width: size.height, height: size.width)
            : size
    }

    func unrotatedRenderSize(_ orientedSize: CGSize) -> CGSize {
        swapsDimensions
            ? CGSize(width: orientedSize.height, height: orientedSize.width)
            : orientedSize
    }

    private var swapsDimensions: Bool {
        self == .clockwise90 || self == .clockwise270
    }
}

struct OriginalDocumentView: View {
    let payload: OriginalDocumentPayload

    var body: some View {
        OriginalDocumentContent(payload: payload, presentation: .viewer)
    }
}

struct OriginalDocumentFitPreview: View {
    let payload: OriginalDocumentPayload
    let onOpenOriginal: (() -> Void)?

    var body: some View {
        OriginalDocumentContent(
            payload: payload,
            presentation: .inline(onOpenOriginal: onOpenOriginal)
        )
    }
}

struct OrderedOriginalDocumentView: View {
    let sources: ReportSources
    let selectedSourceID: ReportSource.ID?
    let payload: OriginalDocumentPayload?
    let isLoading: Bool
    let onSelectSource: (ReportSource.ID) -> Void
    let presentation: OriginalDocumentPresentation

    var body: some View {
        VStack(spacing: 0) {
            if sources.count > 1 { sourceNavigation }
            Group {
                if isLoading {
                    ProgressView(AppLocalization.string("正在读取所选原件…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let payload {
                    OriginalDocumentContent(
                        payload: payload,
                        presentation: presentation
                    )
                } else {
                    ContentUnavailableView(AppLocalization.string("原件暂时无法打开"), systemImage: "doc.questionmark")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .id(selectedSourceID)
        }
    }

    private var sourceNavigation: some View {
        HStack(spacing: 10) {
            Button {
                select(offset: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(selectedIndex <= 0 || isLoading)
            .accessibilityLabel(AppLocalization.string("上一个原件"))

            VStack(spacing: 2) {
                Text(selectedSource?.displayName ?? AppLocalization.string("原件 \(selectedIndex + 1)"))
                    .lineLimit(1)
                Text(AppLocalization.string("第 \(selectedIndex + 1) 个，共 \(sources.count) 个"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AppLocalization.string("原件 \(selectedIndex + 1)，共 \(sources.count) 个"))

            Button {
                select(offset: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(selectedIndex >= sources.count - 1 || isLoading)
            .accessibilityLabel(AppLocalization.string("下一个原件"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .accessibilityIdentifier("ordered-original-navigation")
    }

    private var selectedIndex: Int {
        guard let selectedSourceID,
              let index = sources.elements.firstIndex(where: { $0.id == selectedSourceID }) else {
            return 0
        }
        return index
    }

    private var selectedSource: ReportSource? {
        sources.elements[selectedIndex]
    }

    private func select(offset: Int) {
        let index = selectedIndex + offset
        guard sources.elements.indices.contains(index) else { return }
        onSelectSource(sources.elements[index].id)
    }
}

struct OrderedOriginalDocumentViewer: View {
    @Environment(\.dismiss) private var dismiss
    let sources: ReportSources
    let selectedSourceID: ReportSource.ID?
    let payload: OriginalDocumentPayload?
    let isLoading: Bool
    let onSelectSource: (ReportSource.ID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(AppLocalization.string("查看原图"), systemImage: "doc.richtext")
                    .font(.headline)
                Spacer()
                Button(AppLocalization.string("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("record-original-viewer-close")
            }
            .padding(14)
            Divider()
            OrderedOriginalDocumentView(
                sources: sources,
                selectedSourceID: selectedSourceID,
                payload: payload,
                isLoading: isLoading,
                onSelectSource: onSelectSource,
                presentation: .viewer
            )
        }
        .frame(minWidth: 860, idealWidth: 1_120, minHeight: 620, idealHeight: 780)
        .accessibilityIdentifier("record-original-viewer")
    }
}

private struct OriginalDocumentContent: View {
    let payload: OriginalDocumentPayload
    let presentation: OriginalDocumentPresentation

    var body: some View {
        if UTType(payload.contentTypeIdentifier)?.conforms(to: .pdf) == true {
            PrivatePDFDocumentView(
                data: payload.data,
                presentation: presentation
            )
        } else {
            PrivateImageDocumentView(
                data: payload.data,
                presentation: presentation
            )
        }
    }
}

private struct PrivatePDFDocumentView: View {
    let data: Data
    let presentation: OriginalDocumentPresentation
    @State private var loadState: LoadState = .loading

    var body: some View {
        ZStack {
            switch loadState {
            case let .loaded(session):
                PrivatePDFPagesView(
                    session: session,
                    presentation: presentation
                )
            case .failed:
                ContentUnavailableView(
                    AppLocalization.string("原件无法显示"),
                    systemImage: "doc.questionmark"
                )
                .accessibilityIdentifier("original-document-unavailable")
            case .loading:
                ProgressView(AppLocalization.string("正在准备原件…"))
            }
        }
        .task {
            await loadDocument()
        }
        .onDisappear {
            guard case let .loaded(session) = loadState else { return }
            loadState = .loading
            Task {
                await OriginalDocumentPDFRenderer.release(sessionID: session.id)
            }
        }
    }

    @MainActor
    private func loadDocument() async {
        guard case .loading = loadState else { return }
        guard let session = await OriginalDocumentPDFRenderer.open(data: data) else {
            guard !Task.isCancelled else { return }
            loadState = .failed
            return
        }
        guard !Task.isCancelled else {
            await OriginalDocumentPDFRenderer.release(sessionID: session.id)
            return
        }
        loadState = .loaded(session)
    }

    private enum LoadState {
        case loading
        case loaded(OriginalDocumentPDFSession)
        case failed
    }
}

struct OriginalDocumentViewer: View {
    @Environment(\.dismiss) private var dismiss
    let payload: OriginalDocumentPayload

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(AppLocalization.string("查看原图"), systemImage: "doc.richtext")
                    .font(.headline)
                Spacer()
                Button(AppLocalization.string("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("record-original-viewer-close")
            }
            .padding(14)
            Divider()
            OriginalDocumentView(payload: payload)
        }
        .frame(minWidth: 860, idealWidth: 1_120, minHeight: 620, idealHeight: 780)
        .accessibilityIdentifier("record-original-viewer")
    }
}

/// Renders one PDF page at a time into an in-memory image. The view has no text
/// selection, pasteboard, drag source, URL, context menu, Share or Quick Look path.
private struct PrivatePDFPagesView: View {
    let session: OriginalDocumentPDFSession
    let presentation: OriginalDocumentPresentation
    @State private var pageIndex = 0
    @State private var pageMetadataState: PageMetadataLoadState = .idle
    @State private var zoom = 1.0
    @State private var viewportSize = CGSize.zero
    @State private var fitZoomPercent = 100

    var body: some View {
        Group {
            switch presentation {
            case .viewer:
                interactiveDocument
            case .inline(let onOpenOriginal):
                fittedDocument(onOpenOriginal: onOpenOriginal)
            }
        }
        .task(id: metadataKey) {
            await loadPageMetadata(for: metadataKey)
        }
    }

    private var interactiveDocument: some View {
        VStack(spacing: 0) {
            HStack {
                pageNavigation
                Spacer()
                Button { zoom = max(0.6, zoom - 0.2) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .accessibilityLabel(AppLocalization.string("缩小原件"))
                .accessibilityValue(AppLocalization.string("当前 \(Int(zoom * 100))%"))
                Button { zoom = min(maximumZoom, zoom + 0.2) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .accessibilityLabel(AppLocalization.string("放大原件"))
                .accessibilityValue(AppLocalization.string("当前 \(Int(zoom * 100))%"))
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    if let pageSize {
                        let displaySize = OriginalDocumentLayout.zoomedSize(
                            content: pageSize,
                            container: proxy.size,
                            zoom: zoom
                        )
                        ZStack {
                            InteractivePDFPage(
                                renderKey: PDFPageRenderKey(
                                    sessionID: session.id,
                                    pageIndex: pageIndex,
                                    renderSize: OriginalDocumentPDFLayout.renderSize(
                                        pageSize: pageSize,
                                        zoom: zoom
                                    )
                                ),
                                displaySize: displaySize,
                                accessibilityLabel: AppLocalization.string("原始 PDF 第 \(pageIndex + 1) 页")
                            )
                        }
                        .frame(
                            width: max(displaySize.width, proxy.size.width),
                            height: max(displaySize.height, proxy.size.height)
                        )
                    } else if metadataFailed {
                        unavailablePage
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    } else {
                        ProgressView(AppLocalization.string("正在准备原件…"))
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear { viewportSize = proxy.size }
                .onChange(of: proxy.size) { _, size in
                    viewportSize = size
                    zoom = min(zoom, maximumZoom)
                }
            }
        }
        .onChange(of: pageIndex) { _, _ in zoom = min(zoom, maximumZoom) }
    }

    private func fittedDocument(onOpenOriginal: (() -> Void)?) -> some View {
        VStack(spacing: 0) {
            HStack {
                pageNavigation
                Spacer()
                PreviewZoomControls(zoomPercent: $fitZoomPercent)
                if let onOpenOriginal {
                    Button(AppLocalization.string("查看原图"), action: onOpenOriginal)
                        .accessibilityIdentifier("record-original-open")
                        .accessibilityHint(AppLocalization.string("在独立窗口中查看和缩放原件"))
                }
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
            if let pageSize {
                FittedPDFPage(
                    renderKey: PDFPageRenderKey(
                        sessionID: session.id,
                        pageIndex: pageIndex,
                        renderSize: OriginalDocumentPDFLayout.renderSize(
                            pageSize: pageSize,
                            zoom: 1
                        )
                    ),
                    accessibilityLabel: AppLocalization.string("完整预览，PDF 第 \(pageIndex + 1) 页"),
                    zoom: CGFloat(fitZoomPercent) / 100,
                    onOpenOriginal: onOpenOriginal
                )
                .id(pageIndex)
            } else if metadataFailed {
                unavailablePage
            } else {
                ProgressView(AppLocalization.string("正在准备原件…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var pageNavigation: some View {
        Group {
            Button { pageIndex = max(0, pageIndex - 1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(pageIndex == 0)
            .accessibilityLabel(AppLocalization.string("上一页"))
            Text(AppLocalization.string("第 \(pageIndex + 1) 页，共 \(session.pageCount) 页"))
                .monospacedDigit()
                .accessibilityLabel(AppLocalization.string("原件第 \(pageIndex + 1) 页，共 \(session.pageCount) 页"))
            Button { pageIndex = min(session.pageCount - 1, pageIndex + 1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(pageIndex >= session.pageCount - 1)
            .accessibilityLabel(AppLocalization.string("下一页"))
        }
    }

    private var pageSize: CGSize? {
        guard case let .loaded(key, metadata) = pageMetadataState,
              key == metadataKey else {
            return nil
        }
        return metadata.mediaBoxSize
    }

    private var metadataFailed: Bool {
        guard case let .failed(key) = pageMetadataState else { return false }
        return key == metadataKey
    }

    private var metadataKey: PDFPageMetadataKey {
        PDFPageMetadataKey(sessionID: session.id, pageIndex: pageIndex)
    }

    private var unavailablePage: some View {
        ContentUnavailableView(
            AppLocalization.string("原件无法显示"),
            systemImage: "doc.questionmark"
        )
        .accessibilityIdentifier("original-document-unavailable")
    }

    private var maximumZoom: Double {
        guard let pageSize else { return 2.4 }
        return OriginalDocumentLayout.maximumZoom(
            content: pageSize,
            container: viewportSize
        )
    }

    @MainActor
    private func loadPageMetadata(for key: PDFPageMetadataKey) async {
        pageMetadataState = .loading(key)
        guard let metadata = await OriginalDocumentPDFRenderer.pageMetadata(
            sessionID: key.sessionID,
            pageIndex: key.pageIndex
        ) else {
            guard !Task.isCancelled, key == metadataKey else { return }
            pageMetadataState = .failed(key)
            return
        }
        guard !Task.isCancelled, key == metadataKey else { return }
        pageMetadataState = .loaded(key, metadata)
    }

    private enum PageMetadataLoadState {
        case idle
        case loading(PDFPageMetadataKey)
        case loaded(PDFPageMetadataKey, OriginalDocumentPDFPageMetadata)
        case failed(PDFPageMetadataKey)
    }
}

private struct PDFPageMetadataKey: Equatable, Hashable {
    let sessionID: UUID
    let pageIndex: Int
}

private struct PDFPageRenderKey: Equatable {
    let sessionID: UUID
    let pageIndex: Int
    let renderSize: CGSize
}

@MainActor
private func renderPDFPage(for key: PDFPageRenderKey) async -> NSImage? {
    guard let raster = await OriginalDocumentPDFRenderer.render(
        sessionID: key.sessionID,
        pageIndex: key.pageIndex,
        renderSize: key.renderSize
    ), !Task.isCancelled else {
        return nil
    }
    let cgImage = raster.cgImage
    return NSImage(
        cgImage: cgImage,
        size: NSSize(width: cgImage.width, height: cgImage.height)
    )
}

private struct InteractivePDFPage: View {
    let renderKey: PDFPageRenderKey
    let displaySize: CGSize
    let accessibilityLabel: String
    @State private var image: NSImage?
    @State private var renderedKey: PDFPageRenderKey?

    var body: some View {
        Group {
            if let image, renderedKey == renderKey {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .accessibilityLabel(accessibilityLabel)
            } else {
                ProgressView(AppLocalization.string("正在准备原件…"))
            }
        }
        .task(id: renderKey) {
            await render()
        }
    }

    @MainActor
    private func render() async {
        let key = renderKey
        guard let renderedImage = await renderPDFPage(for: key),
              key == renderKey else {
            return
        }
        image = renderedImage
        renderedKey = key
    }
}

private struct FittedPDFPage: View {
    let renderKey: PDFPageRenderKey
    let accessibilityLabel: String
    let zoom: CGFloat
    let onOpenOriginal: (() -> Void)?
    @State private var image: NSImage?
    @State private var renderedKey: PDFPageRenderKey?

    var body: some View {
        Group {
            if let image, renderedKey == renderKey {
                FittedOriginalImage(
                    image: image,
                    accessibilityLabel: accessibilityLabel,
                    zoom: zoom,
                    rotation: .zero,
                    onOpenOriginal: onOpenOriginal
                )
            } else {
                ProgressView(AppLocalization.string("正在准备原件…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: renderKey) {
            await render()
        }
    }

    @MainActor
    private func render() async {
        let key = renderKey
        guard let renderedImage = await renderPDFPage(for: key),
              key == renderKey else {
            return
        }
        image = renderedImage
        renderedKey = key
    }
}

private struct PrivateImageDocumentView: View {
    let data: Data
    let presentation: OriginalDocumentPresentation
    @State private var loadState: LoadState = .loading

    var body: some View {
        Group {
            switch loadState {
            case let .loaded(image):
                PrivateImageView(
                    image: image,
                    presentation: presentation
                )
            case .failed:
                ContentUnavailableView(AppLocalization.string("原件无法显示"), systemImage: "doc.questionmark")
            case .loading:
                ProgressView(AppLocalization.string("正在准备原件…"))
            }
        }
        .task {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard case .loading = loadState else { return }
        let maximumPixelSize = switch presentation {
        case .viewer: BoundedImageThumbnailDecoder.defaultMaximumPixelSize
        case .inline: 1_600
        }
        let thumbnail = await BoundedImageThumbnailDecoder.decode(
            data: data,
            maximumPixelSize: maximumPixelSize
        )
        guard !Task.isCancelled else { return }
        guard let thumbnail else {
            loadState = .failed
            return
        }
        let image = thumbnail.cgImage
        loadState = .loaded(NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        ))
    }

    private enum LoadState {
        case loading
        case loaded(NSImage)
        case failed
    }
}

private struct PrivateImageView: View {
    let image: NSImage
    let presentation: OriginalDocumentPresentation
    @State private var zoom = 1.0
    @State private var viewportSize = CGSize.zero
    @State private var fitZoomPercent = 100
    @State private var rotation = OriginalDocumentRotation.zero

    var body: some View {
        switch presentation {
        case .viewer:
            interactiveImage
        case .inline(let onOpenOriginal):
            fittedImage(onOpenOriginal: onOpenOriginal)
        }
    }

    private var interactiveImage: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppLocalization.string("原始图片"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ImageRotationControls(rotation: $rotation)
                Button { zoom = max(0.4, zoom - 0.2) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .accessibilityLabel(AppLocalization.string("缩小原件"))
                .accessibilityValue(AppLocalization.string("当前 \(Int(zoom * 100))%"))
                Button { zoom = min(maximumZoom, zoom + 0.2) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .accessibilityLabel(AppLocalization.string("放大原件"))
                .accessibilityValue(AppLocalization.string("当前 \(Int(zoom * 100))%"))
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    let displaySize = OriginalDocumentLayout.zoomedSize(
                        content: rotation.orientedSize(image.size),
                        container: proxy.size,
                        zoom: zoom
                    )
                    RotatedOriginalImage(
                        image: image,
                        rotation: rotation,
                        displaySize: displaySize
                    )
                    .accessibilityLabel(AppLocalization.string("原始报告图片"))
                    .frame(
                        width: max(displaySize.width, proxy.size.width),
                        height: max(displaySize.height, proxy.size.height)
                    )
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear { viewportSize = proxy.size }
                .onChange(of: proxy.size) { _, size in
                    viewportSize = size
                    zoom = min(zoom, maximumZoom)
                }
            }
        }
        .onChange(of: rotation) { _, _ in zoom = min(zoom, maximumZoom) }
    }

    private func fittedImage(onOpenOriginal: (() -> Void)?) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppLocalization.string("完整预览"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ImageRotationControls(rotation: $rotation)
                PreviewZoomControls(zoomPercent: $fitZoomPercent)
                if let onOpenOriginal {
                    Button(AppLocalization.string("查看原图"), action: onOpenOriginal)
                        .accessibilityIdentifier("record-original-open")
                        .accessibilityHint(AppLocalization.string("在独立窗口中查看和缩放原件"))
                }
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
            FittedOriginalImage(
                image: image,
                accessibilityLabel: onOpenOriginal == nil
                    ? AppLocalization.string("完整预览")
                    : AppLocalization.string("完整预览，点击查看原图"),
                zoom: CGFloat(fitZoomPercent) / 100,
                rotation: rotation,
                onOpenOriginal: onOpenOriginal
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var maximumZoom: Double {
        OriginalDocumentLayout.maximumZoom(
            content: rotation.orientedSize(image.size),
            container: viewportSize
        )
    }
}

struct FittedOriginalImage: View {
    let image: NSImage
    let accessibilityLabel: String
    let zoom: CGFloat
    let rotation: OriginalDocumentRotation
    let onOpenOriginal: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let fittedSize = OriginalDocumentLayout.widthFittedSize(
                content: rotation.orientedSize(image.size),
                containerWidth: proxy.size.width,
                zoom: zoom
            )
            ScrollView([.horizontal, .vertical]) {
                Group {
                    if let onOpenOriginal {
                        Button(action: onOpenOriginal) {
                            fittedImage(size: fittedSize)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(AppLocalization.string("在独立窗口中查看和缩放原件"))
                    } else {
                        fittedImage(size: fittedSize)
                    }
                }
                .frame(
                    minWidth: proxy.size.width,
                    minHeight: proxy.size.height,
                    alignment: .top
                )
                .accessibilityIdentifier("original-document-fit-preview")
                .accessibilityLabel(accessibilityLabel)
            }
        }
        .frame(minHeight: 240)
    }

    private func fittedImage(size: CGSize) -> some View {
        RotatedOriginalImage(
            image: image,
            rotation: rotation,
            displaySize: size
        )
            .contentShape(Rectangle())
    }
}

private struct RotatedOriginalImage: View {
    let image: NSImage
    let rotation: OriginalDocumentRotation
    let displaySize: CGSize

    var body: some View {
        let renderSize = rotation.unrotatedRenderSize(displaySize)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: renderSize.width, height: renderSize.height)
            .rotationEffect(rotation.angle)
            .frame(width: displaySize.width, height: displaySize.height)
    }
}

private struct ImageRotationControls: View {
    @Binding var rotation: OriginalDocumentRotation

    var body: some View {
        HStack(spacing: 8) {
            Button {
                rotation.rotateLeft()
            } label: {
                Image(systemName: "rotate.left")
            }
            .accessibilityIdentifier("record-original-rotate-left")
            .accessibilityLabel(AppLocalization.string("向左旋转"))

            Button {
                rotation.rotateRight()
            } label: {
                Image(systemName: "rotate.right")
            }
            .accessibilityIdentifier("record-original-rotate-right")
            .accessibilityLabel(AppLocalization.string("向右旋转"))
        }
        .buttonStyle(.borderless)
    }
}

enum OriginalDocumentPreviewZoom {
    static let minimum = 60
    static let maximum = 240
    static let step = 20

    static func zoomedOut(from value: Int) -> Int {
        max(minimum, value - step)
    }

    static func zoomedIn(from value: Int) -> Int {
        min(maximum, value + step)
    }
}

private struct PreviewZoomControls: View {
    @Binding var zoomPercent: Int

    var body: some View {
        HStack(spacing: 8) {
            Button {
                zoomPercent = OriginalDocumentPreviewZoom.zoomedOut(from: zoomPercent)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoomPercent <= OriginalDocumentPreviewZoom.minimum)
            .accessibilityIdentifier("record-original-zoom-out")
            .accessibilityLabel(AppLocalization.string("缩小原件"))
            .accessibilityValue(AppLocalization.string("当前 \(zoomPercent)%"))

            Button {
                zoomPercent = OriginalDocumentPreviewZoom.zoomedIn(from: zoomPercent)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(zoomPercent >= OriginalDocumentPreviewZoom.maximum)
            .accessibilityIdentifier("record-original-zoom-in")
            .accessibilityLabel(AppLocalization.string("放大原件"))
            .accessibilityValue(AppLocalization.string("当前 \(zoomPercent)%"))
        }
        .buttonStyle(.borderless)
    }
}
