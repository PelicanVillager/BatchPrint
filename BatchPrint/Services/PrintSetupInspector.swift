import AppKit
import ApplicationServices

/// 提交打印前对参数做一次自检：把最终会交给 CUPS 的选项取出来，并给出风险提示。
///
/// `PMPrintSettingsToOptionsWithPrinterAndPageFormat` 返回的就是打印系统真正下发的
/// CUPS 选项串，里面能看到 `sides=two-sided-long-edge` 这样的双面参数，
/// 因此运行日志里可以直接确认“双面到底有没有生效”。
struct PrintSetupReport {
    var printerName: String
    var cupsOptions: String
    var summary: String
    var warnings: [String]
}

enum PrintSetupInspector {
    static func report(for printInfo: NSPrintInfo, preset: PrintPreset) -> PrintSetupReport {
        let options = cupsOptions(for: printInfo) ?? ""
        let name = printInfo.printer.name.isEmpty ? "系统默认打印机" : printInfo.printer.name
        var warnings: [String] = []
        let capabilities = PrinterCapabilities.capabilities(for: printInfo)

        if preset.duplex != .none, !capabilities.supportsDuplex(preset.duplex) {
            warnings.append("打印机“\(name)”的驱动未声明“\(preset.duplex.title)”能力，双面打印可能无效。")
        }
        if preset.colorMode == .color, !capabilities.isColorDevice {
            warnings.append("打印机“\(name)”是黑白设备，彩色文档会按黑白输出。")
        } else if preset.colorMode == .color, capabilities.colorColorModel == nil {
            warnings.append("打印机“\(name)”的驱动未提供彩色模式选项，可能只能黑白输出。")
        }
        if preset.colorMode != .color, capabilities.isColorDevice, capabilities.monochromeColorModel == nil {
            warnings.append("打印机“\(name)”的驱动未提供黑白模式选项，可能仍按彩色耗材输出。")
        }
        if options.isEmpty {
            warnings.append("无法从打印系统读取参数，请检查打印机是否在线。")
        }

        return PrintSetupReport(
            printerName: name,
            cupsOptions: options,
            summary: summary(from: options),
            warnings: warnings
        )
    }

    static func cupsOptions(for printInfo: NSPrintInfo) -> String? {
        guard let printer = PrinterCapabilities.currentPrinter(of: printInfo) else { return nil }

        var options: UnsafeMutablePointer<CChar>?
        let status = PMPrintSettingsToOptionsWithPrinterAndPageFormat(
            OpaquePointer(printInfo.pmPrintSettings()),
            printer,
            OpaquePointer(printInfo.pmPageFormat()),
            &options
        )
        guard status == noErr, let options else { return nil }
        defer { free(options) }
        return String(cString: options)
    }

    /// 只挑出与打印效果有关的关键选项，避免日志里塞满内部键。
    static func summary(from options: String) -> String {
        let interesting = [
            "sides=", "Duplex=", "ColorModel=", "media=", "copies=",
            "collate=", "fit-to-page", "InputSlot=", "print-quality"
        ]
        let picked = options
            .split(separator: " ")
            .map(String.init)
            .filter { piece in interesting.contains { piece.hasPrefix($0) } }
        return picked.isEmpty ? "（无显式参数，使用打印机默认值）" : picked.joined(separator: " ")
    }
}
