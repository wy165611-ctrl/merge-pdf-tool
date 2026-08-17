import Foundation
import PDFKit

enum PDFSplitOperation: String, CaseIterable, Identifiable {
    case extract
    case delete
    case eachPage
    case chunks

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .extract: return "提取页面"
        case .delete: return "删除后导出"
        case .eachPage: return "每页单独导出"
        case .chunks: return "固定页数拆分"
        }
    }
}

enum PDFSplitError: LocalizedError {
    case emptyPageRange
    case invalidPageToken(String)
    case invalidPageRange(String)
    case pageOutOfBounds(Int, Int)
    case duplicatePage(Int)
    case invalidChunkSize
    case unreadablePDF(String)
    case lockedPDF(String)
    case emptyDocument(String)
    case noPagesToExport
    case unableToReadPage(Int)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyPageRange:
            return "页码范围不能为空。"
        case .invalidPageToken(let token):
            return "无法识别页码：\(token)。请输入例如 1-3, 7, 10-15。"
        case .invalidPageRange(let token):
            return "页码范围无效：\(token)。起始页不能大于结束页。"
        case .pageOutOfBounds(let page, let pageCount):
            return "第 \(page) 页超出 PDF 页数（共 \(pageCount) 页）。"
        case .duplicatePage(let page):
            return "页码 \(page) 重复，请删除重复项后重试。"
        case .invalidChunkSize:
            return "固定拆分页数必须是大于 0 的整数。"
        case .unreadablePDF(let name):
            return "无法读取 PDF：\(name)。"
        case .lockedPDF(let name):
            return "PDF 已加密或需要密码：\(name)。"
        case .emptyDocument(let name):
            return "PDF 没有页面：\(name)。"
        case .noPagesToExport:
            return "没有可导出的页面。"
        case .unableToReadPage(let page):
            return "无法读取第 \(page + 1) 页。"
        case .saveFailed(let path):
            return "无法写入文件：\(path)。"
        }
    }
}

enum PDFSplitService {
    static func parsePageRange(_ text: String, pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else { throw PDFSplitError.noPagesToExport }

        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "；", with: ";")
        let rawTokens = normalized.split { character in
            character == "," || character == ";" || character == "\n"
        }
        let tokens = rawTokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !tokens.isEmpty else { throw PDFSplitError.emptyPageRange }

        var result: [Int] = []
        var seen = Set<Int>()

