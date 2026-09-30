import Foundation
import Network

/// 查询、诊断并修复目标打印队列的状态。
///
/// 数据来源是 CUPS 自带的 `lpstat`；为了让输出不受系统语言影响，
/// 调用时强制 `LC_ALL=C`，解析英文关键字（同时保留中文关键字做兜底）。
enum PrinterHealthService {
    private static let lpstat = "/usr/bin/lpstat"
    private static let ipptool = "/usr/bin/ipptool"
    private static let lpadmin = "/usr/sbin/lpadmin"
    private static let cupsenable = "/usr/sbin/cupsenable"
    private static let cupsaccept = "/usr/sbin/cupsaccept"

    // MARK: - 体检

    /// 读取目标打印机的状态。`printerName` 为空时使用系统默认打印机。
    ///
    /// 这是非隔离的异步函数，`Process` 调用不会占用主线程。
    static func inspect(printerName: String?, probeDevice: Bool = true) async -> PrinterHealth {
        var health = PrinterHealth()

        guard let name = resolvePrinterName(printerName) else {
            health.printerName = printerName ?? ""
            health.stateMessage = "找不到可用的打印机"
            return health
        }
        health.printerName = name

        if let output = run(lpstat, ["-p", name])?.output {
            parsePrintersOutput(output, into: &health)
        }

        if let output = run(lpstat, ["-a", name])?.output {
            parseAcceptingOutput(output, into: &health)
        }

        if let output = run(lpstat, ["-o", name])?.output {
            health.pendingJobs = output
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .count
        }

        health.errorPolicy = errorPolicy(for: name)

        if let device = deviceURI(for: name) {
            health.deviceURI = device
            if let endpoint = endpoint(from: device) {
                health.deviceHost = endpoint.host
                health.devicePort = endpoint.port
                if probeDevice {
                    health.deviceReachable = await tcpReachable(
                        host: endpoint.host,
                        port: endpoint.port,
                        timeout: 2.5
                    )
                }
            }
        }

        return health
    }

    // MARK: - 修复

    struct ResumeOutcome: Sendable {
        var succeeded: Bool
        var message: String
    }

    /// 恢复被停用/停止接收作业的队列。
    static func resume(printerName: String?) -> ResumeOutcome {
        guard let name = resolvePrinterName(printerName) else {
            return ResumeOutcome(succeeded: false, message: "找不到可用的打印机，无法恢复队列。")
        }

        var notes: [String] = []

        if let output = run(lpstat, ["-a", name])?.output, !isAccepting(output) {
            let result = run(cupsaccept, [name])
            if result?.status == 0 {
                notes.append("已让队列重新接收作业。")
            } else {
                return ResumeOutcome(succeeded: false, message: permissionHint(
                    command: "cupsaccept \(name)",
                    detail: result?.error ?? "未知错误"
                ))
            }
        }

        let enableResult = run(cupsenable, [name])
        guard enableResult?.status == 0 else {
            return ResumeOutcome(succeeded: false, message: permissionHint(
                command: "cupsenable \(name)",
                detail: enableResult?.error ?? "未知错误"
            ))
        }
        notes.append("已恢复队列「\(name)」。")

        return ResumeOutcome(succeeded: true, message: notes.joined(separator: " "))
    }

