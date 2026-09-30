import AppKit
import Foundation
import PDFKit

struct PrintSummary {
    /// 计划打印的作业总数 = 文件数 × 批次数。
    var total: Int
    var rounds: Int
    var succeeded: Int
    var failed: [String]
    var skipped: [String]
    /// 因为中途停止而没有提交的作业数。
    var notExecuted: Int
}

struct PrintProgress {
    var isRunning = false
    /// 已处理（成功或失败）的作业数，跨批次累计。
    var completedJobs = 0
    /// 计划作业总数 = 文件数 × 批次数。
    var total = 0
    var currentRound = 1
    var rounds = 1
    /// 当前批内正在打印第几个文件。
    var currentRoundIndex = 0
    /// 当前批的文件数。
    var currentRoundTotal = 0
    var currentFileName = ""
    var fractionCompleted: Double {
        guard total > 0 else { return 0 }
        return Double(completedJobs) / Double(total)
    }
}

enum PrintRunnerError: LocalizedError {
    case unsupportedFile(String)
    case missingPrinter(String)
    case cannotOpenFile(String)
    case invalidPageRange(String)
    case externalPrintFallback(String)
    case printOperationFailed(String)
    case officeConversionFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let name):
            return "不支持的文件类型：\(name)"
        case .missingPrinter(let name):
            return "找不到打印机：\(name)"
        case .cannotOpenFile(let name):
            return "无法打开文件：\(name)"
        case .invalidPageRange(let value):
            return "页面范围格式不正确：\(value)"
        case .externalPrintFallback(let name):
            return "已打开 \(name)，但该应用不支持自动打印，请手动确认。"
        case .printOperationFailed(let name):
            return "系统未能完成打印作业：\(name)"
        case .officeConversionFailed(let message):
            return "Word 转 PDF 失败：\(message)"
        case .cancelled:
            return "打印已停止"
        }
    }
}

@MainActor
final class PrintJobRunner: ObservableObject {
    @Published var progress = PrintProgress()
    @Published var logLines: [String] = []

    private var cancelled = false
    private var onStatusChange: ((UUID, PrintJobStatus) -> Void)?
    /// 本次运行中已经转换好的 Word → PDF，批次之间复用，避免每一批都重新转换。
    private var convertedPDFs: [URL: URL] = [:]

    func cancel() {
        cancelled = true
        appendLog("收到停止请求，正在结束后续任务…")
    }

    func reset() {
        cancelled = false
        progress = PrintProgress()
        logLines.removeAll()
        removeConvertedPDFs()
    }

    /// 清理转换出来的临时 PDF 及其临时目录。
    private func removeConvertedPDFs() {
        for pdfURL in convertedPDFs.values {
            let directory = pdfURL.deletingLastPathComponent()
            if directory.lastPathComponent.hasPrefix("BatchPrint-") {
                try? FileManager.default.removeItem(at: directory)
            } else {
                try? FileManager.default.removeItem(at: pdfURL)
            }
        }
        convertedPDFs.removeAll()
    }

