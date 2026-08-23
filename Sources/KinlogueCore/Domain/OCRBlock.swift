import Foundation

public struct NormalizedRect: Codable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }

    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        let values = [x, y, width, height]
        guard values.allSatisfy(\.isFinite),
              x >= 0,
              y >= 0,
              width >= 0,
              height >= 0,
              x + width <= 1,
              y + height <= 1 else {
            throw DomainValidationError.invalidNormalizedBounds
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                x: container.decode(Double.self, forKey: .x),
                y: container.decode(Double.self, forKey: .y),
                width: container.decode(Double.self, forKey: .width),
                height: container.decode(Double.self, forKey: .height)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Normalized bounds must be finite and contained in the unit rectangle"
                )
            )
        }
    }
}

public enum OCRMethod: String, Codable, Hashable, Sendable {
    case pdfTextLayer
    case vision
}

public struct OCRBlock: Codable, Identifiable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case sourceID
        case attachmentID
        case filePageNumber
        case text
        case boundingBox
        case confidence
        case method
        case engineVersion
    }

    public let id: UUID
    public let sourceID: ReportSource.ID?
    public let attachmentID: Attachment.ID?
    public let filePageNumber: Int
    public let text: String
    public let boundingBox: NormalizedRect
    public let confidence: Double?
    public let method: OCRMethod
    public let engineVersion: String
    private let projectedReportPageNumber: Int?

    public init(
        id: UUID = UUID(),
        pageNumber: Int,
        text: String,
        boundingBox: NormalizedRect,
        confidence: Double?,
        method: OCRMethod,
        engineVersion: String
    ) throws {
        guard pageNumber > 0 else {
            throw DomainValidationError.invalidPageNumber
        }
        if let confidence, !(0...1).contains(confidence) || !confidence.isFinite {
            throw DomainValidationError.invalidConfidence
        }
        guard !engineVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.emptyRequiredText
        }

        self.id = id
        sourceID = nil
        attachmentID = nil
        filePageNumber = pageNumber
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.method = method
        self.engineVersion = engineVersion
        projectedReportPageNumber = nil
    }

    public init(
        id: UUID = UUID(),
        sourceID: ReportSource.ID,
        attachmentID: Attachment.ID,
        filePageNumber: Int,
        text: String,
        boundingBox: NormalizedRect,
        confidence: Double?,
        method: OCRMethod,
        engineVersion: String
    ) throws {
        guard filePageNumber > 0 else { throw DomainValidationError.invalidPageNumber }
        if let confidence, !(0...1).contains(confidence) || !confidence.isFinite {
            throw DomainValidationError.invalidConfidence
        }
        guard !engineVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.emptyRequiredText
        }
        self.id = id
        self.sourceID = sourceID
        self.attachmentID = attachmentID
        self.filePageNumber = filePageNumber
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.method = method
        self.engineVersion = engineVersion
        projectedReportPageNumber = nil
    }

    public var pageNumber: Int { projectedReportPageNumber ?? filePageNumber }

    public func attributedAndValidated(for sources: ReportSources) throws -> Self {
        if let sourceID, let attachmentID {
            guard let source = sources.elements.first(where: { $0.id == sourceID }),
                  source.attachmentID == attachmentID,
                  filePageNumber <= source.pageCount else {
                throw DomainValidationError.invalidCatalogReference
            }
            return self
        }
        guard let source = sources.soleSource,
              filePageNumber <= source.pageCount else {
            throw DomainValidationError.invalidCatalogReference
        }
        return try Self(
            id: id,
            sourceID: source.id,
            attachmentID: source.attachmentID,
            filePageNumber: filePageNumber,
            text: text,
            boundingBox: boundingBox,
            confidence: confidence,
            method: method,
            engineVersion: engineVersion
        )
    }

    public func projected(for sources: ReportSources) throws -> Self {
        let validated = try attributedAndValidated(for: sources)
        guard let sourceID = validated.sourceID,
              let page = sources.logicalPage(
                  forSourceID: sourceID,
                  filePage: validated.filePageNumber
              ) else { throw DomainValidationError.invalidCatalogReference }
        return Self(
            id: validated.id,
            sourceID: try required(validated.sourceID),
            attachmentID: try required(validated.attachmentID),
            filePageNumber: validated.filePageNumber,
            text: validated.text,
            boundingBox: validated.boundingBox,
            confidence: validated.confidence,
            method: validated.method,
            engineVersion: validated.engineVersion,
            projectedReportPageNumber: page
        )
    }

    func replacingText(with text: String) -> Self {
        Self(
            id: id,
            sourceID: sourceID,
            attachmentID: attachmentID,
            filePageNumber: filePageNumber,
            text: text,
            boundingBox: boundingBox,
            confidence: confidence,
            method: method,
            engineVersion: engineVersion,
            projectedReportPageNumber: projectedReportPageNumber
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                sourceID: container.decode(ReportSource.ID.self, forKey: .sourceID),
                attachmentID: container.decode(Attachment.ID.self, forKey: .attachmentID),
                filePageNumber: container.decode(Int.self, forKey: .filePageNumber),
                text: container.decode(String.self, forKey: .text),
                boundingBox: container.decode(NormalizedRect.self, forKey: .boundingBox),
                confidence: container.decodeIfPresent(Double.self, forKey: .confidence),
                method: container.decode(OCRMethod.self, forKey: .method),
                engineVersion: container.decode(String.self, forKey: .engineVersion)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid OCR block provenance")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard projectedReportPageNumber == nil else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "A transient logical-page OCR projection cannot be persisted"
                )
            )
        }
        guard let sourceID, let attachmentID else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "OCR block lacks source identity")
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(attachmentID, forKey: .attachmentID)
        try container.encode(filePageNumber, forKey: .filePageNumber)
        try container.encode(text, forKey: .text)
        try container.encode(boundingBox, forKey: .boundingBox)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encode(method, forKey: .method)
        try container.encode(engineVersion, forKey: .engineVersion)
    }

    public func referencesSource(pageNumber: Int, boundingBox: NormalizedRect?) -> Bool {
        self.pageNumber == pageNumber && (boundingBox == nil || self.boundingBox == boundingBox)
    }

    private init(
        id: UUID,
        sourceID: ReportSource.ID?,
        attachmentID: Attachment.ID?,
        filePageNumber: Int,
        text: String,
        boundingBox: NormalizedRect,
        confidence: Double?,
        method: OCRMethod,
        engineVersion: String,
        projectedReportPageNumber: Int?
    ) {
        self.id = id
        self.sourceID = sourceID
        self.attachmentID = attachmentID
        self.filePageNumber = filePageNumber
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.method = method
        self.engineVersion = engineVersion
        self.projectedReportPageNumber = projectedReportPageNumber
    }

    private func required<T>(_ value: T?) throws -> T {
        guard let value else { throw DomainValidationError.invalidCatalogReference }
        return value
    }
}
