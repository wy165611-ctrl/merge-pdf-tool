import Foundation
import AppKit
import PDFKit

enum ValidationError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { "验证失败：\(String(describing: self))" }
}

func makePDF(at url: URL, pageSizes: [CGSize], marker: String) throws {
    let document = PDFDocument()
    for (index, size) in pageSizes.enumerated() {
        guard let page = PDFPage(image: NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let text = "\(marker)-\(index + 1)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 22),
                .foregroundColor: NSColor.black
            ]
            text.draw(at: CGPoint(x: 24, y: size.height / 2), withAttributes: attributes)
            return true
        }) else { throw ValidationError.failed("无法创建测试页") }
        document.insert(page, at: document.pageCount)
    }
    guard document.write(to: url) else { throw ValidationError.failed("无法写入 \(url.path)") }
}

@main
struct TestRunner {
    static func main() throws {
guard CommandLine.arguments.count > 1 else { throw ValidationError.failed("缺少测试目录参数") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let inputA = root.appendingPathComponent("a-2pages.pdf")
let inputB = root.appendingPathComponent("b-1page-landscape.pdf")
let inputC = root.appendingPathComponent("c-3pages.pdf")
let output = root.appendingPathComponent("merged.pdf")
try? FileManager.default.removeItem(at: output)
try makePDF(at: inputA, pageSizes: [CGSize(width: 300, height: 400), CGSize(width: 300, height: 400)], marker: "A")
try makePDF(at: inputB, pageSizes: [CGSize(width: 600, height: 300)], marker: "B")
try makePDF(at: inputC, pageSizes: [CGSize(width: 400, height: 500), CGSize(width: 400, height: 500), CGSize(width: 400, height: 500)], marker: "C")

let merged = PDFDocument()
for url in [inputA, inputB, inputC] {
    guard let source = PDFDocument(url: url) else { throw ValidationError.failed("无法读取输入") }
    for index in 0..<source.pageCount {
        guard let page = source.page(at: index) else { throw ValidationError.failed("无法读取页面") }
        merged.insert(page, at: merged.pageCount)
    }
}
guard merged.pageCount == 6 else { throw ValidationError.failed("期望 6 页，实际 \(merged.pageCount) 页") }
guard merged.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 300, height: 400) else { throw ValidationError.failed("第 1 页尺寸不正确") }
guard merged.page(at: 2)?.bounds(for: .mediaBox).size == CGSize(width: 600, height: 300) else { throw ValidationError.failed("第 3 页方向/尺寸不正确") }
guard merged.page(at: 5)?.bounds(for: .mediaBox).size == CGSize(width: 400, height: 500) else { throw ValidationError.failed("第 6 页尺寸不正确") }
guard merged.write(to: output), let reopened = PDFDocument(url: output), reopened.pageCount == 6 else { throw ValidationError.failed("输出无法重新打开或页数不正确") }
print("PDF 合并验证通过：输入 2+1+3 页，输出 6 页；顺序和页面尺寸均正确。")

let fileA = PDFFileItem(id: UUID(), url: inputA, pageCount: 2)
let fileB = PDFFileItem(id: UUID(), url: inputB, pageCount: 1)
let fileC = PDFFileItem(id: UUID(), url: inputC, pageCount: 3)
var editedPages = [
    PDFPageItem.pages(for: fileC)[2],
    PDFPageItem.pages(for: fileA)[1],
    PDFPageItem.pages(for: fileB)[0]
]
editedPages[0].rotate(by: -90)
guard editedPages[0].rotation == 270 else {
    throw ValidationError.failed("页面旋转角度规范化不正确")
}

let editedOutput = root.appendingPathComponent("edited-pages.pdf")
try? FileManager.default.removeItem(at: editedOutput)
try PDFMergeService.merge(
    pageItems: editedPages,
    to: editedOutput,
    compressed: false,
    enhanced: false,
    clarityLevel: .standard
)
guard let editedDocument = PDFDocument(url: editedOutput), editedDocument.pageCount == 3 else {
    throw ValidationError.failed("页面编辑导出页数不正确")
}
guard editedDocument.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 400, height: 500),
      editedDocument.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 300, height: 400),
      editedDocument.page(at: 2)?.bounds(for: .mediaBox).size == CGSize(width: 600, height: 300) else {
    throw ValidationError.failed("页面编辑后的顺序或尺寸不正确")
}
guard editedDocument.page(at: 0)?.rotation == 270 else {
    throw ValidationError.failed("页面旋转没有应用到导出文档")
}
guard PDFPageItem.pages(for: fileA).count == 2,
      PDFPageItem.pages(for: fileC).allSatisfy({ $0.rotation == 0 && $0.isIncluded }) else {
    throw ValidationError.failed("页面模型不应修改原始页面状态")
}
print("页面编辑验证通过：自定义顺序、旋转和非破坏式导出均正确。")

