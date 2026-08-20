import Foundation
import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class PDFMergeStore: ObservableObject {
    @Published private(set) var items: [PDFFileItem] = []
    @Published private(set) var pageItemsByFileID: [UUID: [PDFPageItem]] = [:]
    @Published var selectedFileID: UUID?
    @Published var selectedPageIDs: Set<UUID> = []
    @Published private(set) var focusedPageID: UUID?
    @Published private(set) var isMerging = false
    @Published private(set) var isRecognizing = false
    @Published private(set) var resultURL: URL?
    @Published var alert: PDFAlert?
    @Published var isDropTargeted = false
    @Published var compressAfterMerge = false
    @Published var enhanceAfterMerge = false
    @Published var clarityLevel: PDFClarityLevel = .standard

    private let lastDirectoryKey = "lastSaveDirectory"
    private var documentCache: [UUID: PDFDocument] = [:]

    var totalPages: Int {
        items.reduce(0) { total, item in
            total + pageItemsByFileID[item.id, default: PDFPageItem.pages(for: item)].count
        }
    }

    var includedPageCount: Int {
        pageItemsByFileID.values.reduce(0) { total, pages in
            total + pages.count(where: \.isIncluded)
        }
    }

    var currentPages: [PDFPageItem] {
        guard let selectedFileID,
              let item = items.first(where: { $0.id == selectedFileID }) else {
            return []
        }
        return pageItemsByFileID[item.id, default: PDFPageItem.pages(for: item)]
    }

    var currentDocument: PDFDocument? {
        guard let selectedFileID else { return nil }
        return documentCache[selectedFileID]
    }

    var previewPage: PDFPage? {
        guard let focusedPageID,
              let pageItem = currentPages.first(where: { $0.id == focusedPageID }),
              let document = currentDocument else {
            return nil
        }
        return document.page(at: pageItem.sourcePageIndex)
    }

    var previewPageNumber: Int? {
        guard let focusedPageID else { return nil }
        return currentPages.firstIndex(where: { $0.id == focusedPageID }).map { $0 + 1 }
    }

    func selectFile(_ fileID: UUID?) {
        guard let fileID,
              let item = items.first(where: { $0.id == fileID }) else {
            selectedFileID = nil
            selectedPageIDs = []
            focusedPageID = nil
            return
        }

        selectedFileID = item.id
        selectedPageIDs = []
        _ = loadDocument(for: item)
        focusedPageID = pageItemsByFileID[item.id, default: PDFPageItem.pages(for: item)].first?.id
    }

    func focusPage(_ pageID: UUID) {
        guard currentPages.contains(where: { $0.id == pageID }) else { return }
        focusedPageID = pageID
        if selectedPageIDs.isEmpty {
            selectedPageIDs = [pageID]
        }
    }

    func updateFocusedPage(from selection: Set<UUID>) {
        guard let pageID = currentPages.last(where: { selection.contains($0.id) })?.id else {
            focusedPageID = currentPages.first?.id
            return
        }
        focusedPageID = pageID
    }

    func pdfDocument(for fileID: UUID) -> PDFDocument? {
        if let document = documentCache[fileID] {
            return document
        }
        guard let item = items.first(where: { $0.id == fileID }) else { return nil }
        return loadDocument(for: item)
    }

    func pdfPage(for pageItem: PDFPageItem) -> PDFPage? {
        pdfDocument(for: pageItem.sourceFileID)?.page(at: pageItem.sourcePageIndex)
    }

    func toggleInclusion(for pageID: UUID) {
        guard !isMerging, !isRecognizing else { return }
        updateCurrentPages { pages in
            guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
            pages[index].isIncluded.toggle()
        }
    }

    func selectAllCurrentPages() {
        selectedPageIDs = Set(currentPages.map(\.id))
        updateFocusedPage(from: selectedPageIDs)
    }

    func movePages(from offsets: IndexSet, to destination: Int) {
        guard !isMerging, !isRecognizing else { return }
        updateCurrentPages { pages in
            pages.move(fromOffsets: offsets, toOffset: destination)
        }
    }

    func deleteSelectedPages() {
        guard !isMerging, !isRecognizing, !selectedPageIDs.isEmpty else { return }
        updateCurrentPages { pages in
            pages.removeAll { selectedPageIDs.contains($0.id) }
        }
        selectedPageIDs = []
        focusedPageID = currentPages.first?.id
    }

    func rotateSelectedPages(by degrees: Int) {
        guard !isMerging, !isRecognizing, !selectedPageIDs.isEmpty else { return }
        updateCurrentPages { pages in
            for index in pages.indices where selectedPageIDs.contains(pages[index].id) {
                pages[index].rotate(by: degrees)
            }
        }
    }

    func addFilesWithPanel() {
        guard !isMerging else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.title = "选择 PDF 或图片"
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
    }

    func addFolderWithPanel() {
        guard !isMerging else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.title = "选择包含 PDF 或图片的文件夹"
        panel.prompt = "读取文件夹"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        do {
            let files = try FolderReader.directFiles(in: folderURL)
            add(urls: files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            if files.isEmpty {
                alert = PDFAlert(title: "文件夹为空", message: "所选文件夹中没有可读取的文件。")
            }
        } catch {
            alert = PDFAlert(title: "无法读取文件夹", message: "请检查文件夹访问权限后重试。\n\(error.localizedDescription)")
        }
    }

    func reorderFromText(_ text: String) {
        reorderFromText(text, completionTitle: nil)
    }

    func reorderFromImageWithPanel() {
        guard !isMerging, !isRecognizing else { return }

        guard !items.isEmpty else {
            alert = PDFAlert(title: "请先添加文件", message: "添加 PDF 或图片后，再选择截图识别排序。")
            return
        }

        let panel = NSOpenPanel()
        panel.title = "选择顺序截图"
        panel.prompt = "识别并排序"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let imageURL = panel.url else { return }

        isRecognizing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try OCRTextRecognizer.recognizeText(in: imageURL))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isRecognizing = false

                switch result {
                case .success(let text):
                    self.reorderFromText(text, completionTitle: "截图识别完成")
                case .failure(let error):
                    self.alert = PDFAlert(title: "截图识别失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func reorderFromText(_ text: String, completionTitle: String?) {
        guard !isMerging else { return }
        let originalCount = items.count
        let result = FileOrderResolver.resolve(urls: items.map(\.url), text: text)
        let itemByPath = Dictionary(uniqueKeysWithValues: items.map { ($0.url.standardizedFileURL.path.lowercased(), $0) })
        let matchedItems = result.orderedURLs.compactMap { itemByPath[$0.standardizedFileURL.path.lowercased()] }

        guard !matchedItems.isEmpty else {
            let recognizedText = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "、")
            let preview = recognizedText.count > 120
                ? String(recognizedText.prefix(120)) + "…"
                : recognizedText
            alert = PDFAlert(
                title: completionTitle == nil ? "未匹配到文件" : "截图未匹配到文件",
                message: "没有找到与识别文字相符的 PDF，当前列表保持不变。\n识别结果：\(preview.isEmpty ? "（空）" : preview)"
            )
            return
        }

        items = matchedItems
        normalizeSelectedFile()
        resultURL = nil

        var messages: [String] = []
        let unmatchedCount = originalCount - matchedItems.count
        if unmatchedCount > 0 {
            messages.append("已移除未在粘贴内容中提到的文件：\(unmatchedCount) 个（仅从列表移除，未删除原文件）")
        }
        if !result.unknownLines.isEmpty {
            messages.append("未找到：" + result.unknownLines.joined(separator: "、"))
        }
        if !result.duplicateLines.isEmpty {
            messages.append("重复项已忽略：" + result.duplicateLines.joined(separator: "、"))
        }

        if completionTitle != nil {
            let recognizedLineCount = text
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .count
            messages.insert("已识别 \(recognizedLineCount) 行文字，并按截图中的出现顺序匹配文件。", at: 0)
        }

        if !messages.isEmpty {
            alert = PDFAlert(
                title: completionTitle ?? "顺序已更新",
                message: messages.joined(separator: "\n")
            )
        }
    }

    func importDropped(providers: [NSItemProvider]) {
        guard !isMerging else { return }
        // 按 providers 的顺序逐个读取，保证一次拖入多个文件时沿用系统顺序。
        Task { [weak self] in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.fileURL() {
                    urls.append(url)
                }
            }
            guard let self else { return }
            self.add(urls: urls)
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        guard !isMerging else { return }
        items.move(fromOffsets: offsets, toOffset: destination)
        resultURL = nil
    }

    func remove(at offsets: IndexSet) {
        guard !isMerging else { return }
        let removedIDs = offsets.compactMap { index in
            items.indices.contains(index) ? items[index].id : nil
        }
        items.remove(atOffsets: offsets)
        removePageState(for: removedIDs)
        resultURL = nil
    }

    func remove(_ item: PDFFileItem) {
        guard !isMerging else { return }
        items.removeAll { $0.id == item.id }
        removePageState(for: [item.id])
        resultURL = nil
    }

    func clear() {
        guard !isMerging else { return }
        items.removeAll()
        pageItemsByFileID.removeAll()
        documentCache.removeAll()
        selectedFileID = nil
        selectedPageIDs = []
        focusedPageID = nil
        resultURL = nil
    }

    func mergeWithSavePanel() {
        guard !isMerging else { return }
        guard !items.isEmpty else {
            alert = PDFAlert(title: "无法合并", message: "请先添加至少一个 PDF 或图片文件。")
            return
        }

        let pageItems = items.flatMap { item in
            pageItemsByFileID[item.id, default: PDFPageItem.pages(for: item)]
        }
        guard pageItems.contains(where: \.isIncluded) else {
            alert = PDFAlert(title: "无法合并", message: "请至少选择一个页面参与合并。")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.title = "保存合并后的 PDF"
        panel.prompt = "保存"
        panel.nameFieldStringValue = "合并后的文档.pdf"
        if let path = UserDefaults.standard.string(forKey: lastDirectoryKey) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let finalURL = url.pathExtension.lowercased() == "pdf" ? url : url.appendingPathExtension("pdf")
        UserDefaults.standard.set(finalURL.deletingLastPathComponent().path, forKey: lastDirectoryKey)
        startMerge(
            pageItems: pageItems,
            to: finalURL,
            compressed: compressAfterMerge,
            enhanced: enhanceAfterMerge,
            clarityLevel: clarityLevel
        )
    }

    func revealResultInFinder() {
        guard let resultURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resultURL])
    }

    private func updateCurrentPages(_ transform: (inout [PDFPageItem]) -> Void) {
        guard let selectedFileID,
              let item = items.first(where: { $0.id == selectedFileID }) else {
            return
        }

        var pages = pageItemsByFileID[item.id, default: PDFPageItem.pages(for: item)]
        transform(&pages)
        pageItemsByFileID[item.id] = pages

        let pageIDs = Set(pages.map(\.id))
        selectedPageIDs = selectedPageIDs.intersection(pageIDs)
        if let focusedPageID, !pageIDs.contains(focusedPageID) {
            self.focusedPageID = pages.first?.id
        }
    }

    private func loadDocument(for item: PDFFileItem) -> PDFDocument? {
        if let document = documentCache[item.id] {
            return document
        }
        guard let document = PDFDocument(url: item.url) else { return nil }
        documentCache[item.id] = document
        return document
    }

    private func removePageState(for fileIDs: [UUID]) {
        for fileID in fileIDs {
            pageItemsByFileID.removeValue(forKey: fileID)
            documentCache.removeValue(forKey: fileID)
        }
        normalizeSelectedFile()
    }

    private func normalizeSelectedFile() {
        guard let selectedFileID,
              let item = items.first(where: { $0.id == selectedFileID }) else {
            selectFile(items.first?.id)
            return
        }

        _ = loadDocument(for: item)
        let currentIDs = Set(currentPages.map(\.id))
        selectedPageIDs = selectedPageIDs.intersection(currentIDs)
        if let focusedPageID, currentIDs.contains(focusedPageID) {
            return
        }
        self.focusedPageID = currentPages.first?.id
    }

    private func add(urls: [URL]) {
        guard !urls.isEmpty else { return }
        var additions: [PDFFileItem] = []
        var problems: [String] = []
        let existingPaths = Set(items.map { $0.url.standardizedFileURL.path })
        var seenPaths = existingPaths

        for url in urls {
            let standardized = url.standardizedFileURL
            guard PDFMergeService.supports(standardized) else {
                problems.append("不支持的文件格式：\(url.lastPathComponent)")
                continue
            }
            guard !seenPaths.contains(standardized.path) else { continue }
            let document: PDFDocument
            do {
                document = try PDFMergeService.loadDocument(from: standardized)
            } catch let error as MergeError {
                switch error {
                case .locked:
                    problems.append("文件已加密或需要密码：\(url.lastPathComponent)")
                default:
                    problems.append("无法读取或文件已损坏：\(url.lastPathComponent)")
                }
                continue
            } catch {
                problems.append("无法读取或文件已损坏：\(url.lastPathComponent)")
                continue
            }
            guard document.pageCount > 0 else {
                problems.append("文件没有页面：\(url.lastPathComponent)")
                continue
            }
            let item = PDFFileItem(url: standardized, pageCount: document.pageCount)
            additions.append(item)
            documentCache[item.id] = document
            seenPaths.insert(standardized.path)
        }

        if !additions.isEmpty {
            items.append(contentsOf: additions)
            for item in additions {
                pageItemsByFileID[item.id] = PDFPageItem.pages(for: item)
            }
            if selectedFileID == nil {
                selectFile(additions[0].id)
            }
            resultURL = nil
        }
        if !problems.isEmpty {
            alert = PDFAlert(
                title: additions.isEmpty ? "无法添加文件" : "部分文件未添加",
                message: problems.joined(separator: "\n")
            )
        }
    }

    private func startMerge(
        pageItems: [PDFPageItem],
        to destinationURL: URL,
        compressed: Bool,
        enhanced: Bool,
        clarityLevel: PDFClarityLevel
    ) {
        isMerging = true
        resultURL = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<URL, Error>
            do {
                try PDFMergeService.merge(
                    pageItems: pageItems,
                    to: destinationURL,
                    compressed: compressed,
                    enhanced: enhanced,
                    clarityLevel: clarityLevel
                )
                result = .success(destinationURL)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isMerging = false
                switch result {
                case .success(let url):
                    self.resultURL = url
                case .failure(let error):
                    let title: String
                    if enhanced && compressed {
                        title = "合并、清晰化或压缩失败"
                    } else if enhanced {
                        title = "合并或清晰化失败"
                    } else if compressed {
                        title = "合并或压缩失败"
                    } else {
                        title = "合并失败"
                    }
                    self.alert = PDFAlert(title: title, message: error.localizedDescription)
                }
            }
        }
    }
}
