import Foundation
import AppKit
import CoreGraphics
import PDFKit
import Accelerate

enum PDFClarityLevel: String, CaseIterable, Identifiable {
    case light
    case standard
    case strong

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "轻度"
        case .standard: return "标准"
        case .strong: return "强化"
        }
    }

    fileprivate var renderScale: CGFloat {
        switch self {
        case .light: return 1.5
        case .standard: return 2.0
        case .strong: return 2.5
        }
    }

    fileprivate var contrast: Double {
        switch self {
        case .light: return 1.04
        case .standard: return 1.1
        case .strong: return 1.16
        }
    }

    fileprivate var brightness: Double {
        switch self {
        case .light: return 0.005
        case .standard: return 0.01
        case .strong: return 0.015
        }
    }
}

enum PDFPageEnhancementError: LocalizedError {
    case unableToRender(Int, String)
    case unableToCreatePage(Int)

    var errorDescription: String? {
        switch self {
        case .unableToRender(let pageNumber, let reason):
            return "无法清晰化第 \(pageNumber) 页：\(reason)"
        case .unableToCreatePage(let pageNumber):
            return "无法生成清晰化后的第 \(pageNumber) 页。"
        }
    }
}

enum PDFPageEnhancer {
    private static let maximumPixelDimension = 4096

    static func enhance(_ document: PDFDocument, level: PDFClarityLevel) throws -> PDFDocument {
        let enhancedDocument = PDFDocument()

        for index in 0..<document.pageCount {
            let pageNumber = index + 1
            guard let page = document.page(at: index) else {
                throw PDFPageEnhancementError.unableToRender(pageNumber, "无法读取页面对象")
            }
            guard let image = try enhancedImage(for: page, level: level) else {
                throw PDFPageEnhancementError.unableToRender(pageNumber, "无法生成图像")
            }
            guard let enhancedPage = PDFPage(image: NSImage(cgImage: image, size: page.bounds(for: .mediaBox).size)) else {
                throw PDFPageEnhancementError.unableToCreatePage(pageNumber)
            }

            for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                enhancedPage.setBounds(page.bounds(for: box), for: box)
            }
            enhancedPage.rotation = page.rotation
            enhancedDocument.insert(enhancedPage, at: enhancedDocument.pageCount)
        }

        return enhancedDocument
    }

    private static func enhancedImage(
        for page: PDFPage,
        level: PDFClarityLevel
    ) throws -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let maximumDimension = max(bounds.width, bounds.height)
        let cappedScale = min(level.renderScale, CGFloat(maximumPixelDimension) / maximumDimension)
        let scale = max(1.0, cappedScale)
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
            return nil
        }

        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.saveGState()
        context.translateBy(x: -bounds.minX * scale, y: -bounds.minY * scale)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let renderedImage = context.makeImage() else {
            return nil
        }
        return enhanceBitmap(renderedImage, level: level)
    }

    private static func enhanceBitmap(_ image: CGImage, level: PDFClarityLevel) -> CGImage {
        guard let sourceData = image.dataProvider?.data,
              let sourcePointer = CFDataGetBytePtr(sourceData) else {
            return image
        }

        let byteCount = image.bytesPerRow * image.height
        var workingData = Data(bytes: sourcePointer, count: byteCount)
        let rowBytes = image.bytesPerRow
        let height = vImagePixelCount(image.height)
        let width = vImagePixelCount(image.width)

        if level != .light {
            var denoisedData = Data(count: byteCount)
            let error = workingData.withUnsafeMutableBytes { sourceBytes in
                denoisedData.withUnsafeMutableBytes { destinationBytes in
                    var sourceBuffer = vImage_Buffer(
                        data: sourceBytes.baseAddress,
                        height: height,
                        width: width,
                        rowBytes: rowBytes
                    )
                    var destinationBuffer = vImage_Buffer(
                        data: destinationBytes.baseAddress,
                        height: height,
                        width: width,
                        rowBytes: rowBytes
                    )
                    return vImageBoxConvolve_ARGB8888(
                        &sourceBuffer,
                        &destinationBuffer,
                        nil,
                        0,
                        0,
                        3,
                        3,
                        nil,
                        vImage_Flags(kvImageEdgeExtend)
                    )
                }
            }
            if error == kvImageNoError {
                workingData = denoisedData
            }
        }

        var sharpenedData = Data(count: byteCount)
        let sharpenKernel: [Int16]
        switch level {
        case .light: sharpenKernel = [0, -1, 0, -1, 5, -1, 0, -1, 0]
        case .standard: sharpenKernel = [0, -1, 0, -1, 6, -1, 0, -1, 0]
        case .strong: sharpenKernel = [0, -1, 0, -1, 7, -1, 0, -1, 0]
        }
        let sharpenError = workingData.withUnsafeMutableBytes { sourceBytes in
            sharpenedData.withUnsafeMutableBytes { destinationBytes in
                sharpenKernel.withUnsafeBufferPointer { kernel in
                    var sourceBuffer = vImage_Buffer(
                        data: sourceBytes.baseAddress,
                        height: height,
                        width: width,
                        rowBytes: rowBytes
                    )
                    var destinationBuffer = vImage_Buffer(
                        data: destinationBytes.baseAddress,
                        height: height,
                        width: width,
                        rowBytes: rowBytes
                    )
                    return vImageConvolve_ARGB8888(
                        &sourceBuffer,
                        &destinationBuffer,
                        nil,
                        0,
                        0,
                        kernel.baseAddress!,
                        3,
                        3,
                        1,
                        nil,
                        vImage_Flags(kvImageEdgeExtend)
                    )
                }
            }
        }
        if sharpenError == kvImageNoError {
            workingData = sharpenedData
        }

        workingData.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            let pixels = baseAddress.assumingMemoryBound(to: UInt8.self)
            let brightnessOffset = level.brightness * 255.0
            for index in stride(from: 0, to: byteCount, by: 4) {
                for component in 0..<3 {
                    let original = Double(pixels[index + component])
                    let adjusted = ((original - 127.5) * level.contrast) + 127.5 + brightnessOffset
                    pixels[index + component] = UInt8(max(0, min(255, adjusted.rounded())))
                }
            }
        }

        guard let provider = CGDataProvider(data: workingData as CFData),
              let enhancedImage = CGImage(
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: image.bitsPerComponent,
                  bitsPerPixel: image.bitsPerPixel,
                  bytesPerRow: rowBytes,
                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: image.bitmapInfo,
                  provider: provider,
                  decode: image.decode,
                  shouldInterpolate: true,
                  intent: image.renderingIntent
              ) else {
            return image
        }
        return enhancedImage
    }
}
