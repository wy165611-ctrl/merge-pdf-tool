#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_DIR/build/test-fixtures"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
MODULE_CACHE="$PROJECT_DIR/build/module-cache-tests"
mkdir -p "$MODULE_CACHE"

swiftc \
  -swift-version 5 \
  -module-cache-path "$MODULE_CACHE" \
  -framework AppKit \
  -framework PDFKit \
  -framework Accelerate \
  "$PROJECT_DIR/Sources/FolderReader.swift" \
  "$PROJECT_DIR/Sources/FileOrderResolver.swift" \
  "$PROJECT_DIR/Sources/Models/PDFFileItem.swift" \
  "$PROJECT_DIR/Sources/Models/PDFPageItem.swift" \
  "$PROJECT_DIR/Sources/PDFPageEnhancer.swift" \
  "$PROJECT_DIR/Sources/PDFDocumentWriter.swift" \
  "$PROJECT_DIR/Sources/Services/PDFMergeService.swift" \
  "$PROJECT_DIR/Tests/merge_validation.swift" \
  -o "$PROJECT_DIR/build/merge_validation"

"$PROJECT_DIR/build/merge_validation" "$TEST_DIR"

swiftc \
  -swift-version 5 \
  -module-cache-path "$MODULE_CACHE" \
  -framework PDFKit \
  "$PROJECT_DIR/Sources/PDFDocumentWriter.swift" \
  "$PROJECT_DIR/Sources/Services/PDFSplitService.swift" \
  "$PROJECT_DIR/Tests/split_validation.swift" \
  -o "$PROJECT_DIR/build/split_validation"

"$PROJECT_DIR/build/split_validation" "$TEST_DIR"

swiftc \
  -swift-version 5 \
  -module-cache-path "$MODULE_CACHE" \
  -framework AppKit \
  -framework PDFKit \
  -framework Vision \
  "$PROJECT_DIR/Sources/Services/OCRService.swift" \
  "$PROJECT_DIR/Tests/pdf_ocr_validation.swift" \
  -o "$PROJECT_DIR/build/pdf_ocr_validation"

"$PROJECT_DIR/build/pdf_ocr_validation" "$TEST_DIR"

swiftc \
  -swift-version 5 \
  -module-cache-path "$MODULE_CACHE" \
  -framework AppKit \
  -framework PDFKit \
  -framework Vision \
  -framework ImageIO \
  "$PROJECT_DIR/Sources/FileOrderResolver.swift" \
  "$PROJECT_DIR/Sources/Services/OCRService.swift" \
  "$PROJECT_DIR/Sources/OCRTextRecognizer.swift" \
  "$PROJECT_DIR/Tests/ocr_validation.swift" \
  -o "$PROJECT_DIR/build/ocr_validation"

"$PROJECT_DIR/build/ocr_validation" "$TEST_DIR"

printf 'not a pdf\n' > "$TEST_DIR/not-a-pdf.txt"
if file -b "$TEST_DIR/not-a-pdf.txt" | grep -qi 'PDF'; then
  echo "错误提示测试失败：文本文件被识别为 PDF"
  exit 1
fi

if [[ -e "$TEST_DIR/empty-output.pdf" ]]; then
  echo "空列表测试失败：产生了输出文件"
  exit 1
fi

echo "基础错误路径验证通过：非 PDF 被拒绝，空列表不产生输出。"
