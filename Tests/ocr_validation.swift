import Foundation
import AppKit

enum OCRTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String { "OCR 验证失败：\(String(describing: self))" }
}

func makeOCRFixture(at url: URL) throws {
    let size = NSSize(width: 1600, height: 620)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 52, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let lines = ["成绩单", "教务处", "简历", "竞赛证书"]
        for (index, line) in lines.enumerated() {
            line.draw(at: NSPoint(x: 100, y: CGFloat(lines.count - index - 1) * 135 + 45), withAttributes: attributes)
        }
        return true
    }

    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw OCRTestError.failed("无法生成测试截图")
    }
    try pngData.write(to: url)
}

@main
struct OCRValidation {
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            throw OCRTestError.failed("缺少测试目录参数")
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let imageURL: URL
        if CommandLine.arguments.count > 2 {
            imageURL = URL(fileURLWithPath: CommandLine.arguments[2])
        } else {
            imageURL = root.appendingPathComponent("ocr-fixture.png")
            try makeOCRFixture(at: imageURL)
        }

        let recognizedText = try OCRTextRecognizer.recognizeText(in: imageURL)
        let urls = [
            URL(fileURLWithPath: "/tmp/简历.pdf"),
            URL(fileURLWithPath: "/tmp/竞赛证书_合并.pdf"),
            URL(fileURLWithPath: "/tmp/成绩单.pdf"),
            URL(fileURLWithPath: "/tmp/教务处.pdf")
        ]
        let result = FileOrderResolver.resolve(urls: urls, text: recognizedText)
        let expected = ["成绩单.pdf", "教务处.pdf", "简历.pdf", "竞赛证书_合并.pdf"]
        guard result.orderedURLs.map(\.lastPathComponent) == expected else {
            throw OCRTestError.failed("识别文字或排序不正确：\(result.orderedURLs.map(\.lastPathComponent))\n识别结果：\(recognizedText)")
        }

        print("OCR 截图识别验证通过：识别文字顺序正确，并按成绩单 → 教务处 → 简历 → 竞赛证书完成排序。")
    }
}
