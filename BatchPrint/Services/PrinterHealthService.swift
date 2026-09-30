import Foundation
import Network

/// 查询、诊断并修复目标打印队列的状态。
///
/// 主数据来源是 IPP（`ipptool` 问本机 CUPS），一次就能拿到队列名、描述、状态、
/// 设备地址、出错策略和排队作业数，而且不受系统语言影响；`lpstat` 只作为兜底。
///
/// 这里有个容易踩的坑：系统里显示的打印机名（`NSPrinter` 给的名字，也就是 CUPS 的
/// `printer-info`）和真正的队列名经常不一样，例如显示名 “HP LaserJet M403dn”
/// 对应队列 “HP_LaserJet_M403dn_BW”。拿显示名去问 `lpstat` 会直接失败，
/// 界面就会显示“无法读取打印状态”，所以必须先做名字映射。
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
        // 首选 IPP：一次查询拿全，而且不看系统语言脸色。
        let queues = fetchQueues()
        if !queues.isEmpty {
            var health = PrinterHealth()
            guard let record = pickQueue(for: printerName, from: queues) else {
                health.printerName = printerName ?? ""
                health.stateMessage = "在本机 CUPS 里找不到这台打印机"
                return health
            }
            apply(record, to: &health)
            await probeReachability(of: &health, enabled: probeDevice)
            return health
        }

        // 兜底：系统里没有 ipptool 时退回 lpstat 文本解析。
        return await inspectViaLpstat(printerName: printerName, probeDevice: probeDevice)
    }

    /// `lpstat` 兜底路径。
    private static func inspectViaLpstat(printerName: String?, probeDevice: Bool) async -> PrinterHealth {
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
        }

        await probeReachability(of: &health, enabled: probeDevice)
        return health
    }

    /// 设备连通性探测：拿设备地址里的主机和端口连一下。
    private static func probeReachability(of health: inout PrinterHealth, enabled: Bool) async {
        guard enabled, let device = health.deviceURI, let target = endpoint(from: device) else { return }
        health.deviceHost = target.host
        health.devicePort = target.port
        health.deviceReachable = await tcpReachable(
            host: target.host,
            port: target.port,
            timeout: 2.5
        )
    }

    // MARK: - IPP 查询

    /// 本机 CUPS 里的一台队列。
    struct QueueRecord: Sendable, Equatable {
        var name = ""
        /// CUPS 的 `printer-info`，也就是系统里显示的那个打印机名。
        var info = ""
        var state: PrinterHealth.QueueState = .unknown
        var stateReasons = ""
        var stateMessage = ""
        var isAcceptingJobs = true
        var queuedJobs = 0
        var deviceURI = ""
        var errorPolicy: String?

        /// 界面显示用的名字：优先显示名，退而求其次用队列名。
        var displayName: String { info.isEmpty ? name : info }
    }

    /// 问本机 CUPS 要全部队列的信息。读不到就返回空数组，由调用方决定怎么兜底。
    static func fetchQueues() -> [QueueRecord] {
        let testFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchPrint-queues-\(UUID().uuidString)")
            .appendingPathExtension("test")
        defer { try? FileManager.default.removeItem(at: testFile) }

        let definition = """
        {
          OPERATION CUPS-Get-Printers
          GROUP operation-attributes-tag
          ATTR charset attributes-charset utf-8
          ATTR language attributes-natural-language en
          ATTR keyword requested-attributes printer-name,printer-info,printer-state,printer-state-reasons,printer-state-message,printer-is-accepting-jobs,device-uri,printer-error-policy,queued-job-count
          STATUS successful-ok
          DISPLAY printer-name
          DISPLAY printer-info
          DISPLAY printer-state
          DISPLAY printer-state-reasons
          DISPLAY printer-state-message
          DISPLAY printer-is-accepting-jobs
          DISPLAY device-uri
          DISPLAY printer-error-policy
          DISPLAY queued-job-count
        }
        """

        do {
            try definition.write(to: testFile, atomically: true, encoding: .utf8)
        } catch {
            return []
        }

        // 用 -tv：只有它在多台打印机的输出之间插入 `-- separator --`，切记录最稳。
        guard let output = run(ipptool, ["-tv", "ipp://localhost:631/", testFile.path])?.output else {
            return []
        }
        return parseQueues(from: output)
    }

    /// 解析 `ipptool` 的输出。
    ///
    /// 注意：`ipptool -t` 的输出**没有** `-- separator --` 分隔行（`-tv` 才有），
    /// 而且 CUPS 是按属性名排序返回的，同一台打印机的属性一定是连续的。
    /// 所以这里准备了两种切分方式：有分隔行就用分隔行，没有就用“第一行的属性名再次出现”判新记录。
    static func parseQueues(from output: String) -> [QueueRecord] {
        var pairs: [(key: String, value: String)] = []
        var sawSeparator = false
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.contains("-- separator --") {
                sawSeparator = true
                pairs.append((separatorKey, ""))
                continue
            }
            guard let separator = line.range(of: " = ") else { continue }
            let key = line[line.startIndex..<separator.lowerBound]
                .split(separator: " ")
                .first
                .map(String.init) ?? ""
            guard !key.isEmpty else { continue }
            pairs.append((key, String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)))
        }

        let anchor = sawSeparator ? separatorKey : pairs.first?.key
        var groups: [[(key: String, value: String)]] = []
        var current: [(key: String, value: String)] = []
        for pair in pairs {
            if pair.key == anchor, !current.isEmpty {
                groups.append(current)
                current = []
            }
            current.append(pair)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap(makeRecord)
    }

    private static let separatorKey = "--separator--"

    private static func makeRecord(from pairs: [(key: String, value: String)]) -> QueueRecord? {
        var fields: [String: String] = [:]
        for pair in pairs where pair.key != separatorKey {
            // 同一属性出现多次时（例如多条 state-reasons）拼起来，别把后面的值丢掉。
            if let existing = fields[pair.key], !existing.isEmpty, !pair.value.isEmpty {
                fields[pair.key] = existing + "," + pair.value
            } else if fields[pair.key] == nil || !pair.value.isEmpty {
                fields[pair.key] = pair.value
            }
        }

        guard let name = fields["printer-name"], !name.isEmpty else { return nil }
        var record = QueueRecord()
        record.name = name
        record.info = fields["printer-info"] ?? ""
        record.state = queueState(from: fields["printer-state"] ?? "")
        record.stateReasons = fields["printer-state-reasons"] ?? ""
        record.stateMessage = fields["printer-state-message"] ?? ""
        record.isAcceptingJobs = (fields["printer-is-accepting-jobs"] ?? "true").lowercased() != "false"
        record.queuedJobs = Int(fields["queued-job-count"] ?? "") ?? 0
        record.deviceURI = fields["device-uri"] ?? ""
        let policy = fields["printer-error-policy"] ?? ""
        record.errorPolicy = policy.isEmpty ? nil : policy
        return record
    }

    static func queueState(from value: String) -> PrinterHealth.QueueState {
        switch value.lowercased() {
        case "idle": return .idle
        case "processing": return .processing
        case "stopped": return .stopped
        default: return .unknown
        }
    }

    /// 把队列记录填进体检结果。
    static func apply(_ record: QueueRecord, to health: inout PrinterHealth) {
        health.printerName = record.name
        health.displayName = record.displayName
        health.state = record.state
        health.isAcceptingJobs = record.isAcceptingJobs
        health.pendingJobs = record.queuedJobs
        health.errorPolicy = record.errorPolicy
        if !record.deviceURI.isEmpty {
            health.deviceURI = record.deviceURI
        }

        var messages: [String] = []
        let reasons = record.stateReasons
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "none" }
        if !reasons.isEmpty {
            messages.append(reasons.joined(separator: ", "))
        }
        // CUPS 常把同一件事同时放进 state-reasons 和 state-message（比如 paused / Paused），去个重。
        let duplicatesReason = reasons.contains {
            $0.lowercased() == record.stateMessage.lowercased()
        }
        if !record.stateMessage.isEmpty, !duplicatesReason {
            messages.append(record.stateMessage)
        }
        health.stateMessage = messages.joined(separator: " · ")
    }

    /// 挑出用户想要的那台队列：名字可能是队列名，也可能是界面上的显示名。
    static func pickQueue(for requested: String?, from queues: [QueueRecord]) -> QueueRecord? {
        guard !queues.isEmpty else { return nil }

        let wanted = requested?.trimmingCharacters(in: .whitespaces) ?? ""
        if wanted.isEmpty {
            if let defaultName = systemDefaultDestination(),
               let match = queues.first(where: { $0.name == defaultName }) {
                return match
            }
            // 系统默认拿不到时，退回用“系统默认打印机”的显示名去匹配。
            if let displayName = PrinterService.defaultPrinterName(), !displayName.isEmpty,
               let match = queues.first(where: { $0.info == displayName }) {
                return match
            }
            return queues.first
        }

        // 1. 队列名精确匹配
        if let exact = queues.first(where: { $0.name == wanted }) { return exact }
        // 2. 显示名精确匹配（界面里给的就是这个名字）
        if let byInfo = queues.first(where: { $0.info == wanted }) { return byInfo }

        // 3. 忽略大小写、空格、下划线、连字符后相等
        let key = normalizedQueueKey(wanted)
        if let match = queues.first(where: {
            normalizedQueueKey($0.name) == key || normalizedQueueKey($0.info) == key
        }) {
            return match
        }

        // 4. 互相包含（例如 “HP LaserJet M403dn” vs “HP_LaserJet_M403dn_BW”）
        return queues.first { record in
            let name = normalizedQueueKey(record.name)
            let info = normalizedQueueKey(record.info)
            return name.contains(key) || key.contains(name) || info.contains(key)
        }
    }

    static func normalizedQueueKey(_ value: String) -> String {
        let dropped: Set<Character> = [" ", "_", "-", "（", "）", "(", ")", ".", "·"]
        return String(value.lowercased().filter { !dropped.contains($0) })
    }

    // MARK: - 修复

    struct ResumeOutcome: Sendable {
        var succeeded: Bool
        var message: String
    }

    /// 恢复被停用/停止接收作业的队列。
    static func resume(printerName: String?) -> ResumeOutcome {
        let queues = fetchQueues()
        guard let name = resolveQueueName(printerName, queues: queues) else {
            return ResumeOutcome(succeeded: false, message: "找不到可用的打印机，无法恢复队列。")
        }

        var notes: [String] = []

        let record = queues.first { $0.name == name }
        let rejected: Bool = if let record {
            !record.isAcceptingJobs
        } else if let output = run(lpstat, ["-a", name])?.output {
            !isAccepting(output)
        } else {
            false
        }

        if rejected {
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
        guard let name = resolveQueueName(printerName, queues: fetchQueues()) else {
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

        // IPP 队列列表解析：两种真实格式都要能切对
        let queues = parseQueues(from: Self.queueListSample)
        let separated = parseQueues(from: Self.queueListWithSeparatorSample)
        if separated.map(\.name) != queues.map(\.name) {
            failures.append("带分隔符的队列列表解析错误：\(separated.map(\.name))")
        }
        if queues.count != 2 {
            failures.append("队列列表解析错误：期望 2 台，实际 \(queues.count) 台")
        } else {
            if queues[0].name != "HP_LaserJet_M403dn_BW" || queues[0].info != "HP LaserJet M403dn" {
                failures.append("队列名/描述解析错误：\(queues[0].name) / \(queues[0].info)")
            }
            if queues[0].state != .idle || queues[0].queuedJobs != 0 || queues[0].errorPolicy != "retry-job" {
                failures.append("队列状态解析错误：\(queues[0])")
            }
            if queues[1].state != .stopped || queues[1].stateReasons != "paused" || queues[1].isAcceptingJobs {
                failures.append("停用队列解析错误：\(queues[1])")
            }
            if queues[1].deviceURI != "ipp://192.168.0.8/ipp/print" {
                failures.append("设备地址解析错误：\(queues[1].deviceURI)")
            }
        }

        // 显示名 → 队列名 的映射（这就是“无法读取打印状态”的病根）
        let lookups: [(requested: String, expected: String?)] = [
            ("HP LaserJet M403dn", "HP_LaserJet_M403dn_BW"),
            ("HP_LaserJet_M403dn_BW", "HP_LaserJet_M403dn_BW"),
            ("hp laserjet m403dn", "HP_LaserJet_M403dn_BW"),
            ("HP Color LaserJet Flow E78635（右边白色）", "HP_ColorLaserJet_E78635"),
            ("不存在的打印机", nil)
        ]
        for sample in lookups {
            let resolved = pickQueue(for: sample.requested, from: queues)?.name
            if resolved != sample.expected {
                failures.append("打印机名映射错误：\(sample.requested) → \(resolved ?? "nil")")
            }
        }

        return failures
    }

    /// 自检样本：`ipptool -t` 的真实格式，没有 `-- separator --`。
    private static let queueListSample = """
            printer-error-policy (nameWithoutLanguage) = retry-job
            printer-is-accepting-jobs (boolean) = true
            printer-state (enum) = idle
            printer-state-reasons (keyword) = none
            printer-state-message (textWithoutLanguage) = 
            queued-job-count (integer) = 0
            printer-name (nameWithoutLanguage) = HP_LaserJet_M403dn_BW
            printer-info (textWithoutLanguage) = HP LaserJet M403dn
            device-uri (uri) = ipp://192.168.0.9/ipp/print
            printer-error-policy (nameWithoutLanguage) = stop-printer
            printer-is-accepting-jobs (boolean) = false
            printer-state (enum) = stopped
            printer-state-reasons (keyword) = paused
            printer-state-message (textWithoutLanguage) = 
            queued-job-count (integer) = 3
            printer-name (nameWithoutLanguage) = HP_ColorLaserJet_E78635
            printer-info (textWithoutLanguage) = HP Color LaserJet Flow E78635（右边白色）
            device-uri (uri) = ipp://192.168.0.8/ipp/print
    """

    /// 自检样本：`ipptool -tv` 的真实格式，带分离行和若干无关噪音。
    private static let queueListWithSeparatorSample = """
            "/tmp/x.test":
                CUPS-Get-Printers:
                    requested-attributes (1setOf keyword) = printer-name,printer-info
                /tmp/x                                                           [PASS]
                    RECEIVED: 1528 bytes in response
                    status-code = successful-ok (successful-ok)
                    printer-error-policy (nameWithoutLanguage) = retry-job
                    printer-is-accepting-jobs (boolean) = true
                    printer-state (enum) = idle
                    printer-state-reasons (keyword) = none
                    printer-state-message (textWithoutLanguage) = 
                    queued-job-count (integer) = 0
                    printer-name (nameWithoutLanguage) = HP_LaserJet_M403dn_BW
                    printer-info (textWithoutLanguage) = HP LaserJet M403dn
                    device-uri (uri) = ipp://192.168.0.9/ipp/print
                    -- separator --
                    printer-error-policy (nameWithoutLanguage) = stop-printer
                    printer-is-accepting-jobs (boolean) = false
                    printer-state (enum) = stopped
                    printer-state-reasons (keyword) = paused
                    printer-state-message (textWithoutLanguage) = 
                    queued-job-count (integer) = 3
                    printer-name (nameWithoutLanguage) = HP_ColorLaserJet_E78635
                    printer-info (textWithoutLanguage) = HP Color LaserJet Flow E78635（右边白色）
                    device-uri (uri) = ipp://192.168.0.8/ipp/print
    """

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
        if let name = systemDefaultDestination() { return name }
        return PrinterService.defaultPrinterName().flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 把界面上的名字（显示名或队列名）解析成真正的 CUPS 队列名。
    static func resolveQueueName(_ printerName: String?, queues: [QueueRecord]) -> String? {
        if !queues.isEmpty, let match = pickQueue(for: printerName, from: queues) {
            return match.name
        }
        return resolvePrinterName(printerName)
    }

    /// 系统默认队列名（`lpstat -d` 给出的就是队列名）。注意别把整行转小写，队列名区分大小写。
    static func systemDefaultDestination() -> String? {
        guard let output = run(lpstat, ["-d"])?.output else { return nil }
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["system default destination:", "系统默认目的位置：", "系统默认目的位置:"] {
            if let range = line.range(of: marker, options: [.caseInsensitive]) {
                let name = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return nil
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
