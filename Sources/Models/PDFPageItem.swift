import Foundation

struct PDFPageItem: Identifiable, Equatable {
    let id: UUID
    let sourceFileID: UUID
    let sourceURL: URL
    let sourcePageIndex: Int
    var rotation: Int
    var isIncluded: Bool

    init(
        id: UUID = UUID(),
        sourceFileID: UUID,
        sourceURL: URL,
        sourcePageIndex: Int,
        rotation: Int = 0,
        isIncluded: Bool = true
    ) {
        self.id = id
        self.sourceFileID = sourceFileID
        self.sourceURL = sourceURL
        self.sourcePageIndex = sourcePageIndex
        self.rotation = PDFPageItem.normalizedRotation(rotation)
        self.isIncluded = isIncluded
    }

    var originalPageNumber: Int {
        sourcePageIndex + 1
    }

    static func pages(for file: PDFFileItem) -> [PDFPageItem] {
        (0..<file.pageCount).map { index in
            PDFPageItem(
                sourceFileID: file.id,
                sourceURL: file.url,
                sourcePageIndex: index
            )
        }
    }

    static func normalizedRotation(_ value: Int) -> Int {
        let remainder = value % 360
        return remainder >= 0 ? remainder : remainder + 360
    }

    mutating func rotate(by degrees: Int) {
        rotation = Self.normalizedRotation(rotation + degrees)
    }
}
