import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct MainView: View {
    @StateObject private var store = PDFMergeStore()
    @State private var isOrderSheetPresented = false
    @State private var isSplitSheetPresented = false
    @State private var isOCRSheetPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            documentWorkspace
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .addFilesRequested)) { _ in
            store.addFilesWithPanel()
        }
        .alert(item: $store.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好的")))
        }
        .sheet(isPresented: $isOrderSheetPresented) {
            OrderTextView(store: store, isPresented: $isOrderSheetPresented)
        }
        .sheet(isPresented: $isSplitSheetPresented) {
            SplitView()
        }
        .sheet(isPresented: $isOCRSheetPresented) {
            OCRView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("合并 PDF / 图片")
                        .font(.system(size: 28, weight: .bold))
                    Text("文件仅在本机处理，不会上传。拖入文件即可开始。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: store.addFilesWithPanel) {
                        Label("添加文件", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isMerging || store.isRecognizing)
                    Button(action: store.addFolderWithPanel) {
                        Label("添加文件夹", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isMerging || store.isRecognizing)
                    Button {
                        isSplitSheetPresented = true
                    } label: {
                        Label("拆分 PDF", systemImage: "scissors")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isMerging || store.isRecognizing)
                    Button {
                        isOCRSheetPresented = true
                    } label: {
                        Label("PDF OCR", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isMerging || store.isRecognizing)
                }
            }
            HStack(spacing: 18) {
                Label("\(store.items.count) 个文件", systemImage: "doc.on.doc")
                Label("\(store.totalPages) 页", systemImage: "doc.text")
                if store.isRecognizing {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在识别截图，请稍候…")
                        .foregroundStyle(.secondary)
                } else if store.isMerging {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.enhanceAfterMerge ? "正在合并并清晰化，请稍候…" : "正在合并，请稍候…")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var documentWorkspace: some View {
        HSplitView {
            fileSidebar
                .frame(minWidth: 220, idealWidth: 270, maxWidth: 360)

            HSplitView {
                pageSidebar
                    .frame(minWidth: 230, idealWidth: 310, maxWidth: 430)
                previewPane
                    .frame(minWidth: 360, idealWidth: 560)
            }
        }
        .frame(minHeight: 360)
    }

    private var fileSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("待合并文件")
                    .font(.headline)
                Spacer()
                Text("\(store.items.count)")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if store.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: store.isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                        .font(.system(size: 34))
                        .foregroundStyle(store.isDropTargeted ? Color.accentColor : .secondary)
                    Text("拖入 PDF 或图片")
                        .font(.headline)
                    Text("或使用右上角的添加按钮")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .trailing)
                            Image(systemName: item.isImage ? "photo" : "doc.richtext")
                                .foregroundStyle(item.isImage ? .blue : .red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.fileName)
                                    .lineLimit(1)
                                Text("\(item.typeLabel) · \(store.pageItemsByFileID[item.id]?.count ?? item.pageCount) 页")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button {
                                store.remove(item)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除此文件")
                            .disabled(store.isMerging || store.isRecognizing)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(
                            store.selectedFileID == item.id
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onTapGesture {
                            store.selectFile(item.id)
                        }
                    }
                    .onDelete(perform: store.remove)
                    .onMove(perform: store.move)
                }
                .listStyle(.inset)
                .onReceive(store.$selectedPageIDs) { selection in
                    store.updateFocusedPage(from: selection)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(store.isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
                .padding(8)
                .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $store.isDropTargeted) { providers in
            store.importDropped(providers: providers)
            return true
        }
    }

    private var pageSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("页面")
                        .font(.headline)
                    Text("选择页面可预览、排序或编辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !store.currentPages.isEmpty {
                    Button {
                        store.selectAllCurrentPages()
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .buttonStyle(.borderless)
                    .help("全选当前 PDF 页面")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if store.currentPages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                        Text(store.items.isEmpty ? "添加 PDF 或图片后显示页面" : "当前文件没有可显示的页面")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedPageIDs) {
                    ForEach(Array(store.currentPages.enumerated()), id: \.element.id) { index, pageItem in
                        HStack(alignment: .top, spacing: 8) {
                            PageThumbnailView(page: store.pdfPage(for: pageItem))
                                .frame(width: 78, height: 104)
                                .clipShape(RoundedRectangle(cornerRadius: 5))

                            VStack(alignment: .leading, spacing: 5) {
                                Text("第 \(index + 1) 页")
                                    .font(.callout.weight(.medium))
                                Text("原第 \(pageItem.originalPageNumber) 页")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if pageItem.rotation != 0 {
                                    Label("旋转 \(pageItem.rotation)°", systemImage: "rotate.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer(minLength: 2)

                            Button {
                                store.toggleInclusion(for: pageItem.id)
                            } label: {
                                Image(systemName: pageItem.isIncluded ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(pageItem.isIncluded ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(pageItem.isIncluded ? "从最终合并中排除" : "参与最终合并")
                            .disabled(store.isMerging || store.isRecognizing)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.focusPage(pageItem.id)
                        }
                        .tag(pageItem.id)
                    }
                    .onMove(perform: store.movePages)
                }
                .listStyle(.inset)
            }

            pageEditorToolbar
        }
    }

    private var pageEditorToolbar: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(spacing: 6) {
                Text("已选 \(store.selectedPageIDs.count) 页")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.rotateSelectedPages(by: -90)
                } label: {
                    Image(systemName: "rotate.left")
                }
                .buttonStyle(.borderless)
                .help("左旋 90°")
                .disabled(store.selectedPageIDs.isEmpty || store.isMerging || store.isRecognizing)
                Button {
                    store.rotateSelectedPages(by: 90)
                } label: {
                    Image(systemName: "rotate.right")
                }
                .buttonStyle(.borderless)
                .help("右旋 90°")
                .disabled(store.selectedPageIDs.isEmpty || store.isMerging || store.isRecognizing)
                Button {
                    store.deleteSelectedPages()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除选中页面")
                .disabled(store.selectedPageIDs.isEmpty || store.isMerging || store.isRecognizing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            HStack {
                if let pageNumber = store.previewPageNumber {
                    Text("第 \(pageNumber) / \(store.currentPages.count) 页")
                        .font(.headline)
                } else {
                        Text("页面预览")
                        .font(.headline)
                }
                Spacer()
                if store.selectedPageIDs.count > 1 {
                    Text("已选择 \(store.selectedPageIDs.count) 页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if let document = store.currentDocument, let page = store.previewPage {
                PDFPreviewView(document: document, page: page)
                    .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("选择页面查看预览")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if let resultURL = store.resultURL {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("合并完成")
                            .fontWeight(.medium)
                        Text(resultURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Button("在 Finder 中显示", action: store.revealResultInFinder)
                        .buttonStyle(.link)
                } else {
                    Text("拖动列表项目可调整合并顺序")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                if !store.items.isEmpty {
                    Button {
                        store.reorderFromImageWithPanel()
                    } label: {
                        Label("截图识别", systemImage: "text.viewfinder")
                    }
                    .disabled(store.isMerging || store.isRecognizing)
                    .help("选择包含文件名或关键词的截图，识别后自动按出现顺序排列")

                    Button("粘贴顺序") {
                        isOrderSheetPresented = true
                    }
                    .disabled(store.isMerging || store.isRecognizing)
                    .help("粘贴每行一个文件名，按文字顺序排列")

                    Button("清空", action: store.clear)
                        .disabled(store.isMerging || store.isRecognizing)
                }
                Spacer()
                clarityControls
                compressionToggle
                Button(action: store.mergeWithSavePanel) {
                    if store.isMerging {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("合并为 PDF")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isMerging || store.isRecognizing || store.items.isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }

    private var clarityControls: some View {
        HStack(spacing: 8) {
            Toggle("清晰化 PDF", isOn: $store.enhanceAfterMerge)
                .toggleStyle(.checkbox)
                .help("重新渲染每页并进行锐化、降噪和对比度增强；扫描件效果更明显，但页面会栅格化。")
                .disabled(store.isMerging || store.isRecognizing)
            if store.enhanceAfterMerge {
                Picker("清晰度", selection: $store.clarityLevel) {
                    ForEach(PDFClarityLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .frame(width: 110)
                .help("选择清晰化强度")
                .disabled(store.isMerging || store.isRecognizing)
            }
        }
    }

    @ViewBuilder
    private var compressionToggle: some View {
        if #available(macOS 13.4, *) {
            Toggle("压缩 PDF", isOn: $store.compressAfterMerge)
                .toggleStyle(.checkbox)
                .help("合并时优化图片以减小文件体积，可能会降低图片质量。")
                .disabled(store.isMerging || store.isRecognizing)
        } else {
            Label("压缩 PDF（需 macOS 13.4+）", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
                .help("PDF 压缩需要 macOS 13.4 或更高版本。")
        }
    }
}
