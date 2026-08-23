import KinlogueCore

struct TextExtractionOutputLimits: Sendable {
    /// Leaves ample room under the 16 MiB OCR-object ceiling for
    /// JSON escaping, block metadata, and extracted candidate copies.
    static let standard = Self(
        maximumBlockCount: 4_096,
        maximumBlockUTF8ByteCount: 64 * 1024,
        maximumTotalTextUTF8ByteCount: 1 * 1024 * 1024
    )

    let maximumBlockCount: Int
    let maximumBlockUTF8ByteCount: Int
    let maximumTotalTextUTF8ByteCount: Int

    init(
        maximumBlockCount: Int,
        maximumBlockUTF8ByteCount: Int,
        maximumTotalTextUTF8ByteCount: Int
    ) {
        precondition(maximumBlockCount > 0)
        precondition(maximumBlockUTF8ByteCount > 0)
        precondition(maximumTotalTextUTF8ByteCount > 0)
        self.maximumBlockCount = maximumBlockCount
        self.maximumBlockUTF8ByteCount = maximumBlockUTF8ByteCount
        self.maximumTotalTextUTF8ByteCount = maximumTotalTextUTF8ByteCount
    }
}

struct TextExtractionOutputBudget {
    let limits: TextExtractionOutputLimits
    private(set) var blockCount = 0
    private(set) var totalTextUTF8ByteCount = 0

    func validateTextLayerUpperBound(_ text: String) throws {
        guard totalTextUTF8ByteCount <= limits.maximumTotalTextUTF8ByteCount,
              text.utf8.count <= limits.maximumTotalTextUTF8ByteCount
                - totalTextUTF8ByteCount else {
            throw TextExtractionError.resourceLimitExceeded
        }
    }

    mutating func consume(_ block: OCRBlock) throws {
        let blockByteCount = block.text.utf8.count
        guard blockCount < limits.maximumBlockCount,
              blockByteCount <= limits.maximumBlockUTF8ByteCount,
              totalTextUTF8ByteCount <= limits.maximumTotalTextUTF8ByteCount,
              blockByteCount <= limits.maximumTotalTextUTF8ByteCount - totalTextUTF8ByteCount else {
            throw TextExtractionError.resourceLimitExceeded
        }
        blockCount += 1
        totalTextUTF8ByteCount += blockByteCount
    }
}
