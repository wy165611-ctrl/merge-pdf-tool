import Foundation
import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class PDFSplitStore: ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceDocument: PDFDocument?
    @Published var operation: PDFSplitOperation = .extract
    @Published var pageRangeText = ""
    @Published var chunkSizeText = "5"
    @Published var selectedPageIndices: Set<Int> = []
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var exportedURLs: [URL] = []
    @Published var alert: PDFAlert?

    var pageCount: Int {
        sourceDocument?.pageCount ?? 0
    }

    var selectedPageCount: Int {
        selectedPageIndices.count
    }

    var sourceName: String {
        sourceURL?.lastPathComponent ?? "未选择 PDF"
    }

    var isMultiOutput: Bool {
        operation == .eachPage || operation == .chunks
    }

    func openPDFWithPanel() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "选择要拆分的 PDF"
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
            alert = PDFAlert(title: "无法拆分 PDF", message: "PDF 没有页面：\(url.lastPathComponent)")
            return
        }

        sourceURL = url.standardizedFileURL
        sourceDocument = document
        selectedPageIndices = Set(0..<document.pageCount)
        pageRangeText = document.pageCount == 1 ? "1" : "1-\(document.pageCount)"
        exportedURLs = []
        progress = 0
    }

    func page(at index: Int) -> PDFPage? {
        sourceDocument?.page(at: index)
    }

    func applyPageRange() {
        guard pageCount > 0 else {
            alert = PDFAlert(title: "请先选择 PDF", message: "打开 PDF 后再输入页码范围。")
            return
        }
        do {
            let indices = try PDFSplitService.parsePageRange(pageRangeText, pageCount: pageCount)
            selectedPageIndices = Set(indices)
        } catch {
            alert = PDFAlert(title: "页码格式错误", message: error.localizedDescription)
        }
    }

    func exportWithPanel() {
        guard let sourceURL else {
            alert = PDFAlert(title: "请先选择 PDF", message: "打开 PDF 后再执行拆分或提取。")
            return
        }
        guard !isExporting else { return }

        let indices = selectedPageIndices.sorted()
        let chunkSize: Int
        if operation == .chunks {
            guard let value = Int(chunkSizeText.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
                alert = PDFAlert(title: "拆分参数错误", message: PDFSplitError.invalidChunkSize.localizedDescription)
                return
            }
            chunkSize = value
        } else {
            chunkSize = 1
        }

        do {
            _ = try PDFSplitService.pageGroups(
                pageCount: pageCount,
                operation: operation,
                pageIndices: indices,
                chunkSize: chunkSize
            )
        } catch {
            alert = PDFAlert(title: "无法导出", message: error.localizedDescription)
            return
        }

        if isMultiOutput {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = "选择拆分文件保存文件夹"
            panel.prompt = "选择文件夹"
            guard panel.runModal() == .OK, let directory = panel.url else { return }
            startExport(
                sourceURL: sourceURL,
                pageIndices: indices,
                chunkSize: chunkSize,
                destinationURL: nil,
                outputDirectory: directory
            )
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.canCreateDirectories = true
            panel.title = operation == .extract ? "保存提取后的 PDF" : "保存删除页面后的 PDF"
            panel.prompt = "保存"
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let suffix = operation == .extract ? "-提取.pdf" : "-删除后.pdf"
            panel.nameFieldStringValue = baseName + suffix
            guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
            let finalURL = destinationURL.pathExtension.lowercased() == "pdf"
                ? destinationURL
                : destinationURL.appendingPathExtension("pdf")
            startExport(
                sourceURL: sourceURL,
                pageIndices: indices,
                chunkSize: chunkSize,
                destinationURL: finalURL,
                outputDirectory: nil
            )
        }
    }

    private func startExport(
        sourceURL: URL,
        pageIndices: [Int],
        chunkSize: Int,
        destinationURL: URL?,
        outputDirectory: URL?
    ) {
        isExporting = true
        progress = 0
        exportedURLs = []
        let operation = operation

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<[URL], Error>
            do {
                let urls = try PDFSplitService.export(
                    sourceURL: sourceURL,
                    operation: operation,
                    pageIndices: pageIndices,
                    chunkSize: chunkSize,
                    destinationURL: destinationURL,
                    outputDirectory: outputDirectory,
                    progress: { completed, total in
                        DispatchQueue.main.async {
                            self?.progress = total == 0 ? 0 : Double(completed) / Double(total)
                        }
                    }
                )
                result = .success(urls)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isExporting = false
                switch result {
                case .success(let urls):
                    self.progress = 1
                    self.exportedURLs = urls
                case .failure(let error):
                    self.alert = PDFAlert(title: "拆分失败", message: error.localizedDescription)
                }
            }
        }
    }
}
