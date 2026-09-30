import Foundation
import SwiftUI

/// 界面用的打印机状态看板：谁需要都从这里拿，避免各视图各查一遍。
@MainActor
final class PrinterMonitor: ObservableObject {
    @Published private(set) var health: PrinterHealth?
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    /// 恢复队列等操作的结果提示。
    @Published private(set) var actionMessage: String?

    var lastCheckedText: String? {
        guard let lastChecked else { return nil }
        return "上次检查 " + lastChecked.formatted(date: .omitted, time: .shortened)
    }

    @discardableResult
    func refresh(printerName: String?) async -> PrinterHealth {
        isChecking = true
        let result = await PrinterHealthService.inspect(printerName: printerName)
        health = result
        lastChecked = Date()
        isChecking = false
        return result
    }

    @discardableResult
    func resume(printerName: String?) async -> PrinterHealthService.ResumeOutcome {
        actionMessage = "正在恢复队列…"
        let outcome = PrinterHealthService.resume(printerName: printerName)
        actionMessage = outcome.message
        await refresh(printerName: printerName)
        return outcome
    }

    /// 把队列出错策略改成自动重试，避免下次又被一次超时停住。
    @discardableResult
    func enableAutoRetry(printerName: String?) async -> PrinterHealthService.ResumeOutcome {
        actionMessage = "正在把出错策略改成自动重试…"
        let outcome = PrinterHealthService.enableAutoRetry(printerName: printerName)
        actionMessage = outcome.message
        await refresh(printerName: printerName)
        return outcome
    }
}