editedPages[1].isIncluded = false
let extractedOutput = root.appendingPathComponent("edited-pages-extracted.pdf")
try? FileManager.default.removeItem(at: extractedOutput)
try PDFMergeService.merge(
    pageItems: editedPages,
    to: extractedOutput,
    compressed: false,
    enhanced: false,
    clarityLevel: .standard
)
guard let extractedDocument = PDFDocument(url: extractedOutput), extractedDocument.pageCount == 2 else {
    throw ValidationError.failed("排除页面后的导出页数不正确")
}
print("页面排除验证通过：未勾选页面不会进入最终 PDF。")

let enhancedOutput = root.appendingPathComponent("merged-enhanced.pdf")
try? FileManager.default.removeItem(at: enhancedOutput)
let enhancedDocument = try PDFPageEnhancer.enhance(merged, level: .standard)
guard enhancedDocument.pageCount == 6 else {
    throw ValidationError.failed("清晰化后的 PDF 页数不正确")
}
guard enhancedDocument.page(at: 2)?.bounds(for: .mediaBox).size == CGSize(width: 600, height: 300) else {
    throw ValidationError.failed("清晰化后的第 3 页尺寸不正确")
}
try PDFDocumentWriter.write(enhancedDocument, to: enhancedOutput, compressed: false)
guard let reopenedEnhanced = PDFDocument(url: enhancedOutput), reopenedEnhanced.pageCount == 6 else {
    throw ValidationError.failed("清晰化后的 PDF 无法重新打开或页数不正确")
}
print("PDF 清晰化验证通过：输出可重新打开，页数和页面尺寸保持不变。")

let compressedOutput = root.appendingPathComponent("merged-compressed.pdf")
try? FileManager.default.removeItem(at: compressedOutput)
if #available(macOS 13.4, *) {
    try PDFDocumentWriter.write(merged, to: compressedOutput, compressed: true)
    guard let compressed = PDFDocument(url: compressedOutput), compressed.pageCount == 6 else {
        throw ValidationError.failed("压缩后的 PDF 无法重新打开或页数不正确")
    }
    print("PDF 压缩验证通过：压缩选项输出可重新打开，页数保持为 6 页。")
}

let orderText = "c-3pages.pdf\n1. a-2pages.pdf\nb-1page-landscape"
let orderResult = FileOrderResolver.resolve(urls: [inputA, inputB, inputC], text: orderText)
let expectedOrder = [inputC.lastPathComponent, inputA.lastPathComponent, inputB.lastPathComponent]
guard orderResult.orderedURLs.map(\.lastPathComponent) == expectedOrder else {
    throw ValidationError.failed("粘贴文字排序不正确：\(orderResult.orderedURLs.map(\.lastPathComponent))")
}
guard orderResult.unknownLines.isEmpty, orderResult.duplicateLines.isEmpty else {
    throw ValidationError.failed("有效文件名不应被判定为未知或重复")
}
print("文件夹文件名排序验证通过：支持换行、数字序号和省略 .pdf 扩展名。")

let smartURLs = [
    URL(fileURLWithPath: "/tmp/教务处_12.pdf"),
    URL(fileURLWithPath: "/tmp/竞赛证书_合并.pdf"),
    URL(fileURLWithPath: "/tmp/申请表1.pdf")
]
let smartResult = FileOrderResolver.resolve(urls: smartURLs, text: "我需要你按照申请表 教务处 竞赛证书合并")
guard smartResult.orderedURLs.map(\.lastPathComponent) == ["申请表1.pdf", "教务处_12.pdf", "竞赛证书_合并.pdf"] else {
    throw ValidationError.failed("自然语言关键词排序不正确：\(smartResult.orderedURLs.map(\.lastPathComponent))")
}
print("自然语言关键词排序验证通过：申请表1 → 教务处_12 → 竞赛证书_合并。")

let filteredResult = FileOrderResolver.resolve(urls: smartURLs, text: "请合并申请表和教务处")
guard filteredResult.orderedURLs.map(\.lastPathComponent) == ["申请表1.pdf", "教务处_12.pdf"] else {
    throw ValidationError.failed("未提及文件移除验证不正确：\(filteredResult.orderedURLs.map(\.lastPathComponent))")
}
print("未提及文件移除验证通过：竞赛证书_合并.pdf 已从当前列表排除。")

let folder = root.appendingPathComponent("folder-source", isDirectory: true)
try? FileManager.default.removeItem(at: folder)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try FileManager.default.copyItem(at: inputA, to: folder.appendingPathComponent("02-a.pdf"))
try FileManager.default.copyItem(at: inputB, to: folder.appendingPathComponent("01-b.pdf"))
try Data("not pdf".utf8).write(to: folder.appendingPathComponent("03-note.txt"))
let folderFiles = try FolderReader.directFiles(in: folder)
let sortedFolderFiles = folderFiles.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
guard sortedFolderFiles.map(\.lastPathComponent) == ["01-b.pdf", "02-a.pdf", "03-note.txt"] else {
    throw ValidationError.failed("文件夹直接文件读取或排序不正确")
}
print("文件夹读取验证通过：直接文件和非 PDF 文件均被发现，应用会跳过非 PDF。")
    }
}
