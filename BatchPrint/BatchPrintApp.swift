import SwiftUI

@main
struct BatchPrintApp: App {
    @StateObject private var store = PrintPresetStore()
    @StateObject private var printerMonitor = PrinterMonitor()

    init() {
        // 带上 --print-check / --list-printers 时不启动界面，直接做完自检就退出。
        if let exitCode = PrintCheckCommand.exitCodeIfRequested() {
            exit(exitCode)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(printerMonitor)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择文件夹…") {
                    NotificationCenter.default.post(name: .batchPrintSelectFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let batchPrintSelectFolder = Notification.Name("BatchPrintSelectFolder")
}