    func run(
        items: [PrintFileItem],
        preset: PrintPreset,
        onStatusChange: @escaping (UUID, PrintJobStatus) -> Void
    ) async -> PrintSummary {
        reset()
        self.onStatusChange = onStatusChange
        defer { removeConvertedPDFs() }

        let queue = items.filter(\.isSelected)
        let rounds = preset.normalizedRounds
        let totalJobs = queue.count * rounds

        progress.total = totalJobs
        progress.rounds = rounds
        progress.currentRoundTotal = queue.count
        progress.isRunning = true

        var succeeded = 0
        var failures: [String] = []
        var skipped: [String] = []
        var completed = 0

        if rounds > 1 {
            appendLog("打印队列共 \(queue.count) 个文件 × \(rounds) 批，合计 \(totalJobs) 个作业。")
        } else {
            appendLog("打印队列共 \(queue.count) 个文件。")
        }
        logPrintSetup(preset: preset)

        // 外层是批次：每一批都按列表顺序把选中的文件各打印一遍，
        // 打完一批才进入下一批，避免“同一个文件连着打好几份”。
        for round in 1...rounds {
            if cancelled { break }

            progress.currentRound = round
            if rounds > 1 {
                appendLog("—— 第 \(round)/\(rounds) 批开始 ——")
            }

            for (index, item) in queue.enumerated() {
                if cancelled {
                    for pending in queue[index...] {
                        skipped.append(pending.fileName)
                        updateStatus(for: pending.id, status: .skipped("用户停止"))
                    }
                    appendLog("已停止：本批剩余 \(queue.count - index) 个文件未打印。")
                    break
                }

                progress.currentRoundIndex = index + 1
                progress.currentFileName = item.fileName
                updateStatus(for: item.id, status: .printing)
                if rounds > 1 {
                    appendLog("第 \(round)/\(rounds) 批 · 第 \(index + 1)/\(queue.count) 个文件：\(item.fileName)")
                } else {
                    appendLog("正在打印第 \(index + 1)/\(queue.count) 个文件：\(item.fileName)")
                }

                do {
                    try await printFile(at: item.url, preset: preset)
                    succeeded += 1
                    completed += 1
                    updateStatus(for: item.id, status: .success)
                    appendLog("成功：\(item.fileName)")
                } catch {
                    let message = error.localizedDescription
                    let prefix = rounds > 1 ? "第 \(round) 批 · " : ""
                    failures.append("\(prefix)\(item.fileName)：\(message)")
                    completed += 1
                    updateStatus(for: item.id, status: .failed(message))
                    appendLog("失败：\(item.fileName) — \(message)")
                }

                progress.completedJobs = completed
                await Task.yield()
            }

            if cancelled { break }

            if rounds > 1 {
                appendLog("—— 第 \(round)/\(rounds) 批完成 ——")
            }
            if round < rounds {
                await waitBetweenRounds(nextRound: round + 1, rounds: rounds, seconds: preset.normalizedRoundDelaySeconds)
            }
        }

        progress.isRunning = false
        progress.currentFileName = ""
        progress.currentRoundIndex = 0

        let summary = PrintSummary(
            total: totalJobs,
            rounds: rounds,
            succeeded: succeeded,
            failed: failures,
            skipped: skipped,
            notExecuted: max(0, totalJobs - completed)
        )
        appendLog("完成：成功 \(summary.succeeded) 个，失败 \(summary.failed.count) 个，未执行 \(summary.notExecuted) 个。")
        return summary
    }

    /// 批次之间的等待时间，期间随时可以点“停止后续任务”。
    private func waitBetweenRounds(nextRound: Int, rounds: Int, seconds: Double) async {
        guard seconds > 0 else { return }

        appendLog("等待 \(Int(seconds)) 秒后开始第 \(nextRound)/\(rounds) 批（可随时停止）。")
        var remaining = seconds
        while remaining > 0 {
            if cancelled {
                appendLog("已停止，不再开始下一批。")
                return
            }
            let slice = min(0.5, remaining)
            try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            remaining -= slice
        }
    }

    /// 打印前把最终下发的参数写进日志，方便确认双面、色彩等设置是否真的生效。
    private func logPrintSetup(preset: PrintPreset) {
        do {
            let printInfo = try PrintInfoFactory.make(preset: preset)
            let report = PrintSetupInspector.report(for: printInfo, preset: preset)
            appendLog("目标打印机：\(report.printerName)")
            appendLog("实际下发参数：\(report.summary)")
            for warning in report.warnings {
                appendLog("注意：\(warning)")
            }
        } catch {
            appendLog("打印参数自检失败：\(error.localizedDescription)")
        }
    }

    private func updateStatus(for id: UUID, status: PrintJobStatus) {
        onStatusChange?(id, status)
    }

    private func appendLog(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        logLines.append("[\(time)] \(message)")
    }

    private func printFile(at url: URL, preset: PrintPreset) async throws {
        let ext = url.pathExtension.lowercased()
        guard let type = SupportedFileType(rawValue: ext) else {
            throw PrintRunnerError.unsupportedFile(url.lastPathComponent)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PrintRunnerError.cannotOpenFile(url.lastPathComponent)
        }

        switch type {
        case .pdf:
            try printPDF(at: url, preset: preset)
        case .jpg, .png, .tiff:
            try printImage(at: url, preset: preset)
        case .doc, .docx:
            try await printWordDocument(at: url, preset: preset)
        }
    }