    private static func permissionHint(
        command: String,
        detail: String,
        action: String = "恢复队列失败"
    ) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = trimmed.isEmpty ? "" : "（\(trimmed)）"
        return "\(action)\(reason)。可以在终端里执行：sudo \(command)"
    }

    /// 把队列的出错策略改成 `retry-job`：打印机打盹导致的超时自动重试，
    /// 不会再出现“一次失败就把整个队列停掉、后面作业全堆着不出纸”的情况。
    @discardableResult
    static func enableAutoRetry(printerName: String?) -> ResumeOutcome {
        guard let name = resolvePrinterName(printerName) else {
            return ResumeOutcome(succeeded: false, message: "找不到可用的打印机，无法修改出错策略。")
        }

        let arguments = ["-p", name, "-o", "printer-error-policy=\(PrinterHealth.autoRetryPolicy)"]
        let command = "lpadmin -p \(name) -o printer-error-policy=\(PrinterHealth.autoRetryPolicy)"

        guard let result = run(lpadmin, arguments) else {
            return ResumeOutcome(succeeded: false, message: "无法执行 lpadmin，请检查系统环境。")
        }
        guard result.status == 0 else {
            return ResumeOutcome(succeeded: false, message: permissionHint(
                command: command,
                detail: result.error,
                action: "修改出错策略失败"
            ))
        }

        return ResumeOutcome(
            succeeded: true,
            message: "已把「\(name)」的出错策略改成自动重试（retry-job）。"
        )
    }

    // MARK: - lpstat 解析

    /// `lpstat -p NAME` 的输出，例如：
    /// `printer NAME is idle.  enabled since …`
    /// `printer NAME now printing NAME-198.  enabled since …`
    /// `printer NAME disabled since … -` 换行 `\tPaused`
    static func parsePrintersOutput(_ output: String, into health: inout PrinterHealth) {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let firstLine = lines.first ?? ""
        let first = firstLine.lowercased()

        if first.contains(" now printing") || first.contains("正在打印") {
            health.state = .processing
        } else if first.contains(" is idle") || first.contains("闲置") {
            health.state = .idle
        } else if first.contains(" disabled since") || first.contains("已停用") {
            health.state = .stopped
        } else {
            health.state = .unknown
        }

        // 停用原因有时跟在第一行 " - " 后面，有时单独占一行（如 “Paused”）。
        var message = ""
        if let range = firstLine.range(of: " - ") {
            message = String(firstLine[range.upperBound...])
        }
        if message.isEmpty, lines.count > 1 {
            message = lines.dropFirst().first { !$0.isEmpty } ?? ""
        }
        health.stateMessage = message.trimmingCharacters(in: .whitespaces)
    }

    /// `lpstat -a NAME` 的输出：`NAME accepting requests since …`
    private static func parseAcceptingOutput(_ output: String, into health: inout PrinterHealth) {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        health.isAcceptingJobs = isAccepting(output)
    }

    private static func isAccepting(_ output: String) -> Bool {
        let text = output.lowercased()
        if text.contains(" not accepting") || text.contains("不接受请求") || text.contains("已停止接受") {
            return false
        }
        return true
    }

    /// 纯逻辑自检：不碰真实打印机，只验证状态/地址解析规则，`BatchPrint --self-test` 用。
    static func selfTestFailures() -> [String] {
        var failures: [String] = []

        let endpoints: [(uri: String, host: String?, port: UInt16?)] = [
            ("ipp://192.168.0.9/ipp/print", "192.168.0.9", 631),
            ("ipps://printer.local:8632/ipp/print", "printer.local", 8632),
            ("socket://192.168.0.20:9100", "192.168.0.20", 9100),
            ("lpd://192.168.0.30/queue", "192.168.0.30", 515),
            ("usb://HP/LaserJet", nil, nil),
            ("dnssd://HP%20Printer._ipp._tcp.local./?uuid=1", nil, nil)
        ]
        for sample in endpoints {
            let parsed = endpoint(from: sample.uri)
            if parsed?.host != sample.host || parsed?.port != sample.port {
                failures.append(
                    "设备地址解析错误：\(sample.uri) → "
                        + (parsed.map { "\($0.host):\($0.port)" } ?? "nil")
                )
            }
        }

        let states: [(output: String, state: PrinterHealth.QueueState, message: String)] = [
            ("printer X is idle.  enabled since Wed Sep 30 12:41:03 2026", .idle, ""),
            ("printer X now printing X-198.  enabled since Wed Sep 30 12:41:03 2026", .processing, ""),
            ("printer X disabled since Wed Sep 30 09:58:39 2026 -\n\tPaused", .stopped, "Paused"),
            ("打印机X已停用，时间始于Wed Sep 30 09:58:39 2026 -\n\tPaused", .stopped, "Paused")
        ]
        for sample in states {
            var health = PrinterHealth()
            parsePrintersOutput(sample.output, into: &health)
            if health.state != sample.state {
                failures.append("状态解析错误：\(sample.output) → \(health.state.rawValue)")
            }
            if health.stateMessage != sample.message {
                failures.append("停用原因解析错误：期望「\(sample.message)」实际「\(health.stateMessage)」")
            }
        }

        let accepting: [(output: String, expected: Bool)] = [
            ("X accepting requests since Wed Sep 30 12:41:03 2026", true),
            ("X not accepting requests since Wed Sep 30 09:58:39 2026 - Paused", false)
        ]
        for sample in accepting where isAccepting(sample.output) != sample.expected {
            failures.append("接收作业状态解析错误：\(sample.output)")
        }

        let policies: [(output: String, expected: String?)] = [
            ("\tprinter-error-policy (nameWithoutLanguage) = retry-job\n", "retry-job"),
            ("\tprinter-error-policy (nameWithoutLanguage) = stop-printer\n", "stop-printer"),
            ("\tprinter-state (enum) = idle\n", nil)
        ]
        for sample in policies where parseErrorPolicy(from: sample.output) != sample.expected {
            failures.append("出错策略解析错误：\(sample.output) → \(parseErrorPolicy(from: sample.output) ?? "nil")")
        }

        return failures
    }

    private static func deviceURI(for printerName: String) -> String? {
        guard let output = run(lpstat, ["-v", printerName])?.output else { return nil }
        let line = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }

        // 英文 “device for NAME: URI”、中文 “用于 NAME 的设备：URI” 都靠第一个冒号切开。
        let halfWidth = line.firstIndex(of: ":")
        let fullWidth = line.firstIndex(of: "：")
        let separator: String.Index? = switch (halfWidth, fullWidth) {
        case let (half?, full?): half < full ? half : full
        case let (half?, nil): half
        case let (nil, full?): full
        default: nil
        }
        guard let separator else { return nil }
        let uri = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        return uri.isEmpty ? nil : uri
    }

    /// 读队列的出错策略。
    ///
    /// `lpstat` / `lpoptions` 都不暴露这个属性，只能走 IPP；`ipptool` 又不吃标准输入，
    /// 所以这里临时写一份请求定义再去问本机 CUPS。读不到就返回 nil，不影响其它体检项。
    static func errorPolicy(for printerName: String) -> String? {
        let encodedName = printerName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? printerName
        let testFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchPrint-errpolicy-\(UUID().uuidString)")
            .appendingPathExtension("test")
        defer { try? FileManager.default.removeItem(at: testFile) }

        let definition = """
        {
          OPERATION Get-Printer-Attributes
          GROUP operation-attributes-tag
          ATTR charset attributes-charset utf-8
          ATTR language attributes-natural-language en
          ATTR uri printer-uri $uri
          ATTR keyword requested-attributes printer-error-policy
          STATUS successful-ok
          DISPLAY printer-error-policy
        }
        """

        do {
            try definition.write(to: testFile, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        let arguments = ["-t", "ipp://localhost:631/printers/\(encodedName)", testFile.path]
        guard let output = run(ipptool, arguments)?.output else { return nil }
        return parseErrorPolicy(from: output)
    }

    /// 从 ipptool 的输出里取策略值：
    /// `printer-error-policy (nameWithoutLanguage) = retry-job`
    static func parseErrorPolicy(from output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard line.contains("printer-error-policy"), let equals = line.range(of: "=") else { continue }
            let value = line[equals.upperBound...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// 从设备 URI 里取出可探测的主机和端口；本地/发现类地址返回 nil。
    static func endpoint(from uri: String) -> (host: String, port: UInt16)? {
        guard let url = URL(string: uri), let host = url.host, !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""

        let defaultPort: UInt16? = switch scheme {
        case "ipp", "ipps": 631
        case "socket", "jetdirect": 9100
        case "lpd": 515
        case "http": 80
        case "https": 443
        case "usb", "dnssd", "mdns", "ipp-usb": nil
        default: nil
        }

        guard let port = url.port.map({ UInt16($0) }) ?? defaultPort else { return nil }
        return (host, port)
    }

    private static func resolvePrinterName(_ printerName: String?) -> String? {
        if let printerName, !printerName.trimmingCharacters(in: .whitespaces).isEmpty {
            return printerName
        }
        if let output = run(lpstat, ["-d"])?.output {
            // 注意别把整行转小写：CUPS 的打印机名是区分大小写的。
            let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in ["system default destination:", "系统默认目的位置：", "系统默认目的位置:"] {
                if let range = line.range(of: marker, options: [.caseInsensitive]) {
                    let name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { return name }
                }
            }
        }
        return PrinterService.defaultPrinterName().flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - 设备连通性

    private static func tcpReachable(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "BatchPrint.printer-probe")
            let state = ProbeState()

            @Sendable func finish(_ reachable: Bool) {
                guard state.markDone() else { return }
                connection.cancel()
                continuation.resume(returning: reachable)
            }

            connection.stateUpdateHandler = { connectionState in
                switch connectionState {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// 保证 continuation 只被 resume 一次。
    private final class ProbeState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func markDone() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - 进程调用

    private struct ProcessResult {
        var status: Int32
        var output: String
        var error: String
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> ProcessResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // 强制英文输出，避免解析到本地化文案；同时给出完整 PATH，防止子进程找不到辅助工具。
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // 先读干净管道再 waitUntilExit，避免输出量大时被管道缓冲卡住。
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            error: String(decoding: errData, as: UTF8.self)
        )
    }
}
