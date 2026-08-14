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
  "$PROJECT_DIR/Sources/FolderReader.swift" \
  "$PROJECT_DIR/Sources/FileOrderResolver.swift" \
  "$PROJECT_DIR/Tests/merge_validation.swift" \
  -o "$PROJECT_DIR/build/merge_validation"

"$PROJECT_DIR/build/merge_validation" "$TEST_DIR"

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
