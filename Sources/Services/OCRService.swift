import Foundation
import AppKit
import ImageIO
import PDFKit
import Vision

struct OCRTextObservation: Equatable {
    let text: String
    let boundingBox: CGRect
}

struct OCRPageResult: Identifiable {
    let id: Int
    let pageIndex: Int
    let text: String
    let observations: [OCRTextObservation]
}

struct OCRProgress {
    let completedPages: Int
    let totalPages: Int
    let currentPage: Int
}

struct OCRDocumentResult {
    let sourceURL: URL
    let pages: [OCRPageResult]

    var text: String {
        pages.map { page in
            let pageText = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return pageText.isEmpty ? "第 \(page.pageIndex + 1) 页：\n（未识别到文字）" : "第 \(page.pageIndex + 1) 页：\n\(pageText)"
        }
        .joined(separator: "\n\n")
    }

    var hasRecognizedText: Bool {
        pages.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

final class OCRCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

enum OCRServiceError: LocalizedError {
    case noText
    case unavailable
    case cancelled
    case unreadablePDF(String)
    case lockedPDF(String)
    case emptyPDF(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noText:
            return "没有识别到文字。"
        case .unavailable:
            return "macOS Vision 文字识别组件当前不可用。"
        case .cancelled:
            return "OCR 已取消。"
        case .unreadablePDF(let name):
            return "无法读取 PDF：\(name)。"
        case .lockedPDF(let name):
            return "PDF 已加密或需要密码：\(name)。"
        case .emptyPDF(let name):
            return "PDF 没有页面：\(name)。"
        case .failed(let message):
            return "OCR 失败：\(message)"
        }
    }
}

enum OCRTesseractError: LocalizedError {
    case unavailable
    case noText
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "未安装 Tesseract 中文识别组件。"
        case .noText:
            return "Tesseract 没有识别到文字。"
        case .failed(let message):
            return message
        }
    }
}

enum OCRService {
    private static let maximumOCRPixelDimension = 2400
    private static let recognitionLanguages = ["zh-Hans", "en-US"]

    static func recognizePDF(
        at url: URL,
        token: OCRCancellationToken = OCRCancellationToken(),
        progress: ((OCRProgress) -> Void)? = nil
    ) throws -> OCRDocumentResult {
        guard let document = PDFDocument(url: url) else {
            throw OCRServiceError.unreadablePDF(url.lastPathComponent)
        }
        if document.isLocked {
            throw OCRServiceError.lockedPDF(url.lastPathComponent)
        }
        guard document.pageCount > 0 else {
            throw OCRServiceError.emptyPDF(url.lastPathComponent)
        }

        var pages: [OCRPageResult] = []
        pages.reserveCapacity(document.pageCount)

        for index in 0..<document.pageCount {
            if token.isCancelled {
                throw OCRServiceError.cancelled
            }
            guard let page = document.page(at: index) else {
                throw OCRServiceError.failed("无法读取第 \(index + 1) 页")
            }

            let image = try render(page: page)
            let result = try recognize(image: image, pageIndex: index, token: token)
            pages.append(result)
            progress?(OCRProgress(
                completedPages: index + 1,
                totalPages: document.pageCount,
                currentPage: index + 1
            ))
        }

        return OCRDocumentResult(sourceURL: url, pages: pages)
    }

