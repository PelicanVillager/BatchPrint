import SwiftUI

struct FileListView: View {
    @Binding var files: [PrintFileItem]
    @Binding var selectedIDs: Set<UUID>
    let missingIDs: Set<UUID>
    let onMove: (IndexSet, Int) -> Void
    @State private var draggedItem: PrintFileItem?
    @State private var showsHierarchy = true
    @State private var collapsedFolders: Set<String> = []

    private var rows: [FileListEntry] {
        FileListEntry.rows(files: files, hierarchy: showsHierarchy, collapsed: collapsedFolders)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("待打印文件").font(.headline)
                Spacer()
                Text("\(files.filter(\.isSelected).count)/\(files.count) 已勾选")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            HStack {
                Picker("显示方式", selection: $showsHierarchy) {
                    Text("文件夹层级").tag(true)
                    Text("打印顺序").tag(false)
                }
                .pickerStyle(.segmented)
                Button { moveHighlighted(up: true) } label: { Image(systemName: "arrow.up") }
                    .disabled(!canMoveHighlighted(up: true))
                    .help("将高亮文件上移一位")
                Button { moveHighlighted(up: false) } label: { Image(systemName: "arrow.down") }
                    .disabled(!canMoveHighlighted(up: false))
                    .help("将高亮文件下移一位")
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            Text("按序号打印；切换到打印顺序可拖动排序，或选中行后用箭头调整。")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.bottom, 8)

            if files.isEmpty {
                ContentUnavailableView("暂无文件", systemImage: "doc.on.doc",
                    description: Text("导入文件夹及其子文件夹，或单独导入文件。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedIDs) {
                    ForEach(rows) { entry in
                        if let folder = entry.folderURL {
                            Button {
                                if collapsedFolders.contains(entry.id) { collapsedFolders.remove(entry.id) }
                                else { collapsedFolders.insert(entry.id) }
                            } label: {
                                HStack {
                                    Image(systemName: collapsedFolders.contains(entry.id) ? "chevron.right" : "chevron.down")
                                        .frame(width: 12)
                                    Image(systemName: "folder.fill").foregroundStyle(.yellow)
                                    Text(folder.lastPathComponent).fontWeight(.medium)
                                }
                                .padding(.leading, CGFloat(entry.depth) * 18)
                            }
                            .buttonStyle(.plain)
                            .help(folder.path)
                        } else if let id = entry.fileID, let index = files.firstIndex(where: { $0.id == id }) {
                            FileRow(file: $files[index], isMissing: missingIDs.contains(id),
                                    sequence: index + 1, showsPath: !showsHierarchy)
                                .padding(.leading, CGFloat(entry.depth) * 18)
                                .tag(id)
                                .onDrag {
                                    guard !showsHierarchy else { return NSItemProvider() }
                                    draggedItem = files[index]
                                    return NSItemProvider(object: id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: FileDropDelegate(
                                    target: files[index], files: $files, draggedItem: $draggedItem,
                                    isEnabled: !showsHierarchy))
                                .contextMenu {
                                    Button("上移") { moveOne(id, up: true) }.disabled(index == 0)
                                    Button("下移") { moveOne(id, up: false) }.disabled(index == files.count - 1)
                                    Button("在 Finder 中显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([files[index].url])
                                    }
                                }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func canMoveHighlighted(up: Bool) -> Bool {
        let indices = files.indices.filter { selectedIDs.contains(files[$0].id) }
        guard let first = indices.first, let last = indices.last else { return false }
        return up ? first > 0 : last < files.count - 1
    }

    private func moveHighlighted(up: Bool) {
        guard canMoveHighlighted(up: up) else { return }
        let ids = files.filter { selectedIDs.contains($0.id) }.map(\.id)
        for id in up ? ids : ids.reversed() { moveOne(id, up: up) }
    }

    private func moveOne(_ id: UUID, up: Bool) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        guard up ? index > 0 : index < files.count - 1 else { return }
        onMove(IndexSet(integer: index), up ? index - 1 : index + 2)
    }
}

/// 目录视图按真实父目录组织；文件序号始终来自打印队列。
struct FileListEntry: Identifiable {
    let id: String
    let folderURL: URL?
    let fileID: UUID?
    let depth: Int

    static func rows(files: [PrintFileItem], hierarchy: Bool, collapsed: Set<String>) -> [FileListEntry] {
        guard hierarchy else {
            return files.map { FileListEntry(id: $0.id.uuidString, folderURL: nil, fileID: $0.id, depth: 0) }
        }
        let roots = Set(files.map { ($0.sourceFolder ?? $0.url.deletingLastPathComponent()).standardizedFileURL })
            .sorted { $0.pathComponents.count < $1.pathComponents.count }
        var children: [String: [FileListEntry]] = [:]
        var folders = Set<String>()
        for file in files {
            let parent = file.url.deletingLastPathComponent().standardizedFileURL
            let root = roots.first { parent.path == $0.path || parent.path.hasPrefix($0.path + "/") } ?? parent
            var chain = [parent]
            while let current = chain.last, current.path != root.path, current.path != "/" {
                chain.append(current.deletingLastPathComponent())
            }
            // 非包含关系时使用实际父目录，避免生成无关祖先。
            if chain.last?.path != root.path { chain = [parent] }
            var parentKey = ""
            for (depth, folder) in chain.reversed().enumerated() {
                let key = folder.path
                if folders.insert(key).inserted {
                    children[parentKey, default: []].append(FileListEntry(id: key, folderURL: folder, fileID: nil, depth: depth))
                }
                parentKey = key
            }
            children[parentKey, default: []].append(FileListEntry(id: file.id.uuidString, folderURL: nil, fileID: file.id, depth: chain.count))
        }
        var result: [FileListEntry] = []
        func appendChildren(_ key: String, depth: Int) {
            for entry in children[key] ?? [] {
                result.append(FileListEntry(id: entry.id, folderURL: entry.folderURL, fileID: entry.fileID, depth: depth))
                if entry.folderURL != nil, !collapsed.contains(entry.id) { appendChildren(entry.id, depth: depth + 1) }
            }
        }
        appendChildren("", depth: 0)
        return result
    }
}

private struct FileDropDelegate: DropDelegate {
    let target: PrintFileItem
    @Binding var files: [PrintFileItem]
    @Binding var draggedItem: PrintFileItem?

    let isEnabled: Bool

    func dropEntered(info: DropInfo) {
        guard isEnabled, let draggedItem else { return }
        guard draggedItem.id != target.id else { return }
        guard
            let from = files.firstIndex(where: { $0.id == draggedItem.id }),
            let to = files.firstIndex(where: { $0.id == target.id })
        else {
            return
        }

        withAnimation {
            files.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isEnabled else { return false }
        draggedItem = nil
        return true
    }
}

private struct FileRow: View {
    @Binding var file: PrintFileItem
    let isMissing: Bool
    let sequence: Int
    let showsPath: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(sequence)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 24)
            Toggle("", isOn: $file.isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Image(systemName: file.type?.systemImageName ?? "doc")
                .foregroundStyle(file.type?.isImage == true ? .purple : .blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if showsPath {
                    Text(file.url.deletingLastPathComponent().path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Text(file.fileSizeText)
                    Text(file.modifiedAtText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(status: file.status)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 3)
        .listRowBackground(
            isMissing ? Color.red.opacity(0.16) : Color.clear
        )
    }
}

struct StatusBadge: View {
    let status: PrintJobStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            Text(status.title)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
    }

    private var iconName: String {
        switch status {
        case .queued: "clock"
        case .printing: "printer"
        case .success: "checkmark.circle"
        case .failed: "xmark.circle"
        case .skipped: "forward.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .queued: .secondary
        case .printing: .blue
        case .success: .green
        case .failed: .red
        case .skipped: .orange
        }
    }
}
