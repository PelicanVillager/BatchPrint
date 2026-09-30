import Foundation

/// 一次“打印前体检”的结果：目标打印队列现在到底能不能干活。
///
/// 为什么需要它：CUPS 的默认出错策略是 `stop-printer`，只要有一个作业报
/// “打印机没有响应”，整个队列就会被自动暂停。此后提交的作业只会静静排队，
/// 一张纸都不出——从界面上看就像“点了打印没反应”。所以在提交前先看一眼队列状态，
/// 把“静默失灵”变成“当场提示 + 一键恢复”。
struct PrinterHealth: Sendable, Equatable {
    /// 队列状态，对应 `lpstat -p` 里的 idle / printing / disabled。
    enum QueueState: String, Sendable {
        case idle
        case processing
        case stopped
        case unknown
    }

    /// 给界面用的严重程度，视图层只管照着上色。
    enum Severity: Sendable {
        case ok
        case info
        case warning
        case critical
        case unknown
    }

    /// CUPS 里的队列名，例如 `HP_LaserJet_M403dn_BW`；所有命令都用它。
    var printerName = ""
    /// 系统里显示的名字（CUPS 的 `printer-info`），例如 `HP LaserJet M403dn`。
    var displayName = ""
    var state: QueueState = .unknown
    /// 队列是否还在接收新作业（对应 `cupsaccept` 那个开关）。
    var isAcceptingJobs = true
    /// 队列被停用时系统给出的原因，例如 `Paused`、`The printer is not responding.`。
    var stateMessage = ""
    /// 队列里还没打完的作业数。
    var pendingJobs = 0
    /// CUPS 的队列出错策略；nil 表示没读到（例如系统里没有 ipptool）。
    var errorPolicy: String?
    /// 驱动里的设备地址，例如 `ipp://192.168.0.9/ipp/print`。
    var deviceURI: String?
    var deviceHost: String?
    var devicePort: UInt16?
    /// 设备端口通不通；nil 表示没探测（本地 USB、Bonjour 之类的地址）。
    var deviceReachable: Bool?

    var isStopped: Bool { state == .stopped }
    var isProcessing: Bool { state == .processing }
    var isUnknown: Bool { state == .unknown }

    /// 说人话的时候用显示名，找不到就用队列名。
    var title: String { displayName.isEmpty ? printerName : displayName }

    /// 出错策略是不是“自动重试”。CUPS 默认的 `stop-printer` 一次失败就把整个队列停掉。
    static let autoRetryPolicy = "retry-job"
    var hasAutoRetry: Bool { errorPolicy == Self.autoRetryPolicy }

    /// 需要用户先处理一下才能打印的情况。
    var needsAttention: Bool {
        isStopped || !isAcceptingJobs || deviceReachable == false
    }

    var severity: Severity {
        if isStopped || !isAcceptingJobs || deviceReachable == false { return .critical }
        if isUnknown { return .unknown }
        // 没在打印却还有未完成作业，多半是卡住了，值得看一眼。
        if pendingJobs > 0, !isProcessing { return .warning }
        if isProcessing { return .info }
        return .ok
    }

    /// 界面上那一行大字。
    var headline: String {
        if !isAcceptingJobs { return "队列已停止接收作业" }
        if isStopped { return "队列已停用，作业只会排队不出纸" }
        if deviceReachable == false { return "打印机不在线" }
        if isUnknown { return "无法读取打印状态" }
        if isProcessing {
            return pendingJobs > 1 ? "正在打印（队列中还有 \(pendingJobs) 个作业）" : "正在打印"
        }
        if pendingJobs > 0 { return "空闲，但队列中还有 \(pendingJobs) 个作业" }
        return "空闲，可以打印"
    }

    /// 界面上那一行小字。
    var detailText: String? {
        var parts: [String] = []
        if !stateMessage.isEmpty { parts.append("系统状态：\(stateMessage)") }
        if let errorPolicy {
            parts.append(
                hasAutoRetry
                    ? "出错策略：自动重试（retry-job）"
                    : "出错策略：\(errorPolicy)（一次失败就会停用队列）"
            )
        }
        if let deviceURI { parts.append("设备：\(deviceURI)") }
        if deviceReachable == false, let deviceHost, let devicePort {
            parts.append("\(deviceHost):\(devicePort) 没有响应")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 修复建议，第一条会被界面当作主要提示。
    var suggestions: [String] {
        if isStopped {
            var items = [
                "点「恢复队列」让作业重新开始出纸。",
                "也可以手动执行：cupsenable \(printerName)"
            ]
            if errorPolicy != nil, !hasAutoRetry {
                items.append("把出错策略改成自动重试，可以避免下次一次超时又停住队列（点「开启自动重试」）。")
            }
            return items
        }
        if !isAcceptingJobs {
            return [
                "点「恢复队列」让队列重新接收作业。",
                "也可以手动执行：cupsaccept \(printerName)"
            ]
        }
        if deviceReachable == false {
            return [
                "检查打印机电源和网线/无线连接是否正常。",
                "打印机会在深度休眠时短暂不应答，可在打印机设置里延长休眠时间。"
            ]
        }
        if isUnknown {
            return ["在「系统设置 → 打印机与扫描仪」里确认这台打印机是否还在。"]
        }
        return []
    }
}
