import KinlogueCore

public actor OnDeviceTextExtractionService: TextExtractionService {
    private let pdfExtractor: PDFTextExtractor
    private let imageRecognizer: VisionTextRecognizer

    public init(
        pdfExtractor: PDFTextExtractor = PDFTextExtractor(),
        imageRecognizer: VisionTextRecognizer = VisionTextRecognizer()
    ) {
        self.pdfExtractor = pdfExtractor
        self.imageRecognizer = imageRecognizer
    }

    public func extractText(from file: ValidatedImportedFile) async throws -> [OCRBlock] {
        switch file.kind {
        case .pdf:
            try await pdfExtractor.extractText(from: file)
        case .image:
            try await imageRecognizer.extractText(from: file)
        }
    }
}
