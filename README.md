# BatchPrint

BatchPrint 是一个 macOS 原生批量打印工具，使用 SwiftUI 编写。它从一个源文件夹扫描 PDF、Word 和常见图片文件，按顺序提交打印作业，并在打印前检查文件是否仍然存在。

## 功能概览

- 选择源文件夹并递归扫描 `.pdf`、`.doc`、`.docx`、`.jpg`、`.png`、`.tiff` 文件。
- 文件列表展示名称、大小、修改时间和状态。
- 支持勾选、全选/反选、拖拽排序。
- 自动获取系统打印机列表，保存并恢复打印预设。
- 打印前先给目标队列做一次“体检”：队列被停用、打印机掉线都会当场提示并提供一键恢复；还能读出队列的出错策略，一键开启“超时自动重试”。
- 支持页面范围、份数、单双面、色彩模式、纸张尺寸、缩放和方向设置。
- 支持“批次（整批重复）”打印：一批 = 把选中的文件按列表顺序各打印一遍，打完这一批再开始下一批，批次之间可以留出取纸、装订的间隔时间。
- 每批打印前会把最终下发给打印机的参数（含 `sides=…` 双面参数）写进运行日志，便于确认设置真的生效。
- 打印前检查缺失文件，可选择跳过缺失文件继续打印。
- 显示实时进度和运行日志，结束后输出成功/失败汇总。
- 打印过程中可停止后续任务；已提交的作业不受影响。
- 选中单个 `.doc`/`.docx` 文件后，可点击“转换预览”先查看 PDF 转换结果，再决定是否打印。
- `.doc`/`.docx` 转换时自动加载 macOS 系统中文字体，并映射宋体、仿宋、楷体、黑体等常见字体名，减少空白页和缺字问题。

## 项目结构

```text
BatchPrint/
  BatchPrintApp.swift
  Models/
    FileType.swift
    PrinterHealth.swift
    PrintFileItem.swift
    PrintJobStatus.swift
    PrintPreset.swift
  Services/
    ExternalDocumentPrinter.swift
    FileAvailabilityChecker.swift
    FolderScanner.swift
    OfficePDFConverter.swift
    PrintJobRunner.swift
    PrintPresetStore.swift
    PrinterHealthService.swift
    PrinterMonitor.swift
    PrinterService.swift
    WordDocumentPrinter.swift
  Views/
    ContentView.swift
    FileListView.swift
    PrintSettingsView.swift
    ProgressPanel.swift
Support/
  Info.plist
Package.swift
Makefile
```

## 在 Xcode 中打开

1. 使用 Xcode 15 或更新版本，在 macOS 14 或更高版本上打开 `BatchPrint.xcodeproj`。
2. 选择 `BatchPrint` scheme，然后运行。
3. 如提示代码签名，可将签名身份设置为 `Sign to Run Locally`，或使用 `com.local.BatchPrint` 作为 Bundle ID 的本地开发身份。

也可以直接打开根目录下的 `Package.swift`，以 Swift Package 方式运行 `BatchPrint` 可执行目标。

## 构建并打包 .app

在项目根目录执行（`make app` 内部直接调用 `swiftc`，不依赖 SwiftPM）：

```bash
make app
open dist/BatchPrint.app
```

其他常用命令：

```bash
make check   # 打印参数自检，不开界面
make run     # 打包并打开 .app
```

注意：当前工作环境只有 Command Line Tools，而且本机 `swift build` 会报
`this SDK is not supported by the compiler`（Command Line Tools 的 SDK 与 Swift 工具链版本不匹配），
所以 `Makefile` 里的 `build` 目标改成直接用 `swiftc` 编译；在装有完整 Xcode 的机器上仍可用 SwiftPM / Xcode 工程构建。

## 命令行自检

打包好的应用（或 `.build/release/BatchPrint`）可以直接查询“这组参数最终会下发给打印机的选项”：

```bash
.build/release/BatchPrint --list-printers
.build/release/BatchPrint --print-check --duplex longEdge --copies 2
.build/release/BatchPrint --printer-status      # 队列是否被停用、打印机是否在线
.build/release/BatchPrint --resume-printer      # 恢复被停用的队列
.build/release/BatchPrint --enable-auto-retry   # 出错策略改成自动重试，超时不再停队列
.build/release/BatchPrint --self-test           # 只跑解析规则自检，不碰真实打印机
```

