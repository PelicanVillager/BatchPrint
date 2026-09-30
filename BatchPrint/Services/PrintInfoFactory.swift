import AppKit

/// 把界面上的打印参数翻译成一份可以直接交给打印系统的 `NSPrintInfo`。
///
/// 这里有一个曾经踩过的坑：`NSPrintInfo` 的 `dictionary` 只认识官方声明的那几个键
/// （纸型、份数、方向、缩放……），其余键会被静默忽略——所以老代码里写的
/// `NSPrintDuplex` / `NSPrintColorMode` 其实从来没有生效过，双面打印自然打不出来。
/// 驱动级参数（双面、色彩）必须写进 `printSettings`：键名用下划线代替点号，
/// 即 `com.apple.print.PrintSettings.PMDuplexing` → `com_apple_print_PrintSettings_PMDuplexing`。
enum PrintInfoFactory {
    /// `kPMDuplexingKey` 在 `printSettings` 里的键名写法。
    static let duplexSettingsKey = "com_apple_print_PrintSettings_PMDuplexing"
    /// 驱动（PPD）里的彩色模式选项名。
    static let colorModelSettingsKey = "ColorModel"

    /// `PMDuplexMode` 的取值：单面 1，长边翻转 2，短边翻转 3。
    static func duplexValue(for mode: DuplexMode) -> Int {
        switch mode {
        case .none: return 1
        case .longEdge: return 2
        case .shortEdge: return 3
        }
    }

    static func make(preset: PrintPreset) throws -> NSPrintInfo {
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else {
            throw PrintRunnerError.missingPrinter(preset.printerName ?? "默认打印机")
        }

        if let printerName = preset.printerName, let printer = NSPrinter(name: printerName) {
            printInfo.printer = printer
        }

        printInfo.jobDisposition = .spool
        printInfo.orientation = preset.orientation == .portrait ? .portrait : .landscape
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .fit
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        printInfo.paperSize = paperSize(for: preset)

        let attributes = printInfo.dictionary()
        attributes[NSPrintInfo.AttributeKey.copies] = NSNumber(value: max(1, preset.copies))
        // 始终要求按份装订：多页文档打印多份时，出来的应该是“一份一份”，不是“一页一页”。
        attributes[NSPrintInfo.AttributeKey.mustCollate] = NSNumber(value: true)

        if preset.scaling == .percentage {
            attributes[NSPrintInfo.AttributeKey.scalingFactor] = NSNumber(value: preset.scalePercentage / 100.0)
        }

        // 双面：PrintCore 的键才会被换算成 CUPS 的 sides=two-sided-…。写别的键等于没写。
        printInfo.printSettings[duplexSettingsKey] = NSNumber(value: duplexValue(for: preset.duplex))

        // 色彩：驱动一般用 ColorModel=Gray/RGB 表示黑白与彩色，先看打印机支不支持。
        let capabilities = PrinterCapabilities.capabilities(for: printInfo)
        let colorModel: String?
        switch preset.colorMode {
        case .color:
            colorModel = capabilities.colorColorModel
        case .monochrome, .grayscale:
            colorModel = capabilities.monochromeColorModel
        }
        if let colorModel {
            printInfo.printSettings[colorModelSettingsKey] = colorModel
        }

        return printInfo
    }

    private static func paperSize(for preset: PrintPreset) -> NSSize {
        switch preset.paperSize {
        case .a4:
            return NSSize(width: 595.28, height: 841.89)
        case .letter:
            return NSSize(width: 612, height: 792)
        case .a3:
            return NSSize(width: 841.89, height: 1190.55)
        case .legal:
            return NSSize(width: 612, height: 1008)
        case .b5:
            return NSSize(width: 498.9, height: 708.66)
        case .custom:
            let width = max(100, preset.customPaperWidthMM) * 72.0 / 25.4
            let height = max(100, preset.customPaperHeightMM) * 72.0 / 25.4
            return NSSize(width: width, height: height)
        }
    }
}
