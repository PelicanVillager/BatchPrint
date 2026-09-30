import SwiftUI

struct PrintSettingsView: View {
    @EnvironmentObject private var store: PrintPresetStore
    let printerNames: [String]

    var body: some View {
        ScrollView {
            Form {
                Section("打印机") {
                    Picker("目标打印机", selection: printerBinding) {
                        Text("系统默认打印机").tag("")
                        ForEach(printerNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }

                    Button("刷新打印机列表") {
                        NotificationCenter.default.post(name: .batchPrintRefreshPrinters, object: nil)
                    }
                }

                Section("页面范围") {
                    Picker("打印范围", selection: $store.preset.pageRange.isAllPages) {
                        Text("全部").tag(true)
                        Text("自定义页码").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if !store.preset.pageRange.isAllPages {
                        TextField("例如：1-3,5", text: $store.preset.pageRange.customText)
                    }
                }

                Section("份数与版面") {
                    Stepper(value: $store.preset.copies, in: 1...99) {
                        LabeledContent("每份文件份数", value: "\(store.preset.copies)")
                    }

                    Picker("双面打印", selection: $store.preset.duplex) {
                        ForEach(DuplexMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Picker("方向", selection: $store.preset.orientation) {
                        ForEach(Orientation.allCases) { orientation in
                            Text(orientation.title).tag(orientation)
                        }
                    }
                }

                Section("批次（整批重复打印）") {
                    Stepper(value: $store.preset.rounds, in: 1...99) {
                        LabeledContent("批次数", value: "\(store.preset.rounds)")
                    }

                    if store.preset.rounds > 1 {
                        Stepper(value: $store.preset.roundDelaySeconds, in: 0...600, step: 5) {
                            LabeledContent("批次间隔", value: "\(Int(store.preset.roundDelaySeconds)) 秒")
                        }
                    }

                    Text(batchHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("颜色与纸张") {
                    Picker("色彩模式", selection: $store.preset.colorMode) {
                        ForEach(ColorMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Picker("纸张尺寸", selection: $store.preset.paperSize) {
                        ForEach(PaperSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }

                    if store.preset.paperSize == .custom {
                        HStack {
                            TextField("宽度", value: $store.preset.customPaperWidthMM, format: .number)
                            TextField("高度", value: $store.preset.customPaperHeightMM, format: .number)
                        }
                        .textFieldStyle(.roundedBorder)
                        .help("单位：毫米")
                    }
                }

                Section("缩放") {
                    Picker("缩放方式", selection: $store.preset.scaling) {
                        ForEach(ScalingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    if store.preset.scaling == .percentage {
                        Slider(value: $store.preset.scalePercentage, in: 10...400, step: 5) {
                            Text("缩放比例")
                        } minimumValueLabel: {
                            Text("10%")
                        } maximumValueLabel: {
                            Text("400%")
                        }
                        Text("\(Int(store.preset.scalePercentage))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("支持的文件类型") {
                    ForEach(SupportedFileType.allCases) { type in
                        Toggle(type.title, isOn: typeBinding(for: type))
                    }
                }

                Section {
                    Button("恢复默认设置") {
                        store.reset()
                    }
                }
            }
            .formStyle(.grouped)
            .padding(12)
        }
    }

    private var printerBinding: Binding<String> {
        Binding(
            get: { store.preset.printerName ?? "" },
            set: { newValue in
                store.preset.printerName = newValue.isEmpty ? nil : newValue
            }
        )
    }

    /// 用一句人话解释“批次数”是怎么回事，省得跟“份数”混起来。
    private var batchHint: String {
        let rounds = store.preset.rounds
        let copies = store.preset.copies

        guard rounds > 1 else {
            return "批次数为 1：选中的文件按列表顺序各打印 \(copies) 份，打完即结束。"
        }

        let delay = store.preset.roundDelaySeconds > 0
            ? "，每批之间停 \(Int(store.preset.roundDelaySeconds)) 秒"
            : ""
        return "选中的文件按列表顺序各打印 \(copies) 份算 1 批，这样重复 \(rounds) 批\(delay)。"
            + "适合“一批打完、取出装订，再打下一批”。"
    }

    private func typeBinding(for type: SupportedFileType) -> Binding<Bool> {
        Binding(
            get: { store.preset.enabledTypes.contains(type.rawValue) },
            set: { enabled in
                if enabled {
                    store.preset.enabledTypes.insert(type.rawValue)
                } else {
                    store.preset.enabledTypes.remove(type.rawValue)
                }
            }
        )
    }
}

extension Notification.Name {
    static let batchPrintRefreshPrinters = Notification.Name("BatchPrintRefreshPrinters")
}
