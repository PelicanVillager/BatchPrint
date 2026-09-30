import AppKit
import ApplicationServices

/// 打印机自身声明支持哪些能力。
///
/// AppKit 没有任何查询 PPD 选项的接口，只能先用 PrintCore 取到 PPD
/// （`PMPrinterCopyDescriptionURL` 给出的临时文件），再解析我们关心的选项。
struct PrinterCapabilities {
    /// `*Duplex` 选项的取值，例如 `None`、`DuplexNoTumble`、`DuplexTumble`。
    var duplexValues: Set<String> = []
    /// `*ColorModel` 选项的取值，例如 `Gray`、`RGB`。
    var colorModelValues: [String] = []
    /// PPD 里的 `*ColorDevice`，用于区分黑白机与彩色机。
    var isColorDevice = false

    var supportsDuplex: Bool { !duplexValues.isEmpty }

    func supportsDuplex(_ mode: DuplexMode) -> Bool {
        switch mode {
        case .none:
            return true
        case .longEdge:
            return duplexValues.contains("DuplexNoTumble")
        case .shortEdge:
            return duplexValues.contains("DuplexTumble")
        }
    }

    /// 黑白、灰度打印要用的驱动选项值，取不到就返回 nil。
    var monochromeColorModel: String? {
        if colorModelValues.contains("Gray") { return "Gray" }
        if colorModelValues.contains("Grayscale") { return "Grayscale" }
        if colorModelValues.contains("Mono") { return "Mono" }
        return nil
    }

    /// 彩色打印要用的驱动选项值，取不到就返回 nil。
    var colorColorModel: String? {
        if colorModelValues.contains("RGB") { return "RGB" }
        if colorModelValues.contains("CMYK") { return "CMYK" }
        if colorModelValues.contains("Color") { return "Color" }
        return nil
    }

    private static var cache: [String: PrinterCapabilities] = [:]

    static func capabilities(for printInfo: NSPrintInfo) -> PrinterCapabilities {
        guard let rawPrinter = currentPrinter(of: printInfo) else { return PrinterCapabilities() }

        let name = PMPrinterGetName(rawPrinter).map { $0.takeUnretainedValue() as String } ?? ""
        if let cached = cache[name] { return cached }

        var capabilities = PrinterCapabilities()
        if let text = ppdText(of: rawPrinter) {
            capabilities = parse(ppd: text)
        }
        cache[name] = capabilities
        return capabilities
    }

    static func currentPrinter(of printInfo: NSPrintInfo) -> PMPrinter? {
        var printer: PMPrinter?
        let session = printInfo.pmPrintSession()
        guard PMSessionGetCurrentPrinter(OpaquePointer(session), &printer) == noErr else { return nil }
        return printer
    }

    private static func ppdText(of printer: PMPrinter) -> String? {
        var url: Unmanaged<CFURL>?
        guard PMPrinterCopyDescriptionURL(printer, kPMPPDDescriptionType as CFString, &url) == noErr,
              let url = url?.takeRetainedValue() as URL?
        else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func parse(ppd text: String) -> PrinterCapabilities {
        var capabilities = PrinterCapabilities()
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*Duplex ") {
                if let value = optionValue(in: line, keyword: "*Duplex") {
                    capabilities.duplexValues.insert(value)
                }
            } else if line.hasPrefix("*ColorModel ") {
                if let value = optionValue(in: line, keyword: "*ColorModel"),
                   !capabilities.colorModelValues.contains(value)
                {
                    capabilities.colorModelValues.append(value)
                }
            } else if line.hasPrefix("*ColorDevice:") {
                let value = line.dropFirst("*ColorDevice:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                capabilities.isColorDevice = value.hasPrefix("true")
            }
        }
        return capabilities
    }

    /// 从 `*Duplex DuplexNoTumble/长边（纵向）: "…"` 这类行里取出选项值。
    private static func optionValue(in line: String, keyword: String) -> String? {
        let rest = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let value = rest.prefix { $0 != ":" && $0 != "/" }
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
