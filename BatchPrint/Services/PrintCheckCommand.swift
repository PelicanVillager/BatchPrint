import AppKit
import Foundation

/// 命令行自检：不开界面，直接打印某组参数最终会下发给打印系统的内容。
///
/// 用法（`: ` 后面是示例）：
///   `BatchPrint --print-check`
///   `BatchPrint --print-check --printer "HP LaserJet M403dn" --duplex longEdge --copies 2`
///   `BatchPrint --list-printers`
///   `BatchPrint --printer-status`      查看目标队列是否被停用、打印机是否在线
///   `BatchPrint --resume-printer`      恢复被停用的队列（等同界面上的“恢复队列”）
///   `BatchPrint --enable-auto-retry`   把队列出错策略改成 retry-job，超时自动重试
///   `BatchPrint --self-test`           只跑解析规则自检，不访问真实打印机
enum PrintCheckCommand {
    /// 如果命令行里带了自检参数，就执行并返回退出码；否则返回 nil，正常启动界面。
    static func exitCodeIfRequested() -> Int32? {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--list-printers") {
            listPrinters()
            return 0
        }

        if arguments.contains("--self-test") {
            return selfTest()
        }

        if arguments.contains("--printer-status") {
            return printerStatus(printerName: printerNameArgument(in: arguments))
        }

        if arguments.contains("--resume-printer") {
            return resumePrinter(printerName: printerNameArgument(in: arguments))
        }

        if arguments.contains("--enable-auto-retry") {
            return enableAutoRetry(printerName: printerNameArgument(in: arguments))
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

    private static func printerNameArgument(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--printer"), index + 1 < arguments.count else {
            return nil
        }
        let value = arguments[index + 1]
        return value.isEmpty ? nil : value
    }

    private static func listPrinters() {
        print("系统默认打印机：\(PrinterService.defaultPrinterName() ?? "未设置")")
        for name in PrinterService.availablePrinterNames() {
            print("· \(name)")
        }
    }

    /// 纯逻辑自检：验证状态解析规则，不访问真实打印机。
    private static func selfTest() -> Int32 {
        let failures = PrinterHealthService.selfTestFailures()
        guard failures.isEmpty else {
            for failure in failures {
                print("失败：\(failure)")
            }
            print("自检未通过：\(failures.count) 项。")
            return 1
        }
        print("打印机状态解析自检全部通过。")
        return 0
    }

    /// 体检报告：队列被停用、打印机掉线都会在这里现形。
    private static func printerStatus(printerName: String?) -> Int32 {
        let health = waitFor { await PrinterHealthService.inspect(printerName: printerName) }

        print("目标打印机：\(health.printerName.isEmpty ? "未指定" : health.printerName)")
        print("队列状态：\(health.headline)")
        print("接收作业：\(health.isAcceptingJobs ? "是" : "否")")
        if !health.stateMessage.isEmpty {
            print("系统状态：\(health.stateMessage)")
        }
        print("未完成作业：\(health.pendingJobs)")
        if let policy = health.errorPolicy {
            print("出错策略：\(policy)\(health.hasAutoRetry ? "（一次失败会自动重试）" : "（一次失败就会停用队列）")")
        }
        if let deviceURI = health.deviceURI {
            print("设备地址：\(deviceURI)")
        }
        if let reachable = health.deviceReachable {
            print("设备连通：\(reachable ? "通" : "不通")")
        }
        for suggestion in health.suggestions {
            print("建议：\(suggestion)")
        }

        if health.needsAttention {
            print("结论：现在提交作业只会排队，不会出纸。")
            return 1
        }
        print("结论：可以正常打印。")
        return 0
    }

    private static func resumePrinter(printerName: String?) -> Int32 {
        let outcome = PrinterHealthService.resume(printerName: printerName)
        print(outcome.message)
        return outcome.succeeded ? 0 : 1
    }

    private static func enableAutoRetry(printerName: String?) -> Int32 {
        let outcome = PrinterHealthService.enableAutoRetry(printerName: printerName)
        print(outcome.message)
        return outcome.succeeded ? 0 : 1
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

            let health = waitFor { await PrinterHealthService.inspect(printerName: preset.printerName) }
            print("打印机状态：\(health.printerName) — \(health.headline)")
            for suggestion in health.suggestions {
                print("建议：\(suggestion)")
            }
            if health.needsAttention {
                print("注意：目标队列现在不能打印，作业只会排队；可执行 BatchPrint --resume-printer 恢复。")
            }
            return 0
        } catch {
            print("自检失败：\(error.localizedDescription)")
            return 1
        }
    }

    /// 命令行是同步流程，这里用信号量把异步体检结果等出来。
    private static func waitFor<T>(_ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}
