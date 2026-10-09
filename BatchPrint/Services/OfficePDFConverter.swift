import Foundation
import CoreText
import PDFKit

enum OfficePDFConverter {
    static func convertToPDF(sourceURL: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            guard let sofficeURL = libreOfficeExecutable() else {
                throw PrintRunnerError.officeConversionFailed(
                    "未找到 LibreOffice/OpenOffice。可安装 LibreOffice，或设置 BATCHPRINT_SOFFICE_PATH。"
                )
            }

            let outputDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BatchPrint-\(UUID().uuidString)", isDirectory: true)
            let profileDirectory = outputDirectory.appendingPathComponent("profile", isDirectory: true)
            let fontCacheDirectory = outputDirectory.appendingPathComponent("fontcache", isDirectory: true)
            try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: fontCacheDirectory, withIntermediateDirectories: true)

            let fontConfigurationURL = outputDirectory.appendingPathComponent("fonts.conf")
            let homeFontDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Fonts", isDirectory: true)
            // 先用已安装的原字体；只有缺少原字体时才加入后备字体。
            let fontConfiguration = fontConfigurationXML(
                homeFontDirectory: homeFontDirectory, cacheDirectory: fontCacheDirectory
            )
            try fontConfiguration.write(
                to: fontConfigurationURL,
                atomically: true,
                encoding: .utf8
            )

            let process = Process()
            process.executableURL = sofficeURL
            process.arguments = [
                "-env:UserInstallation=\(profileDirectory.absoluteString)",
                "--headless",
                "--convert-to",
                "pdf",
                "--outdir",
                outputDirectory.path,
                sourceURL.path
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["FONTCONFIG_FILE"] = fontConfigurationURL.path
            environment["XDG_CACHE_HOME"] = outputDirectory.path
            process.environment = environment

            let logURL = outputDirectory.appendingPathComponent("conversion.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let logHandle = try FileHandle(forWritingTo: logURL)
            defer { try? logHandle.close() }
            process.standardOutput = logHandle
            process.standardError = logHandle
            var succeeded = false
            defer { if !succeeded { try? FileManager.default.removeItem(at: outputDirectory) } }

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorData = (try? Data(contentsOf: logURL)) ?? Data()
                let message = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
                throw PrintRunnerError.officeConversionFailed(message)
            }

            let expectedName = sourceURL.deletingPathExtension().lastPathComponent + ".pdf"
            let expectedURL = outputDirectory.appendingPathComponent(expectedName)
            guard let document = PDFDocument(url: expectedURL), document.pageCount > 0 else {
                throw PrintRunnerError.officeConversionFailed("未生成有效 PDF，请检查文档是否损坏或受密码保护。")
            }
            succeeded = true
            return expectedURL
        }.value
    }

    static func fontConfigurationXML(homeFontDirectory: URL, cacheDirectory: URL) -> String {
        var families = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        // 新装的字体可能尚未被 CoreText 注册，直接读取字体文件的真实 family 名称。
        for directory in [URL(fileURLWithPath: "/Library/Fonts"), homeFontDirectory] {
            if let urls = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let url as URL in urls where ["ttf", "otf", "ttc", "dfont"].contains(url.pathExtension.lowercased()) {
                    if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                        for descriptor in descriptors {
                            if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String {
                                families.append(family)
                            }
                        }
                    }
                }
            }
        }
        let groups: [(aliases: [String], candidates: [String], fallback: String)] = [
            (["宋体", "SimSun", "NSimSun"], ["宋体", "SimSun", "宋体-简", "Songti SC"], "Songti SC"),
            (["仿宋", "仿宋_GB2312", "FangSong", "FangSong_GB2312"], ["仿宋", "仿宋_GB2312", "FangSong", "FangSong_GB2312", "STFangsong"], "Songti SC"),
            (["楷体", "楷体_GB2312", "KaiTi", "KaiTi_GB2312"], ["楷体", "楷体_GB2312", "KaiTi", "KaiTi_GB2312", "楷体-简", "Kaiti SC"], "Kaiti SC"),
            (["方正小标宋简体", "方正小标宋", "FZXiaoBiaoSong-B05S"], ["方正小标宋简体", "方正小标宋", "方正简体小标宋", "FZXiaoBiaoSong-B05S"], "Songti SC"),
            (["黑体", "SimHei"], ["黑体", "SimHei", "黑体-简", "Heiti SC"], "Heiti SC")
        ]
        var rules: [String] = []
        for group in groups {
            let target = group.candidates.compactMap { candidate in
                families.first { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            }.first ?? group.fallback
            for alias in group.aliases {
                // 不覆盖已经安装的同名字体。
                guard !families.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) else { continue }
                rules.append("<alias binding=\"strong\"><family>\(xmlEscaped(alias))</family><prefer><family>\(xmlEscaped(target))</family></prefer></alias>")
            }
        }
        let directories = ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts", homeFontDirectory.path]
        return """
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
        <fontconfig>
        \(directories.map { "<dir>\(xmlEscaped($0))</dir>" }.joined(separator: "\n"))
        <cachedir>\(xmlEscaped(cacheDirectory.path))</cachedir>
        \(rules.joined(separator: "\n"))
        </fontconfig>
        """
    }

    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func libreOfficeExecutable() -> URL? {
        var candidates: [URL] = []

        if let configured = ProcessInfo.processInfo.environment["BATCHPRINT_SOFFICE_PATH"],
           !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(URL(fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice"))
        candidates.append(URL(fileURLWithPath: "/Applications/OpenOffice.app/Contents/MacOS/soffice"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/soffice"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/soffice"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/soffice"))

        candidates.append(
            home.appendingPathComponent(
                ".cache/codex-runtimes/codex-primary-runtime/dependencies/native/libreoffice-headless/libreoffice/LibreOfficeDev.app/Contents/MacOS/soffice"
            )
        )

        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}
