import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct PDFItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let pageCount: Int

    var fileName: String { url.lastPathComponent }
}

struct PDFAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class PDFMergeStore: ObservableObject {
    @Published private(set) var items: [PDFItem] = []
    @Published private(set) var isMerging = false
    @Published private(set) var resultURL: URL?
    @Published var alert: PDFAlert?
    @Published var isDropTargeted = false

    private let lastDirectoryKey = "lastSaveDirectory"

    var totalPages: Int { items.reduce(0) { $0 + $1.pageCount } }

    func addFilesWithPanel() {
        guard !isMerging else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.title = "选择 PDF 文件"
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
    }

    func addFolderWithPanel() {
        guard !isMerging else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.title = "选择包含 PDF 的文件夹"
        panel.prompt = "读取文件夹"
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        do {
            let files = try FolderReader.directFiles(in: folderURL)
            add(urls: files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            if files.isEmpty {
                alert = PDFAlert(title: "文件夹为空", message: "所选文件夹中没有可读取的文件。")
            }
        } catch {
            alert = PDFAlert(title: "无法读取文件夹", message: "请检查文件夹访问权限后重试。\n\(error.localizedDescription)")
        }
    }

    func reorderFromText(_ text: String) {
        guard !isMerging else { return }
        let originalCount = items.count
        let result = FileOrderResolver.resolve(urls: items.map(\.url), text: text)
        let itemByPath = Dictionary(uniqueKeysWithValues: items.map { ($0.url.standardizedFileURL.path.lowercased(), $0) })
        items = result.orderedURLs.compactMap { itemByPath[$0.standardizedFileURL.path.lowercased()] }
        resultURL = nil

        var messages: [String] = []
        let removedCount = originalCount - items.count
        if removedCount > 0 {
            messages.append("已移除未在粘贴内容中提到的文件：\(removedCount) 个（仅从列表移除，未删除原文件）")
        }
        if !result.unknownLines.isEmpty {
            messages.append("未找到：" + result.unknownLines.joined(separator: "、"))
        }
        if !result.duplicateLines.isEmpty {
            messages.append("重复项已忽略：" + result.duplicateLines.joined(separator: "、"))
        }
        if !messages.isEmpty {
            alert = PDFAlert(title: "顺序已更新", message: messages.joined(separator: "\n"))
        }
    }

    func importDropped(providers: [NSItemProvider]) {
        guard !isMerging else { return }
        // 按 providers 的顺序逐个读取，保证一次拖入多个文件时沿用系统顺序。
        Task { [weak self] in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.fileURL() {
                    urls.append(url)
                }
            }
            guard let self else { return }
            self.add(urls: urls)
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        guard !isMerging else { return }
        items.move(fromOffsets: offsets, toOffset: destination)
        resultURL = nil
    }

    func remove(at offsets: IndexSet) {
        guard !isMerging else { return }
        items.remove(atOffsets: offsets)
        resultURL = nil
    }

    func remove(_ item: PDFItem) {
        guard !isMerging else { return }
        items.removeAll { $0.id == item.id }
        resultURL = nil
    }

    func clear() {
        guard !isMerging else { return }
        items.removeAll()
        resultURL = nil
    }

    func mergeWithSavePanel() {
        guard !isMerging else { return }
        guard !items.isEmpty else {
            alert = PDFAlert(title: "无法合并", message: "请先添加至少一个 PDF 文件。")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.title = "保存合并后的 PDF"
        panel.prompt = "保存"
        panel.nameFieldStringValue = "合并后的文档.pdf"
        if let path = UserDefaults.standard.string(forKey: lastDirectoryKey) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let finalURL = url.pathExtension.lowercased() == "pdf" ? url : url.appendingPathExtension("pdf")
        UserDefaults.standard.set(finalURL.deletingLastPathComponent().path, forKey: lastDirectoryKey)
        startMerge(to: finalURL)
    }

    func revealResultInFinder() {
        guard let resultURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resultURL])
    }

    private func add(urls: [URL]) {
        guard !urls.isEmpty else { return }
        var additions: [PDFItem] = []
        var problems: [String] = []
        let existingPaths = Set(items.map { $0.url.standardizedFileURL.path })
        var seenPaths = existingPaths

        for url in urls {
            let standardized = url.standardizedFileURL
            guard standardized.pathExtension.lowercased() == "pdf" else {
                problems.append("不是 PDF：\(url.lastPathComponent)")
                continue
            }
            guard !seenPaths.contains(standardized.path) else { continue }
            guard let document = PDFDocument(url: standardized) else {
                problems.append("无法读取或文件已损坏：\(url.lastPathComponent)")
                continue
            }
            if document.isLocked {
                problems.append("文件已加密或需要密码：\(url.lastPathComponent)")
                continue
            }
            guard document.pageCount > 0 else {
                problems.append("文件没有页面：\(url.lastPathComponent)")
                continue
            }
            additions.append(PDFItem(url: standardized, pageCount: document.pageCount))
            seenPaths.insert(standardized.path)
        }

        if !additions.isEmpty {
            items.append(contentsOf: additions)
            resultURL = nil
        }
        if !problems.isEmpty {
            alert = PDFAlert(
                title: additions.isEmpty ? "无法添加文件" : "部分文件未添加",
                message: problems.joined(separator: "\n")
            )
        }
    }

