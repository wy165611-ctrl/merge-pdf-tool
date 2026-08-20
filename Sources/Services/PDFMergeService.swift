import Foundation
import AppKit
import PDFKit

enum MergeError: LocalizedError {
    case unreadable(String)
    case locked(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "合并时无法读取文件：\(name)"
        case .locked(let name):
            return "文件已加密或需要密码：\(name)"
        case .empty:
            return "没有可合并的页面。"
        }
    }
}

enum PDFMergeService {
    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "ico", "icns"
    ]

    static func supports(_ sourceURL: URL) -> Bool {
        let extensionName = sourceURL.pathExtension.lowercased()
        if extensionName == "pdf" {
            return true
        }
        return supportedImageExtensions.contains(extensionName)
    }

    static func loadDocument(from sourceURL: URL) throws -> PDFDocument {
        if sourceURL.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: sourceURL) else {
                throw MergeError.unreadable(sourceURL.lastPathComponent)
            }
            guard !document.isLocked else {
                throw MergeError.locked(sourceURL.lastPathComponent)
            }
            return document
        }

        guard supports(sourceURL),
              let image = NSImage(contentsOf: sourceURL),
              let page = PDFPage(image: image) else {
            throw MergeError.unreadable(sourceURL.lastPathComponent)
        }

        let document = PDFDocument()
        document.insert(page, at: 0)
        return document
    }

    static func merge(
        pageItems: [PDFPageItem],
        to destinationURL: URL,
        compressed: Bool,
        enhanced: Bool,
        clarityLevel: PDFClarityLevel
    ) throws {
        let includedPages = pageItems.filter(\.isIncluded)
        guard !includedPages.isEmpty else {
            throw MergeError.empty
        }

        let merged = PDFDocument()
        var sourceDocuments: [URL: PDFDocument] = [:]

        for pageItem in includedPages {
            let source: PDFDocument
            if let cached = sourceDocuments[pageItem.sourceURL] {
                source = cached
            } else {
                let loaded = try loadDocument(from: pageItem.sourceURL)
                sourceDocuments[pageItem.sourceURL] = loaded
                source = loaded
            }

            guard let page = source.page(at: pageItem.sourcePageIndex) else {
                throw MergeError.unreadable(pageItem.sourceURL.lastPathComponent)
            }

            let outputPage = page.copy() as? PDFPage ?? page
            outputPage.rotation = PDFPageItem.normalizedRotation(page.rotation + pageItem.rotation)
            merged.insert(outputPage, at: merged.pageCount)
        }

        try write(merged, to: destinationURL, compressed: compressed, enhanced: enhanced, clarityLevel: clarityLevel)
    }

    static func merge(
        sourceURLs: [URL],
        to destinationURL: URL,
        compressed: Bool,
        enhanced: Bool,
        clarityLevel: PDFClarityLevel
    ) throws {
        guard !sourceURLs.isEmpty else {
            throw MergeError.empty
        }

        let merged = PDFDocument()
        for sourceURL in sourceURLs {
            let source = try loadDocument(from: sourceURL)

            for index in 0..<source.pageCount {
                guard let page = source.page(at: index) else {
                    throw MergeError.unreadable(sourceURL.lastPathComponent)
                }
                merged.insert(page, at: merged.pageCount)
            }
        }

        guard merged.pageCount > 0 else {
            throw MergeError.empty
        }

        try write(merged, to: destinationURL, compressed: compressed, enhanced: enhanced, clarityLevel: clarityLevel)
    }

    private static func write(
        _ document: PDFDocument,
        to destinationURL: URL,
        compressed: Bool,
        enhanced: Bool,
        clarityLevel: PDFClarityLevel
    ) throws {
        let documentToWrite = enhanced
            ? try PDFPageEnhancer.enhance(document, level: clarityLevel)
            : document

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try PDFDocumentWriter.write(documentToWrite, to: destinationURL, compressed: compressed)
    }
}
