#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/合并 PDF.app"

rm -rf "$APP_DIR" "$BUILD_DIR/module-cache" "$BUILD_DIR/module-cache-tests" "$BUILD_DIR/merge_validation" "$BUILD_DIR/test-fixtures"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
MODULE_CACHE="$BUILD_DIR/module-cache"
mkdir -p "$MODULE_CACHE"

swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -module-cache-path "$MODULE_CACHE" \
  -framework SwiftUI \
  -framework AppKit \
  -framework PDFKit \
  -framework UniformTypeIdentifiers \
  "$PROJECT_DIR/Sources/FolderReader.swift" \
  "$PROJECT_DIR/Sources/FileOrderResolver.swift" \
  "$PROJECT_DIR/Sources/PDFMergeApp.swift" \
  -o "$APP_DIR/Contents/MacOS/PDFMerge"

cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/PDFMerge"
# 工作区可能带有 Finder/File Provider 扩展属性；清掉产物属性，避免 codesign 拒绝。
xattr -cr "$APP_DIR"
# 给无开发者证书的本地构建做临时签名，Launch Services 才能正常识别为应用。
for attempt in 1 2 3; do
  xattr -cr "$APP_DIR"
  if codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1; then
    break
  fi
done
xattr -cr "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "已生成：$APP_DIR"
