import SwiftUI

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case dateDescending
    case dateAscending
    case nameAscending
    case sizeDescending

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateDescending: return String(localized: "时间（最近）")
        case .dateAscending:  return String(localized: "时间（最早）")
        case .nameAscending:  return String(localized: "名称（A→Z）")
        case .sizeDescending: return String(localized: "体积（大→小）")
        }
    }
}

struct LibraryScreen: View {
    @ObservedObject var store: ReceivedFileCacheStore
    let onShare: (URL) -> Void
    let onPreview: (URL) -> Void

    @State private var searchText = ""
    @State private var sortOption: LibrarySortOption = .dateDescending
    @State private var renameTarget: CachedReceivedFile?
    @State private var renameText: String = ""
    @State private var deleteTarget: CachedReceivedFile?
    @State private var isMultiSelect: Bool = false
    @State private var selectedIDs: Set<String> = []
    @State private var bulkDeleteConfirm = false
    @State private var saveToast: SaveToast?
    @State private var detailTarget: CachedReceivedFile?

    private var filteredFiles: [CachedReceivedFile] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [CachedReceivedFile]
        if trimmed.isEmpty {
            base = store.cachedFiles
        } else {
            base = store.cachedFiles.filter { file in
                file.displayName.localizedCaseInsensitiveContains(trimmed)
                    || file.fileName.localizedCaseInsensitiveContains(trimmed)
            }
        }
        return sorted(base)
    }

    private func sorted(_ files: [CachedReceivedFile]) -> [CachedReceivedFile] {
        switch sortOption {
        case .dateDescending: return files.sorted { $0.receivedAt > $1.receivedAt }
        case .dateAscending:  return files.sorted { $0.receivedAt < $1.receivedAt }
        case .nameAscending:  return files.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        case .sizeDescending: return files.sorted { $0.fileSize > $1.fileSize }
        }
    }

    var body: some View {
        content
            .modifier(LibraryAlertsModifier(
                renameTarget: $renameTarget,
                renameText: $renameText,
                deleteTarget: $deleteTarget,
                bulkDeleteConfirm: $bulkDeleteConfirm,
                selectedCount: selectedIDs.count,
                onCommitRename: commitRename,
                onCommitSingleDelete: commitSingleDelete,
                onCommitBulkDelete: commitBulkDelete
            ))
    }

    private var content: some View {
        Group {
            if store.cachedFiles.isEmpty {
                EmptyStateView()
            } else {
                fileList
            }
        }
        .overlay(alignment: .top) {
            if let toast = saveToast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.spring(duration: 0.3), value: saveToast?.id)
        .navigationTitle("我的文件")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: Binding(
            get: { detailTarget != nil },
            set: { if !$0 { detailTarget = nil } }
        )) {
            if let target = detailTarget {
                FileDetailScreen(
                    store: store,
                    initialFile: target,
                    onShare: onShare,
                    onPreview: onPreview
                )
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索文件名")
        .toolbar { toolbarContent }
        .refreshable {
            store.refresh(cleanup: false)
        }
        .onChange(of: store.feedback) { feedback in
            guard let feedback, feedback.source == .delete else { return }
            presentToast(SaveToast(message: feedback.message, style: .failure))
            store.clearFeedback()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(isMultiSelect ? "完成" : "选择") {
                withAnimation {
                    isMultiSelect.toggle()
                    if !isMultiSelect { selectedIDs.removeAll() }
                }
            }
            .disabled(store.cachedFiles.isEmpty)
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("排序方式", selection: $sortOption) {
                    ForEach(LibrarySortOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("排序方式")
        }

        if isMultiSelect {
            ToolbarItemGroup(placement: .bottomBar) {
                Text(selectedIDs.isEmpty ? "未选择" : "已选 \(selectedIDs.count) 项")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    bulkDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除所选文件")
                .disabled(selectedIDs.isEmpty)
            }
        }
    }

    private var fileList: some View {
        List {
            Section {
                ForEach(filteredFiles) { file in
                    Button {
                        handleTap(file)
                    } label: {
                        LibraryRow(
                            file: file,
                            isSelecting: isMultiSelect,
                            isSelected: selectedIDs.contains(file.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(isMultiSelect ? "轻点切换选中" : "轻点预览文件")
                    .accessibilityAddTraits(isMultiSelect && selectedIDs.contains(file.id) ? [.isSelected] : [])
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTarget = file
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            beginRename(file)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(.indigo)
                        Button {
                            onShare(file.url)
                        } label: {
                            Label("分享", systemImage: "square.and.arrow.up")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        if PhotoLibrarySaver.canSave(extension: file.fileExtension) {
                            Button {
                                Task { await saveImageToPhotos(file) }
                            } label: {
                                Label("存到相册", systemImage: "photo.on.rectangle")
                            }
                            .tint(.pink)
                        }
                    }
                    .contextMenu {
                        Button {
                            detailTarget = file
                        } label: { Label("详情", systemImage: "info.circle") }
                        Button {
                            onPreview(file.url)
                        } label: { Label("预览", systemImage: "eye") }
                        Button {
                            onShare(file.url)
                        } label: { Label("分享", systemImage: "square.and.arrow.up") }
                        if PhotoLibrarySaver.canSave(extension: file.fileExtension) {
                            Button {
                                Task { await saveImageToPhotos(file) }
                            } label: { Label("存到相册", systemImage: "photo.on.rectangle") }
                        }
                        Button {
                            beginRename(file)
                        } label: { Label("重命名", systemImage: "pencil") }
                        Button(role: .destructive) {
                            deleteTarget = file
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
            } header: {
                if !store.cachedFiles.isEmpty {
                    Text(store.cacheSummary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func handleTap(_ file: CachedReceivedFile) {
        if isMultiSelect {
            toggleSelection(for: file.id)
        } else {
            onPreview(file.url)
        }
    }

    private func toggleSelection(for id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func beginRename(_ file: CachedReceivedFile) {
        renameTarget = file
        renameText = file.displayName
    }

    private func commitRename() {
        defer { renameTarget = nil }
        guard let file = renameTarget else { return }
        store.rename(file: file, to: renameText)
    }

    private func commitSingleDelete() {
        defer { deleteTarget = nil }
        guard let file = deleteTarget else { return }
        store.deleteFiles(ids: [file.id])
    }

    private func commitBulkDelete() {
        store.deleteFiles(ids: selectedIDs)
        selectedIDs.removeAll()
        isMultiSelect = false
    }

    @MainActor
    private func saveImageToPhotos(_ file: CachedReceivedFile) async {
        do {
            try await PhotoLibrarySaver.save(fileURL: file.url)
            presentToast(SaveToast(message: String(localized: "已保存到相册"), style: .success))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(localized: "保存失败")
            presentToast(SaveToast(message: message, style: .failure))
        }
    }

    @MainActor
    private func presentToast(_ toast: SaveToast) {
        saveToast = toast
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run {
                if saveToast?.id == toast.id {
                    saveToast = nil
                }
            }
        }
    }
}

struct SaveToast: Identifiable, Equatable {
    enum Style { case success, failure }
    let id = UUID()
    let message: String
    let style: Style
}

private struct ToastView: View {
    let toast: SaveToast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.style == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(toast.style == .success ? Color.green : Color.orange)
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 24)
    }
}

private struct LibraryRow: View {
    let file: CachedReceivedFile
    let isSelecting: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
            }
            FileThumbnailView(
                url: file.url,
                cacheKey: "row-\(file.fileName)-\(file.modifiedAt.timeIntervalSince1970)"
            )
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text("\(file.sizeDescription) · \(file.receivedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有接收到文件")
                .font(.headline)
            Text("切换到「扫码」标签，对准发送端动画码即可开始接收")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("发送端：在对方设备浏览器打开 cimbar.org")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LibraryAlertsModifier: ViewModifier {
    @Binding var renameTarget: CachedReceivedFile?
    @Binding var renameText: String
    @Binding var deleteTarget: CachedReceivedFile?
    @Binding var bulkDeleteConfirm: Bool
    let selectedCount: Int
    let onCommitRename: () -> Void
    let onCommitSingleDelete: () -> Void
    let onCommitBulkDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("重命名", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("文件名", text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存", action: onCommitRename)
                Button("取消", role: .cancel) { renameTarget = nil }
            } message: {
                Text("将同步重命名磁盘上的文件，分享与「文件」App 中一致；扩展名保持不变")
            }
            .alert("删除文件", isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            )) {
                Button("删除", role: .destructive, action: onCommitSingleDelete)
                Button("取消", role: .cancel) { deleteTarget = nil }
            } message: {
                if let target = deleteTarget {
                    Text("将删除「\(target.displayName)」，无法恢复。")
                }
            }
            .confirmationDialog("删除所选文件？", isPresented: $bulkDeleteConfirm, titleVisibility: .visible) {
                Button("删除 \(selectedCount) 个", role: .destructive, action: onCommitBulkDelete)
                Button("取消", role: .cancel) {}
            }
    }
}
