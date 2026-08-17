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
  -framework Accelerate \
  -framework UniformTypeIdentifiers \
  -framework Vision \
  -framework ImageIO \
  "$PROJECT_DIR/Sources/FolderReader.swift" \
  "$PROJECT_DIR/Sources/FileOrderResolver.swift" \
  "$PROJECT_DIR/Sources/Services/OCRService.swift" \
  "$PROJECT_DIR/Sources/OCRTextRecognizer.swift" \
  "$PROJECT_DIR/Sources/PDFPageEnhancer.swift" \
  "$PROJECT_DIR/Sources/PDFDocumentWriter.swift" \
  "$PROJECT_DIR/Sources/Models/PDFFileItem.swift" \
  "$PROJECT_DIR/Sources/Models/PDFPageItem.swift" \
  "$PROJECT_DIR/Sources/Services/PDFMergeService.swift" \
  "$PROJECT_DIR/Sources/Services/PDFSplitService.swift" \
  "$PROJECT_DIR/Sources/Stores/OCRStore.swift" \
  "$PROJECT_DIR/Sources/Stores/PDFMergeStore.swift" \
  "$PROJECT_DIR/Sources/Stores/PDFSplitStore.swift" \
  "$PROJECT_DIR/Sources/Utilities/AppNotifications.swift" \
  "$PROJECT_DIR/Sources/Views/MainView.swift" \
  "$PROJECT_DIR/Sources/Views/PDFKitViews.swift" \
  "$PROJECT_DIR/Sources/Views/OrderTextView.swift" \
  "$PROJECT_DIR/Sources/Views/OCRView.swift" \
  "$PROJECT_DIR/Sources/Views/SplitView.swift" \
  "$PROJECT_DIR/Sources/App/PDFMergeApp.swift" \
  -o "$APP_DIR/Contents/MacOS/PDFMerge"

cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
chmod +x "$APP_DIR/Contents/MacOS/PDFMerge"

clear_bundle_metadata() {
  xattr -cr "$APP_DIR" 2>/dev/null || true
  xattr -r -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
  xattr -r -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true
}

# 工作区可能带有 Finder/File Provider 扩展属性；清掉产物属性，避免 codesign 拒绝。
clear_bundle_metadata
# 给无开发者证书的本地构建做临时签名，Launch Services 才能正常识别为应用。
for attempt in 1 2 3; do
  clear_bundle_metadata
  if codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1; then
    break
  fi
done
clear_bundle_metadata
codesign --verify --deep --strict "$APP_DIR"

echo "已生成：$APP_DIR"
