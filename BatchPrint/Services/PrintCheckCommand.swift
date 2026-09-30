import AppKit
import Foundation

/// 命令行自检：不开界面，直接打印某组参数最终会下发给打印系统的内容。
///
/// 用法（`: ` 后面是示例）：
///   `BatchPrint --print-check`
///   `BatchPrint --print-check --printer "HP LaserJet M403dn" --duplex longEdge --copies 2`
///   `BatchPrint --list-printers`
enum PrintCheckCommand {
    /// 如果命令行里带了自检参数，就执行并返回退出码；否则返回 nil，正常启动界面。
    static func exitCodeIfRequested() -> Int32? {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--list-printers") {
            listPrinters()
            return 0
        }

        guard arguments.contains("--print-check") else { return nil }

        var preset = PrintPreset()
        preset.duplex = .none

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil

            switch argument {
            case "--printer":
                preset.printerName = value
                index += 2
                continue
            case "--duplex":
                guard let value, let mode = duplexMode(from: value) else {
                    print("参数 --duplex 只接受 none / longEdge / shortEdge")
                    return 2
                }
                preset.duplex = mode
            case "--copies":
                guard let value, let copies = Int(value), copies > 0 else {
                    print("参数 --copies 需要一个正整数")
                    return 2
                }
                preset.copies = copies
            default:
                break
            }

            index += 1
        }

        return check(preset: preset)
    }

    private static func duplexMode(from value: String) -> DuplexMode? {
        switch value.lowercased() {
        case "none": return DuplexMode.none
        case "longedge", "long-edge", "longedgebinding": return .longEdge
        case "shortedge", "short-edge", "shortedgebinding": return .shortEdge
        default: return nil
        }
    }

    private static func listPrinters() {
        print("系统默认打印机：\(PrinterService.defaultPrinterName() ?? "未设置")")
        for name in PrinterService.availablePrinterNames() {
            print("· \(name)")
        }
    }

    private static func check(preset: PrintPreset) -> Int32 {
        do {
            let printInfo = try PrintInfoFactory.make(preset: preset)
            let report = PrintSetupInspector.report(for: printInfo, preset: preset)

            print("目标打印机：\(report.printerName)")
            print("双面设置：\(preset.duplex.title)（PMDuplexing=\(PrintInfoFactory.duplexValue(for: preset.duplex))）")
            print("份数：\(preset.copies)")
            print("关键参数：\(report.summary)")
            print("完整 CUPS 选项：\(report.cupsOptions)")
            for warning in report.warnings {
                print("注意：\(warning)")
            }
            return 0
        } catch {
            print("自检失败：\(error.localizedDescription)")
            return 1
        }
    }
}