输出示例：

```text
目标打印机：HP LaserJet M403dn
双面设置：双面（长边翻转）（PMDuplexing=2）
关键参数：collate=True copies=2 media=A4 sides=two-sided-long-edge
```

看到 `sides=two-sided-long-edge`（长边）或 `sides=two-sided-short-edge`（短边）就说明双面参数确实下发到打印系统了；如果打印机驱动本身不支持，会在“注意”里给出提示。

`--printer-status` 的输出示例（队列被停用时退出码为 1，方便脚本判断）：

```text
目标打印机：HP_LaserJet_M403dn_BW
队列状态：队列已停用，作业只会排队不出纸
接收作业：是
系统状态：Paused
未完成作业：0
出错策略：stop-printer（一次失败就会停用队列）
设备地址：ipp://192.168.0.9/ipp/print
设备连通：通
建议：点「恢复队列」让作业重新开始出纸。
建议：也可以手动执行：cupsenable HP_LaserJet_M403dn_BW
建议：把出错策略改成自动重试，可以避免下次一次超时又停住队列（点「开启自动重试」）。
结论：现在提交作业只会排队，不会出纸。
```

对应的 `make` 目标：`make check`（参数自检）、`make status`（体检）、`make resume`（恢复队列）、`make retry-job`（开启自动重试）、`make self-test`（解析规则自检）。

### 队列出错策略（为什么建议开自动重试）

CUPS 默认的队列出错策略是 `stop-printer`：只要有**一次**作业报“打印机没有响应”，整个队列就会被暂停，
之后提交的作业全部静静排队。打印机深度休眠、网络抖动都可能触发它，这就是“打印机又不能用”的根因。

改成 `retry-job` 后，超时会被自动重试，队列不再被停住：

```bash
sudo lpadmin -p HP_LaserJet_M403dn_BW -o printer-error-policy=retry-job
```

在 BatchPrint 里不用敲命令：设置面板的“打印机”一栏会读出当前策略，不是自动重试时会出现「开启自动重试」按钮；
命令行则是 `BatchPrint --enable-auto-retry`。体检结果里也会写明当前策略。

## 实现说明与已知限制

- PDF 和图片通过 `NSPrintOperation` 直接打印；PDF 支持 `1-3,5` 形式的自定义页面范围。
- `.doc`、`.docx` 文件会优先通过 LibreOffice/OpenOffice 的 headless 模式转换为 PDF，再使用 BatchPrint 的 PDF 打印流程，尽量保留原排版。
- 转换器会优先查找以下位置：
  - 环境变量 `BATCHPRINT_SOFFICE_PATH` 指定的 `soffice`
  - 常见 LibreOffice/OpenOffice 安装路径
  - 本机 Codex 运行时中的 LibreOffice
- 如果找不到 LibreOffice/OpenOffice，会退回使用 macOS `textutil` 转成 RTF 打印。
- 对于 Microsoft Word、Pages 和 TextEdit，仍会优先使用应用自身的 AppleScript 打印。
- 转换 PDF 时会自动生成临时 `fonts.conf`，加载 `/System/Library/Fonts`、`/System/Library/Fonts/Supplemental`、`/Library/Fonts` 和用户字体目录，并加入常见中文字体别名。
- macOS 系统通常没有“仿宋”“楷体”“方正小标宋简体”等字体，程序会将它们映射到系统已有的宋体或黑体，以保证内容完整，但字体样式可能不完全一致。若必须保持原字体，请先安装对应字体。
- 双面打印必须写进 `NSPrintInfo.printSettings`，键名是 `com_apple_print_PrintSettings_PMDuplexing`，取值为 `1` 单面、`2` 长边翻转、`3` 短边翻转。`NSPrintInfo.dictionary()` 只认官方声明的那几个键（纸张、份数、方向、缩放……），其它键会被静默忽略——早期版本写的 `NSPrintDuplex` / `NSPrintColorMode` 就属于这种情况，双面打印一直没生效，现在已改为正确写法。
- 色彩模式通过驱动选项 `ColorModel`（`Gray` / `RGB` 等）设置，取值来自打印机 PPD；驱动未提供该选项时会跳过并在日志里提示。
- 打印机会在打印前读取一次 PPD（`PMPrinterCopyDescriptionURL`），用于判断是否支持双面、支持哪种色彩模式；判断失败只是少一条提示，不会影响打印。
- 份数会同时打开“按份装订”（collate），多页文档打印多份时是一份一份出纸。
- 批次打印是“整批重复”：批次 3 表示选中的文件整套打完再重复两遍；如果只想让同一个文件多出几份，用“每份文件份数”。
- AppleScript 自动打印首次运行时，macOS 可能要求授予自动化权限。
- 目前没有启用 App Sandbox，因此应用可以直接读取用户选择的文件夹。若要提交 App Store，需要补充沙盒配置与文件访问权限处理。