    private func startMerge(to destinationURL: URL) {
        isMerging = true
        resultURL = nil
        let sourceURLs = items.map(\.url)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<URL, Error>
            do {
                let merged = PDFDocument()
                for sourceURL in sourceURLs {
                    guard let source = PDFDocument(url: sourceURL), !source.isLocked else {
                        throw MergeError.unreadable(sourceURL.lastPathComponent)
                    }
                    for index in 0..<source.pageCount {
                        guard let page = source.page(at: index) else {
                            throw MergeError.unreadable(sourceURL.lastPathComponent)
                        }
                        merged.insert(page, at: merged.pageCount)
                    }
                }
                guard merged.pageCount > 0 else { throw MergeError.empty }
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                guard merged.write(to: destinationURL) else {
                    throw MergeError.saveFailed(destinationURL.path)
                }
                result = .success(destinationURL)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isMerging = false
                switch result {
                case .success(let url):
                    self.resultURL = url
                case .failure(let error):
                    self.alert = PDFAlert(title: "合并失败", message: error.localizedDescription)
                }
            }
        }
    }
}

enum MergeError: LocalizedError {
    case unreadable(String)
    case saveFailed(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "合并时无法读取文件：\(name)"
        case .saveFailed(let path): return "无法写入保存位置：\(path)\n请检查权限或选择其他位置。"
        case .empty: return "没有可合并的页面。"
        }
    }
}

extension NSItemProvider {
    func fileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let nsurl = item as? NSURL {
                    continuation.resume(returning: nsurl as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

@main
struct PDFMergeApp: App {
    var body: some Scene {
        WindowGroup("合并 PDF") {
            ContentView()
                .frame(minWidth: 680, minHeight: 500)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("添加 PDF…", action: NotificationCenter.default.postAddFiles)
                    .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}

extension NotificationCenter {
    func postAddFiles() {
        post(name: .addFilesRequested, object: nil)
    }
}

extension Notification.Name {
    static let addFilesRequested = Notification.Name("addFilesRequested")
}

struct ContentView: View {
    @StateObject private var store = PDFMergeStore()
    @State private var isOrderSheetPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fileList
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("合并 PDF")
                        .font(.system(size: 28, weight: .bold))
                    Text("文件仅在本机处理，不会上传。拖入文件即可开始。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: store.addFilesWithPanel) {
                        Label("添加 PDF", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isMerging)
                    Button(action: store.addFolderWithPanel) {
                        Label("添加文件夹", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isMerging)
                }
            }
            HStack(spacing: 18) {
                Label("\(store.items.count) 个文件", systemImage: "doc.on.doc")
                Label("\(store.totalPages) 页", systemImage: "doc.text")
                if store.isMerging {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在合并，请稍候…")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var fileList: some View {
        Group {
            if store.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: store.isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                        .font(.system(size: 44))
                        .foregroundStyle(store.isDropTargeted ? Color.accentColor : .secondary)
                    Text("将 PDF 文件拖到这里")
                        .font(.title3.weight(.medium))
                    Text("也可以点击右上角“添加 PDF”或“添加文件夹”")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            } else {
                List {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Image(systemName: "doc.richtext")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.fileName)
                                    .lineLimit(1)
                                Text(item.url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(item.pageCount) 页")
                                .foregroundStyle(.secondary)
                            Button {
                                store.remove(item)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除此文件")
                            .disabled(store.isMerging)
                        }
                        .padding(.vertical, 5)
                    }
                    .onDelete(perform: store.remove)
                    .onMove(perform: store.move)
                }
                .listStyle(.inset)
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

    private var footer: some View {
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
            if !store.items.isEmpty {
                Button("粘贴顺序") {
                    isOrderSheetPresented = true
                }
                .disabled(store.isMerging)
                .help("粘贴每行一个文件名，按文字顺序排列")
            }
            if !store.items.isEmpty {
                Button("清空", action: store.clear)
                    .disabled(store.isMerging)
            }
            Button(action: store.mergeWithSavePanel) {
                if store.isMerging {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("合并 PDF")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isMerging || store.items.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }
}

struct OrderTextView: View {
    @ObservedObject var store: PDFMergeStore
    @Binding var isPresented: Bool
    @State private var text = ""
    @FocusState private var isTextEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("按粘贴文字排序")
                .font(.title2.weight(.semibold))
                Text("可以直接粘贴自然语言，例如“按照申请表、教务处、竞赛证书合并”。应用会识别文件名中的关键词并按出现顺序排列；未提到的文件会从当前列表移除，但不会删除原文件。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .focused($isTextEditorFocused)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            HStack {
                Text("当前 (store.items.count) 个文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    isPresented = false
                }
                Button("按此顺序排列") {
                    store.reorderFromText(text)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isMerging)
            }
        }
        .padding(24)
        .frame(width: 560, height: 390)
        .onAppear {
            isTextEditorFocused = true
        }
    }
}