    private func printWordDocument(at url: URL, preset: PrintPreset) async throws {
        let appName = ExternalDocumentPrinter.applicationName(for: url)?.lowercased() ?? ""

        if ["microsoft word", "pages", "textedit"].contains(appName) {
            appendLog("使用 \(appName) 直接打印：\(url.lastPathComponent)")
            try ExternalDocumentPrinter.printDocument(at: url, preset: preset)
            return
        }

        let pdfURL: URL
        if let cached = convertedPDFs[url] {
            appendLog("复用本次运行已转换的 PDF：\(url.lastPathComponent)")
            pdfURL = cached
        } else {
            do {
                appendLog("正在将 Word 文档转换为 PDF：\(url.lastPathComponent)")
                let converted = try await OfficePDFConverter.convertToPDF(sourceURL: url)
                convertedPDFs[url] = converted
                pdfURL = converted
            } catch {
                appendLog("Word 转 PDF 失败，将退回 RTF 打印：\(error.localizedDescription)")
                try await WordDocumentPrinter.printDocument(at: url, preset: preset)
                return
            }
        }

        if let convertedDocument = PDFDocument(url: pdfURL) {
            appendLog("PDF 转换完成：\(convertedDocument.pageCount) 页，提取文字 \(convertedDocument.string?.count ?? 0) 字符")
        }

        appendLog("开始打印转换后的 PDF：\(url.lastPathComponent)")
        try printPDF(at: pdfURL, preset: preset)
    }

    private func printPDF(at url: URL, preset: PrintPreset) throws {
        guard let document = PDFDocument(url: url) else {
            throw PrintRunnerError.cannotOpenFile(url.lastPathComponent)
        }

        let pageIndices = try selectedPageIndices(for: document, pageRange: preset.pageRange)
        let documentToPrint: PDFDocument

        if pageIndices.count == document.pageCount {
            documentToPrint = document
        } else {
            let subset = PDFDocument()
            for index in pageIndices {
                if let page = document.page(at: index) {
                    subset.insert(page, at: subset.pageCount)
                }
            }
            guard subset.pageCount > 0 else {
                throw PrintRunnerError.invalidPageRange(preset.pageRange.customText)
            }
            documentToPrint = subset
        }

        let info = try PrintInfoFactory.make(preset: preset)
        guard let operation = documentToPrint.printOperation(
            for: info,
            scalingMode: preset.scaling == .fit ? .pageScaleDownToFit : .pageScaleNone,
            autoRotate: true
        ) else {
            throw PrintRunnerError.cannotOpenFile(url.lastPathComponent)
        }
        try runOperation(operation, fileName: url.lastPathComponent)
    }

    private func selectedPageIndices(for document: PDFDocument, pageRange: PageRange) throws -> [Int] {
        if pageRange.isAllPages {
            return Array(0..<document.pageCount)
        }

        let text = pageRange.customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw PrintRunnerError.invalidPageRange(text)
        }

        var indices = Set<Int>()
        for component in text.split(separator: ",") {
            let value = String(component).trimmingCharacters(in: .whitespaces)
            if value.contains("-") {
                let parts = value.split(separator: "-", maxSplits: 1)
                guard
                    parts.count == 2,
                    let start = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                    let end = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                    start >= 1,
                    end >= start
                else {
                    throw PrintRunnerError.invalidPageRange(value)
                }
                indices.formUnion((start...end).map { $0 - 1 })
            } else {
                guard let page = Int(value), page >= 1 else {
                    throw PrintRunnerError.invalidPageRange(value)
                }
                indices.insert(page - 1)
            }
        }

        let validIndices = indices.filter { $0 >= 0 && $0 < document.pageCount }.sorted()
        guard !validIndices.isEmpty else {
            throw PrintRunnerError.invalidPageRange(text)
        }
        return validIndices
    }

    private func printImage(at url: URL, preset: PrintPreset) throws {
        guard let image = NSImage(contentsOf: url) else {
            throw PrintRunnerError.cannotOpenFile(url.lastPathComponent)
        }

        let info = try PrintInfoFactory.make(preset: preset)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = preset.scaling == .fit ? .scaleProportionallyDown : .scaleAxesIndependently

        let operation = NSPrintOperation(view: imageView, printInfo: info)
        try runOperation(operation, fileName: url.lastPathComponent)
    }

    private func runOperation(_ operation: NSPrintOperation, fileName: String) throws {
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let success = operation.run()
        if !success {
            throw PrintRunnerError.printOperationFailed(fileName)
        }
    }
}