## 常见问题

### 点了“开始打印”却一直不出纸，队列也不动？

先看右侧设置面板最上面的“打印机状态”那一行，或者直接跑 `BatchPrint --printer-status`。

最常见的原因是 **macOS 把打印队列停用了**：CUPS 的默认出错策略是 `stop-printer`，
只要有作业报一次“打印机没有响应”（打印机深度休眠、网络抖动都会触发），整个队列就会被暂停，
之后提交的作业只会安静地排队，从界面上看就像“点了没反应”。

处理办法：点界面上那个红色的“队列已停用，点此恢复”，或在设置面板里点“恢复队列”，
命令行则是 `BatchPrint --resume-printer`（等同于 `cupsenable 打印机名`）。
BatchPrint 现在会在提交前主动体检，遇到这种情况先弹窗说明并给出一键恢复，不会再让作业悄悄堆进队列。

要断根的话，把队列出错策略改成自动重试（设置面板里的“开启自动重试”、命令行 `--enable-auto-retry`、
或者 `sudo lpadmin -p 打印机名 -o printer-error-policy=retry-job`），这样单次超时只会重试，不会停住队列。

如果体检显示“打印机不在线”，那就是电源或网络的问题，跟队列无关。

### 怎么让一批文件“整批打完再打下一批”？

在右侧设置面板的“批次（整批重复打印）”里设置批次数和批次间隔：

- 批次数 3 = 把勾选的文件按列表顺序各打印一遍算 1 批，这样重复 3 批（先打完一批，再打下一批）。
- 批次间隔用于取纸、装订，设为 0 就是一气呵成。
- 打印过程中随时可以点“停止后续任务”，当前批打完后不再开始下一批。

### 为什么双面打印以前打不出来？

早期版本把双面参数写成了 `NSPrintDuplex` 键，但 AppKit 早已不认这个键（未知键会被静默忽略），所以双面设置从来没传到打印机。现在改为写入 `printSettings` 的 `com_apple_print_PrintSettings_PMDuplexing`（1 单面 / 2 长边 / 3 短边），日志里能看到 `sides=two-sided-long-edge` 之类的参数。若打印机驱动本身没有双面能力，日志会提示“未声明双面能力”。

### 怎么确认参数真的生效？

打开运行日志，看“实际下发参数”这一行；或者用命令行自检：`BatchPrint --print-check --duplex longEdge`。

### 为什么打印出来是空白页？

常见原因是 Word→PDF 转换时没有加载中文字体。BatchPrint 已通过临时 `fonts.conf` 强制加载 macOS 系统中文字体，并为宋体、仿宋、楷体、黑体等常见字体名设置替代规则。遇到问题时，先使用“转换预览”查看 PDF 是否正常。

### 为什么某些字体看起来不一样？

macOS 系统字体中可能没有原文档使用的“仿宋”“楷体”“方正小标宋简体”。BatchPrint 会用系统中文字体替代，因此内容会保留，但字体样式可能变化。安装对应字体后重新预览即可。

### 为什么 `.docx` 有时会退回 RTF 打印？

如果找不到 LibreOffice/OpenOffice，BatchPrint 会退回 `textutil` 的 RTF 打印。RTF 打印的排版保真度低于 PDF 转换，建议安装 LibreOffice 或设置 `BATCHPRINT_SOFFICE_PATH`。
