import Foundation
import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class OCRStore: ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceDocument: PDFDocument?
    @Published private(set) var pageResults: [OCRPageResult] = []
    @Published private(set) var recognizedText = ""
    @Published var selectedPageIndex = 0
    @Published private(set) var isRecognizing = false
    @Published private(set) var currentPage = 0
    @Published private(set) var totalPages = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var isExportingText = false
    @Published var alert: PDFAlert?

    private var cancellationToken: OCRCancellationToken?

    var sourceName: String {
        sourceURL?.lastPathComponent ?? "未选择 PDF"
    }

    var selectedPageResult: OCRPageResult? {
        pageResults.first { $0.pageIndex == selectedPageIndex }
    }

    func openPDFWithPanel() {
        guard !isRecognizing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "选择扫描版 PDF"
        panel.prompt = "打开"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url: url)
    }

    func load(url: URL) {
        guard url.pathExtension.lowercased() == "pdf" else {
            alert = PDFAlert(title: "无法打开文件", message: "请选择 PDF 文件。")
            return
        }
        guard let document = PDFDocument(url: url) else {
            alert = PDFAlert(title: "无法打开 PDF", message: "文件可能已损坏或无法读取：\(url.lastPathComponent)")
            return
        }
        if document.isLocked {
            alert = PDFAlert(title: "无法打开 PDF", message: "文件已加密或需要密码：\(url.lastPathComponent)")
            return
        }
        guard document.pageCount > 0 else {
            alert = PDFAlert(title: "无法进行 OCR", message: "PDF 没有页面：\(url.lastPathComponent)")
            return
        }

        sourceURL = url.standardizedFileURL
        sourceDocument = document
        pageResults = []
        recognizedText = ""
        selectedPageIndex = 0
        currentPage = 0
        totalPages = document.pageCount
        progress = 0
    }

    func page(at index: Int) -> PDFPage? {
        sourceDocument?.page(at: index)
    }

    func startRecognition() {
        guard let sourceURL, !isRecognizing else { return }
        guard sourceDocument?.pageCount ?? 0 > 0 else {
            alert = PDFAlert(title: "请先选择 PDF", message: "打开扫描版 PDF 后再开始 OCR。")
            return
        }

        let token = OCRCancellationToken()
        cancellationToken = token
        isRecognizing = true
        currentPage = 0
        totalPages = sourceDocument?.pageCount ?? 0
        progress = 0
        pageResults = []
        recognizedText = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<OCRDocumentResult, Error>
            do {
                result = .success(try OCRService.recognizePDF(at: sourceURL, token: token) { update in
                    DispatchQueue.main.async {
                        self?.currentPage = update.completedPages
                        self?.totalPages = update.totalPages
                        self?.progress = update.totalPages == 0
                            ? 0
                            : Double(update.completedPages) / Double(update.totalPages)
                    }
                })
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isRecognizing = false
                self.cancellationToken = nil
                switch result {
                case .success(let documentResult):
                    self.pageResults = documentResult.pages
                    self.recognizedText = documentResult.text
                    self.selectedPageIndex = documentResult.pages.first?.pageIndex ?? 0
                    self.progress = 1
                    if !documentResult.hasRecognizedText {
                        self.alert = PDFAlert(title: "OCR 完成但没有文字", message: "没有在 PDF 中识别到可用文字。")
                    }
                case .failure(let error):
                    if let ocrError = error as? OCRServiceError, case .cancelled = ocrError {
                        self.alert = PDFAlert(title: "OCR 已取消", message: "已停止识别，未完成的页面没有结果。")
                    } else {
                        self.alert = PDFAlert(title: "PDF OCR 失败", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    func cancelRecognition() {
        guard isRecognizing else { return }
        cancellationToken?.cancel()
    }

    func exportTXTWithSavePanel() {
        guard !recognizedText.isEmpty, !isRecognizing, !isExportingText else { return }
        guard let sourceURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "导出 OCR 文本"
        panel.prompt = "导出"
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-OCR.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let finalURL = url.pathExtension.lowercased() == "txt"
            ? url
            : url.appendingPathExtension("txt")
        startTextExport(to: finalURL, text: recognizedText)
    }

    private func startTextExport(to url: URL, text: String) {
        isExportingText = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<Void, Error>
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isExportingText = false
                switch result {
                case .success:
                    self.alert = PDFAlert(title: "OCR 文本已导出", message: url.path)
                case .failure(let error):
                    self.alert = PDFAlert(title: "导出 OCR 文本失败", message: error.localizedDescription)
                }
            }
        }
    }
}