        for token in tokens {
            guard !token.isEmpty else { continue }

            if let range = token.range(of: "^(\\d+)\\s*-\\s*(\\d+)$", options: .regularExpression) {
                let value = String(token[range])
                let parts = value.split(separator: "-")
                guard parts.count == 2,
                      let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                      let end = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                    throw PDFSplitError.invalidPageToken(token)
                }
                guard start <= end else {
                    throw PDFSplitError.invalidPageRange(token)
                }
                for pageNumber in start...end {
                    try appendPageNumber(pageNumber, pageCount: pageCount, to: &result, seen: &seen)
                }
            } else if let pageNumber = Int(token), token.allSatisfy({ $0.isNumber }) {
                try appendPageNumber(pageNumber, pageCount: pageCount, to: &result, seen: &seen)
            } else {
                throw PDFSplitError.invalidPageToken(token)
            }
        }

        guard !result.isEmpty else { throw PDFSplitError.emptyPageRange }
        return result.map { $0 - 1 }
    }

    static func pageGroups(
        pageCount: Int,
        operation: PDFSplitOperation,
        pageIndices: [Int] = [],
        chunkSize: Int = 1
    ) throws -> [[Int]] {
        guard pageCount > 0 else { throw PDFSplitError.noPagesToExport }

        switch operation {
        case .extract:
            let pages = try validatedIndices(pageIndices, pageCount: pageCount)
            return [pages]
        case .delete:
            let deleted = try validatedIndices(pageIndices, pageCount: pageCount)
            let deletedSet = Set(deleted)
            let remaining = (0..<pageCount).filter { !deletedSet.contains($0) }
            guard !remaining.isEmpty else { throw PDFSplitError.noPagesToExport }
            return [remaining]
        case .eachPage:
            return (0..<pageCount).map { [$0] }
        case .chunks:
            guard chunkSize > 0 else { throw PDFSplitError.invalidChunkSize }
            return stride(from: 0, to: pageCount, by: chunkSize).map { start in
                Array(start..<min(start + chunkSize, pageCount))
            }
        }
    }

    static func export(
        sourceURL: URL,
        operation: PDFSplitOperation,
        pageIndices: [Int] = [],
        chunkSize: Int = 1,
        destinationURL: URL? = nil,
        outputDirectory: URL? = nil,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> [URL] {
        guard let source = PDFDocument(url: sourceURL) else {
            throw PDFSplitError.unreadablePDF(sourceURL.lastPathComponent)
        }
        if source.isLocked {
            throw PDFSplitError.lockedPDF(sourceURL.lastPathComponent)
        }
        guard source.pageCount > 0 else {
            throw PDFSplitError.emptyDocument(sourceURL.lastPathComponent)
        }

        let groups = try pageGroups(
            pageCount: source.pageCount,
            operation: operation,
            pageIndices: pageIndices,
            chunkSize: chunkSize
        )
        guard !groups.isEmpty else { throw PDFSplitError.noPagesToExport }

        let directory: URL
        if let outputDirectory {
            directory = outputDirectory
        } else if let destinationURL {
            directory = destinationURL.deletingLastPathComponent()
        } else {
            throw PDFSplitError.saveFailed("未选择输出位置")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var outputURLs: [URL] = []
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        for (index, group) in groups.enumerated() {
            let url: URL
            if groups.count == 1, let destinationURL {
                url = destinationURL
            } else {
                let fileName: String
                switch operation {
                case .extract:
                    fileName = "\(baseName)-提取.pdf"
                case .delete:
                    fileName = "\(baseName)-删除后.pdf"
                case .eachPage:
                    fileName = String(format: "\(baseName)-第%02d页.pdf", index + 1)
                case .chunks:
                    fileName = String(format: "\(baseName)-第%02d组.pdf", index + 1)
                }
                url = uniqueURL(in: directory, preferredFileName: fileName)
            }

            let document = try makeDocument(from: source, pageIndices: group)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            do {
                try PDFDocumentWriter.write(document, to: url, compressed: false)
            } catch {
                throw PDFSplitError.saveFailed(url.path)
            }
            outputURLs.append(url)
            progress?(index + 1, groups.count)
        }
        return outputURLs
    }

    static func makeDocument(from source: PDFDocument, pageIndices: [Int]) throws -> PDFDocument {
        let indices = try validatedIndices(pageIndices, pageCount: source.pageCount)
        let document = PDFDocument()
        for index in indices {
            guard let page = source.page(at: index) else {
                throw PDFSplitError.unableToReadPage(index)
            }
            let outputPage = page.copy() as? PDFPage ?? page
            document.insert(outputPage, at: document.pageCount)
        }
        guard document.pageCount > 0 else { throw PDFSplitError.noPagesToExport }
        return document
    }

    private static func appendPageNumber(
        _ pageNumber: Int,
        pageCount: Int,
        to result: inout [Int],
        seen: inout Set<Int>
    ) throws {
        guard pageNumber >= 1, pageNumber <= pageCount else {
            throw PDFSplitError.pageOutOfBounds(pageNumber, pageCount)
        }
        guard seen.insert(pageNumber).inserted else {
            throw PDFSplitError.duplicatePage(pageNumber)
        }
        result.append(pageNumber)
    }

    private static func validatedIndices(_ indices: [Int], pageCount: Int) throws -> [Int] {
        guard !indices.isEmpty else { throw PDFSplitError.noPagesToExport }
        var seen = Set<Int>()
        for index in indices {
            guard (0..<pageCount).contains(index) else {
                throw PDFSplitError.pageOutOfBounds(index + 1, pageCount)
            }
            guard seen.insert(index).inserted else {
                throw PDFSplitError.duplicatePage(index + 1)
            }
        }
        return indices
    }

    private static func uniqueURL(in directory: URL, preferredFileName: String) -> URL {
        let fileManager = FileManager.default
        let preferredURL = directory.appendingPathComponent(preferredFileName)
        guard fileManager.fileExists(atPath: preferredURL.path) else { return preferredURL }

        let base = preferredURL.deletingPathExtension().lastPathComponent
        let ext = preferredURL.pathExtension
        var suffix = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }
}
