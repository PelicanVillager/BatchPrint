import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PrintPresetStore
    @StateObject private var runner = PrintJobRunner()
    @StateObject private var printerMonitor = PrinterMonitor()

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
    @State private var showPrinterHealthAlert = false
    @State private var printerHealthMessage = ""
    @State private var printerFixMessage: String?
    @State private var summaryAdvice: String?

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

    /// 工具栏上那个红色提醒按钮的文案：队列的问题谈队列，设备的问题谈设备。
    private var printerAlertTitle: String {
        guard let health = printerMonitor.health else { return "打印机状态异常" }
        if health.isStopped || !health.isAcceptingJobs { return "队列已停用，点此恢复" }
        if health.deviceReachable == false { return "打印机不在线，点此重试" }
        return "打印机不可用"
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
        .environmentObject(printerMonitor)
        .onAppear {
            refreshPrinterList()
        }
        .task(id: store.preset.printerName) {
            // 界面出现时、以及切换目标打印机时，都自动体检一次。
            await printerMonitor.refresh(printerName: store.preset.printerName)
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
        .alert("打印前检查：打印机现在不能打", isPresented: $showPrinterHealthAlert) {
            Button("恢复队列并继续打印") {
                Task { await resumeQueueAndStart() }
            }
            Button("仍然继续提交") {
                startPrint(skippingMissing: pendingSkipMissing, forcingUnhealthyQueue: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(printerHealthMessage)
        }
        .alert("恢复队列失败", isPresented: Binding(
            get: { printerFixMessage != nil },
            set: { if !$0 { printerFixMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(printerFixMessage ?? "未知错误")
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

            if printerMonitor.health?.needsAttention == true {
                Button {
                    Task { await handlePrinterAlert() }
                } label: {
                    Label(printerAlertTitle, systemImage: "exclamationmark.triangle.fill")
                }
                .tint(.red)
                .help("目标打印队列当前不能打印，点一下试着让它重新工作")
            }

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
        if let summaryAdvice {
            lines.append("\n" + summaryAdvice)
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

    private func startPrint(skippingMissing: Bool, forcingUnhealthyQueue: Bool = false) {
        Task { @MainActor in
            await performStartPrint(
                skippingMissing: skippingMissing,
                forcingUnhealthyQueue: forcingUnhealthyQueue
            )
        }
    }

    private func performStartPrint(skippingMissing: Bool, forcingUnhealthyQueue: Bool) async {
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
        pendingSkipMissing = skippingMissing

        // 打印前体检：队列被停用、打印机掉线这类问题先摊开说，别让作业悄悄堆在队列里。
        if !forcingUnhealthyQueue {
            let health = await printerMonitor.refresh(printerName: store.preset.printerName)
            if health.needsAttention {
                printerHealthMessage = healthAlertMessage(health)
                showPrinterHealthAlert = true
                return
            }
            runner.preflightNotes = preflightNotes(for: health)
        } else {
            runner.preflightNotes = ["打印前检查：用户选择忽略队列异常，直接提交作业。"]
        }

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

        let result = await runner.run(
            items: availableQueue,
            preset: store.preset
        ) { id, status in
            updateStatus(for: id, status: status)
        }

        // 打完之后再看一眼：如果是队列被停用拖累的失败，直接在结果里给出下一步。
        let healthAfterRun = await printerMonitor.refresh(printerName: store.preset.printerName)
        summaryAdvice = adviceAfterRun(summary: result, health: healthAfterRun)

        isPrinting = false
        showProgressPanel = false
        summary = result
        showSummaryAlert = true
    }

    /// 恢复队列，成功后直接接着打印。
    private func resumeQueueAndStart() async {
        let outcome = await printerMonitor.resume(printerName: store.preset.printerName)
        if outcome.succeeded {
            startPrint(skippingMissing: pendingSkipMissing)
        } else {
            printerFixMessage = outcome.message
        }
    }

    /// 工具栏红按钮：队列类问题就地恢复，设备类问题重新探一次。
    private func handlePrinterAlert() async {
        let health = printerMonitor.health
        if health?.isStopped == true || health?.isAcceptingJobs == false {
            await printerMonitor.resume(printerName: store.preset.printerName)
        } else {
            await printerMonitor.refresh(printerName: store.preset.printerName)
        }
    }

    private func healthAlertMessage(_ health: PrinterHealth) -> String {
        var lines: [String] = ["打印机「\(health.printerName)」\(health.headline)。"]
        if health.isStopped, !health.stateMessage.isEmpty {
            lines.append("系统给出的原因：\(health.stateMessage)")
        }
        if !health.suggestions.isEmpty {
            lines.append("")
            lines.append(contentsOf: health.suggestions)
        }
        lines.append("")
        lines.append("现在提交的话，作业只会排在队列里，不会出纸。")
        return lines.joined(separator: "\n")
    }

    private func preflightNotes(for health: PrinterHealth) -> [String] {
        var notes = ["打印前检查：\(health.printerName) — \(health.headline)"]
        if health.pendingJobs > 0 {
            notes.append("打印前检查：队列中已有 \(health.pendingJobs) 个未完成作业。")
        }
        return notes
    }

    private func adviceAfterRun(summary: PrintSummary, health: PrinterHealth) -> String? {
        guard !summary.failed.isEmpty || summary.notExecuted > 0 else { return nil }
        guard health.needsAttention else { return nil }
        return "提示：\(health.headline)。\(health.suggestions.first ?? "") 处理后可重新提交失败的作业。"
    }

    private func updateStatus(for id: UUID, status: PrintJobStatus) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].status = status
    }
}
