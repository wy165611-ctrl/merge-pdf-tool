import Foundation
import PDFKit

enum PDFDocumentWriteError: LocalizedError {
    case compressionUnavailable
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .compressionUnavailable:
            return "PDF 压缩需要 macOS 13.4 或更高版本。请关闭压缩选项后重试。"
        case .saveFailed(let path):
            return "无法写入保存位置：\(path)\n请检查权限或选择其他位置。"
        }
    }
}

enum PDFDocumentWriter {
    static func write(_ document: PDFDocument, to url: URL, compressed: Bool) throws {
        let didWrite: Bool

        if compressed {
            guard #available(macOS 13.4, *) else {
                throw PDFDocumentWriteError.compressionUnavailable
            }

            let options: [PDFDocumentWriteOption: Any] = [
                PDFDocumentWriteOption.saveImagesAsJPEGOption: true,
                PDFDocumentWriteOption.optimizeImagesForScreenOption: true
            ]
            didWrite = document.write(to: url, withOptions: options)
        } else {
            didWrite = document.write(to: url)
        }

        guard didWrite else {
            throw PDFDocumentWriteError.saveFailed(url.path)
        }
    }
}
