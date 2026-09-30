import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PrintPresetStore
    @StateObject private var runner = PrintJobRunner()

    @State private var folderURL: URL?
    @State private var files: [PrintFileItem] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var printerNames: [String] = []
    @State private var scannerErrorMessage: String?

    @State private var missingFiles: [MissingFile] = []
    @State private var showMissingAlert = false
    @State private var showSummaryAlert = false
    @State private var summary: PrintSummary?
    @State private var showProgressPanel = false
    @State private var isPrinting = false
    @State private var isPreviewing = false
    @State private var previewErrorMessage: String?
    @State private var showRoundsAlert = false
    @State private var roundsConfirmed = false
    @State private var pendingSkipMissing = false

    private var selectedFiles: [PrintFileItem] {
        files.filter(\.isSelected)
    }

    private var missingIDs: Set<UUID> {
        Set(FileAvailabilityChecker.check(files).map(\.item.id))
    }

    private var selectedWordPreviewItem: PrintFileItem? {
        let selected = selectedFiles
        guard selected.count == 1, let item = selected.first else { return nil }
        return item.type == .doc || item.type == .docx ? item : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            HSplitView {
                FileListView(
                    files: $files,
                    selectedIDs: $selectedIDs,
                    missingIDs: missingIDs,
                    onMove: moveFiles
                )
                .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 0) {
                    PrintSettingsView(printerNames: printerNames)
                    Divider()
                    logView
                }
                .frame(minWidth: 360, idealWidth: 440, maxWidth: 560, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            refreshPrinterList()
        }
        .onReceive(NotificationCenter.default.publisher(for: .batchPrintSelectFolder)) { _ in
            chooseFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .batchPrintRefreshPrinters)) { _ in
            refreshPrinterList()
        }
        .alert("发现缺失文件", isPresented: $showMissingAlert) {
            Button("跳过缺失文件并继续") {
                startPrint(skippingMissing: true)
            }
            Button("取消打印", role: .cancel) {}
        } message: {
            Text(missingAlertMessage)
        }
        .alert("确认批次打印", isPresented: $showRoundsAlert) {
            Button("开始打印") {
                roundsConfirmed = true
                startPrint(skippingMissing: pendingSkipMissing)
            }
            Button("取消", role: .cancel) {
                roundsConfirmed = false
            }
        } message: {
            Text(roundsAlertMessage)
        }
        .alert("扫描失败", isPresented: Binding(
            get: { scannerErrorMessage != nil },
            set: { if !$0 { scannerErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(scannerErrorMessage ?? "未知错误")
        }
        .alert("打印结果", isPresented: $showSummaryAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(summaryMessage)
        }
        .alert("转换预览失败", isPresented: Binding(
            get: { previewErrorMessage != nil },
            set: { if !$0 { previewErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(previewErrorMessage ?? "未知错误")
        }
        .sheet(isPresented: $showProgressPanel) {
            ProgressPanel(
                runner: runner,
                onStop: {
                    runner.cancel()
                },
                onClose: {
                    showProgressPanel = false
                }
            )
            .frame(width: 620, height: 460)
        }
    }

    private var toolbar: some View {
        HStack {
            Button {
                chooseFolder()
            } label: {
                Label("选择文件夹", systemImage: "folder")
            }

            Button {
                refreshFolder()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(folderURL == nil)

            Divider()
                .frame(height: 20)

            Button {
                setAllSelected(true)
            } label: {
                Label("全选", systemImage: "checkmark.circle")
            }
            .disabled(files.isEmpty)

            Button {
                setAllSelected(false)
            } label: {
                Label("全不选", systemImage: "circle")
            }
            .disabled(files.isEmpty)

            Button {
                invertSelection()
            } label: {
                Label("反选", systemImage: "circle.lefthalf.filled")
            }
            .disabled(files.isEmpty)

            Spacer()

            if let folderURL {
                Text(folderURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                previewSelectedWordDocument()
            } label: {
                if isPreviewing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("转换预览", systemImage: "eye")
                }
            }
            .disabled(selectedWordPreviewItem == nil || isPrinting || runner.progress.isRunning || isPreviewing)

            if isPrinting {
                Button(role: .destructive) {
                    runner.cancel()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
            } else {
                Button {
                    startPrint(skippingMissing: false)
                } label: {
                    Label("开始打印", systemImage: "printer.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFiles.isEmpty || runner.progress.isRunning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("运行日志")
                    .font(.headline)
                Spacer()
                Button("清空") {
                    runner.logLines.removeAll()
                }
                .font(.caption)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(runner.logLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
    }

    private var missingAlertMessage: String {
        let names = missingFiles.map(\.item.fileName)
        return "以下文件已不存在或无法访问：\n\n" + names.joined(separator: "\n")
    }

    private var roundsAlertMessage: String {
        let rounds = store.preset.normalizedRounds
        let count = selectedFiles.count
        return "将把勾选的 \(count) 个文件整套重复打印 \(rounds) 批，合计 \(count * rounds) 个作业。\n\n"
            + "每一批都按列表顺序打印一遍，打完一批再开始下一批。"
    }

    private var summaryMessage: String {
        guard let summary else { return "" }
        var lines = [
            "作业总数：\(summary.total)",
            "成功：\(summary.succeeded)",
            "失败：\(summary.failed.count)"
        ]
        if summary.rounds > 1 {
            lines.append("批次数：\(summary.rounds)")
        }
        if summary.notExecuted > 0 {
            lines.append("未执行：\(summary.notExecuted)")
        }
        if !summary.failed.isEmpty {
            lines.append("\n失败详情：")
            lines.append(contentsOf: summary.failed)
        }
        return lines.joined(separator: "\n")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择源文件夹"

        if panel.runModal() == .OK, let url = panel.url {
            folderURL = url
            refreshFolder()
        }
    }

    private func refreshFolder() {
        guard let folderURL else { return }
        do {
            files = try FolderScanner().scan(
                folder: folderURL,
                preserving: files,
                enabledTypes: store.preset.enabledTypes
            )
            scannerErrorMessage = nil
        } catch {
            scannerErrorMessage = error.localizedDescription
        }
    }

    private func refreshPrinterList() {
        printerNames = PrinterService.availablePrinterNames()
        if store.preset.printerName == nil, let defaultName = PrinterService.defaultPrinterName() {
            store.preset.printerName = defaultName
        }
    }

    private func setAllSelected(_ selected: Bool) {
        for index in files.indices {
            files[index].isSelected = selected
        }
    }

    private func invertSelection() {
        for index in files.indices {
            files[index].isSelected.toggle()
        }
    }

    private func moveFiles(from source: IndexSet, to destination: Int) {
        files.move(fromOffsets: source, toOffset: destination)
    }

    private func previewSelectedWordDocument() {
        guard let item = selectedWordPreviewItem, !isPreviewing else { return }

        isPreviewing = true

        Task { @MainActor in
            do {
                let convertedURL = try await OfficePDFConverter.convertToPDF(sourceURL: item.url)
                let previewURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BatchPrint-Preview-\(UUID().uuidString)")
                    .appendingPathExtension("pdf")
                try FileManager.default.moveItem(at: convertedURL, to: previewURL)
                NSWorkspace.shared.open(previewURL)
            } catch {
                previewErrorMessage = error.localizedDescription
            }

            isPreviewing = false
        }
    }

    private func startPrint(skippingMissing: Bool) {
        let queue = files.filter(\.isSelected)
        let missing = FileAvailabilityChecker.check(queue)

        if !missing.isEmpty && !skippingMissing {
            missingFiles = missing
            showMissingAlert = true
            return
        }

        // 批次打印会连着出很多纸，先确认一次，避免误操作。
        if store.preset.normalizedRounds > 1, !roundsConfirmed {
            pendingSkipMissing = skippingMissing
            showRoundsAlert = true
            return
        }
        roundsConfirmed = false

        let missingIDs = Set(missing.map(\.item.id))
        for missingItem in missing {
            updateStatus(for: missingItem.item.id, status: .skipped("文件缺失"))
        }

        let availableQueue = queue.filter { !missingIDs.contains($0.id) }
        guard !availableQueue.isEmpty else {
            summary = PrintSummary(
                total: queue.count * store.preset.normalizedRounds,
                rounds: store.preset.normalizedRounds,
                succeeded: 0,
                failed: [],
                skipped: missing.map(\.item.fileName),
                notExecuted: queue.count * store.preset.normalizedRounds
            )
            showSummaryAlert = true
            return
        }

        isPrinting = true
        showProgressPanel = true

        Task {
            let result = await runner.run(
                items: availableQueue,
                preset: store.preset
            ) { id, status in
                updateStatus(for: id, status: status)
            }

            isPrinting = false
            showProgressPanel = false
            summary = result
            showSummaryAlert = true
        }
    }

    private func updateStatus(for id: UUID, status: PrintJobStatus) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].status = status
    }
}
