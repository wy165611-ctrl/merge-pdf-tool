import Foundation

struct PDFFileItem: Identifiable, Equatable {
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
}

struct PDFAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
