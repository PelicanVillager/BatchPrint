import SwiftUI

struct ProgressPanel: View {
    @ObservedObject var runner: PrintJobRunner
    let onStop: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(runner.progress.isRunning ? "正在批量打印" : "打印已结束")
                    .font(.title2.bold())
                Spacer()
                Button("关闭") {
                    onClose()
                }
                .disabled(runner.progress.isRunning)
            }

            ProgressView(value: runner.progress.fractionCompleted) {
                HStack {
                    Text(currentTitle)
                    Spacer()
                    Text("\(runner.progress.completedJobs)/\(runner.progress.total)")
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.blue)

            if runner.progress.rounds > 1 {
                Text(roundTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(runner.logLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                if runner.progress.isRunning {
                    Button(role: .destructive) {
                        onStop()
                    } label: {
                        Label("停止后续任务", systemImage: "stop.fill")
                    }
                }
                Spacer()
            }
        }
        .padding(20)
    }

    private var currentTitle: String {
        if runner.progress.isRunning {
            return "正在打印：\(runner.progress.currentFileName)"
        }
        return "任务已全部处理"
    }

    private var roundTitle: String {
        let progress = runner.progress
        guard progress.currentRoundIndex > 0 else {
            return "共 \(progress.rounds) 批，合计 \(progress.total) 个作业"
        }
        return "第 \(progress.currentRound)/\(progress.rounds) 批 · "
            + "本批第 \(progress.currentRoundIndex)/\(progress.currentRoundTotal) 个文件"
    }
}
