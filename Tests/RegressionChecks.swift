import Foundation
import PDFKit

// 单独编译扫描器、列表模型及转换器，不启动界面，也不提交打印作业。
enum PrintRunnerError: Error {
    case officeConversionFailed(String)
}

@main
struct RegressionChecks {
    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("BatchPrint-Checks-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let nested = root.appendingPathComponent("二级/三级")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        let urls = [root.appendingPathComponent("2.pdf"), root.appendingPathComponent("10.pdf"), nested.appendingPathComponent("表格.docx")]
        for url in urls { try Data("fixture".utf8).write(to: url) }
        try Data().write(to: root.appendingPathComponent("忽略.txt"))
        let scanner = FolderScanner()
        let types: Set<String> = ["pdf", "docx"]
        var items = try scanner.scan(folder: root, preserving: [], enabledTypes: types)
        precondition(items.count == 3)
        precondition(items[0].fileName == "2.pdf" && items[1].fileName == "10.pdf")
        items.reverse()
        items[0].isSelected = false
        let refreshed = try scanner.scan(sources: [root, urls[0], nested], preserving: items, enabledTypes: types)
        precondition(refreshed.map(\.id) == items.map(\.id), "刷新必须保留顺序和 ID")
        precondition(!refreshed[0].isSelected && refreshed.count == 3, "保留勾选且重复导入去重")
        let single = try scanner.scan(sources: [urls[0]], preserving: [], enabledTypes: types)
        precondition(single.count == 1 && single[0].url == urls[0])
        let rows = FileListEntry.rows(files: refreshed, hierarchy: true, collapsed: [])
        precondition(rows.filter { $0.fileID != nil }.count == 3)
        precondition(rows.first { $0.fileID == refreshed[0].id }?.depth == 3, "显示三级目录")
        let collapsed = FileListEntry.rows(files: refreshed, hierarchy: true, collapsed: [root.path])
        precondition(collapsed.count == 1, "收起父目录隐藏所有后代")
        precondition(FileListEntry.rows(files: refreshed, hierarchy: false, collapsed: []).compactMap(\.fileID) == items.map(\.id))
        let overlapping = try scanner.scan(sources: [nested, root], preserving: [], enabledTypes: types)
        let overlapRows = FileListEntry.rows(files: overlapping, hierarchy: true, collapsed: [])
        precondition(overlapRows.filter { $0.fileID != nil }.count == 3)
        precondition(overlapRows.filter { $0.folderURL?.path == nested.path }.count == 1)
        try manager.removeItem(at: urls[0])
        let missing = try scanner.scan(sources: [root], preserving: refreshed, enabledTypes: types)
        precondition(missing.map(\.id) == refreshed.map(\.id), "缺失文件保留以便打印前提示")
        let fontXML = OfficePDFConverter.fontConfigurationXML(
            homeFontDirectory: manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts"),
            cacheDirectory: root.appendingPathComponent("cache & fonts"))
        _ = try XMLDocument(xmlString: fontXML)
        precondition(!fontXML.contains("mode=\"prepend\""), "不应强制覆盖原字体")
        print("通过：递归扫描、单文件导入、去重、刷新保序、勾选保持、缺失文件、目录展开收起、交叠来源、字体配置 XML")
        if CommandLine.arguments.count > 1 {
            let pdf = try await OfficePDFConverter.convertToPDF(sourceURL: URL(fileURLWithPath: CommandLine.arguments[1]))
            guard let document = PDFDocument(url: pdf) else { preconditionFailure("PDF 无效") }
            precondition(document.page(at: 0)?.string?.contains("表格栏目") == true, "表头应保留在第一页")
            print("转换通过：\(document.pageCount) 页，表格栏目位于第一页；输出 \(pdf.path)")
        }
    }
}
