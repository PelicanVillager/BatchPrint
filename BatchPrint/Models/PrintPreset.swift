import Foundation

enum PaperSize: String, CaseIterable, Codable, Identifiable {
    case a4
    case letter
    case a3
    case legal
    case b5
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: "A4"
        case .letter: "Letter"
        case .a3: "A3"
        case .legal: "Legal"
        case .b5: "B5"
        case .custom: "自定义"
        }
    }
}

enum DuplexMode: String, CaseIterable, Codable, Identifiable {
    case none
    case longEdge
    case shortEdge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "单面"
        case .longEdge: "双面（长边翻转）"
        case .shortEdge: "双面（短边翻转）"
        }
    }
}

enum ColorMode: String, CaseIterable, Codable, Identifiable {
    case color
    case monochrome
    case grayscale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .color: "彩色"
        case .monochrome: "黑白"
        case .grayscale: "灰度"
        }
    }
}

enum ScalingMode: String, CaseIterable, Codable, Identifiable {
    case fit
    case percentage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: "适合页面"
        case .percentage: "按百分比缩放"
        }
    }
}

enum Orientation: String, CaseIterable, Codable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait: "纵向"
        case .landscape: "横向"
        }
    }
}

struct PageRange: Equatable, Codable {
    var isAllPages = true
    var customText = ""
}

struct PrintPreset: Codable, Equatable {
    var printerName: String?
    var pageRange = PageRange()
    var copies = 1
    var duplex = DuplexMode.none
    var colorMode = ColorMode.color
    var paperSize = PaperSize.a4
    var customPaperWidthMM = 210.0
    var customPaperHeightMM = 297.0
    var scaling = ScalingMode.fit
    var scalePercentage = 100.0
    var orientation = Orientation.portrait
    /// 整批重复的批次数：1 表示只打一遍，3 表示“把选中的文件整套打完，再整套打两遍”。
    var rounds = 1
    /// 每批之间的间隔秒数，留给人工取纸、装订的时间。
    var roundDelaySeconds = 0.0
    var enabledTypes = Set(SupportedFileType.allCases.map(\.rawValue))

    init() {}

    /// 手写解码：新版本新增了批次相关的字段，旧存档里没有这些键，
    /// 用 `decodeIfPresent` 兜底，避免升级后把用户之前保存的设置全部丢掉。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        printerName = try container.decodeIfPresent(String.self, forKey: .printerName)
        pageRange = try container.decodeIfPresent(PageRange.self, forKey: .pageRange) ?? PageRange()
        copies = try container.decodeIfPresent(Int.self, forKey: .copies) ?? 1
        duplex = try container.decodeIfPresent(DuplexMode.self, forKey: .duplex) ?? .none
        colorMode = try container.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? .color
        paperSize = try container.decodeIfPresent(PaperSize.self, forKey: .paperSize) ?? .a4
        customPaperWidthMM = try container.decodeIfPresent(Double.self, forKey: .customPaperWidthMM) ?? 210.0
        customPaperHeightMM = try container.decodeIfPresent(Double.self, forKey: .customPaperHeightMM) ?? 297.0
        scaling = try container.decodeIfPresent(ScalingMode.self, forKey: .scaling) ?? .fit
        scalePercentage = try container.decodeIfPresent(Double.self, forKey: .scalePercentage) ?? 100.0
        orientation = try container.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .portrait
        rounds = try container.decodeIfPresent(Int.self, forKey: .rounds) ?? 1
        roundDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .roundDelaySeconds) ?? 0.0
        enabledTypes = try container.decodeIfPresent(Set<String>.self, forKey: .enabledTypes)
            ?? Set(SupportedFileType.allCases.map(\.rawValue))
    }

    /// 合法的批次数，至少 1 批。
    var normalizedRounds: Int {
        min(max(rounds, 1), 99)
    }

    /// 合法的批次间隔（秒）。
    var normalizedRoundDelaySeconds: Double {
        min(max(roundDelaySeconds, 0), 3600)
    }
}
