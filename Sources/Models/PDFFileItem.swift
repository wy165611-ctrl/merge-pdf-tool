import Foundation

struct PDFFileItem: Identifiable, Equatable {
    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "ico", "icns"
    ]

    let id: UUID
    let url: URL
    let pageCount: Int

    init(id: UUID = UUID(), url: URL, pageCount: Int) {
        self.id = id
        self.url = url
        self.pageCount = pageCount
    }

    var fileName: String {
        url.lastPathComponent
    }

    var isImage: Bool {
        Self.supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

    var typeLabel: String {
        isImage ? "图片" : "PDF"
    }
}

struct PDFAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
