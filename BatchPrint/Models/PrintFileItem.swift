import Foundation

struct PrintFileItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let fileName: String
    let fileExtension: String
    let fileSize: Int64
    let modifiedAt: Date?
    let sourceFolder: URL?
    var isSelected: Bool
    var status: PrintJobStatus

    init(
        id: UUID = UUID(),
        url: URL,
        fileName: String,
        fileExtension: String,
        fileSize: Int64,
        modifiedAt: Date?,
        sourceFolder: URL? = nil,
        isSelected: Bool = true,
        status: PrintJobStatus = .queued
    ) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.sourceFolder = sourceFolder
        self.isSelected = isSelected
        self.status = status
    }

    var type: SupportedFileType? {
        SupportedFileType(rawValue: fileExtension.lowercased())
    }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var modifiedAtText: String {
        guard let modifiedAt else { return "未知" }
        return modifiedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
