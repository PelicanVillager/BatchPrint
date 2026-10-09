import Foundation

struct FolderScanner {
    enum ScannerError: LocalizedError {
        case notDirectory
        case inaccessible

        var errorDescription: String? {
            switch self {
            case .notDirectory: return "所选路径不是文件夹。"
            case .inaccessible: return "无法读取所选文件或文件夹，请检查访问权限。"
            }
        }
    }

    func scan(folder: URL, preserving previousItems: [PrintFileItem], enabledTypes: Set<String>) throws -> [PrintFileItem] {
        try scan(sources: [folder], preserving: previousItems, enabledTypes: enabledTypes)
    }

    /// 已导入的文件保留 ID、勾选和手动顺序；新文件按路径自然排序后追加。
    func scan(sources: [URL], preserving previousItems: [PrintFileItem], enabledTypes: Set<String>) throws -> [PrintFileItem] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let previous = Dictionary(uniqueKeysWithValues: previousItems.map { ($0.url.standardizedFileURL.path, $0) })
        var discovered: [PrintFileItem] = []
        var seen = Set<String>()
        for source in sources {
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: source.path, isDirectory: &directory) else {
                // 刷新时保留缺失条目，让打印前检查提示缺失，而不是悄悄移除。
                continue
            }
            let urls: [URL]
            if directory.boolValue {
                var enumerationError: Error?
                guard let enumerator = manager.enumerator(
                    at: source, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, error in enumerationError = error; return false }
                ) else { throw ScannerError.inaccessible }
                urls = enumerator.allObjects as? [URL] ?? []
                if let enumerationError { throw enumerationError }
            } else {
                urls = [source]
            }
            for url in urls.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
                let path = url.standardizedFileURL.path
                let ext = url.pathExtension.lowercased()
                guard enabledTypes.contains(ext), SupportedFileType(rawValue: ext) != nil, !seen.contains(path) else { continue }
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true else { continue }
                seen.insert(path)
                let old = previous[path]
                discovered.append(PrintFileItem(
                    id: old?.id ?? UUID(), url: url, fileName: url.lastPathComponent,
                    fileExtension: ext, fileSize: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate,
                    sourceFolder: old?.sourceFolder ?? (directory.boolValue ? source : source.deletingLastPathComponent()),
                    isSelected: old?.isSelected ?? true, status: old?.status ?? .queued
                ))
            }
        }
        let updated = Dictionary(uniqueKeysWithValues: discovered.map { ($0.url.standardizedFileURL.path, $0) })
        let retained = previousItems.compactMap { old -> PrintFileItem? in
            guard enabledTypes.contains(old.fileExtension) else { return nil }
            if let item = updated[old.url.standardizedFileURL.path] { return item }
            return manager.fileExists(atPath: old.url.path) ? nil : old
        }
        return retained + discovered.filter { previous[$0.url.standardizedFileURL.path] == nil }
    }
}