    static func recognizeImageTextWithVision(in imageURL: URL) throws -> String {
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw OCRServiceError.failed("图片格式无法读取")
        }
        let result = try recognizeWithVision(image: image, pageIndex: 0)
        guard !result.text.isEmpty else { throw OCRServiceError.noText }
        return result.text
    }

    static func recognizeImageTextWithTesseract(in imageURL: URL) throws -> String {
        let fileManager = FileManager.default
        let executableCandidates = [
            "/opt/homebrew/bin/tesseract",
            "/usr/local/bin/tesseract"
        ]
        guard let executablePath = executableCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw OCRTesseractError.unavailable
        }

        let tessdataCandidates = [
            "/opt/homebrew/share/tessdata",
            "/usr/local/share/tessdata"
        ]
        guard let tessdataPath = tessdataCandidates.first(where: {
            fileManager.fileExists(atPath: ($0 as NSString).appendingPathComponent("chi_sim.traineddata"))
        }) else {
            throw OCRTesseractError.unavailable
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [imageURL.path, "stdout", "-l", "chi_sim+eng", "--psm", "6"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        var environment = ProcessInfo.processInfo.environment
        environment["TESSDATA_PREFIX"] = tessdataPath
        process.environment = environment

        do {
            try process.run()
        } catch {
            throw OCRTesseractError.failed(error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OCRTesseractError.failed(message?.isEmpty == false ? message! : "识别进程异常退出")
        }

        let text = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw OCRTesseractError.noText
        }
        return text
    }

    static func render(page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw OCRServiceError.failed("页面尺寸无效")
        }

        let maximumDimension = max(bounds.width, bounds.height)
        let scale = max(1.0, min(3.0, CGFloat(maximumOCRPixelDimension) / maximumDimension))
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw OCRServiceError.failed("无法创建 OCR 图像缓冲区")
        }

        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.saveGState()
        context.translateBy(x: -bounds.minX * scale, y: -bounds.minY * scale)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw OCRServiceError.failed("无法生成 OCR 图像")
        }
        return image
    }

    private static func recognize(
        image: CGImage,
        pageIndex: Int,
        token: OCRCancellationToken = OCRCancellationToken()
    ) throws -> OCRPageResult {
        if token.isCancelled {
            throw OCRServiceError.cancelled
        }

        do {
            return try recognizeWithVision(image: image, pageIndex: pageIndex, token: token)
        } catch {
            if token.isCancelled {
                throw OCRServiceError.cancelled
            }

            do {
                let text = try recognizeWithTesseract(image: image)
                return OCRPageResult(
                    id: pageIndex,
                    pageIndex: pageIndex,
                    text: text,
                    observations: []
                )
            } catch let tesseractError as OCRTesseractError {
                if case .noText = tesseractError {
                    return OCRPageResult(id: pageIndex, pageIndex: pageIndex, text: "", observations: [])
                }
                throw error
            }
        }
    }

    private static func recognizeWithVision(
        image: CGImage,
        pageIndex: Int,
        token: OCRCancellationToken = OCRCancellationToken()
    ) throws -> OCRPageResult {
        if token.isCancelled {
            throw OCRServiceError.cancelled
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages

        do {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
        } catch {
            let nsError = error as NSError
            if nsError.domain == "Foundation._GenericObjCError", nsError.code == 0 {
                throw OCRServiceError.unavailable
            }
            throw OCRServiceError.failed("\(nsError.domain) (\(nsError.code))：\(nsError.localizedDescription)")
        }

        let observations = (request.results ?? [])
            .compactMap { observation -> OCRTextObservation? in
                guard let text = observation.topCandidates(1).first?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else {
                    return nil
                }
                return OCRTextObservation(text: text, boundingBox: observation.boundingBox)
            }
            .sorted { first, second in
                let verticalDistance = abs(first.boundingBox.midY - second.boundingBox.midY)
                if verticalDistance > 0.03 {
                    return first.boundingBox.midY > second.boundingBox.midY
                }
                return first.boundingBox.minX < second.boundingBox.minX
            }

        return OCRPageResult(
            id: pageIndex,
            pageIndex: pageIndex,
            text: observations.map(\.text).joined(separator: "\n"),
            observations: observations
        )
    }

    private static func recognizeWithTesseract(image: CGImage) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-pdf-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw OCRTesseractError.failed("无法创建 OCR 临时图像")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OCRTesseractError.failed("无法写入 OCR 临时图像")
        }
        return try recognizeImageTextWithTesseract(in: url)
    }
}
