import Foundation
import AppKit
import PDFKit

enum PDFOCRValidationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String { "PDF OCR 验证失败：\(String(describing: self))" }
}

func makeScannedPDF(at url: URL, pages: [[String]]) throws {
    let document = PDFDocument()
    let pageSize = NSSize(width: 1600, height: 700)

    for lines in pages {
        let image = NSImage(size: pageSize, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 58, weight: .medium),
                .foregroundColor: NSColor.black
            ]
            for (index, line) in lines.enumerated() {
                line.draw(
                    at: NSPoint(x: 110, y: pageSize.height - CGFloat(index + 1) * 150),
                    withAttributes: attributes
                )
            }
            return true
        }
        guard let page = PDFPage(image: image) else {
            throw PDFOCRValidationError.failed("无法创建扫描型 PDF 页面")
        }
        document.insert(page, at: document.pageCount)
    }

    guard document.write(to: url) else {
        throw PDFOCRValidationError.failed("无法写入测试 PDF")
    }
}

@main
struct PDFOCRValidation {
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            throw PDFOCRValidationError.failed("缺少测试目录参数")
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = root.appendingPathComponent("pdf-ocr-fixture.pdf")
        try? FileManager.default.removeItem(at: fixture)
        try makeScannedPDF(
            at: fixture,
            pages: [
                ["成绩单 Invoice", "Student Record"],
                ["教务处 Office", "Academic Affairs"]
            ]
        )

        let token = OCRCancellationToken()
        var progress: [OCRProgress] = []
        let result = try OCRService.recognizePDF(at: fixture, token: token) { update in
            progress.append(update)
        }
        let containsChinese = result.text.contains("成绩单") || result.text.contains("教务处")
        let containsEnglish = result.text.contains("Invoice") ||
            result.text.contains("Student") ||
            result.text.contains("Office") ||
            result.text.contains("Academic")
        guard result.pages.count == 2,
              result.hasRecognizedText,
              containsChinese,
              containsEnglish else {
            throw PDFOCRValidationError.failed("中英文 PDF OCR 结果不正确：\(result.text)")
        }
        guard progress.last?.completedPages == 2,
              progress.last?.totalPages == 2,
              progress.last?.currentPage == 2 else {
            throw PDFOCRValidationError.failed("PDF OCR 进度回调不正确")
        }
        print("PDF OCR 中英文识别验证通过：2 页结果和进度均正确。")

        let textOutput = root.appendingPathComponent("pdf-ocr-result.txt")
        try? FileManager.default.removeItem(at: textOutput)
        try result.text.write(to: textOutput, atomically: true, encoding: .utf8)
        let reopenedText = try String(contentsOf: textOutput, encoding: .utf8)
        guard reopenedText == result.text,
              reopenedText.contains("成绩单"),
              reopenedText.contains("Academic Affairs") else {
            throw PDFOCRValidationError.failed("OCR TXT 导出内容或 UTF-8 编码不正确")
        }
        print("PDF OCR TXT 导出验证通过：中英文内容可按 UTF-8 写入并重新读取。")

        let blankFixture = root.appendingPathComponent("pdf-ocr-blank.pdf")
        try? FileManager.default.removeItem(at: blankFixture)
        try makeScannedPDF(at: blankFixture, pages: [[]])
        let blankResult = try OCRService.recognizePDF(at: blankFixture)
        guard blankResult.pages.count == 1, !blankResult.hasRecognizedText else {
            throw PDFOCRValidationError.failed("空白 PDF OCR 应返回空结果")
        }
        print("PDF OCR 空结果验证通过：空白页面不会导致任务失败。")

        let cancelledToken = OCRCancellationToken()
        cancelledToken.cancel()
        do {
            _ = try OCRService.recognizePDF(at: fixture, token: cancelledToken)
            throw PDFOCRValidationError.failed("预取消 OCR 没有停止")
        } catch let error as OCRServiceError {
            guard case .cancelled = error else {
                throw PDFOCRValidationError.failed("取消任务错误类型不正确：\(error.localizedDescription)")
            }
        }
        print("PDF OCR 取消验证通过：取消令牌可在开始前停止任务。")

        let inProgressToken = OCRCancellationToken()
        var inProgressUpdates: [OCRProgress] = []
        do {
            _ = try OCRService.recognizePDF(at: fixture, token: inProgressToken) { update in
                inProgressUpdates.append(update)
                if update.completedPages == 1 {
                    inProgressToken.cancel()
                }
            }
            throw PDFOCRValidationError.failed("进行中的 OCR 没有在页面边界停止")
        } catch let error as OCRServiceError {
            guard case .cancelled = error,
                  inProgressUpdates.last?.completedPages == 1 else {
                throw PDFOCRValidationError.failed("进行中取消的状态或进度不正确")
            }
        }
        print("PDF OCR 进行中取消验证通过：完成第 1 页后停止后续页面。")
    }
}
