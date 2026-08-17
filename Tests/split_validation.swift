import Foundation
import PDFKit

enum SplitValidationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String { "PDF 拆分验证失败：\(String(describing: self))" }
}

func expectSplitError(
    _ label: String,
    operation: () throws -> Void,
    matches predicate: (PDFSplitError) -> Bool
) throws {
    do {
        try operation()
        throw SplitValidationError.failed("\(label) 未抛出错误")
    } catch let error as PDFSplitError {
        guard predicate(error) else {
            throw SplitValidationError.failed("\(label) 抛出了错误但类型不正确：\(error.localizedDescription)")
        }
    }
}

@main
struct SplitValidation {
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            throw SplitValidationError.failed("缺少测试目录参数")
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let input = root.appendingPathComponent("c-3pages.pdf")

        let parsed = try PDFSplitService.parsePageRange("1-3, 7, 10-15", pageCount: 15)
        let expected = [0, 1, 2, 6] + Array(9...14)
        guard parsed == expected else {
            throw SplitValidationError.failed("页码范围解析不正确：\(parsed)")
        }
        print("页码范围解析验证通过：支持单页、连续范围和中英文逗号。")

        try expectSplitError("空输入", operation: {
            _ = try PDFSplitService.parsePageRange("   ", pageCount: 5)
        }) { error in
            if case .emptyPageRange = error { return true }
            return false
        }
        try expectSplitError("重复页码", operation: {
            _ = try PDFSplitService.parsePageRange("1-2, 2", pageCount: 5)
        }) { error in
            if case .duplicatePage(2) = error { return true }
            return false
        }
        try expectSplitError("越界页码", operation: {
            _ = try PDFSplitService.parsePageRange("1, 6", pageCount: 5)
        }) { error in
            if case .pageOutOfBounds(6, 5) = error { return true }
            return false
        }
        try expectSplitError("非法格式", operation: {
            _ = try PDFSplitService.parsePageRange("1--3", pageCount: 5)
        }) { error in
            if case .invalidPageToken = error { return true }
            return false
        }
        print("页码输入错误验证通过：空输入、重复、越界和非法格式均会拒绝。")

        guard try PDFSplitService.pageGroups(
            pageCount: 6,
            operation: .extract,
            pageIndices: [0, 2, 5]
        ) == [[0, 2, 5]] else {
            throw SplitValidationError.failed("提取页面分组不正确")
        }
        guard try PDFSplitService.pageGroups(
            pageCount: 6,
            operation: .delete,
            pageIndices: [1, 4]
        ) == [[0, 2, 3, 5]] else {
            throw SplitValidationError.failed("删除页面后的分组不正确")
        }
        guard try PDFSplitService.pageGroups(
            pageCount: 6,
            operation: .chunks,
            chunkSize: 2
        ) == [[0, 1], [2, 3], [4, 5]] else {
            throw SplitValidationError.failed("固定页数分组不正确")
        }
        print("拆分策略验证通过：提取、删除后保留和固定页数分组均正确。")

        let extractURL = root.appendingPathComponent("split-extracted.pdf")
        try? FileManager.default.removeItem(at: extractURL)
        let extractedURLs = try PDFSplitService.export(
            sourceURL: input,
            operation: .extract,
            pageIndices: [0, 2],
            destinationURL: extractURL
        )
        guard extractedURLs.count == 1,
              let extracted = PDFDocument(url: extractedURLs[0]),
              extracted.pageCount == 2 else {
            throw SplitValidationError.failed("页面提取输出不正确")
        }

        let splitDirectory = root.appendingPathComponent("split-output", isDirectory: true)
        try? FileManager.default.removeItem(at: splitDirectory)
        try FileManager.default.createDirectory(at: splitDirectory, withIntermediateDirectories: true)

        var progressEvents: [(Int, Int)] = []
        let eachPageURLs = try PDFSplitService.export(
            sourceURL: input,
            operation: .eachPage,
            outputDirectory: splitDirectory,
            progress: { progressEvents.append(($0, $1)) }
        )
        guard eachPageURLs.count == 3,
              eachPageURLs.allSatisfy({ PDFDocument(url: $0)?.pageCount == 1 }),
              progressEvents.last?.0 == 3,
              progressEvents.last?.1 == 3 else {
            throw SplitValidationError.failed("逐页导出或进度回调不正确")
        }

