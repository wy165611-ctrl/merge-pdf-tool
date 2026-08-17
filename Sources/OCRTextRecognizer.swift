import Foundation

enum OCRRecognitionError: LocalizedError {
    case noText
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noText:
            return "没有识别到文字。请换一张更清晰、包含文件名或关键词的截图。"
        case .unavailable:
            return "macOS 的文字识别组件当前不可用，请稍后重试或检查系统更新。"
        case .failed(let message):
            return "无法读取这张图片：\(message)"
        }
    }
}

struct OCRTextRecognizer {
    static func recognizeText(in imageURL: URL) throws -> String {
        var tesseractError: Error?
        do {
            // Tesseract is preferred when available because it is more reliable for
            // Chinese text on systems where Vision returns incomplete observations.
            return try OCRService.recognizeImageTextWithTesseract(in: imageURL)
        } catch {
            tesseractError = error
        }

        do {
            return try recognizeWithVision(in: imageURL)
        } catch let visionError {
            if let tesseractError,
               !(tesseractError is OCRTesseractError) {
                throw tesseractError
            }
            throw visionError
        }
    }

    private static func recognizeWithVision(in imageURL: URL) throws -> String {
        do {
            return try OCRService.recognizeImageTextWithVision(in: imageURL)
        } catch let error as OCRServiceError {
            switch error {
            case .noText:
                throw OCRRecognitionError.noText
            case .unavailable:
                throw OCRRecognitionError.unavailable
            case .failed(let message):
                throw OCRRecognitionError.failed(message)
            case .cancelled, .unreadablePDF, .lockedPDF, .emptyPDF:
                throw OCRRecognitionError.failed(error.localizedDescription)
            }
        } catch {
            throw OCRRecognitionError.failed(error.localizedDescription)
        }
    }

}
