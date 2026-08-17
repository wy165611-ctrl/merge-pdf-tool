import SwiftUI

@main
struct PDFMergeApp: App {
    var body: some Scene {
        WindowGroup("合并 PDF") {
            MainView()
                .frame(minWidth: 1040, minHeight: 680)
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