        let chunkURLs = try PDFSplitService.export(
            sourceURL: input,
            operation: .chunks,
            chunkSize: 2,
            outputDirectory: splitDirectory
        )
        guard chunkURLs.count == 2,
              PDFDocument(url: chunkURLs[0])?.pageCount == 2,
              PDFDocument(url: chunkURLs[1])?.pageCount == 1 else {
            throw SplitValidationError.failed("固定页数拆分输出不正确")
        }

        let deleteURL = root.appendingPathComponent("split-deleted.pdf")
        try? FileManager.default.removeItem(at: deleteURL)
        let deletedURLs = try PDFSplitService.export(
            sourceURL: input,
            operation: .delete,
            pageIndices: [1],
            destinationURL: deleteURL
        )
        guard deletedURLs.count == 1,
              PDFDocument(url: deletedURLs[0])?.pageCount == 2 else {
            throw SplitValidationError.failed("删除页面后导出不正确")
        }
        print("PDF 拆分输出验证通过：提取、逐页导出、固定页数拆分和删除后导出均可重新打开。")

        let chineseInput = root.appendingPathComponent("中文资料-测试.pdf")
        try? FileManager.default.removeItem(at: chineseInput)
        try FileManager.default.copyItem(at: input, to: chineseInput)
        let chineseOutput = root.appendingPathComponent("中文资料-提取.pdf")
        try? FileManager.default.removeItem(at: chineseOutput)
        let chineseURLs = try PDFSplitService.export(
            sourceURL: chineseInput,
            operation: .extract,
            pageIndices: [0],
            destinationURL: chineseOutput
        )
        guard chineseURLs.first?.lastPathComponent == "中文资料-提取.pdf" else {
            throw SplitValidationError.failed("中文文件名输出不正确")
        }
        print("中文文件名验证通过：输入和输出路径均可正常处理。")

        let corruptInput = root.appendingPathComponent("corrupt.pdf")
        try Data("not a real pdf".utf8).write(to: corruptInput)
        try expectSplitError("损坏 PDF", operation: {
            _ = try PDFSplitService.export(
                sourceURL: corruptInput,
                operation: .eachPage,
                outputDirectory: splitDirectory
            )
        }) { error in
            if case .unreadablePDF = error { return true }
            return false
        }

        try expectSplitError("空 PDF", operation: {
            _ = try PDFSplitService.pageGroups(
                pageCount: 0,
                operation: .eachPage,
                pageIndices: []
            )
        }) { error in
            if case .noPagesToExport = error { return true }
            return false
        }
        try expectSplitError("空 PDF 无页面导出", operation: {
            _ = try PDFSplitService.pageGroups(
                pageCount: 1,
                operation: .extract,
                pageIndices: []
            )
        }) { error in
            if case .noPagesToExport = error { return true }
            return false
        }

        let encryptedInput = root.appendingPathComponent("encrypted.pdf")
        try? FileManager.default.removeItem(at: encryptedInput)
        guard let encryptedSource = PDFDocument(url: input),
              encryptedSource.write(
                  to: encryptedInput,
                  withOptions: [
                      PDFDocumentWriteOption.ownerPasswordOption: "owner-password",
                      PDFDocumentWriteOption.userPasswordOption: "user-password"
                  ]
              ),
              let encryptedDocument = PDFDocument(url: encryptedInput),
              encryptedDocument.isLocked else {
            throw SplitValidationError.failed("无法创建加密 PDF 测试文件")
        }
        try expectSplitError("加密 PDF", operation: {
            _ = try PDFSplitService.export(
                sourceURL: encryptedInput,
                operation: .eachPage,
                outputDirectory: splitDirectory
            )
        }) { error in
            if case .lockedPDF = error { return true }
            return false
        }
        print("异常 PDF 验证通过：损坏、空 PDF 和加密 PDF 均会被拒绝。")

        let largeGroups = try PDFSplitService.pageGroups(
            pageCount: 1000,
            operation: .chunks,
            chunkSize: 10
        )
        guard largeGroups.count == 100,
              largeGroups.first == Array(0..<10),
              largeGroups.last == Array(990..<1000) else {
            throw SplitValidationError.failed("大页数 PDF 分组不正确")
        }
        print("大页数策略验证通过：1000 页按每 10 页分组无需一次性生成高清图像。")
    }
}
